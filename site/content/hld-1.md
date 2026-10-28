## Interview framework | P3 | must

### How to run a system design interview

#### Core idea
A 45–60 minute HLD round evaluates whether you can **drive an ambiguous problem to a reasonable architecture**, make and justify **trade-offs**, and go **deep** where it matters. There's no single right answer. Interviewers score your process, communication and judgement. At SDE-2 level, they expect you to lead the discussion, not wait to be guided.

#### How it works
**The framework (memorise the flow, adapt the timing)**
| Step | Time (45 min) | Output |
|---|---|---|
| 1. Requirements | 5–7 min | functional requirements (3–5 core features), non-functional requirements (scale, latency, availability, consistency), explicitly out of scope |
| 2. Estimation | 3–5 min | QPS (avg/peak), storage per year, bandwidth, read:write ratio, which decides the architecture |
| 3. API design | 3–5 min | the key endpoints or RPCs with request/response |
| 4. Data model | 3–5 min | entities, the access patterns that drive the DB choice, keys and indexes |
| 5. High-level design | 8–10 min | boxes and arrows: clients → LB/gateway → services → caches, DBs, queues, with the main read and write flows |
| 6. Deep dives | 10–15 min | the 2–3 hardest parts (hot keys, consistency, fan-out, ordering, failure handling) |
| 7. Wrap-up | 2–3 min | bottlenecks, failure modes, monitoring, what you'd do next |

**Universal clarifying questions**
- Who are the users, and how many (DAU/MAU)? Is it global or one region?
- What are the core use cases for *this* interview? What can we skip?
- Read-heavy or write-heavy? What's the peak vs average traffic?
- What latency is acceptable (p99)? What availability (99.9% = 8.7h/year downtime, 99.99% = 52 min/year)?
- Strong consistency needed, or is eventual OK? Where exactly?
- Data retention? Media sizes? Any compliance concerns (PII, payments)?

**Habits that score**
- **Say the trade-off every time you choose**: "I'll use Cassandra here because writes dominate and we access by user_id; we give up ad-hoc queries and strong consistency, which is fine for a feed."
- **Start simple, then scale**: a single-box design → identify the bottlenecks → evolve it. Don't open with 20 microservices.
- **Drive**: "Next I'd like to go deeper on X unless you'd prefer Y."
- **Numbers**: back the decisions with estimates (e.g. "60K QPS reads means we need a cache; one Postgres instance can't serve that").
- **Failure thinking**: what happens when each component dies?

#### Real-world example
At Amazon, Google, Uber and Flipkart, the rubric usually covers: problem exploration, the high-level design, technical depth, trade-off reasoning, communication and **ownership of time**. A common rejection reason is spending 25 minutes on requirements and boxes and never reaching a deep dive. Another is diving into one component's internals without an end-to-end design.

#### Interview questions
?? What's the difference between functional and non-functional requirements?
Functional: what the system does (users can post a tweet, follow users, see a timeline). Non-functional: how well it does it: scale (500M DAU), latency (timeline in < 200ms p99), availability (99.99%), consistency (eventual for feeds, strong for payments), durability, security, cost. Non-functional requirements usually drive the architecture.

?? How do you decide what to deep-dive on?
Pick the parts that are **hardest or most specific to this problem**: the fan-out strategy for a feed, matching and geo-indexing for Uber, the seat-locking concurrency for ticket booking, exactly-once for payments. Ask the interviewer: "I think the most interesting parts are A and B. Which would you like me to go deeper on?"

#### Tricky questions
?? The interviewer keeps adding requirements mid-way. How do you handle it?
It's intentional: they're testing adaptability. Acknowledge it, briefly assess the impact on your design ("this changes the write path; we'll need X"), adapt the relevant parts, and keep the rest. Don't restart from scratch.

?? Is it OK to say "I don't know" about a specific technology?
Yes. Reason from first principles instead: "I haven't used Cassandra in production, but what we need here is a write-optimised, partitioned store keyed by user_id with tunable consistency; an LSM-tree wide-column store fits." Interviewers value reasoning over buzzwords.

#### Interview simulation
**Opening script:** "Before designing, I'd like to clarify the scope and scale. [Ask 4–6 questions.] So the core features are A, B and C, with D out of scope. We expect X DAU with a read:write ratio of about 100:1, latency under 200ms, and high availability; eventual consistency is fine for B but not for C. Let me do quick estimates, then define the APIs and data model, then draw the high-level design, and then we can deep-dive into the hardest parts: I think they're P and Q." This opening alone signals seniority. Practise it until it's natural.

### Back-of-the-envelope estimation

#### Core idea
Estimation converts vague scale ("Instagram-like") into **numbers that drive decisions**: do we need sharding? caching? how many servers? Interviewers don't need precision; they want a sensible order of magnitude, reasoned out loud, in 2–4 minutes.

#### How it works
**Numbers to know by heart**
| Quantity | Value |
|---|---|
| Seconds per day | 86,400 ≈ **10⁵** |
| 1M requests/day | ≈ **12 QPS** |
| 100M requests/day | ≈ **1,200 QPS** |
| 1B requests/day | ≈ **12K QPS** |
| Peak factor | 2–5× average (use 2–3× unless told) |
| 1 KB × 1M | 1 GB |
| 1 KB × 1B | 1 TB |

**Latency numbers (orders of magnitude)**
| Operation | Time |
|---|---|
| L1 cache / main memory reference | ~1 ns / ~100 ns |
| Read 1MB sequentially from memory | ~10 µs |
| SSD random read | ~16–100 µs |
| Read 1MB sequentially from SSD | ~50–200 µs |
| Round trip within a datacenter | ~0.5 ms |
| Redis GET (network included) | ~0.2–1 ms |
| Simple indexed DB query | ~1–10 ms |
| Round trip Mumbai ↔ US East | ~200 ms |

**Rough capacity per node (for sanity checks)**
- A stateless app server: ~1K–10K simple requests per second (depends heavily on the work).
- Postgres/MySQL on good hardware: ~5K–20K simple queries per second; far fewer for complex ones.
- Redis: ~100K+ ops per second per node.
- Kafka broker: ~100MB/s+ of writes; hundreds of thousands of messages per second.

**The method**
1. DAU × actions per user per day gives requests per day, then ÷ 10⁵ for QPS, then × peak factor.
2. Writes and reads separately (read:write ratio).
3. Storage: writes per day × object size × retention (× replication factor 3).
4. Bandwidth: QPS × response size.
5. Cache size: the hot set (often 20% of daily data, following the 80/20 rule).

**Worked example: a Twitter-like service**
- 200M DAU; each posts 2 tweets/day → 400M writes/day ≈ **4.6K write QPS** (peak ~10K).
- Each views a timeline 20×/day → 4B reads/day ≈ **46K read QPS** (peak ~100K) → read-heavy, so cache timelines.
- Tweet size ~300 bytes of text + metadata ≈ 1KB → 400GB/day → **~150TB/year** (before replication and media) → needs a partitioned store.
- Media: 10% of tweets with 500KB images → 20TB/day → object storage + CDN.

#### Real-world example
Estimation reveals architecture: 10K write QPS with 150TB/year rules out "a single Postgres" and points to a sharded or wide-column store. 100K timeline reads per second points to precomputed timelines in a cache. Media volumes point to S3 + CDN. In your 1mg work: if search got ~2K QPS at peak and each request fanned out to 3 services, that's 6K internal calls per second, which justified caching and async fan-out.

#### Interview questions
?? Estimate the storage needed for a URL shortener with 100M new URLs per month, kept for 5 years.
100M × 12 × 5 = 6B URLs. Each record (short code 7B, long URL ~100B, created time, user id, expiry) ≈ 200–500 bytes, so use 500B: 6B × 500B = 3TB, × 3 replicas ≈ 9TB. That's manageable with a sharded or wide-column store, or even a single large Postgres with partitioning plus read replicas.

?? How many servers do we need for 50K QPS?
It depends on the per-request cost. If one instance handles ~2K QPS at the target latency (measured), you need 25 instances, plus headroom (×1.5) for peaks and failures (N+2), so about 40. State the assumption explicitly; the interviewer cares about the method.

#### Tricky questions
?? Why multiply storage by 3?
Replication: most durable storage systems keep 3 copies (HDFS, Cassandra RF=3, S3 internally). Also add overhead for indexes, compaction space (LSM stores need free space) and backups. Overall, 3–5× the raw data is a reasonable planning figure.

#### Interview simulation
Do it aloud on the board in a small table: DAU, actions/day, QPS (avg/peak), read:write, object size, storage/day, storage/5yr, bandwidth. Round aggressively ("86,400 is about 100K"). Then **say what it implies**: "~100K read QPS means caching is mandatory; ~150TB/year means we must partition the data." Numbers without conclusions are wasted time.

## Building blocks I | P3 | must

### Scaling, stateless services and availability

#### Core idea
- **Vertical scaling** (scale up): a bigger machine. Simple, but limited and a single point of failure.
- **Horizontal scaling** (scale out): more machines behind a load balancer. Near-limitless, but needs **stateless** services and distributed data.
- **Availability** comes from **redundancy** (no single points of failure) plus **fast failure detection and failover**.

#### How it works
**Make services stateless**: no user session or request state in server memory. Store it in Redis or a DB, or in the client (a JWT). Then any instance can serve any request, autoscaling and rolling deploys are trivial, and losing an instance loses nothing.

**Availability math**
- Serial dependencies **multiply**: a service calling 3 dependencies each at 99.9% gives 0.999³ ≈ 99.7%.
- Redundant replicas **add up**: two independent 99% instances give 1 − 0.01² = 99.99%.
- So minimise synchronous dependencies on the critical path, and replicate everything.

| Availability | Downtime/year | Downtime/month |
|---|---|---|
| 99% | 3.65 days | 7.3 h |
| 99.9% | 8.76 h | 43.8 min |
| 99.99% | 52.6 min | 4.4 min |
| 99.999% | 5.26 min | 26 s |

**Redundancy levels**: multiple instances → multiple **availability zones** (separate datacentres within a region, around 1–2ms apart) → multiple **regions** (disaster recovery, global latency). Active-passive (a standby takes over) vs active-active (all serve traffic; harder for data consistency).

**Autoscaling**: on CPU, request rate, queue depth or custom metrics. Scale-out takes time (instance boot plus JVM warm-up), so keep headroom, and pre-scale for known events (sales, IPL matches).

**Other scaling tools**: caching, async processing via queues (absorb spikes), read replicas, sharding, CDN, and **graceful degradation** (turn off non-critical features under load).

**SLI / SLO / SLA**: an SLI is a measured indicator (p99 latency, success rate). An SLO is the internal target (99.9% of requests under 300ms). An SLA is a contract with penalties. An **error budget** of 1 − SLO is how much unreliability you can "spend" on releases.

#### Real-world example
Hotstar (JioCinema/Disney+ Hotstar) handled 25M+ concurrent viewers during IPL/World Cup matches by **pre-scaling** ahead of match start (autoscaling is too slow for sudden spikes like toss time), stateless services, aggressive CDN caching, and **graceful degradation**: under extreme load they turn off non-essential features (recommendations, personalisation) to protect video playback.

#### Interview questions
?? Vertical vs horizontal scaling: when would you choose vertical?
Vertical is simpler (no distributed complexity) and is often right for databases until you hit hardware limits: a big Postgres instance can go very far. Choose horizontal for stateless app tiers (easy, elastic), and when you need fault tolerance or scale beyond one machine.

?? How do you make a service highly available?
Run multiple stateless instances across availability zones behind a health-checked load balancer; replicate data stores with automatic failover; remove single points of failure (including config, DNS and secrets); use timeouts, circuit breakers and graceful degradation; deploy with rolling or canary strategies and automatic rollback; monitor SLOs with alerts and runbooks.

#### Tricky questions
?? Adding more app servers didn't improve throughput. Why?
The bottleneck is elsewhere: the database (connections, locks, CPU), a shared cache hot key, a downstream rate limit, the load balancer, or contention on a shared resource (a lock or a sequence). Scaling the stateless tier only helps if it was the bottleneck. Measure first (USE/RED metrics: utilisation, saturation, errors; rate, errors, duration).

#### Interview simulation
Whenever you add a component in a design, mentally run the "what if it dies?" check and say it: "The cache is a cluster with replicas; if it fails, we fall back to the DB with rate limiting to avoid a stampede." Interviewers specifically listen for single points of failure, and fixing them proactively scores well.

### Load balancers in system design

#### Core idea
Load balancers distribute requests across instances, run health checks, and are the entry point for scaling and availability. In system design you decide **where** load balancers go, which **layer** (L4 or L7), the **algorithm**, and how **session affinity** and **global routing** work. (The CS Networks lesson covers the protocol details.)

#### How it works
**Placement in a typical design**
```
Users → DNS (GeoDNS/anycast) → CDN/edge → L7 LB / API Gateway → service instances
                                                     ↓
                                internal service-to-service: client-side LB or service mesh (Envoy)
                                                     ↓
                                    DB proxies (PgBouncer, ProxySQL) → DB primary/replicas
```
- **Global**: route users to the nearest healthy region (GeoDNS, anycast, global LBs like AWS Global Accelerator or GCP's global HTTP LB).
- **Regional edge**: an L7 load balancer (AWS ALB, Nginx, Envoy) terminates TLS and routes by path or host.
- **Internal**: Kubernetes Services (L4 kube-proxy), service meshes (L7 per-request balancing, retries, mTLS), or client-side balancing (gRPC, Spring Cloud LoadBalancer).

**Algorithm choices**: round robin (homogeneous servers and requests), least outstanding requests (variable request cost; AWS ALB supports it), consistent hashing (stickiness for caches or stateful shards), power-of-two-choices (scalable and near-optimal).

**Health checks**: shallow (process up) vs deep (dependencies OK). Deep checks can cause **cascading failure**: if the DB is down, every instance fails its health check and the LB removes them all. Prefer readiness checks of the instance's own ability to serve, with dependency failures handled by circuit breakers.

**The LB isn't a SPOF**: managed LBs are themselves distributed; self-hosted pairs use a VRRP/keepalived floating IP, or DNS with several LB IPs.

#### Real-world example
**Google Maglev** is a software L4 load balancer on commodity servers using consistent hashing, so connection affinity survives LB node changes. **Envoy** (Lyft) became the standard L7 proxy for service meshes (Istio). AWS ALB + ECS (your NeuronixAI setup) provides L7 routing to target groups with health checks on each task.

#### Interview questions
?? Where would you put load balancers in a three-tier web app?
In front of the web/API tier (L7, TLS termination, path routing), between internal services (client-side balancing or a mesh), and for databases via proxies or replica endpoints for read traffic. Global routing via DNS or anycast if multi-region.

?? How do you handle sticky sessions for a stateful app?
Prefer to remove the need: externalise session state (Redis, a JWT). If unavoidable (WebSocket servers, legacy apps), use cookie-based affinity at the L7 LB or consistent hashing on the user id, and accept the trade-offs: uneven load, and lost sessions when that node dies unless state is replicated.

#### Tricky questions
?? Why can a deep health check take your whole service down?
If the health check includes a shared dependency (the DB) and that dependency has a blip, **every** instance reports unhealthy at once, the LB has no healthy targets and returns 503 for everything, even requests that didn't need the DB (cached reads). Keep health checks focused on the instance itself; handle dependency failure with degradation.

#### Interview simulation
In HLD diagrams, draw the LB explicitly, name its type ("an L7 ALB, TLS terminated here"), and mention health checks plus multi-AZ. If WebSockets or gRPC are involved, mention the connection-level balancing caveat. Small, precise remarks like these build credibility quickly.

### Caching strategies

#### Core idea
A cache stores **hot data in fast storage** (memory) closer to the consumer to cut latency and load. Caching is the single most effective scaling tool, and its two hard problems are **invalidation** and **consistency**.

#### How it works
**Where caches live**: client/browser → CDN → API gateway → **application in-process** (Caffeine) → **distributed cache** (Redis, Memcached) → DB buffer pool.

**Read/write patterns**
| Pattern | How | Pros | Cons |
|---|---|---|---|
| **Cache-aside (lazy loading)** | app reads the cache; on a miss, reads the DB and populates the cache; writes go to the DB and **invalidate** the cache | simple, only caches what's used, cache failure isn't fatal | the first read is a miss; stale-data race windows |
| **Read-through** | the cache itself loads from the DB on a miss | cleaner app code | needs cache support or a library |
| **Write-through** | write to the cache and DB synchronously | the cache is always fresh | write latency; caches unread data |
| **Write-back (write-behind)** | write to the cache, flush to the DB asynchronously | very fast writes, coalescing | **risk of data loss**, complexity |
| **Write-around** | write to the DB only; the cache fills on read | avoids polluting the cache with write-once data | first read misses |

**Invalidation strategies**
- **TTL**: simple, bounds staleness. Add **jitter** (TTL ± 10%) so keys don't all expire together.
- **Explicit invalidation on write**: delete the key after a DB write (delete rather than update, which avoids races between concurrent updates).
- **Event-driven**: CDC (Debezium) → Kafka → invalidate or update the caches, reliably and asynchronously.
- **Versioned keys**: `product:123:v42`; bump the version on change.

**The classic race in cache-aside**: Thread A reads the DB (old value) → Thread B updates the DB and deletes the cache → Thread A writes the *old* value into the cache, which is now stale until the TTL. Mitigations: short TTLs, a delayed double delete, versioned or conditional sets, or CDC-driven invalidation.

**Failure modes**
- **Cache stampede / thundering herd**: a hot key expires and thousands of requests hit the DB at once. Fixes: **request coalescing** (single-flight: one loader per key, others wait), **soft TTL / stale-while-revalidate** (serve the stale value while one request refreshes in the background), early probabilistic refresh, and locks.
- **Cache penetration**: requests for keys that don't exist (often malicious) always miss and hit the DB. Fix: **cache negative results** (a short TTL) or a **Bloom filter** of existing keys.
- **Cache avalanche**: many keys expire together, or the cache cluster dies. Fixes: TTL jitter, cache replicas, DB rate limiting or circuit breaking, warm-up.
- **Hot keys**: one key gets enormous traffic (a celebrity, a flash sale product). Fixes: local in-process cache in front of Redis, key replication (`key#1..N` read randomly), read replicas.

**Eviction**: LRU, LFU, TTL-based. Redis's `maxmemory-policy allkeys-lru` / `allkeys-lfu` / `volatile-ttl`.

#### Real-world example
**Your resume**: "Redis Soft TTL caching raised cache hit ratio by 35% and cut database load by 30%." This is **stale-while-revalidate**: each cached medicine search entry has a *soft* expiry (e.g. 5 min) and a *hard* expiry (e.g. 30 min). After the soft expiry, the next request still gets the cached value immediately, and **one** background refresh (guarded by a lock or single-flight) updates it. Users never wait for a DB call on popular queries, and the DB never sees a stampede. Be ready to draw this and explain the lock that ensures a single refresh.

#### Interview questions
?? Explain cache-aside and its consistency problems.
On read: check the cache; on a miss, read the DB and set the cache with a TTL. On write: update the DB, then delete the cache key. Problems: a stale window between the DB write and the cache delete; the race where a slow reader repopulates the cache with old data after a delete; failure to delete leaving stale data until the TTL. Mitigations: TTLs as a safety net, delete instead of update, delayed double delete, CDC-based invalidation, versioning.

?? How do you prevent a cache stampede?
Single-flight (only one request recomputes a key; the others wait for or share its result, e.g. `ConcurrentHashMap<key, CompletableFuture>` in process or a Redis lock across instances), soft TTL with background refresh, probabilistic early expiration (refresh slightly before expiry with increasing probability), and TTL jitter so many keys don't expire together.

?? Redis vs Memcached?
Memcached: a simple multi-threaded key-value cache, slab allocation, no persistence or replication, great for plain caching. Redis: rich data structures (hashes, sorted sets, streams), persistence options, replication and clustering, Lua scripting, pub/sub. Most teams pick Redis for flexibility.

#### Tricky questions
?? Should you update the cache or delete it on write?
Usually **delete**. With two concurrent writers, "update cache" can interleave so that the cache ends with the older value while the DB has the newer one. Deleting forces the next read to load fresh data. Update-in-place is fine with a single writer or versioned compare-and-set.

?? Your cache hit ratio is high but DB load didn't drop. Why?
Perhaps the expensive queries aren't the ones being cached; the misses are concentrated on heavy queries; there's a write-heavy load the cache doesn't help; cache penetration (non-existent keys); or the TTL is too short for expensive keys. Measure DB load by query, not just overall hit ratio.

#### Interview simulation
**Interviewer:** "Design caching for a product details page that gets 50K QPS."

**Clarify:** "How often do products change? How stale can price or stock be? Are there hot products during sales?"

**Answer:** Cache-aside in Redis keyed by `product:{id}` with a TTL of minutes plus jitter; a separate, shorter-TTL or uncached **price and stock** (freshness matters there); event-driven invalidation from the catalogue service on updates; stale-while-revalidate for hot keys; a local Caffeine L1 cache for the top 1,000 products to absorb hot-key traffic; negative caching for 404s; and CDN caching of the rendered page or JSON for anonymous users. Then tie it to your soft-TTL experience at 1mg with the measured results.

### CDN

#### Core idea
A **Content Delivery Network** is a globally distributed set of **edge servers** (Points of Presence, PoPs) that cache content close to users. It cuts latency (shorter round trips), offloads the origin servers and absorbs traffic spikes and DDoS attacks.

#### How it works
- A user requests `cdn.acme.com/img/p123.webp`. DNS or anycast routes them to the nearest PoP. On a **hit**, it's served from the edge (~10–30ms); on a **miss**, the edge fetches from the **origin** (S3 or your servers), caches it per the `Cache-Control` headers, and serves it.
- **Pull CDN** (most common): the edge fetches on demand. **Push CDN**: you upload content to the CDN ahead of time (large, predictable files).
- **Cache-Control headers**: `public, max-age=31536000, immutable` for versioned static assets (`app.3f9c2.js`); `s-maxage` for CDN-specific TTLs; `stale-while-revalidate`; `private`/`no-store` for user-specific data.
- **Cache keys**: URL plus optionally headers, cookies or query params. Careful: varying on cookies destroys the hit ratio.
- **Invalidation**: purge APIs (slow-ish, and costly at scale). Prefer **versioned file names** (content hashes) so new content gets a new URL and you never need to purge.
- **Origin shield**: a mid-tier cache in front of the origin, so 200 PoPs missing doesn't mean 200 origin fetches.
- **Beyond static files**: dynamic acceleration (persistent optimised connections to the origin), **edge compute** (Cloudflare Workers, Lambda@Edge) for auth, A/B tests and personalisation at the edge, video streaming (HLS/DASH segments), WAF, DDoS protection, bot management.

#### Real-world example
**Netflix Open Connect**: Netflix places its own CDN appliances **inside ISPs' networks**, pre-filled overnight with the content predicted to be popular in that region, so most video bytes never cross the internet backbone. **Hotstar** relies on multi-CDN for live cricket, where the same video segments are requested by millions within seconds, an ideal CDN workload.

#### Interview questions
?? What content should go through a CDN?
Static assets (JS, CSS, images, fonts), media (video segments, audio), downloadable files, and cacheable API responses that are the same for many users (product catalogue, public pages), even with short TTLs (micro-caching for 1–5s can absorb enormous spikes). Not: per-user private data, unless it's keyed carefully and marked private.

?? How do you update a cached file on the CDN?
Prefer immutable, versioned URLs (`logo.v2.png` or a content hash in the file name) referenced from HTML with a short TTL, so new deployments use new URLs instantly. Use purge or invalidation APIs for emergencies (it takes seconds to minutes to propagate globally).

#### Tricky questions
?? Your CDN hit ratio is only 30%. What could cause it?
A cache key including unnecessary query params or cookies (each user gets a unique key), `Cache-Control: no-cache/private` sent by the origin, very short TTLs, long-tail content (many unique files rarely requested), or a `Vary` header on User-Agent. Fix by normalising cache keys, adjusting headers, and adding an origin shield.

#### Interview simulation
In any design with media or static content (Instagram, YouTube, e-commerce), say early: "All media is stored in object storage and served via a CDN with long-lived immutable URLs; the origin only sees cache misses." Then estimate the bandwidth saved. It's an easy, high-value point that's often forgotten.

### SQL vs NoSQL: choosing a database

#### Core idea
Choose a database by **data model and access patterns**, **consistency needs**, **scale** and **operational maturity**, not by hype. Relational (SQL) databases are the default; NoSQL families fit specific patterns at scale.

#### How it works
| Family | Examples | Data model | Strengths | Weaknesses | Typical use |
|---|---|---|---|---|---|
| **Relational** | Postgres, MySQL, Aurora | tables, joins, schema | ACID transactions, flexible queries, constraints, mature | horizontal write scaling is hard (sharding is manual) | orders, payments, users, inventory |
| **Key-value** | Redis, DynamoDB, Riak | key → blob | O(1) access, massive scale | no queries beyond the key | sessions, caches, carts, feature flags |
| **Document** | MongoDB, Couchbase, DynamoDB (doc mode) | JSON documents | flexible schema, nested data, good for aggregates read together | joins and multi-document transactions are limited or costly | catalogues, user profiles, CMS |
| **Wide-column** | Cassandra, ScyllaDB, HBase, Bigtable | partition key → sorted rows | huge write throughput, linear scale, multi-DC | queries must follow the partition key; no joins; eventual consistency by default | time-series, messages, activity feeds, IoT |
| **Graph** | Neo4j, Neptune | nodes and edges | multi-hop relationship queries | scaling and niche use | social graphs, fraud rings, recommendations |
| **Search** | Elasticsearch, OpenSearch | inverted index | full-text, fuzzy matching, faceting | not a primary store; eventual consistency | product search, log search |
| **Time-series** | InfluxDB, TimescaleDB, Prometheus | time-ordered metrics | compression, downsampling | specialised | metrics, monitoring |
| **Vector** | pgvector, Pinecone, Milvus | embeddings | similarity search | approximate, specialised | RAG, recommendations |

**Decision questions**
1. Do I need multi-row/multi-entity **transactions** and constraints? → Relational.
2. What are the **access patterns**? Known key lookups at huge scale → KV or wide-column. Ad-hoc queries and reporting → relational.
3. What's the **write volume** and data size? Above what one primary handles even after optimisation → a partitioned store (or sharded SQL, Vitess, Citus, CockroachDB/Spanner-like NewSQL).
4. **Consistency**: strong (relational, Spanner) vs tunable or eventual (Cassandra, DynamoDB).
5. **Team and ops**: the managed options available, familiarity.

**Polyglot persistence**: different stores for different needs within one system (Postgres for orders, Redis for sessions, Elasticsearch for search, S3 for media, Cassandra for activity logs), kept in sync through events or CDC.

#### Real-world example
**Discord** stores trillions of messages in **ScyllaDB** (they migrated from MongoDB to Cassandra, then to ScyllaDB), partitioned by `(channel_id, time bucket)`, because the workload is huge write volume with reads by channel and time. **Uber** uses MySQL-based Schemaless/Docstore for many services. Your NeuronixAI uses **Postgres + pgvector**: relational data and embeddings in one store, which is simpler to operate at moderate scale. A great example of choosing boring technology wisely.

#### Interview questions
?? When would you choose NoSQL over SQL?
When access patterns are simple and known (lookup by key or partition), the scale (write throughput or data volume) exceeds what a single relational primary handles, the schema is highly variable, or you need multi-region writes with availability over strict consistency. Otherwise relational is the safer default.

?? How do you model data in Cassandra or DynamoDB?
**Query-first design**: list the queries, then design one table per query pattern, with the partition key giving even distribution and locality (all data for a query in one partition) and the clustering or sort key giving ordering. Denormalise (duplicate data across tables) and avoid unbounded partitions (bucket by time).

#### Tricky questions
?? "MongoDB is schemaless, so we don't need a schema." Agree?
No. The schema moves into the application (implicit schema). You still need validation, migrations for changed shapes, and indexes designed for your queries. Flexible schemas are useful, but unmanaged ones create data-quality problems.

?? Can't Postgres just scale with read replicas?
Read replicas scale **reads**. Writes still go to one primary, so if write throughput or data size exceeds one machine, you need partitioning or sharding (Citus, application-level sharding) or a distributed SQL database (CockroachDB, YugabyteDB, Spanner). But one well-tuned Postgres handles more than most people assume (tens of thousands of writes per second, terabytes of data).

#### Interview simulation
When you choose a database in an HLD round, use this sentence shape: "**Access pattern** is X, **scale** is Y, **consistency** need is Z, so I'll use [DB], partitioned by [key]; the trade-off is [what we give up]." For example: "Messages are written at 100K/s and read by conversation in time order; eventual consistency is acceptable; so Cassandra partitioned by (conversation_id, month), clustered by message_id. We give up ad-hoc queries, so search goes to Elasticsearch."

### Database replication

#### Core idea
**Replication** keeps copies of data on multiple nodes for **high availability** (survive node failure), **read scaling** (serve reads from replicas), and **geo-locality** (data near users). The key design choices are the **topology** (single-leader, multi-leader, leaderless) and **sync vs async**, which decide your consistency and failure behaviour.

#### How it works
**Single-leader (primary-replica)**
- All writes go to the leader, which streams changes to followers. Reads can go to followers (with lag).
- Simple and the most common (Postgres, MySQL, MongoDB replica sets, Kafka partitions).
- Failover: detect the leader failure, promote a follower, redirect clients. Risks: **lost writes** (async replicas missing the latest writes), **split brain** (two leaders), and choosing the timeout (too short gives false failovers; too long gives longer downtime).

**Multi-leader**
- Several nodes accept writes (e.g. one leader per region) and replicate to each other.
- Benefits: local write latency in each region, tolerance of region failure.
- Problem: **write conflicts** (two regions edit the same record). Resolution: last-write-wins (by timestamp, which loses data), application-specific merging, CRDTs (conflict-free replicated data types), or avoiding conflicts by routing each record's writes to its "home" region.

**Leaderless (Dynamo-style)**
- Clients write to and read from several replicas directly. **Quorums**: with N replicas, write to W and read from R; if **R + W > N**, reads overlap the latest write (e.g. N=3, W=2, R=2).
- Repair mechanisms: **read repair** (fix stale replicas seen during reads), **hinted handoff** (temporarily store writes for a down node), **anti-entropy** with Merkle trees.
- Used by Cassandra, DynamoDB (internally), Riak.

**Sync vs async**: synchronous means no data loss but higher latency and availability coupling; asynchronous means fast but lag and possible loss; semi-synchronous (wait for one replica) is the common compromise.

**Replication lag anomalies and fixes**
| Anomaly | Example | Fix |
|---|---|---|
| Read-your-writes | user posts a comment, refreshes, it's gone | read from the leader for that user for a short time after a write; or track the write's LSN/version |
| Monotonic reads | refreshing shows newer then older data (different replicas) | stick each user to one replica |
| Consistent prefix | seeing an answer before its question | write causally related data to the same partition; causal consistency |

#### Real-world example
**GitHub's 2018 outage**: a brief network partition between the US East Coast and West Coast datacentres triggered an automatic MySQL failover to the West Coast. Writes then landed on both sides, and reconciling the divergent data took about 24 hours of degraded service. It's a textbook case of failover plus async replication plus split-brain risk, and why failover automation must be conservative and fenced.

#### Interview questions
?? Single-leader vs leaderless replication?
Single-leader: simple, consistent ordering of writes, easy reads-after-writes from the leader; but the leader is a write bottleneck and failover is a delicate operation. Leaderless: no failover needed, high write availability and tunable consistency through quorums; but conflict handling (concurrent writes), and more complex reasoning about consistency (sloppy quorums, last-write-wins).

?? What does R + W > N guarantee?
That every read quorum overlaps every write quorum in at least one node, so a read sees at least one copy of the latest successful write (the client picks the newest version). It doesn't by itself guarantee linearizability (concurrent writes, sloppy quorums during failures, last-write-wins clock issues).

#### Tricky questions
?? Your app reads from replicas and users complain their profile edits "disappear" for a few seconds. Fix?
Read-your-writes consistency: after a user writes, route their reads to the primary for a window (e.g. 10s) or until the replica has caught up to the write's LSN (Postgres `pg_last_wal_replay_lsn`). Alternatively, return the updated data in the write response and keep it client-side.

?? What is split brain, and how is it prevented?
Two nodes both believe they're the leader (e.g. after a network partition), both accept writes, and the data diverges. Prevention: consensus-based leader election with quorums (Raft or etcd: only the majority side can elect a leader), **fencing** (the old leader's writes are rejected using epoch numbers or tokens, or STONITH: shoot the other node in the head), and leases.

#### Interview simulation
When you add read replicas in a design, immediately address lag: "Replicas serve catalogue reads, which can tolerate a second of lag; checkout and the user's own recent activity read from the primary." That shows you understand the consequence, not just the box.

### Sharding and partitioning

#### Core idea
**Sharding (partitioning)** splits a dataset across multiple machines so each holds a subset. It scales **writes and storage** beyond one node. The hard parts are choosing the **shard key**, avoiding **hot spots**, and handling **cross-shard queries and rebalancing**.

#### How it works
**Strategies**
| Strategy | How | Pros | Cons |
|---|---|---|---|
| **Range** | key ranges per shard (A–F, G–M…; dates) | efficient range scans | hot spots (all new writes go to the latest range) |
| **Hash** | `hash(key) % N` or hash ranges | even distribution | range queries hit all shards; changing N reshuffles everything (unless consistent hashing) |
| **Consistent hashing** | ring with virtual nodes | adding or removing a node moves only ~1/N of the keys | slightly more complex |
| **Directory / lookup** | a mapping service: key → shard | flexible, supports moving tenants | the lookup service is a dependency and must be cached and highly available |
| **Geo / entity-based** | by region or tenant | locality, compliance | uneven sizes |

**Choosing the shard key**
- **High cardinality** and **even distribution** (avoid `country`, `status`).
- Matches the **dominant access pattern**, so most queries hit **one shard** (`user_id` for user-centric apps, `tenant_id` for SaaS, `conversation_id` for chat).
- Avoid **monotonically increasing** keys with range sharding (timestamps, so all writes hit one shard); hash them or use composite keys.

**Problems**
- **Hot partitions**: a celebrity user or a viral product. Mitigations: key salting (`user123#0..9` for writes, read all and merge), splitting hot partitions, caching.
- **Cross-shard queries**: scatter-gather (query all shards and merge: slow, with tail latency), or maintain secondary indexes and denormalised views (a global secondary index, or a search index).
- **Cross-shard transactions**: avoid them by design (co-locate related data), or use 2PC or sagas.
- **Rebalancing**: use many more logical partitions than physical nodes (e.g. 1,024 partitions over 16 nodes) so you move whole partitions; consistent hashing; online migration with dual writes and backfill.
- **Unique IDs** across shards: Snowflake-style IDs (see the ID generation lesson).

**Partitioning within one DB**: Postgres declarative partitioning (by range on `created_at`, monthly) for manageability: fast drops of old data, partition pruning, smaller indexes. It isn't the same as sharding across machines, but it's often the first step.

#### Real-world example
**Instagram** sharded Postgres early by user id into thousands of **logical shards** mapped onto fewer physical servers, with IDs encoding the shard (time + shard id + sequence), so any ID tells you where its data lives. **Vitess** (YouTube) adds sharding middleware to MySQL. **Notion** sharded Postgres by workspace id into 480 logical shards in 2021, then re-sharded onto more machines in 2023, an approach that applies well to SaaS.

#### Interview questions
?? How do you choose a shard key?
Look at the main query patterns and pick a key that keeps each query on one shard and spreads load evenly: high cardinality, not monotonic, and no dominant single value. Validate against skew (celebrities, big tenants) and plan for them (splitting, salting). Consider how secondary access patterns will be served (secondary indexes or other stores).

?? What happens when you add a new shard with `hash % N`?
Almost every key maps to a different shard (`hash % 4` vs `hash % 5`), forcing massive data movement. Consistent hashing or a fixed large number of logical partitions mapped to nodes avoids this: only a fraction of the data moves.

#### Tricky questions
?? You sharded orders by user_id. Now the seller dashboard needs all orders for a seller. What do you do?
That's a different access pattern across all shards. Options: maintain a second copy of the data partitioned by seller_id (denormalised, updated through events or CDC), a global secondary index, or a search or analytics store (Elasticsearch, a data warehouse) for seller queries. Avoid scatter-gather on the hot path.

?? When should you NOT shard?
When a single node (with vertical scaling, read replicas, caching and query optimisation) still meets the needs, which covers most companies. Sharding adds permanent complexity: cross-shard queries, rebalancing, operational load. Partition within the DB first, archive old data, then shard when the numbers demand it.

#### Interview simulation
After estimation shows the need, say: "Writes are ~20K/s and data grows by 50TB/year, which exceeds one primary, so I'll partition by user_id using consistent hashing over 1,024 logical partitions. User-centric queries hit one partition. The seller-side view is served from a separate seller-partitioned projection updated via Kafka. Hot users are mitigated by caching, plus key salting for their write-heavy tables." Shard key, its justification, secondary patterns and hot spots: all four points covered.
