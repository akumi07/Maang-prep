## HLD problems II | P3 | must

### Distributed cache (design Redis/Memcached as a service)

#### Clarifying questions to ask
- *API?* → get, set (with TTL), delete; maybe atomic incr.
- *Scale?* → e.g. 10TB of hot data, 5M ops/s, sub-millisecond p99 within a datacentre.
- *Consistency?* → Cache semantics: eventual is fine; occasional loss is acceptable (the source of truth is elsewhere).
- *Eviction?* → LRU/LFU when memory is full; TTL expiry.
- *Multi-region?* → Per-region clusters.

#### Requirements
- **Functional**: get/set/delete with TTL; eviction; cluster membership changes without downtime.
- **Non-functional**: very low latency, horizontal scalability, high availability (a node loss means only a partial miss rate increase), even load distribution.

#### Estimation
- 10TB ÷ ~64GB usable per node ≈ **160 nodes** (plus replicas).
- 5M ops/s ÷ ~100K ops/s per node ≈ 50 nodes for throughput, so memory dominates sizing.

#### API
```
GET key → value | miss          SET key value [EX seconds] [NX|XX]
DEL key                          INCRBY key n
```

#### Data model
```
Per node: hash table (key → entry{value, expiresAt, LRU/LFU metadata}) with slab/arena allocation
Cluster: hash slots (e.g. 16384) or consistent hash ring with vnodes → node assignment, stored in config service
```

#### High-level design
```
App servers (smart client library: slot map cached, connection pools, routing by key)
     │
     ▼ direct to owner node
Cache nodes (primary + replica per shard, across AZs)
     ▲
Config/cluster manager (etcd/ZooKeeper): membership, slot→node map, failover decisions
```

#### Deep dives
**Partitioning**: consistent hashing with virtual nodes, or fixed hash slots (Redis Cluster) assigned to nodes, so adding a node moves only some slots. A smart client caches the map and handles MOVED redirects (or a proxy layer such as Twemproxy or Envoy handles routing for simple clients).

**Node internals**: an in-memory hash table; a single-threaded event loop (Redis) or multi-threaded with striped locks (Memcached); a slab allocator to limit fragmentation; eviction via approximated LRU (sample N keys, evict the oldest) or LFU; TTL expiry lazy plus active sampling.

**Replication and failover**: async primary → replica; the cluster manager detects failures (gossip or heartbeats) and promotes replicas. Writes acknowledged just before a failure may be lost, which is acceptable for a cache.

**Hot keys**: detect them with sampling; replicate hot keys to several nodes and read randomly; a client-side L1 cache with short TTLs.

**Thundering herd on node loss**: when a node dies, its keys miss and the DB load spikes. Mitigations: replicas, request coalescing in clients, rate limiting toward the DB, warm-up.

**Facebook's memcache lessons**: leases (prevent stale sets and thundering herds), regional pools, invalidation via MySQL commit-log tailing (mcsqueal), a "gutter" pool to absorb a failed node's traffic.

#### Bottlenecks, failures and trade-offs
- Network bandwidth for large values: compress values, keep them small (< 100KB).
- Rebalancing load: move slots gradually; copy data before switching ownership.
- Consistency with the DB: the cache isn't the source of truth; invalidation strategy is the application's responsibility (see Redis cache invalidation).

#### Follow-up questions
?? What happens when a cache node fails?
Its replica is promoted within seconds (clients refresh their slot map). Without replicas, its keys become misses served from the DB until repopulated, so protect the DB with request coalescing and rate limiting. Consistent hashing ensures only that node's share of keys is affected.

?? How do you add capacity during a sale without a miss storm?
Add nodes and migrate slots gradually, copying the keys for each slot before switching ownership (Redis Cluster migrates key by key with ASK redirects), so reads keep hitting during the move. Pre-scale before the event rather than during peak.

#### Interview simulation
Clarify the API, scale and consistency. Draw clients with slot maps → sharded primaries and replicas → a cluster manager. Deep-dive on **partitioning (slots or vnodes)**, **eviction and expiry internals**, **failover**, and **hot keys**. Mention Facebook's memcache paper for the herd and invalidation problems. It's essentially "Redis Cluster explained", so use your Redis knowledge.

### Payment system

#### Clarifying questions to ask
- *Scope?* → A payment service for an e-commerce platform: accept payments via cards/UPI/wallets through external PSPs (Razorpay, Stripe, Adyen), refunds, payouts to sellers? (Pick payins plus refunds first.)
- *Scale?* → e.g. 1M payments/day, peaking at 500/s during sales.
- *Consistency?* → No double charges, no lost payments; every rupee accounted for.
- *Do we store card data?* → No: PCI scope minimised via PSP tokenisation and hosted fields.
- *Reconciliation with PSPs and banks?* → Yes, daily.

#### Requirements
- **Functional**: create a payment for an order; redirect or SDK flow to the PSP; handle async status (webhooks); refunds (full and partial); a ledger of all money movements; reconciliation.
- **Non-functional**: correctness above all (exactly-once effects), auditability, high availability, security (PCI DSS), idempotency everywhere.

#### Estimation
- 1M/day ≈ 12/s average, 500/s peak: modest throughput. **The difficulty is correctness, not scale.**
- Ledger entries: about 4–6 per payment (double entry) → ~6M rows/day.

#### API
```
POST /v1/payments {orderId, amount, currency, method, idempotencyKey} → 201 {paymentId, status: CREATED, pspClientData}
GET  /v1/payments/{id} → {status}
POST /v1/payments/{id}/refunds {amount, idempotencyKey}
POST /v1/webhooks/{psp}   (signed; async status updates)
```

#### Data model
```
payments(id, order_id, amount_minor, currency, method, status, psp, psp_payment_id, idempotency_key UNIQUE, version, created_at)
payment_attempts(id, payment_id, psp, request, response, status, created_at)          — every external call logged
refunds(id, payment_id, amount_minor, status, psp_refund_id, idempotency_key UNIQUE)
ledger_entries(id, txn_id, account, debit_minor, credit_minor, currency, created_at)   — append-only, double entry
webhook_events(psp_event_id UNIQUE, payload, processed_at)
outbox(...) for PaymentSucceeded/Failed events
```
Use a **relational DB** (Postgres/MySQL): ACID, constraints and auditability matter more than scale.

#### High-level design
```
Checkout → Payment API (idempotency) → Payment service ─▶ PSP adapter (Razorpay/Stripe/…; circuit breakers, timeouts)
                                            │                    │ redirect/SDK (3DS/UPI collect) handled client-side via PSP
                                            ▼                    ▼
                                 Payments DB + Ledger       PSP webhooks → Webhook handler (verify signature, dedupe, state machine)
                                            │
                                 Outbox → Kafka "payment-events" → Order service (confirm order), Notifications, Analytics
Reconciliation job (daily): PSP settlement files vs our ledger → mismatches → alerts / auto-fix workflows
```

#### Deep dives
**Payment state machine**: CREATED → PENDING (sent to the PSP) → AUTHORIZED → CAPTURED (SUCCEEDED) | FAILED | EXPIRED; then REFUND_PENDING → REFUNDED (partial or full). Only valid transitions apply (a conditional update `WHERE status = :from`), so out-of-order webhooks can't regress the state.

**Idempotency at every hop**
- Client → us: the `Idempotency-Key` on create and refund (a unique constraint plus the stored response).
- Us → PSP: pass our payment id as the PSP's idempotency key or reference, so retries don't double-charge.
- PSP → us: webhooks deduped by the PSP event id; processing is a state transition (idempotent).
- Us → downstream: outbox events with ids; consumers dedupe.

**Handling unknown outcomes**: a timeout when calling the PSP means we **don't know** whether the charge happened. Never blindly retry with a new reference. Mark the payment PENDING and query the PSP's status by our reference (with polling or backoff), and rely on the webhook. That's the most important payments insight.

**Double-entry ledger**: every money movement is recorded as balanced entries (debits = credits). For example, on capture: debit `PSP_RECEIVABLE`, credit `MERCHANT_PAYABLE` (minus fees: credit `REVENUE_FEES`). Balances are derived from immutable entries, which gives auditability and catches bugs (anything unbalanced is a red alert).

**Reconciliation**: daily, compare the PSP settlement reports with our payments and ledger: missing at our end (a webhook was lost: fix the state), missing at the PSP (never happened: fail it), amount mismatches (alert). A **safety net** for every gap in real-time processing.

**Security and compliance**: never store raw card numbers (PSP tokens, hosted fields/SDK, so our servers stay out of PCI scope); encrypt sensitive data; verify webhook signatures (HMAC) and timestamps (replay protection); least privilege; audit logs.

**Multiple PSPs**: routing by method, cost, success rate; failover when a PSP is degraded (a circuit breaker). A customer retry after a failure goes through a new attempt (perhaps with another PSP), linked to the same payment.

#### Bottlenecks, failures and trade-offs
- PSP outage: failover routing, a queue of retries, status pages; the order stays pending rather than failing silently.
- Webhook delays or loss: polling plus reconciliation.
- DB as the single source of truth: highly available with synchronous replication (no lost commits), plus backups.
- Consistency over availability: better to show "payment processing" than to risk a double charge.

#### Follow-up questions
?? How do you guarantee a customer is never charged twice?
Idempotency keys end to end: one payment record per checkout (a unique key), a single PSP reference per payment (the PSP dedupes retries), and status queries instead of blind retries after timeouts. State transitions are conditional. Daily reconciliation detects anything that slips through, with automatic refunds of duplicates.

?? The PSP's webhook says SUCCEEDED but our order service never confirmed the order. How?
The payment service updated its DB but the event to the order service was lost (dual write), or the order consumer failed. Fix: the outbox pattern for payment events, idempotent consumers with retries and DLQ, plus a reconciliation job comparing paid payments with confirmed orders.

?? Why use a double-entry ledger instead of just a balance column?
Immutability and auditability: every change is an explicit, balanced record, so you can reconstruct any balance at any time, detect errors (an unbalanced transaction), and satisfy auditors. A mutable balance column loses its history, and concurrent updates can corrupt it silently.

#### Interview simulation
Clarify the scope (payins, refunds, PSPs, no card storage) and emphasise "correctness over scale". Draw the flow including **async webhooks**. Deep-dive on the **state machine**, **idempotency at every hop**, **unknown outcomes (timeouts)**, the **ledger**, and **reconciliation**. Mention PCI scope reduction. Your Stripe integration experience makes this a strong question for you, so prepare one real story (e.g. handling duplicate webhooks).

### Ticket booking (BookMyShow / Ticketmaster)

#### Clarifying questions to ask
- *Scope?* → Browse events and shows, view the seat map, select seats, hold them while paying, confirm.
- *Scale?* → Normal days: moderate. Hot releases (a superstar's movie first-day show, a Coldplay concert): millions of users in minutes.
- *Seat selection or general admission?* → Specific seats (assigned seating).
- *Hold time?* → e.g. 8–10 minutes for payment.
- *Fairness?* → A virtual queue for very hot events.

#### Requirements
- **Functional**: search events and shows; a seat map with live-ish availability; seat holds with expiry; booking confirmation after payment; cancellations.
- **Non-functional**: **no double booking** (strong consistency for seats); handling extreme spikes; fairness; low latency for browsing (cacheable).

#### Estimation
- Normal: ~1K bookings/min. Hot event: 5M users try within 10 minutes for 50K seats, so ~**10K+ hold attempts/s** concentrated on a few shows, an extreme contention hotspot.

#### API
```
GET  /v1/events?city=…&date=…                 (cached)
GET  /v1/shows/{id}/seats                       (seat map + availability, short cache)
POST /v1/shows/{id}/holds {seatIds, idempotencyKey}  → 201 {holdId, expiresAt} | 409 seats taken
POST /v1/holds/{id}/confirm {paymentId}        → booking
DELETE /v1/holds/{id}
```

#### Data model
```
events, venues, screens, seats(seat_id, screen_id, row, number, category)
shows(show_id, event_id, screen_id, start_time)
show_seats(show_id, seat_id, status{AVAILABLE, HELD, BOOKED}, hold_id, hold_expires_at, version)  ← the contention table
holds(hold_id, user_id, show_id, seat_ids, expires_at, status)
bookings(booking_id, user_id, show_id, seat_ids, amount, payment_id, status)
```

#### High-level design
```
Users → CDN (static event pages) → API GW (rate limit, bot protection)
      → [Virtual waiting room for hot shows: queue token → admitted in batches]
      → Catalog/Search service (Elasticsearch, cached)
      → Seat service: seat map (Redis cache of show_seats bitmap) ; holds (Redis SET NX EX per seat or DB conditional update)
      → Booking service: confirm (DB transaction) ← Payment service (webhook/redirect)
      → Expiry worker (release expired holds) ; Notification service (tickets via email/SMS/WhatsApp)
```

#### Deep dives
**Preventing double booking (the core)**
- **DB approach**: one transaction does `UPDATE show_seats SET status='HELD', hold_id=:h, hold_expires_at=now()+'10 min' WHERE show_id=:s AND seat_id IN (:seats) AND (status='AVAILABLE' OR (status='HELD' AND hold_expires_at < now()))`, then checks the affected rows equal the number of seats requested, else rolls back (all-or-nothing). Row-level locking makes it correct.
- **Redis approach for hot shows**: per seat `SET seat:{show}:{seat} {holdId} NX EX 600`, via a Lua script for multiple seats (all-or-nothing). Extremely fast. Confirmed bookings are persisted in the DB (the source of truth for BOOKED) and reconciled.
- Confirmation: in a DB transaction, verify the hold is still valid and owned, set status BOOKED, create the booking, and commit. If the hold expired before the payment success, **refund automatically**.

**Handling hot launches**
- A **virtual waiting room**: users get a queue position, and are admitted in batches at the rate the booking system can handle (Ticketmaster and Queue-it do this). This protects the backend and gives fairness.
- Seat-map reads: serve availability from a Redis bitmap per show (fast), push updates over WebSocket or SSE, or poll every few seconds. Slight staleness is OK, because the hold is authoritative.
- Rate limits per user, CAPTCHAs and bot detection (scalpers).
- "Best available" auto-allocation instead of manual seat picking for the hottest events reduces contention.

**Hold expiry**: a TTL in Redis plus a sweeper for the DB rows (`WHERE status='HELD' AND hold_expires_at < now()`); also lazy checks during new hold attempts.

**Payment integration**: idempotent confirm (a payment webhook could arrive twice); payment timeouts don't book the seats unless the confirmation succeeds; reconciliation.

#### Bottlenecks, failures and trade-offs
- Contention concentrated on one show's rows: the Redis per-seat approach or a single partition per show serialises decisions; scale reads separately.
- Redis failure mid-sale: holds lost, so seats are re-sold while payment is pending? Mitigate with Redis replication plus DB confirmation checks (a booking requires the DB row to transition from HELD by that hold id, or a double check).
- Cascading load from retries: idempotency keys plus client backoff.

#### Follow-up questions
?? Two users click the same seat at the same millisecond. Walk through what happens.
Both requests try to claim it atomically (a conditional DB update, or Redis SET NX). Exactly one succeeds; the other gets 0 rows or nil and returns 409 "seat just taken", and the client refreshes the seat map. Correctness comes from the atomic conditional write, not from checking first.

?? How would you handle 5 million users arriving for 50,000 seats?
A virtual waiting room at the edge (a CDN-hosted queue page), admitting users at a controlled rate; bot protection; seat holds in Redis with all-or-nothing Lua; a pre-scaled booking service; the seat map served from cache with periodic refresh; payments with a hold TTL; clear messaging. Everyone else gets a fair "sold out" quickly instead of errors.

#### Interview simulation
Clarify the normal vs hot traffic and the hold semantics. Present the data model with `show_seats` as the contention point, then the **hold → pay → confirm** flow with expiry. Deep-dive on **atomic seat claiming** (DB vs Redis), the **expiry race with late payments**, and the **virtual waiting room**. Link to the LLD BookMyShow lesson for the in-memory version.

### Web crawler

#### Clarifying questions to ask
- *Purpose?* → A search engine index (general crawl) or a focused crawl (e-commerce prices)?
- *Scale?* → e.g. 1B pages per month.
- *Content types?* → HTML only (plus links); images and PDFs optional.
- *Freshness?* → Recrawl popular or changing pages more often.
- *Politeness?* → Respect robots.txt and per-domain rate limits.
- *Dedup?* → Skip duplicate content and URLs.

#### Requirements
- **Functional**: start from seed URLs; fetch pages; extract links; enqueue new URLs; store content for indexing; recrawl.
- **Non-functional**: scalable (billions of URLs), polite, robust (traps, malformed HTML, slow servers), extensible (new content processors).

#### Estimation
- 1B pages/month ≈ **400 pages/s** (peak ~1K/s). Average page ~100KB → 100TB/month raw (compressed ~25TB).
- URL frontier: tens of billions of discovered URLs → a disk-backed queue plus a dedup structure.

#### API
Internal pipeline (no public API): `seed(urls)`, metrics, an admin interface for priorities and blocklists.

#### Data model
```
URL frontier: prioritized queues + per-host queues (disk-backed: Kafka/RocksDB)
Seen URLs: Bloom filter (fast) + persistent store (URL hash → last crawled, next due, fingerprint)
Content store: object storage (WARC files) ; metadata DB (url, status, content_hash, fetched_at, links_out)
robots.txt cache per host ; DNS cache
```

#### High-level design
```
Seeds → URL Frontier (priority queues → host-partitioned politeness queues)
          │
     Fetcher workers (async HTTP, DNS cache, robots.txt check, per-host rate limit)
          │
     Content processor: parse HTML → extract links + text ; content fingerprint (SimHash) → dedup
          │                                     │
     Content store (S3/WARC) → Indexer          URL extractor → normalize → filter (blocklist, traps)
                                                → seen? (Bloom filter + store) → new URLs → Frontier (priority)
Recrawl scheduler: pages due for refresh (based on change frequency/importance) → Frontier
```

#### Deep dives
**URL frontier**: two levels (the Mercator design). **Front queues** by priority (PageRank-ish importance, freshness need); **back queues** per host, so each host is fetched by one worker at a polite rate (e.g. 1 request per second per host, or per robots.txt `Crawl-delay`), with a heap of "next allowed fetch time" per host. Partition the frontier by host hash across crawler nodes, so politeness state is local.

**Politeness and robots.txt**: fetch and cache `robots.txt` per host (with a TTL); respect Disallow rules; identify with a user agent; back off on 429/503.

**Deduplication**
- URL-level: normalise (lowercase host, remove fragments and default ports, sort query params, strip tracking params) → hash → Bloom filter (fast "definitely new") plus a persistent store for confirmation.
- Content-level: exact duplicates via a hash of the content; near-duplicates via **SimHash** (Google's approach), where pages within a small Hamming distance are treated as duplicates.

**Traps and robustness**: infinite URL spaces (calendars, session ids): limit depth per site, URL length, parameter combinations; timeouts and max page size; handle redirects (with a limit); HTML parsing tolerant of junk.

**Throughput**: async I/O (one worker handles thousands of concurrent fetches), DNS caching (DNS is a common bottleneck), crawlers geographically near target servers.

**Recrawl**: estimate each page's change frequency (from past fetches), and schedule more often for important or frequently changing pages (news homepages hourly, static pages monthly). Conditional GETs (`If-Modified-Since`, ETag) save bandwidth.

#### Bottlenecks, failures and trade-offs
- Frontier size (tens of billions): disk-backed queues, partitioned.
- Hot hosts with millions of URLs: the per-host queue grows, so prioritise within the host.
- Worker crashes: URLs leased from the frontier with timeouts are re-queued (at-least-once fetch; dedup makes it harmless).
- Ethics and legal: robots.txt, rate limits, terms of service, no personal data collection.

#### Follow-up questions
?? How do you avoid hammering a single website?
Per-host back queues served by one worker at a time, with a minimum delay between requests (robots.txt `Crawl-delay` or a default like 1s), adaptive backoff on errors or slow responses, and concurrency limits per IP (many domains share hosting IPs).

?? How do you detect near-duplicate pages?
Compute a SimHash fingerprint of each page's shingled text (a 64-bit hash where similar documents have similar bits); pages whose fingerprints differ in ≤ 3 bits are near-duplicates. Index the fingerprints by bit-blocks for fast lookup.

#### Interview simulation
Clarify the purpose, scale and politeness requirements. Draw the loop: **frontier → fetch → parse → dedup → frontier**, plus storage and recrawl. Deep-dive on the **frontier design (priority plus per-host politeness)**, **URL and content dedup (Bloom filter, SimHash)**, and **traps**. Mention async fetching and DNS caching for throughput.

### Metrics, logging and monitoring system

#### Clarifying questions to ask
- *Metrics, logs, or both? Traces?* → Let's say metrics (time series) plus logs; mention traces.
- *Scale?* → e.g. 10K services/hosts; 10M active time series; 1M log lines/s.
- *Query needs?* → Dashboards (last 1h–30d), alerting (every 30–60s), ad-hoc log search.
- *Retention?* → Metrics: 15 days at full resolution, 1 year downsampled. Logs: 7–30 days hot, then archive.

#### Requirements
- **Functional**: ingest metrics and logs; store them; query and aggregate (dashboards); alert on rules; search logs.
- **Non-functional**: very high write throughput, efficient storage (compression), fast recent queries, the monitoring system more available than what it monitors, no single tenant overwhelming it.

#### Estimation
- Metrics: 10M series, scraped every 15s, gives ~670K samples/s. With Gorilla compression at ~1.4 bytes per sample, that's ~80GB/day.
- Logs: 1M lines/s × 200B = 200MB/s ≈ 17TB/day raw (compressed ~2–3TB/day).

#### API
```
Metrics: Prometheus scrape (pull) or remote_write / OTLP push
Query:   PromQL GET /api/v1/query_range?query=rate(http_requests_total[5m])&start…&end…&step=30s
Logs:    agents ship via OTLP/Fluent Bit → ingestion API ; LogQL/Lucene query API
Alerts:  rules (expr, for: 5m, severity) → Alertmanager → PagerDuty/Slack
```

#### Data model
```
Time series = metric name + labels {service, instance, endpoint, status} → [(timestamp, value)]
TSDB: in-memory head block (recent 2h) + WAL → immutable compressed blocks on disk/object storage
       inverted index: label → series IDs
Logs: streams by labels (service, pod, level) → compressed chunks in object storage + small index (Loki style)
      or full-text inverted index (Elasticsearch style)
```

#### High-level design
```
Services/hosts (instrumented: Micrometer/OpenTelemetry)  ── metrics ──▶ Collectors/Agents (scrape, batch)
                                                         ── logs ────▶ Fluent Bit/Vector agents
                     ▼                                                        ▼
               Kafka (buffer, decouple ingestion spikes) ◀───────────────────┘
                     ▼                                                        ▼
       TSDB cluster (Prometheus+Thanos/Mimir/VictoriaMetrics)       Log store (Loki/Elasticsearch) + S3 archive
                     ▼                                                        ▼
         Query layer (PromQL, caching, downsampled data)         Log query service
                     ▼                                                        
         Dashboards (Grafana) ; Rule evaluator → Alertmanager (dedup, grouping, silencing, routing)
```

#### Deep dives
**Time-series storage**: writes arrive in time order per series. Batch recent samples in memory (the head block) with a WAL for durability, flush to immutable blocks every 2h, and compact them. Compression: **Gorilla** (Facebook) uses delta-of-delta encoding for timestamps and XOR encoding for float values, about 1.37 bytes per sample. An inverted index from labels to series ids serves selectors.

**Cardinality**: the number of unique label combinations. Putting `user_id` or `request_id` in metric labels explodes the series count (memory, slow queries). Enforce cardinality limits per tenant and educate: use logs or traces for high-cardinality data.

**Downsampling and retention**: raw data for 15 days; 5-minute aggregates (min, max, sum, count) for a year; old blocks in object storage (Thanos, Mimir).

**Pull vs push**: Prometheus pulls (scrape) and naturally detects down targets (`up == 0`), but needs service discovery. Push (OTLP, StatsD) suits short-lived jobs and serverless. Many systems support both.

**Logs**: structured JSON logs with a trace id; **Loki** indexes only labels and stores compressed chunks in S3 (cheap; grep-like search within a stream); **Elasticsearch** builds full-text indexes (fast, flexible search, but expensive at volume). Sampling or dropping DEBUG logs in production; PII scrubbing at the agent.

**Alerting**: rules evaluated periodically; a `for:` duration avoids flapping; Alertmanager dedupes, groups (one page for 50 pods failing), silences, and routes by severity. Prefer **SLO-based burn-rate alerts** over raw thresholds (alert when you're consuming the error budget fast).

**Self-monitoring**: the monitoring stack must be more reliable than its targets: separate infrastructure, a meta-monitoring "dead man's switch" alert (an always-firing alert whose absence pages someone).

#### Bottlenecks, failures and trade-offs
- Ingestion spikes during incidents (log volume explodes exactly when things break): a Kafka buffer, rate limiting per tenant, dropping low-priority logs.
- Query of death (a huge PromQL range over high cardinality): query limits, timeouts, caching, downsampled data.
- Storage cost: compression, tiering, retention policies.

#### Follow-up questions
?? Why shouldn't you put user IDs in metric labels?
Each unique label combination is a separate time series held in memory and indexed. Millions of users means millions of series, which blows up memory and query time (a cardinality explosion). Use logs or traces for per-user data, and metrics for aggregates.

?? How do metrics, logs and traces complement each other?
Metrics tell you **something is wrong** (cheap and aggregatable, so they drive alerts and dashboards). Traces show **where** in a request path latency or errors come from. Logs show **why**, the detailed events. They're linked by trace ids and exemplars (a metric data point linking to a sample trace).

#### Interview simulation
Clarify metrics vs logs, scale, retention and queries. Draw agents → Kafka → TSDB/log store → query → dashboards and alerting. Deep-dive on **TSDB storage and compression**, **cardinality**, **downsampling**, and **alerting design (burn-rate, grouping)**. Mention Prometheus/Thanos/Grafana/Loki/OpenTelemetry as real components. Your CloudWatch experience is a good anchor.

### Distributed job scheduler

#### Clarifying questions to ask
- *Job types?* → One-time delayed jobs (send a reminder in 2 days), recurring cron jobs, ad-hoc jobs.
- *Scale?* → e.g. 100M scheduled jobs; 10K jobs firing per second at peak.
- *Precision?* → Within a few seconds of the due time.
- *Execution?* → Jobs are callbacks or messages to other services (HTTP or queue), possibly long-running.
- *Guarantees?* → At-least-once execution; no duplicate execution ideally; retries; history.

#### Requirements
- **Functional**: create, update, cancel and list jobs; cron and one-time triggers; execution with retries, timeouts and DLQ; execution history.
- **Non-functional**: scalable to millions of jobs, highly available (no single scheduler SPOF), timely, durable, at-least-once with idempotency guidance.

#### Estimation
- 100M jobs stored × ~1KB = 100GB of metadata.
- 10K fires/s at peak, so the "find due jobs" step must be efficient and partitioned.

#### API
```
POST /v1/jobs {name, schedule: {cron | runAt}, target: {type: http|kafka, endpoint/topic, payload}, retryPolicy, timeout, idempotencyKey}
DELETE /v1/jobs/{id}      GET /v1/jobs/{id}/executions
```

#### Data model
```
jobs(job_id, owner, schedule, target, retry_policy, status, partition_id, next_run_at, version)
     index (partition_id, next_run_at) where status = ACTIVE
executions(execution_id, job_id, scheduled_for, started_at, finished_at, status, attempt, error)  UNIQUE(job_id, scheduled_for)
```

#### High-level design
```
Clients → Job API → Jobs DB (sharded by partition_id)
                         │
Scheduler nodes (each owns a set of partitions via leases in etcd/ZooKeeper)
   loop: SELECT jobs WHERE partition IN mine AND next_run_at <= now()+lookahead ORDER BY next_run_at LIMIT N FOR UPDATE SKIP LOCKED
         → insert execution (unique job_id+scheduled_for) → publish to Kafka "job-executions" → update next_run_at (cron) / mark done
                         │
Executor workers (consume Kafka; call HTTP target / publish message; timeout; retry with backoff; DLQ) → update execution status
Near-term timers: in-memory timing wheel per scheduler node for jobs due in the next few seconds (precision)
```

#### Deep dives
**Finding due jobs efficiently**: an index on `(partition, next_run_at)`, scanned by the owners of each partition. A lookahead loads jobs due in the next N seconds into an in-memory **timing wheel or heap** for precise firing. Very large scale: bucket jobs by due minute (a time-bucketed table, or a Redis ZSET per partition with the score as the due time).

**Avoiding duplicate firing**: partition ownership through leases (only one scheduler handles a partition); plus a **unique constraint on `(job_id, scheduled_for)`** in executions, so even if two schedulers race (a lease handover), only one execution row is created. Executors are at-least-once, so targets should be idempotent: pass the `execution_id` as an idempotency key.

**Scaling**: more partitions than nodes; rebalance leases when nodes join or leave; stateless executors scaled by Kafka consumer lag.

**Retries and failures**: per-job retry policy (max attempts, backoff); timeouts; DLQ plus alerting; a misfire policy for jobs missed during an outage (fire once now, or skip).

**Cron correctness**: time zones and DST (store the zone with the cron expression; compute the next run in that zone); avoid thundering herds when thousands of jobs are scheduled at 00:00 (spread with jitter if allowed).

**Real systems**: Airflow (DAG workflows), Temporal (durable workflows with timers), Quartz (a clustered JVM scheduler using DB locks), AWS EventBridge Scheduler, Kubernetes CronJobs.

#### Bottlenecks, failures and trade-offs
- The DB as the scheduling hotspot: partitioning, batching, SKIP LOCKED, time-bucketing.
- A scheduler node dies mid-batch: its lease expires, another node takes over, and the unique execution rows prevent duplicates.
- Clock skew between schedulers: use DB time or a single time source for due checks.

#### Follow-up questions
?? How do you guarantee a job runs exactly once?
You can guarantee at most one *execution record* per scheduled time (a unique constraint), and at-least-once *delivery* to the target. True exactly-once effects require the target to be idempotent: pass the execution id and let the target dedupe. Say this explicitly.

?? 1 million jobs are due at midnight. What happens?
Firing is spread across partitions and nodes; executions are enqueued to Kafka, which absorbs the burst; executors scale by lag. If precise timing isn't critical, apply a jitter window. Protect downstream targets with per-target rate limits.

#### Interview simulation
Clarify the job types, scale and guarantees. Draw API → DB → partitioned schedulers (with leases) → Kafka → executors. Deep-dive on **due-job discovery** (index, lookahead, timing wheel), **no-duplicate firing** (leases plus a unique execution key), and **retries/DLQ/idempotency**. Link to the LLD task scheduler for the single-node internals.

### E-commerce checkout and flash sale

#### Clarifying questions to ask
- *Scope?* → Cart → checkout → order placement → payment → confirmation, under normal and flash-sale load (e.g. a Big Billion Days style "₹1 phone sale" with 10K units and 5M users).
- *Inventory guarantees?* → Never oversell.
- *Payment?* → Online via a PSP; reserved stock released if payment fails or times out.
- *Fairness and limits?* → One unit per user for sale items.

#### Requirements
- **Functional**: add to cart, view price with offers, place an order, reserve inventory, pay, confirm, cancel; enforce per-user purchase limits.
- **Non-functional**: no overselling; survive 100× spikes; the checkout latency target; high availability of the order path; graceful degradation of non-critical features.

#### Estimation
- Normal: 1K orders/min. Flash sale: 5M users within the first minute → ~**100K requests/s** at the inventory hot spot for a few SKUs; only 10K succeed.

#### API
```
POST /v1/cart/items | GET /v1/cart
POST /v1/checkout {cartId, addressId, idempotencyKey} → {orderId, amount, paymentSession} | 409 out of stock
POST /v1/orders/{id}/cancel
Payment webhooks → order confirmation
```

#### Data model
```
carts (Redis/DB, per user) ; products & prices (catalog DB + cache)
inventory(sku, warehouse, on_hand, reserved, version) ; reservations(order_id, sku, qty, expires_at, status)
orders(order_id, user_id, status, amount, items[], idempotency_key UNIQUE)
sale_stock (Redis): sale:{sku}:stock counter ; sale:{sku}:buyers set (per-user limit)
```

#### High-level design
```
Users → CDN (static product/sale pages, cached; countdown) → WAF/bot protection → API GW (rate limits)
     → [Waiting room / token issuance for the sale SKU]
     → Checkout service ──▶ Pricing/Offers service (cached rules)
                        ──▶ Inventory service: sale items → Redis Lua (check per-user limit + DECR stock) → reservation token
                                               normal items → DB conditional update (reserve)
                        ──▶ Order service (create order PENDING_PAYMENT, outbox event)
                        ──▶ Payment service (PSP session)
     Kafka: order events → async DB persistence of reservations, notifications, analytics
     Expiry worker: unpaid orders after 10 min → release stock (Redis INCR + DB)
```

#### Deep dives
**Inventory hot spot**: a single DB row for a hot SKU can't take 100K updates per second (row lock contention). Move the sale stock counter into **Redis**, using an atomic Lua script: check the user isn't already in the `buyers` set → check stock > 0 → `DECR` stock → `SADD` the user → return success. Around 100K ops/s on one Redis node. Successful reservations are then persisted to the DB asynchronously (via Kafka) or synchronously in batches. **Reconciliation** keeps Redis and the DB consistent after the sale.

**Request shedding**: once stock hits 0, reject instantly at the edge (a "sold out" flag cached at the CDN or gateway), so millions of late requests never reach the backend.

**Waiting room or token bucket admission**: admit users in proportion to the remaining stock (no point admitting 5M users for 10K units); issue signed purchase tokens to admitted users.

**Order and payment saga**: order PENDING_PAYMENT → payment success → CONFIRMED; payment failure or timeout → release the reservation (INCR the Redis stock, update the DB) → the item becomes available to the next user (with a waitlist if desired). Idempotency keys on checkout prevent duplicate orders from retries.

**Degradation**: turn off recommendations, reviews and non-critical personalisation during the sale; static, CDN-cached sale pages; pre-scaled infrastructure and pre-warmed caches; load tests rehearsing the sale.

#### Bottlenecks, failures and trade-offs
- Redis is the critical path: primary plus replica; if the primary fails mid-sale, async replication might lose some decrements, which risks oversell. Mitigate with `WAIT 1` for sale decrements, or AOF always on a dedicated instance, or accept a tiny oversell buffer and cancel the excess with apologies (a business decision!).
- Payment provider throughput: queue payment session creation; extend holds if the PSP is slow.
- Bots: CAPTCHA, device fingerprinting, per-account limits, purchase tokens.

#### Follow-up questions
?? Why not just use `UPDATE inventory SET stock = stock - 1 WHERE sku = ? AND stock > 0`?
It's correct (no oversell), but under 100K concurrent requests on one row, every update serialises on the row lock, so latency explodes, connections pile up and the DB melts. It's fine for normal traffic; for flash sales, move the hot counter to Redis (or shard the stock into N sub-rows) and persist asynchronously.

?? How do you enforce one unit per user?
Inside the same Redis Lua script as the stock decrement, check and add to a per-SKU buyers set (atomic), plus a DB unique constraint on (user_id, sale_id) as the durable guard when persisting.

#### Interview simulation
Clarify the normal vs sale traffic, the oversell rules and per-user limits. Estimate the spike to show why the DB row is the bottleneck. Draw the edge protections → admission → Redis inventory → order saga → payment. Deep-dive on **atomic Redis Lua reservation**, **load shedding (sold-out flag at the edge)**, **the saga with expiry**, and **Redis failure trade-offs**. Indian interviewers love this one (Flipkart, Meesho, Myntra sales).

### Collaborative document editing (Google Docs)

#### Clarifying questions to ask
- *Real-time collaboration with many simultaneous editors?* → Yes, up to ~100 editors per doc; many viewers.
- *Content?* → Rich text (formatting), comments, cursors and presence.
- *Offline editing?* → Nice to have.
- *Version history?* → Yes.
- *Scale?* → Millions of documents; most have a single editor; a few have many.

#### Requirements
- **Functional**: concurrent editing with changes visible to others in under ~200ms; convergence (everyone sees the same final document); cursors and presence; comments; history and restore; permissions (view, comment, edit).
- **Non-functional**: low latency, no lost edits, consistency (convergence), durability, offline tolerance.

#### Estimation
- Typing generates small operations (~10–50 ops/s per active editor). Most docs are idle; active sessions are a small fraction. Storage: an operations log plus periodic snapshots.

#### API
```
WebSocket per document session:
  client→server: OP {docId, baseRevision, ops:[insert(pos,"a"), delete(pos,len), format(range, bold)], clientOpId}
  server→client: ACK {clientOpId, revision} | REMOTE_OP {revision, ops, author} | PRESENCE {cursors}
REST: GET /v1/docs/{id} (snapshot + revision) ; GET /v1/docs/{id}/history ; permissions APIs
```

#### Data model
```
documents(doc_id, owner, title, latest_revision, snapshot_ref, acl)
operations(doc_id, revision, ops, author, timestamp)        — append-only log (partition by doc_id)
snapshots(doc_id, revision, content_ref)                    — every N ops, in object storage
comments(doc_id, comment_id, anchor_range, thread)
```

#### High-level design
```
Clients ══WebSocket══▶ Collaboration servers (doc session owned by ONE server via consistent hashing on doc_id)
                             │  OT/CRDT engine per doc session (in memory)
                             ├─▶ append ops to Operations log (durable) → periodic snapshot to object storage
                             ├─▶ broadcast transformed ops to all session participants
                             └─▶ presence (cursors) — ephemeral, not persisted
Doc service (REST: load snapshot+ops, ACL), Comments service, Search indexer (async from ops log)
```

#### Deep dives
**Concurrency control: OT vs CRDT**
- **Operational Transformation (OT)**, used by Google Docs: a central server orders operations. When a client sends an op based on an older revision, the server **transforms** it against the ops that happened since (e.g. if someone inserted 3 characters before your position, shift your insert position by 3), applies it, assigns the next revision, and broadcasts it. Clients transform incoming ops against their pending local ops. Correct, but the transformation functions are tricky; the central server is the sequencer.
- **CRDTs** (Yjs, Automerge), used by Figma-like and local-first apps: each character or element gets a unique, ordered id (e.g. RGA/LSEQ position identifiers), so concurrent inserts and deletes merge deterministically without a central sequencer. Great for offline and peer-to-peer use, with metadata overhead (tombstones) and more complex rich-text semantics.
- In an interview: choose **OT with a central per-document server** (simple ordering, as Google does), mention CRDTs as the alternative for offline and decentralised use.

**Session ownership**: all editors of one document connect to the same collaboration server (routing by doc_id via consistent hashing or a lookup service), so one in-memory engine orders all the ops. If that server dies, clients reconnect, a new owner loads the snapshot plus the op log, and clients resend their unacked ops (idempotent by clientOpId).

**Durability**: an op is acked only after it's appended to the durable op log. Snapshots every N ops or minutes speed up loading; history and restore come from replaying or snapshots.

**Presence and cursors**: ephemeral messages broadcast through the session server; cursor positions are transformed like ops so they stay correct.

**Permissions**: checked at session join and per op (a viewer can't send ops); sharing links with roles.

**Offline**: the client queues ops locally; on reconnect it rebases them (OT) or merges them (CRDT). Conflicts are resolved by the algorithm; semantic conflicts are rare and tolerated.

#### Bottlenecks, failures and trade-offs
- A hot document (1,000 editors in a live event doc): the single session server becomes the bottleneck, so cap editors, demote many to viewers (fan-out of snapshots instead of ops), batch ops.
- Op log growth: compaction through snapshots; archive old ops.
- Latency: the server near the users (regional), or client-side optimistic application (apply locally first, reconcile on ack).

#### Follow-up questions
?? Two users type at the same position at the same time. What happens?
Both ops are based on revision R. The server receives A's first and applies it as R+1, then transforms B's op against A's (B's insert position shifts, or a tie-break rule like comparing user ids decides the order), applies it as R+2, and broadcasts both. A's client transforms B's op against its own and everyone converges to the same text.

?? Why route all editors of a document to one server?
OT needs a single total order of operations per document; a single owner can sequence them in memory with low latency. Distributing one document's edits across servers would require distributed consensus per keystroke, which is too slow. It also makes broadcasting to participants simple.

#### Interview simulation
Clarify the collaboration scale, offline needs and history. Explain the core challenge (concurrent edits must converge) and present **OT vs CRDT** with the choice. Draw clients ⇄ a doc-owner collaboration server (WebSocket) → op log plus snapshots. Walk the **concurrent insert example**. Cover failover of the session owner, presence, and permissions. Keep the OT internals at a conceptual level; interviewers rarely expect the transform functions themselves.

### LLM chat assistant with RAG (GenAI system design)

#### Clarifying questions to ask
- *Product?* → A chat assistant answering questions over a company's documents (support knowledge base, policies), with citations. Like your NeuronixAI.
- *Scale?* → e.g. 1M users, 10M messages/day; document corpus of 10M pages.
- *Latency?* → First token < 1.5s; streaming responses.
- *Models?* → Hosted LLM APIs (OpenAI, Anthropic, Gemini) or self-hosted open models? Cost limits?
- *Multi-tenant?* → Yes: each customer sees only their own documents (strict isolation).
- *Freshness?* → New or updated documents are searchable within minutes.
- *Safety?* → Prompt injection, PII, hallucinations.

#### Requirements
- **Functional**: ingest documents (PDF, HTML, docs); chat with conversation memory; answers grounded in retrieved documents with citations; feedback (thumbs up/down); admin analytics.
- **Non-functional**: low time-to-first-token, streaming, tenant isolation, cost efficiency, observability (quality metrics), resilience to LLM provider failures and rate limits.

#### Estimation
- 10M messages/day ≈ 115/s average, peak ~500/s. Each call is ~3K input tokens (context) plus 300 output tokens, so ~1.5M input tokens/s at peak. Cost and **provider rate limits (tokens per minute)** are the real constraints.
- Corpus: 10M pages → ~50M chunks × a 1,536-dim float32 embedding (6KB) ≈ 300GB of vectors (use quantisation to cut it).

#### API
```
POST /v1/conversations → {id}
POST /v1/conversations/{id}/messages {text} → SSE stream: tokens…, then {citations:[{docId, chunkId, snippet}], messageId}
POST /v1/messages/{id}/feedback {rating, comment}
POST /v1/documents (upload) → async ingestion status
```

#### Data model
```
documents(doc_id, tenant_id, source, status, version, acl)
chunks(chunk_id, doc_id, tenant_id, text, metadata{title, section, page}, embedding vector) → pgvector/OpenSearch/Pinecone, filtered by tenant_id
conversations(id, tenant_id, user_id), messages(id, conv_id, role, content, citations, tokens, latency, model)
semantic cache: (tenant_id, normalized question embedding) → answer  (with TTL)
eval/feedback store
```

#### High-level design
```
Ingestion: upload → S3 → Kafka "doc-uploaded" → parser (PDF/HTML → text, tables) → chunker (semantic/structure-aware, overlap)
           → embedding workers (batched; rate-limited) → vector index (+ BM25 keyword index) ; metadata DB

Query:  Client ─SSE─▶ API GW (auth, tenant, rate limits) → Chat orchestrator
          1. load conversation memory (recent turns + summary)
          2. query rewriting (make question standalone using history)
          3. retrieval: hybrid search (vector kNN + BM25) filtered by tenant & ACL → top 50
          4. rerank (cross-encoder) → top 5–8 chunks
          5. build prompt (system rules + context with chunk ids + question), token budget
          6. LLM gateway (provider routing, retries, fallbacks, streaming) → stream tokens to client
          7. post-process: citations validation, safety filters, store message + metrics
        Semantic cache check before step 3 (similar question in same tenant → cached answer)
Observability: traces per step (latency, tokens, cost), feedback, offline eval sets (faithfulness, answer relevance)
```

#### Deep dives
**Chunking**: structure-aware (split by headings, paragraphs and tables), 300–800 tokens with about 10–15% overlap; keep metadata (doc title, section path, page) and prepend the context ("Section: Refund Policy > Exceptions") to improve retrieval. Bad chunking is the number one cause of bad RAG.

**Retrieval quality**
- **Hybrid search**: vector similarity (semantic) plus BM25 (exact terms, product codes, names), fused with reciprocal rank fusion.
- **Reranking** with a cross-encoder model on the top 50 gives much better precision for the final context.
- **Query rewriting**: turn "what about for premium users?" into a standalone question using the conversation history; multi-query expansion for recall.
- **Metadata filters**: tenant_id (mandatory), document permissions, recency.

**Vector index**: HNSW (high recall, fast, memory-heavy) or IVF (cheaper, needs training); quantisation (int8 or PQ) to cut memory. pgvector is fine to roughly tens of millions of vectors with HNSW; a dedicated vector DB or OpenSearch beyond that. Partition by tenant for isolation and filter efficiency.

**Generation**: a prompt with explicit grounding instructions ("answer only from the context; cite chunk ids; say you don't know otherwise"); a token budget split between history, context and the answer; streaming via SSE; a **model router** (a cheap, fast model for simple questions, a stronger one for complex ones).

**LLM gateway**: provider abstraction, API keys and quotas, retries with backoff on 429/5xx, fallback to a secondary provider or model, per-tenant rate limits and cost tracking, a timeout on the first token.

**Caching**: an exact-match cache on (tenant, normalised question, doc version); a **semantic cache** (embedding similarity above a threshold) for FAQs; prompt caching features of providers for the static system prompt.

**Safety**: prompt injection defences (treat retrieved text as data, delimit it clearly, never let documents change system instructions, restrict tool use), PII redaction in logs, output moderation, citation verification (each claim maps to a retrieved chunk).

**Evaluation**: offline golden sets with metrics (retrieval recall@k, faithfulness or groundedness, answer relevance; LLM-as-judge plus human review); online feedback and A/B tests of prompt or model changes; tracing tools (LangSmith, Langfuse, OpenTelemetry).

#### Bottlenecks, failures and trade-offs
- Provider rate limits and outages: a queue with priority, fallback models, graceful messages.
- Cost: caching, smaller models via routing, context trimming, summarising long histories.
- Latency: parallelise retrieval steps, keep the reranker small, stream immediately, keep the vector index in memory.
- Freshness: streaming ingestion; deletes must remove vectors immediately (compliance).
- Hallucinations: grounding prompts, reranking, citations, an "I don't know" policy, evals.

#### Follow-up questions
?? How do you make sure tenant A never sees tenant B's documents?
Tenant id in every chunk's metadata, with a **mandatory filter enforced server-side** in the retrieval layer (never from the client); separate indexes or namespaces per tenant for large customers; ACL checks per document for user-level permissions; tests that attempt cross-tenant retrieval; and caches keyed by tenant.

?? Retrieval returns relevant chunks, but answers still hallucinate. What do you do?
Strengthen the prompt (answer only from the context, cite sources, refuse when unsure), reduce noisy context (fewer, better chunks via a reranker), lower the temperature, verify citations post-generation (drop or flag claims without support), use a stronger model for synthesis, and measure faithfulness with evals to confirm the fix.

?? How would you reduce cost by 50% without hurting quality much?
Measure the cost per component first, then: a semantic cache for repeated questions, route easy queries to a smaller model, trim the context (fewer chunks after reranking, summarised history), provider prompt caching for static prefixes, batch embeddings, and re-embed only changed chunks. Validate each change against the eval set.

#### Interview simulation
This is your **differentiator**, so prepare it as a 20-minute story built on NeuronixAI. Clarify the use case, tenants, latency and scale. Draw the **ingestion pipeline** and the **query pipeline** separately. Deep-dive on **chunking and hybrid retrieval with reranking**, the **LLM gateway (fallbacks, rate limits, streaming)**, **tenant isolation**, and **evaluation**. Then say what you'd improve in your own project with what you know now. That self-critique lands very well.
