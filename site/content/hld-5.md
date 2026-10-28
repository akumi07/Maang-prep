## HLD problems I | P3 | must

### URL shortener (TinyURL / bit.ly)

#### Clarifying questions to ask
- *Core features?* → Shorten a long URL; redirect a short URL to the long one. Custom aliases? Expiry? Analytics (clicks by country or device)?
- *Scale?* → e.g. 100M new URLs/month; read:write ≈ 100:1.
- *Short code length and charset?* → base62 [a-zA-Z0-9]; as short as possible.
- *Can the same long URL get the same short code each time?* → Usually no (each request gets a new code; per-user dedup is optional).
- *Redirect type?* → 301 (permanent, cached by browsers: less load, but analytics are lost) vs 302 (temporary: every click hits us, good for analytics).
- *Abuse?* → Spam and malware URLs: safety checks, rate limits.

#### Requirements
- **Functional**: create a short URL (optional custom alias, optional expiry); redirect; basic click analytics.
- **Non-functional**: very low redirect latency (< 50ms p99), high availability for redirects (99.99%), short codes not guessable in sequence (optional), durable mappings.

#### Estimation
- Writes: 100M/month ≈ 3.3M/day ≈ **40 writes/s** (peak ~100).
- Reads: 100× → **4K redirects/s** (peak ~10K+).
- Storage: 100M × 12 × 5 years = 6B URLs × ~500B ≈ **3TB** (+ replication).
- Code length: 62^7 ≈ 3.5 trillion codes, so **7 characters** is plenty for 6B.
- Cache: 20% of daily reads cover most traffic; a few GB of hot mappings in Redis.

#### API
```
POST /api/v1/urls  {longUrl, customAlias?, expiresAt?}  → 201 {shortUrl, code}
GET  /{code}                                           → 302 Location: longUrl   (404 if missing/expired)
GET  /api/v1/urls/{code}/stats                         → {clicks, byCountry, byDay}
```

#### Data model
```
urls(code PK, long_url, user_id, created_at, expires_at, is_custom)
    — a key-value access pattern: lookup by code → KV/wide-column store or Postgres with PK index
clicks: event stream → aggregated tables (code, day, country, count)
```

#### High-level design
```
Client ──POST──▶ API GW ─▶ Shortener Service ─▶ ID Generator (range allocator) ─▶ DB (urls)
                                                     
Client ──GET /code──▶ CDN/Edge? ─▶ Redirect Service ─▶ Redis cache ─(miss)─▶ DB
                                         │
                                         └─▶ Kafka (click events) ─▶ Analytics consumers ─▶ OLAP store
```

#### Deep dives
**Generating unique short codes**: the core question. Options:
1. **Hash the long URL** (MD5/SHA → take 7 base62 chars): collisions need checking and retrying with a salt, and the same URL always gives the same code (sometimes desired).
2. **Counter + base62 encoding**: a unique numeric id → base62. Codes are unique with no collision checks. But a single DB counter is a bottleneck and SPOF, and sequential codes are guessable.
3. **Range allocation (recommended)**: a coordinator (a DB row or ZooKeeper/etcd) hands each shortener instance a **block of 1M ids**; the instance assigns from its block locally, so there's no per-request coordination. Encode with base62. For non-guessability, permute the id (e.g. multiply by a large prime mod 62^7, or a Feistel cipher) before encoding.
4. **Pre-generated random codes**: a Key Generation Service pre-creates random unused 7-char codes in a table and hands them out in batches (mark them as used). Random, unique, fast.

**Custom aliases**: insert with a unique constraint on `code`; on conflict, return 409. Keep the custom and generated namespaces from colliding (e.g. custom aliases must include a character or length the generator never uses, or simply check uniqueness).

**Redirect path (read-heavy)**: Redis cache-aside (`code → longUrl`, TTL hours); **Bloom filter** of existing codes to reject random-code scanning without DB hits (cache penetration); a negative cache for 404s. The redirect service is stateless and scales horizontally. You can even push hot codes to edge workers or a CDN.

**301 vs 302**: 302 keeps analytics accurate (every click reaches us); 301 reduces load. Most commercial shorteners use 302 (or 301 with short cache headers).

**Analytics**: the redirect service emits an async click event (code, timestamp, IP → geo, user agent) to Kafka without blocking the redirect. Stream processing aggregates per code per day; raw events go to cheap storage. Exact unique-visitor counts use HyperLogLog.

**Expiry**: check `expires_at` on read (lazy) and purge in a background batch.

#### Bottlenecks, failures and trade-offs
- The DB is mostly read-heavy and keyed, so DynamoDB or Cassandra fits (simple KV, easy scaling); Postgres with partitioning plus replicas also works at 3TB.
- ID allocator failure: instances hold blocks, so they keep working for a while; the allocator itself is a replicated DB row.
- A lost block (an instance crashed with unused ids) only wastes ids, which is acceptable.
- Hot links (a viral tweet): served from cache or CDN.
- Abuse: rate-limit creation per user or IP; scan URLs against Safe Browsing lists; blocklists.

#### Follow-up questions
?? How do you avoid two servers generating the same code?
Give each server an exclusive id range from a central allocator (an atomic DB increment of `next_block`). Within its range, a server assigns ids sequentially in memory, so codes are unique by construction, with no collision checks. Alternatively, Snowflake-style ids with worker bits, then base62.

?? How would you make codes non-sequential so people can't enumerate them?
Apply a reversible bijection to the numeric id before base62 encoding: a Feistel network or a multiplicative inverse mod 62^7. The codes look random but stay unique. Or use pre-generated random codes from a key-generation service.

?? How do you handle 10× traffic for one viral link?
It's a hot key, but reads only: Redis plus an in-process LRU on the redirect servers, or CDN caching of the redirect response with a short TTL. Click analytics stay async via Kafka, so the redirect path does no extra writes.

#### Interview simulation
**0–5 min**: clarify the features (aliases, expiry, analytics, 301/302) and scale. **5–8**: estimation, concluding 7 base62 chars, ~4K reads/s, a cache is needed, 3TB storage. **8–12**: APIs and the schema. **12–20**: diagram with separate write and redirect paths. **20–35**: deep dive on **code generation** (compare 4 options, pick range allocation plus permutation) and the **redirect path** (cache, Bloom filter, 302 for analytics). **35–40**: analytics pipeline, expiry, abuse, failures. Say why each choice was made. This problem is about clean reasoning more than complexity.

### Distributed rate limiter service

#### Clarifying questions to ask
- *Client-side library, middleware, or a standalone service?* → A shared service or middleware used by all APIs.
- *Limit keys?* → Per user, per API key, per IP, per endpoint; plan-based limits (free/pro).
- *Algorithms and accuracy?* → Some burst tolerance; approximate is OK within ~1–5%.
- *Scale?* → e.g. 1M requests/s across 500 API servers; 10M distinct keys.
- *Latency budget?* → < 2ms added per request.
- *Behaviour on limiter failure?* → Fail open (allow).

#### Requirements
- **Functional**: decide allow/deny per request for configured rules; return the remaining quota and reset time; configure rules dynamically.
- **Non-functional**: low latency, high availability (never the reason the API is down), horizontally scalable, roughly accurate.

#### Estimation
- 1M decisions/s. Each is a Redis operation of ~0.2–1ms, so a Redis Cluster of ~10–20 shards (~100K ops/s each with headroom).
- Memory: 10M keys × ~100B ≈ 1GB (tiny).

#### API
```
Internal: allow(key: "user:42:/v1/orders", cost=1) → {allowed, remaining, resetAt, retryAfterMs}
Rules API: PUT /rules/{id} {match: {plan:"free", path:"/v1/*"}, limit: 100, window: "1m", algorithm: "token_bucket", burst: 20}
HTTP response on deny: 429, Retry-After, RateLimit-Limit/Remaining/Reset headers
```

#### Data model
```
Rules: stored in DB/config service, cached in every limiter instance (pushed on change)
Counters: Redis keys  rl:{ruleId}:{subject}  → token bucket hash {tokens, ts}  (TTL = refill time × 2)
```

#### High-level design
```
Client → API Gateway / Sidecar ──(rule match, local cache of rules)──▶ Redis Cluster (Lua token bucket per key)
                    │ allowed → forward to service
                    └ denied  → 429 + headers
Rules Admin → Rules DB → change events → all gateways refresh rule cache
Metrics: allowed/denied per rule → Prometheus; denied samples → logs for abuse analysis
```

#### Deep dives
**Algorithm**: token bucket for API quotas with bursts; sliding window counter for smoother enforcement; fixed windows only where edge bursts don't matter. The Lua script makes the decision atomic in Redis (see the Distributed rate limiting lesson).

**Placement**: in the API gateway or a sidecar, so services stay free of limiter logic. Optionally a second layer inside services for business limits (e.g. 5 OTPs per hour per phone).

**Latency reduction**
- Co-locate Redis in the same AZ; pipeline requests; use persistent connections.
- **Hybrid local + global**: for very hot keys, each node takes a local allowance (e.g. 10% of the limit) and syncs counts to Redis asynchronously every 100ms. Fewer round trips, slight over-admission.

**Failure handling**: Redis timeout (5ms) → **fail open** for normal limits (log and alert); **fail closed** for security limits (login brute force). A circuit breaker around Redis. Per-node local fallback limits (coarse) while Redis is down.

**Multi-region**: per-region limits (simplest: divide the global quota by region), or async cross-region aggregation with accepted over-admission.

**Distributed denial-of-service**: rate limiting at the application layer isn't enough. Use edge protection (CDN/WAF, SYN cookies, Cloudflare/AWS Shield), plus IP reputation.

#### Bottlenecks, failures and trade-offs
- Hot keys (one big customer) put load on one Redis shard: local pre-aggregation, or splitting the key into N sub-keys with limit/N each.
- Accuracy vs latency: a strict global check per request (accurate, slower) vs local allowance (fast, approximate).
- Clock usage: use Redis server time (`TIME` inside Lua) rather than client clocks to avoid skew.

#### Follow-up questions
?? How do you update limits without redeploying?
Rules live in a DB or config service; gateways cache them and subscribe to change notifications (Kafka, Redis pub/sub, or periodic polling with ETags). New rules take effect within seconds. Version the rules for auditing.

?? How do you show users how many requests they have left?
Return the `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset` headers (IETF draft standard) or the `X-RateLimit-*` equivalents, computed from the bucket state returned by the Lua script; on 429, include `Retry-After`.

?? What if a client spreads requests across many IPs?
Limit by authenticated identity (API key or user), not just IP; add device fingerprinting and anomaly detection; edge bot management. IP limits are only a first line.

#### Interview simulation
Clarify placement, keys, accuracy and latency. Compare algorithms briefly and choose. Draw gateway → Redis Cluster with the Lua script, and the rules config flow. Deep-dive on **atomicity (Lua)**, **latency (hybrid local/global)** and **failure policy (fail open vs closed)**. Close with headers and monitoring. Tie it to experience: "At OnTheMove we had per-API-key limits at the gateway."

### Notification system

#### Clarifying questions to ask
- *Channels?* → Push (iOS/Android), SMS, email, in-app.
- *Types?* → Transactional (OTP, order updates), marketing campaigns (to millions), reminders (scheduled).
- *Scale?* → e.g. 100M notifications/day, with campaign spikes of 10M in an hour.
- *Latency?* → OTP < 5s end to end; marketing can take hours.
- *Preferences, opt-outs, quiet hours, frequency caps?* → Yes.
- *Delivery tracking (sent, delivered, opened)?* → Yes, basic.

#### Requirements
- **Functional**: send to one user or segments; templates with variables and localisation; preferences and opt-outs; scheduling; retries and provider failover; status tracking.
- **Non-functional**: at-least-once delivery with dedup; priority isolation (OTP never delayed by marketing); horizontal scale; provider rate limits respected.

#### Estimation
- 100M/day ≈ 1.2K/s average; campaigns of 10M in 1 hour ≈ **2.8K/s** extra; OTPs maybe 200/s with strict latency.
- Status records: 100M/day × ~200B = 20GB/day → time-partitioned store with TTL (e.g. 90 days).

#### API
```
POST /v1/notifications  {idempotencyKey, userId | segmentId, templateId, params, channels?, priority, scheduleAt?}
  → 202 {notificationId}
GET  /v1/notifications/{id} → {status per channel}
PUT  /v1/users/{id}/preferences {channels, categories, quietHours}
Provider webhooks: POST /v1/callbacks/{provider} (delivery receipts)
```

#### Data model
```
templates(id, channel, locale, version, subject, body)
preferences(user_id, category, channel, enabled), quiet hours, frequency caps  → cached in Redis
devices(user_id, platform, push_token, last_seen)
notifications(id, user_id, template_id, priority, created_at)          (Cassandra/Dynamo, partition by user_id)
deliveries(notification_id, channel, provider, status, attempts, provider_msg_id, updated_at)
```

#### High-level design
```
Producers (order svc, auth svc, campaign tool)
      │ POST/ event
      ▼
Notification API ─ validate, dedupe(idempotencyKey), store ─▶ Kafka topics by priority: notif.high / notif.low
                                                                     │
          Campaign service ── segment expansion (batch, throttled) ──┘
                                                                     ▼
                           Router/Processor workers: preferences, quiet hours, freq caps, template render
                                                                     │
                       ┌──────────────┬────────────────┬─────────────┴──────┐
                       ▼              ▼                ▼                    ▼
                 push.queue     sms.queue        email.queue           inapp.store (+WebSocket)
                    │              │                  │
             Push workers    SMS workers (provider A → failover B)   Email workers (SES/SendGrid)
                    │              │                  │
                 APNs/FCM      SMS gateways        SMTP API ──▶ delivery webhooks → status updates
Scheduler (delayed sends) → re-injects due notifications into Kafka
```

#### Deep dives
**Priority isolation**: separate topics and worker pools per priority; OTPs bypass campaign queues entirely. Consumers scale on the lag of each topic.

**Campaign fan-out**: a segment of 10M users is expanded in batches by a campaign service (paged queries over the user store), written to the low-priority topic at a **throttled** rate that matches provider quotas and system capacity. Campaigns are pausable and resumable (track the cursor).

**Deduplication and idempotency**: the API dedupes on the idempotency key (unique constraint or Redis `SET NX`). Workers are at-least-once; channel workers check a `(notificationId, channel)` sent marker before calling the provider (a small window of duplicates remains, acceptable for most channels; OTPs are tracked by id).

**Provider management**: per-provider rate limiters (token bucket); a circuit breaker per provider; failover to a secondary provider; cost-aware routing (cheaper SMS provider for marketing). Delivery receipts via webhooks update the status; bounces and invalid tokens disable that address or token.

**Preferences and compliance**: opt-outs enforced centrally; unsubscribe links in emails; DND or TRAI rules for SMS in India (DLT-registered templates, no promotional SMS during restricted hours); frequency caps (max 3 marketing pushes per day) via Redis counters.

**In-app notifications**: stored per user (partitioned by user, sorted by time) and pushed live over WebSocket if online; unread counts in Redis.

**Scheduling**: `scheduleAt` sends go to a delayed queue (a Redis ZSET by time, or a DB table indexed by `send_at`) polled by a scheduler that re-injects due items.

#### Bottlenecks, failures and trade-offs
- Provider outage: failover plus retries with backoff; transactional messages try another channel (OTP via SMS fails, so offer a voice call or email).
- Kafka backlog during campaigns: high-priority traffic is unaffected thanks to separate topics.
- Duplicates vs losses: we choose at-least-once (rare duplicates are better than lost OTPs or order updates).
- Status store write volume: use a write-optimised store with TTLs.

#### Follow-up questions
?? How do you guarantee an OTP arrives within 5 seconds?
A dedicated high-priority path (its own topic and workers with reserved capacity), the fastest provider with a tight timeout and immediate failover, no batching, and monitoring of end-to-end latency per provider with alerting. Optionally race two providers when one is degraded (accepting a possible duplicate).

?? How would you avoid sending the same marketing push twice when a worker crashes?
Before calling the provider, set `sent:{notificationId}:{channel}` with `SET NX` (or a DB status transition QUEUED → SENDING); after the provider responds, mark it SENT. On retry, skip items already in SENDING or SENT (with a timeout to recover stuck SENDING items). A small duplicate window remains if the crash happens between the provider call and the marker. That's acceptable.

?? How do you track whether a push notification was opened?
The client app reports an "opened" event (with the notificationId from the payload) to an analytics endpoint, which updates the delivery status asynchronously and feeds campaign metrics. Email uses tracking pixels and link redirects.

#### Interview simulation
Clarify the channels, types, priorities and scale. Draw the pipeline (API → Kafka by priority → processor → channel queues → provider workers → receipts). Deep-dive on **priority isolation**, **campaign fan-out with throttling**, **provider failover and rate limits**, and **dedup/idempotency**. Mention compliance (DND, unsubscribe). This aligns with the LLD notification design, so reuse its concepts and show the progression from classes to services.

### Chat system (WhatsApp / Messenger)

#### Clarifying questions to ask
- *1:1 and group chat?* → Both; groups up to e.g. 500 (WhatsApp allows 1,024).
- *Features?* → Send and receive in real time, delivery and read receipts (✓✓), online/last seen, message history sync across devices, media (images/video).
- *Scale?* → e.g. 500M DAU, 50 messages/user/day.
- *Message ordering and durability?* → Messages must not be lost; ordered per conversation.
- *End-to-end encryption?* → Mention it (the server stores only ciphertext).
- *Offline users?* → Store and deliver when they reconnect, plus a push notification.

#### Requirements
- **Functional**: 1:1 and group messaging, receipts (sent/delivered/read), presence, history, media sharing, push for offline users.
- **Non-functional**: low latency (< 200ms delivery for online users), high availability, no message loss, per-conversation ordering, multi-device sync, horizontal scale to millions of concurrent connections.

#### Estimation
- 500M DAU × 50 = 25B messages/day ≈ **290K msgs/s** average (peak ~1M/s).
- Concurrent connections: maybe 100M+ at peak. At ~500K–1M connections per gateway server, that's **hundreds of gateway servers**.
- Storage: 25B × 200B ≈ 5TB/day of text (plus media in object storage). Retention: WhatsApp deletes messages from the server after delivery (stored on devices); Messenger keeps history. Ask!

#### API
```
WebSocket (persistent, bidirectional):
  client→server: SEND {clientMsgId, conversationId, ciphertext, type, mediaRef?}
  server→client: ACK {clientMsgId, serverMsgId, seq}  |  MESSAGE {...}  |  RECEIPT {msgId, status}  |  PRESENCE
REST: GET /v1/conversations/{id}/messages?afterSeq=…&limit=50   (sync/history)
      POST /v1/media → pre-signed upload URL
```

#### Data model
```
messages: partition key = conversation_id, clustering = seq (or time-based message_id)   → Cassandra/ScyllaDB/HBase
          {conversation_id, seq, message_id, sender_id, type, body/ciphertext, media_ref, created_at}
conversations(id, type, members) ; user_conversations(user_id, conversation_id, last_read_seq, muted)
inbox / undelivered queue per user device (for offline delivery)
session registry: user_id/device_id → gateway_server_id   (Redis, TTL with heartbeats)
```

#### High-level design
```
Device ══WebSocket══▶ Gateway (connection) servers ──▶ Chat service ──▶ Message store (Cassandra)
   ▲                         │       ▲                     │
   │                         │       └── route to recipient's gateway (session registry in Redis)
   │                         │                             │
   │        Presence service (heartbeats → Redis)          ├─▶ Kafka (message events) ─▶ push service (offline → APNs/FCM)
   │                                                       │                         └▶ search/analytics, receipts
Media: client → pre-signed URL → S3 → CDN ; message carries media reference + key
```

#### Deep dives
**Message flow (1:1)**
1. A sends `SEND{clientMsgId}` over its WebSocket to gateway G1.
2. The chat service assigns a **per-conversation sequence number** (from the conversation's owner shard or an atomic counter), persists the message (quorum write), and replies `ACK` to A (one ✓, "sent"). The `clientMsgId` dedupes A's retries.
3. It looks up B's sessions in the registry → gateway G2 → pushes the `MESSAGE`. B's device acks → server sends a `RECEIPT delivered` to A (✓✓).
4. B offline: the message stays in B's undelivered inbox and a push notification is sent. On reconnect, B syncs with `afterSeq = last seq seen`.
5. B reads it → a `read` receipt → A's ticks turn blue.

**Ordering**: per-conversation sequence numbers assigned server-side (a single owner per conversation via consistent hashing, or an atomic `INCR` in Redis per conversation, with persistence). Clients sort by seq; gaps trigger a re-sync. Don't rely on device clocks.

**Group messages**: fan-out-on-write to each member's delivery path (fine for ≤ 1,000 members): one stored copy in the conversation partition, plus a delivery fan-out to online members' gateways and push for offline ones. For huge channels (broadcast), use fan-out-on-read (members fetch the channel feed).

**Connections at scale**: gateway servers on event-loop frameworks (Netty, Erlang/BEAM, as WhatsApp famously did) hold millions of connections each; heartbeats detect dead connections; the session registry maps user → gateway (updated on connect and disconnect); the load balancer uses consistent hashing or least connections. On deploy, drain connections gradually and make clients reconnect with jitter.

**Presence**: devices send heartbeats every ~30s; a presence service stores `last_seen` in Redis with a TTL; friends subscribe to presence changes (only for open chats, to limit fan-out); "online" = a heartbeat within the TTL.

**Multi-device**: each device keeps its own `last_synced_seq` per conversation; messages are delivered to all of a user's devices; with E2E encryption, each message is encrypted per device (the Signal protocol's sender keys for groups).

**Storage**: Cassandra/ScyllaDB partitioned by conversation_id (bucketed by time for very active chats, to keep partitions bounded), clustered by seq descending for fast "latest messages". Discord stores trillions of messages this way.

#### Bottlenecks, failures and trade-offs
- A gateway crash: clients reconnect to another gateway; undelivered messages are still in the store, so sync on reconnect fills the gaps.
- Lost ACK: the client retries with the same `clientMsgId`, and the server dedupes.
- A hot group (a celebrity's group chat): rate-limit sends, use fan-out-on-read for very large groups.
- Consistency: per-conversation ordering is strong (single sequencer); cross-conversation ordering doesn't matter.

#### Follow-up questions
?? How do you guarantee no message loss?
The client keeps the message in a local outbox until the server ACK arrives (retrying with the same clientMsgId); the server ACKs only after a durable write (quorum); delivery to recipients is tracked per device with sequence numbers; recipients sync from their last acked seq on reconnect. At-least-once everywhere plus dedup by id.

?? How do you show "typing…" indicators?
Ephemeral events sent over the WebSocket to the conversation's online members via the gateways. They're not persisted, are rate-limited (e.g. at most one every 3s), and expire automatically on the client after a few seconds.

?? How does end-to-end encryption change the design?
The server can't read the content: it routes and stores ciphertext only. Key exchange via the Signal protocol (identity keys, prekeys uploaded to the server); each device has its own keys; group messages use sender keys. Server-side search and moderation of content become impossible, so you rely on client-side features and metadata.

#### Interview simulation
Clarify the features and scale (and the history retention policy). Draw clients ⇄ gateways (WebSocket), the chat service, the message store, the session registry, the presence service and the push service. Walk the **1:1 message flow with ACKs and receipts** step by step (the interviewer will check every step). Deep-dive on **ordering (per-conversation seq)**, **offline delivery and sync**, and **connection scaling**. Mention media via S3 plus CDN and the E2E encryption implications. Your Socket.io experience gives you a real anchor for the connection-handling part.

### News feed (Twitter / Facebook timeline)

#### Clarifying questions to ask
- *Feed type?* → A home timeline of posts from accounts you follow. Ranked or chronological? (Start chronological; ranking is a follow-up.)
- *Scale?* → 300M DAU; average 200 follows; some celebrities with 100M followers.
- *Post types?* → Text plus media.
- *Latency?* → Feed loads in < 200ms p99.
- *Freshness?* → New posts appear within a few seconds to a minute.

#### Requirements
- **Functional**: create posts; follow and unfollow; view the home timeline (paginated); view a user's own timeline.
- **Non-functional**: very read-heavy, low read latency, eventual consistency OK, highly available, scales to celebrity accounts.

#### Estimation
- Posts: 300M × 1/day = 300M/day ≈ **3.5K posts/s**.
- Feed reads: 300M × 10 loads/day ≈ 3B/day ≈ **35K reads/s** (peak 100K).
- Fan-out on write: 3.5K posts/s × 200 followers = **700K timeline inserts/s** on average (celebrities skew it massively).
- Timeline cache: 300M users × 800 tweet ids × 8B ≈ 2TB of ids in Redis (cluster) for active users only.

#### API
```
POST /v1/posts {text, mediaIds}                 → 201 {postId}
GET  /v1/feed?cursor=…&limit=20                 → {posts:[…], nextCursor}
POST /v1/users/{id}/follow  | DELETE …/follow
GET  /v1/users/{id}/posts?cursor=…
```

#### Data model
```
posts(post_id [Snowflake], author_id, text, media_refs, created_at)   — sharded by post_id or author_id
follows(follower_id, followee_id) + reverse index followers(followee_id → follower_ids)  — sharded by user
user_timeline: author_id → post ids (sorted)                              
home_timeline cache: Redis list/ZSET  home:{userId} → recent post ids (capped ~800)
```

#### High-level design
```
POST: client → Post service → Posts DB (+ media S3/CDN) → Kafka "post-created"
                                                   │
                                          Fan-out workers ─(followers list)─▶ Redis home:{follower} LPUSH + LTRIM
                                                   │  (skip if author is celebrity)
READ: client → Feed service → Redis home:{user} (post ids)
                              + merge celebrity posts pulled at read time (followed celebs' recent posts, cached)
                              → hydrate ids → Post cache / Posts DB, user info cache → rank/assemble → response
```

#### Deep dives
**Fan-out on write (push)** vs **fan-out on read (pull)**
| | Push (write-time) | Pull (read-time) |
|---|---|---|
| How | on post, insert the id into every follower's timeline cache | on read, fetch recent posts from all followees and merge |
| Read cost | O(1): read a precomputed list | O(#followees) queries plus merge |
| Write cost | O(#followers), huge for celebrities | O(1) |
| Freshness | the delay is the fan-out time | always fresh |
| Wasted work | timelines of inactive users | none |

**Hybrid (what Twitter did)**: push for normal users; for **celebrities** (followers > threshold, e.g. 100K), don't fan out. At read time, merge the precomputed timeline with the recent posts of followed celebrities (cached heavily, since everyone reads them). Skip fan-out to inactive users (rebuild their timeline on demand when they return).

**Timeline storage**: Redis lists of post ids (capped, e.g. 800) per active user, replicated. Hydrate ids into full posts via a post cache (multi-get) and the author info cache.

**Pagination**: cursor = the last seen post id (Snowflake ids are time-sortable): `posts with id < cursor`.

**Ranking (follow-up)**: candidate generation (timeline plus some recommended posts) → feature fetch (engagement, affinity, recency) → ML ranking model → re-ranking for diversity and policy → the final feed. Precompute some scores offline and cache the ranked feed briefly.

**Deletes and unfollows**: delete the post → mark it deleted in the posts DB; hydration filters out deleted ids (lazy cleanup) rather than removing it from millions of timelines. Unfollow → filter at read time and clean up lazily.

**Media**: S3 plus CDN; posts store media references.

#### Bottlenecks, failures and trade-offs
- Fan-out lag during spikes (big events): it's a queue with autoscaled workers, so freshness degrades but reads still work.
- Redis memory: cap the timeline length, and keep timelines only for recently active users.
- A celebrity post read storm: the celebrity's recent-posts cache is replicated or locally cached.
- Consistency: eventual; a post may appear in followers' feeds seconds later.

#### Follow-up questions
?? Why not just query the posts of everyone I follow at read time?
At 100K feed reads/s with 200 followees each, that's 20M post lookups per second plus merging and sorting, too slow and expensive for a 200ms latency target. Precomputing (fan-out on write) moves that cost to write time, where it's spread out and asynchronous. Pull still makes sense for celebrities and inactive users.

?? How do you handle a user who follows 5,000 accounts including 50 celebrities?
Their precomputed timeline covers normal accounts; at read time we fetch the 50 celebrities' latest posts (each a hot, cached list) and k-way merge with the timeline by post id or time. That's bounded work (50 cache reads).

?? A user posts and immediately refreshes but doesn't see their own post. Fix?
Read-your-writes: the feed service always merges the user's own recent posts (from their user timeline or a short-lived cache) into their home feed response, independent of the fan-out lag.

#### Interview simulation
Clarify and estimate (the fan-out number is the key insight: say it out loud). Present push vs pull with the table, choose **hybrid**, draw both paths, then deep-dive on **celebrity handling**, **timeline cache structure and hydration**, and **pagination**. Offer ranking as an extension. This is one of the most-asked HLD problems; practise drawing it in under 10 minutes.

### Instagram (photo sharing)

#### Clarifying questions to ask
- *Core features?* → Upload photos and videos with captions, follow users, home feed, likes and comments, user profile grid. Stories? Reels? (Out of scope unless asked.)
- *Scale?* → 500M DAU; 100M uploads/day; read-heavy.
- *Media sizes?* → Photos ~2–5MB originals; multiple resized versions.
- *Latency?* → Feed < 300ms; images load fast globally.

#### Requirements
- **Functional**: upload media; generate thumbnails and resolutions; feed from follows; like and comment; profile grid; follow graph.
- **Non-functional**: high availability, low-latency global media delivery, durable media, eventual consistency for counts and feeds.

#### Estimation
- Uploads: 100M/day ≈ **1.2K/s**. At ~3MB per original plus ~1MB of resized variants, that's 100M × 4MB ≈ **400TB/day**, so massive object storage with lifecycle tiers, and CDN delivery is essential.
- Feed reads: 500M × 20 = 10B/day ≈ **115K/s**.
- Likes: billions/day → counters must be aggregated.

#### API
```
POST /v1/media/uploads {type, size}          → {uploadId, presignedUrl(s)}
POST /v1/posts {uploadIds, caption, location} → 201 {postId}
GET  /v1/feed?cursor=…                         → posts with CDN media URLs
POST /v1/posts/{id}/likes | DELETE …/likes      GET /v1/posts/{id}/comments?cursor=…
GET  /v1/users/{id}/posts?cursor=…             (profile grid)
```

#### Data model
```
media(media_id, owner_id, status, variants{thumb, 640, 1080 urls}, created_at)     → metadata DB
posts(post_id, author_id, media_ids, caption, created_at)                          → sharded by author_id
follows (graph store / sharded SQL), feed caches (Redis), 
likes(post_id, user_id, created_at) → wide-column, partition by post_id ; like_count aggregated (Redis + periodic flush)
comments(post_id, comment_id, user_id, text, created_at) → partition by post_id
```

#### High-level design
```
Upload: app → Upload service → presigned URL → S3 (originals) → event → Media processing workers
              (resize to variants, transcode video, strip EXIF/GPS, moderation ML) → S3 variants → status READY
Post:   app → Post service → Posts DB → Kafka "post-created" → Feed fan-out (hybrid, as in News Feed)
Read:   app → Feed service → Redis timelines → hydrate posts + counts → media URLs on CDN
Likes/comments: Engagement service → write to store + increment counters (Redis) → async aggregation
```

#### Deep dives
**Media pipeline**: direct-to-S3 uploads with pre-signed URLs (resumable multipart for video). An S3 event triggers processing: generate multiple resolutions and WebP/AVIF formats, extract video thumbnails, transcode video to HLS renditions, run content moderation, and strip location metadata for privacy. The post becomes visible once its media is READY (or show a placeholder). Originals move to cheaper storage tiers after N days.

**Delivery**: the CDN serves all variants. Clients request the right size for the screen (responsive variants). Long cache TTLs via content-addressed URLs.

**Feed**: same as News Feed (hybrid fan-out; celebrities pulled at read time); Instagram's feed is ranked (an ML ranking stage over candidates).

**Likes at scale**: writes go to a likes table (dedup on `(post_id, user_id)`, which makes them idempotent); counters are incremented in Redis (`HINCRBY post:{id} likes 1`) and flushed to the DB periodically; hot posts get sharded counters (N sub-counters, summed on read). Showing "liked by X and 1,234 others" uses an approximate count, fine with eventual consistency.

**Profile grid**: query the posts by author_id ordered by time (author-sharded posts table, cached).

**Instagram's actual stack (well documented)**: Django + Postgres (sharded by logical shards with ids that encode the shard), Cassandra for feeds and inbox, memcached/Redis, and S3/CDN for media. Good to mention.

#### Bottlenecks, failures and trade-offs
- Upload spikes (New Year's Eve): processing queues absorb them; autoscale the workers; the post shows "processing".
- Hot posts (celebrities): counters sharded; comments paginated and cached.
- Storage cost: tiering, dedup of identical uploads by content hash, deleting unused variants.
- Consistency: likes and counts eventually consistent; follow and unfollow reflected in feeds eventually.

#### Follow-up questions
?? How do you design the like counter for a post with 10M likes in an hour?
Each like is recorded idempotently (a unique `(post_id, user_id)` row) via an async queue. The count is served from a cached counter, incremented through sharded Redis counters (`likes:{post}:{0..15}`, picking a random shard and summing on read) and periodically reconciled with the true count from the likes table. Exactness isn't required in real time.

?? How do you prevent the same image being stored twice?
Content hashing (SHA-256 of the bytes) at upload: if the hash exists, reference the existing object. Watch the privacy implications (only dedupe within a user's scope, or for public content).

#### Interview simulation
Clarify the scope (photos plus feed plus likes; stories and reels out). Estimate media volume, which makes S3 plus CDN plus async processing the obvious centrepiece. Draw the upload pipeline first, then the feed (reuse the news feed hybrid), then engagement counters. Deep-dive on **media processing** and **hot counters**. Mentioning Instagram's real architecture choices (sharded Postgres with shard-encoded ids) adds credibility.

### Video streaming (YouTube / Netflix)

#### Clarifying questions to ask
- *Upload and watch (YouTube-style) or a curated catalogue (Netflix)?* → Pick one, or cover both: user uploads plus streaming.
- *Scale?* → 1B views/day; 500 hours of video uploaded per minute (YouTube's public figure).
- *Devices and network conditions?* → Phones on 3G to 4K TVs, so adaptive bitrate is needed.
- *Live streaming?* → Out of scope unless asked.
- *Features?* → Upload, process, watch, search, recommendations, view counts, comments.

#### Requirements
- **Functional**: upload video; transcode to multiple resolutions and formats; stream with adaptive bitrate; resume playback; search; view counts.
- **Non-functional**: smooth playback (fast start < 2s, minimal rebuffering), global availability, durable storage, cost-efficient bandwidth.

#### Estimation
- Uploads: 500 hrs/min ≈ 30K hrs of video per hour. Each hour of source ≈ several GB; transcoded into ~6–10 renditions → **petabytes per month** of storage.
- Views: 1B/day ≈ 11.5K starts/s; average bitrate ~3 Mbps × concurrent viewers (~tens of millions) → **tens of Tbps**: only feasible with CDNs and edge caches.

#### API
```
POST /v1/videos/uploads {title, size} → {videoId, resumable upload URL}
GET  /v1/videos/{id}                  → metadata + manifest URL (HLS .m3u8 / DASH .mpd), thumbnails
GET  {cdn}/videos/{id}/{rendition}/seg_000123.ts   (segments from CDN)
POST /v1/videos/{id}/views {position} (heartbeat for watch progress)
```

#### Data model
```
videos(video_id, owner_id, title, description, status{UPLOADING, PROCESSING, READY}, duration, renditions, created_at)
video_files: object storage — originals + per-rendition segments + manifests
watch_progress(user_id, video_id, position, updated_at)   → wide-column / KV
view_counts: streaming aggregation → counters store
```

#### High-level design
```
Upload: client → Upload service (resumable, chunked) → object storage (raw)
           → Kafka "video-uploaded" → Transcoding orchestrator → split into chunks (GOPs)
           → parallel transcoding workers (H.264/H.265/AV1 × 240p…4K) → package HLS/DASH segments + manifests
           → storage → mark READY → CDN pre-warm for popular uploaders
Watch:  client → Metadata API (video info + manifest URL, signed) → player fetches manifest → segments from CDN edge
           → ABR: player picks rendition per segment based on bandwidth/buffer
Analytics: player heartbeats → Kafka → view counts, watch time, recommendations features
```

#### Deep dives
**Transcoding pipeline**: split the source into chunks at keyframes, transcode the chunks **in parallel** across many workers (a DAG: split → transcode × N renditions → merge/package → thumbnails), retry failed chunks independently. Codecs: H.264 (universal), VP9/AV1 (better compression; YouTube and Netflix use them for bandwidth savings), H.265. Netflix uses **per-title/per-shot encoding** (choosing bitrate ladders per content complexity).

**Adaptive bitrate streaming (HLS/DASH)**: video is split into 2–10 second segments per rendition. The manifest lists the renditions. The player measures throughput and buffer level and switches renditions per segment, so a slow network means a lower resolution instead of stalls. Fast start: begin with a low rendition, then ramp up.

**CDN strategy**: popular content is cached at the edge (a power-law distribution: a small fraction of videos gets most views). **Netflix Open Connect** places appliances inside ISPs and pre-positions content overnight. YouTube uses Google's edge network. The long tail is served from regional caches or the origin.

**View counting**: player heartbeats → Kafka → stream aggregation (dedupe by session, filter bots) → periodic counter updates. View counts are eventually consistent (YouTube famously paused counts at "301+" for verification in the past).

**Resume watching**: periodic progress writes (every 10s) to a KV store keyed by (user, video); last write wins.

**Security and DRM**: signed URLs or tokens for segment access; DRM (Widevine, FairPlay, PlayReady) for premium content; geo-restrictions.

#### Bottlenecks, failures and trade-offs
- Transcoding cost and time: prioritise popular uploaders; do a fast low-resolution pass first so the video is watchable quickly, with higher resolutions later.
- Storage cost: don't keep every rendition for rarely watched videos (transcode on demand for the long tail), tier the originals.
- A CDN miss storm for a viral new video: origin shield, pre-warming.
- Metadata DB: read-heavy, cached; sharded by video_id.

#### Follow-up questions
?? How does adaptive bitrate streaming work?
The video is encoded at several bitrates and cut into small segments; a manifest describes them. The player downloads segments sequentially, measures download speed and buffer health, and picks the bitrate for the next segment accordingly. It switches down when the network degrades (avoiding rebuffering) and up when it improves.

?? Why split videos into chunks for transcoding?
Parallelism (a 2-hour movie transcoded by 100 workers in minutes instead of hours), fault isolation (retry only the failed chunk), and scheduling flexibility (spread across spot instances). Chunks are cut at keyframes so they can be encoded independently.

#### Interview simulation
Clarify upload vs catalogue and the scale; estimate bandwidth (which points straight to CDN). Draw the upload → transcoding DAG → storage, and the watch path via manifest → CDN segments. Deep-dive on **ABR streaming**, the **parallel transcoding pipeline** and the **CDN strategy** (mention Open Connect). Close with view counting and cost trade-offs.

### Ride-hailing (Uber / Ola)

#### Clarifying questions to ask
- *Core flows?* → A rider requests a ride → matched to a nearby driver → driver accepts → live tracking → trip → fare → payment.
- *Scale?* → e.g. 10M rides/day; 1M active drivers sending location every 4s.
- *Matching objective?* → Minimise pickup ETA; fairness to drivers; acceptance rates.
- *Surge pricing?* → Yes, dynamic by zone.
- *Global or per city?* → Many cities; each city mostly independent.

#### Requirements
- **Functional**: driver location updates; rider requests; matching; trip lifecycle; live tracking; fare estimates and surge; payments; ratings.
- **Non-functional**: matching in seconds; location updates at high write rates; no double assignment of drivers; high availability (people stranded otherwise); city-level isolation.

#### Estimation
- Location updates: 1M drivers / 4s = **250K writes/s** (ephemeral: only the latest location matters, plus a trip trail).
- Ride requests: 10M/day ≈ 115/s average, peaks ~1K/s, with each match querying nearby drivers.
- Trip storage: 10M × 5KB = 50GB/day.

#### API
```
Driver: WS/HTTP POST /v1/drivers/me/location {lat, lng, heading, ts}  (every 4s)
        POST /v1/drivers/me/status {ONLINE|OFFLINE}
        Push: RIDE_OFFER {tripId, pickup, eta} → POST /v1/trips/{id}/accept|reject
Rider:  POST /v1/fare-estimates {pickup, drop, type} → {fare, surgeMultiplier, eta}
        POST /v1/trips {pickup, drop, type, estimateId} → {tripId, status: MATCHING}
        WS: TRIP_UPDATE {status, driverLocation, eta}
```

#### Data model
```
Driver location: in-memory geo index (sharded by city/H3 cell) + Redis GEO; last location TTL
drivers(id, vehicle, status, rating, city)        trips(id, rider_id, driver_id, status, pickup, drop, fare, timestamps) → sharded SQL by city/trip_id
trip_locations(trip_id, ts, lat, lng) → time-series / wide-column (for fare & disputes)
surge(city, h3_cell, multiplier, computed_at) → Redis
```

#### High-level design
```
Driver app ─(4s)─▶ Location gateway ─▶ Kafka "driver-locations" ─▶ Location service (geo index per city, in-memory, replicated)
                                                         └─▶ trip trail store, supply/demand aggregator → Surge service
Rider app ─▶ API GW ─▶ Trip service ─▶ Matching/Dispatch service ─(nearby drivers by H3 rings)─▶ Location service
                                   │                            └─ ETA service (routing engine, road graph)
                                   ├─ offer to driver(s) via push/WS gateway; driver accepts → atomic assignment
                                   ├─ Pricing service (base fare + surge)
                                   └─ Payment service (after trip) ; Notification service
Live tracking: driver locations of active trips → pub/sub → rider's WS connection
```

#### Deep dives
**Geo indexing**: Uber uses **H3** hexagonal cells. Drivers are indexed by cell in memory (`cell → set of available drivers`), sharded by city or region. A query looks at the rider's cell plus k rings of neighbours until enough candidates are found. Location updates move a driver between cells (O(1)). In memory because the data is ephemeral and the write rate is huge; replicated for failover; rebuildable from the stream within seconds.

**Matching / dispatch**
1. Candidates: nearby available drivers of the right vehicle type.
2. Rank by **ETA** (road-network routing, not straight-line distance), plus acceptance probability and fairness.
3. Offer to the best driver with a ~15s timeout (or to a few at once, first-accept-wins). On reject or timeout, move to the next.
4. **Atomic assignment**: driver status AVAILABLE → ASSIGNED with a conditional update (CAS in the location service, or a DB `UPDATE … WHERE status='AVAILABLE'`), so a driver can't be double-booked.
5. Advanced: **batch matching** in short windows (e.g. 2s), solving the assignment problem across many riders and drivers to minimise total ETA (globally better than greedy).

**Surge pricing**: aggregate demand (requests, app opens) and supply (available drivers) per H3 cell per minute through stream processing; the multiplier follows the demand/supply ratio with smoothing and caps; it's shown in fare estimates and locked into the trip when accepted.

**Trip state machine**: REQUESTED → MATCHING → DRIVER_ASSIGNED → DRIVER_ARRIVED → IN_PROGRESS → COMPLETED (or CANCELLED with a reason and fee rules). Persisted in a DB with transitions validated; events published for notifications and payments.

**Location tracking for riders**: the active trip's driver updates are routed (pub/sub keyed by tripId) to the rider's WebSocket.

**City isolation**: deploy cells per region or city so one city's surge or outage doesn't affect others; data partitioned by city.

#### Bottlenecks, failures and trade-offs
- 250K location writes/s: don't persist every update to a DB. Keep it in memory, plus an async trail for active trips only.
- Location service node failure: replicas, or rebuild from the Kafka stream (state recovers within one update interval).
- Matching contention in hotspots (an airport after a concert): batch matching, queueing systems at airports.
- Network partitions: drivers' apps buffer updates; trips continue offline; payments are settled later.

#### Follow-up questions
?? How do you prevent two riders from being matched to the same driver?
The assignment is an atomic state transition on the driver (compare-and-set from AVAILABLE to ASSIGNED, or a DB conditional update, or by routing all dispatch for a geo-shard through a single matcher instance that serialises decisions). The loser of the race moves to the next candidate.

?? Why use ETA instead of distance for matching?
A driver 500m away across a river or on a one-way road may be 10 minutes away, while one 1.5km away on the same road is 3 minutes away. ETA from a routing engine (road graph plus live traffic) reflects the actual pickup time, which is what riders experience.

?? How would you compute surge pricing?
Stream-aggregate demand and supply per geo cell per short window, compute a ratio, map it to a multiplier via a smoothed, capped function (avoiding oscillation), publish it to a cache read by the pricing service, and lock the price at request time so it doesn't change mid-booking. Also, surge itself increases supply (it attracts drivers).

#### Interview simulation
Clarify the flows and scale; the location update rate drives the design (in-memory geo index). Draw the location pipeline, then the request → matching → assignment → tracking flow. Deep-dive on the **geo index (H3, rings)**, **matching with atomic assignment**, and **surge**. Mention city-based partitioning and the trip state machine. Link to the LLD cab-booking design to show the class-level depth too.

### File storage and sync (Dropbox / Google Drive)

#### Clarifying questions to ask
- *Features?* → Upload and download files, sync across devices automatically, share files and folders, version history. Real-time collaborative editing? (Out of scope; that's Google Docs.)
- *File sizes?* → Up to e.g. 50GB.
- *Scale?* → 50M DAU; 500M files/day changed.
- *Conflict handling?* → Two devices edit offline: keep both versions ("conflicted copy").
- *Bandwidth efficiency?* → Only upload changed parts.

#### Requirements
- **Functional**: upload, download and delete; automatic sync across devices; offline edits that sync later; sharing with permissions; versioning and restore.
- **Non-functional**: durability (never lose a file), consistency of the file metadata, bandwidth and storage efficiency, reasonable sync latency (seconds).

#### Estimation
- 500M file changes/day ≈ **6K changes/s**; average file 1MB but changes are small deltas.
- Storage: users × quota; with dedup, total storage in the exabyte range for Dropbox-scale (they built their own storage system, Magic Pocket).

#### API
```
POST /v1/files/commit {path, blockHashes[], size, parentRevision}  → {revision} | 409 conflict | {missingBlocks[]}
PUT  /v1/blocks/{hash}  (upload a block; idempotent by content hash)
GET  /v1/blocks/{hash}
GET  /v1/changes?cursor=… (long-poll / notification) → list of metadata changes since cursor
POST /v1/shares {path, userId, role}
```

#### Data model
```
Block storage: content-addressed blocks (4MB chunks), key = SHA-256(block) → object storage
Metadata DB (sharded by namespace/user, strongly consistent):
  files(namespace_id, path, file_id, latest_revision, is_deleted)
  revisions(file_id, revision, block_hashes[], size, modified_by, created_at)
  journal(namespace_id, seq, change)   ← per-namespace ordered change log for sync cursors
  shares(namespace_id, user_id, role)
```

#### High-level design
```
Desktop/Mobile client (watcher + chunker + local DB of synced state)
   │ 1. chunk changed file → hashes
   │ 2. ask metadata service which blocks are missing
   ▼
Block service ⇄ Object storage (dedup by hash)         Metadata service ⇄ Metadata DB (sharded SQL) ⇄ Journal
   │ 3. upload only missing blocks (parallel)                │ 4. commit new revision (optimistic concurrency on parentRevision)
                                                            ▼
                                Notification service (long-poll/WebSocket) → other devices: "namespace X changed, cursor N"
                                                            → devices fetch changes since cursor → download missing blocks → reconstruct
```

#### Deep dives
**Chunking and deduplication**: split files into blocks (fixed 4MB, or **content-defined chunking** with rolling hashes so that an insertion doesn't shift all later block boundaries). The block's hash is its id, so identical blocks are stored once across all users (huge savings for common files) and only changed blocks are uploaded on edits (delta sync).

**Commit protocol**: the client uploads the missing blocks, then commits the new block list with `parentRevision`. If the server's latest revision ≠ parentRevision, there's a **conflict**: the server rejects the commit, and the client saves its version as a "conflicted copy" next to the server's version. Metadata updates are transactional (a strongly consistent DB).

**Sync notifications**: each namespace has an ordered **journal** (sequence numbers). Devices keep a cursor and long-poll or subscribe for "changed" signals, then fetch the changes since their cursor. Ordering and completeness come for free.

**Storage durability**: object storage with replication or erasure coding across zones; block integrity verified by hash on read.

**Sharing**: shared folders are namespaces mounted into several users' trees, with permission checks in the metadata service.

**Versioning**: revisions keep their block lists; old blocks are retained per the version retention policy; garbage collection of unreferenced blocks uses reference counting or mark-and-sweep.

#### Bottlenecks, failures and trade-offs
- The metadata DB is the heart: sharded by namespace, with strong consistency per namespace (Dropbox moved metadata to a sharded MySQL system called Edgestore).
- Hot shared folders (a company-wide folder): many devices sync at once, so cache the journal reads and fan out notifications efficiently.
- Large uploads: resumable and parallel block uploads; the client retries each block idempotently.
- Security: encryption at rest and in transit; dedup across users can leak information (did someone else upload this file?), so some services dedupe only per user.

#### Follow-up questions
?? Why split files into blocks?
Delta sync (only changed blocks are re-uploaded), deduplication (identical blocks stored once), parallel and resumable transfers, and efficient versioning (new revisions share unchanged blocks).

?? How are conflicting edits from two offline devices resolved?
Optimistic concurrency: each commit states the revision it was based on. The first commit wins; the second is rejected as a conflict, and that client keeps its version as a separate "conflicted copy" file for the user to merge manually. Automatic merging only for formats that support it (like docs with OT/CRDTs).

?? How does a device learn about changes quickly without constant polling?
A notification channel (long-poll or WebSocket) tells devices that a namespace changed; the device then calls the changes API with its cursor. The notification carries no data, just a nudge, so the system stays simple and correct even if a notification is lost (the next poll catches up).

#### Interview simulation
Clarify sync, sharing, versioning and conflict expectations. The core insight to state early: "Split files into content-addressed blocks: dedup plus delta sync. Metadata is separate and strongly consistent, with a per-namespace journal for sync." Draw client ⇄ block service and metadata service, plus notifications. Deep-dive on **chunking and dedup**, the **commit protocol with conflicts**, and **sync via journal cursors**. Mention Dropbox's real systems (Magic Pocket, Edgestore) for extra credibility.

### Search autocomplete (typeahead)

#### Clarifying questions to ask
- *What are we completing?* → Search queries (like Google or Amazon) by popularity; maybe personalised.
- *Scale?* → e.g. 10B searches/day; every keystroke triggers a request (debounced).
- *Latency?* → < 50–100ms p99 per keystroke.
- *Freshness?* → New trending queries should appear within minutes or hours.
- *Number of suggestions?* → Top 5–10 per prefix.
- *Filter offensive or blocked terms?* → Yes.

#### Requirements
- **Functional**: given a prefix, return the top K completions by popularity (optionally personalised and localised); support typos (a nice-to-have).
- **Non-functional**: very low latency, high QPS, high availability, eventual freshness.

#### Estimation
- 10B searches/day × ~5 keystroke requests (with debounce) = 50B requests/day ≈ **600K QPS** (peak 1M+), so it must be served from memory, with heavy caching including client-side and CDN.
- Query vocabulary: maybe 1B distinct queries, but the top ~100M cover nearly all traffic. The trie or index must fit in memory across shards.

#### API
```
GET /v1/autocomplete?q=dol&limit=8&lang=en&loc=IN  → ["dolo 650", "dolo 650 uses", "dolly", …]
```

#### Data model
```
Offline: query logs → aggregated counts per (normalized query, locale, time window) → top-K per prefix
Online serving: Trie / prefix map with precomputed top-K at each node, sharded by prefix range
               (or Redis: key = "ac:{prefix}" → ZSET/list of top suggestions)
```

#### High-level design
```
Client (debounce 100ms, local cache of prefix results)
   │
CDN/edge cache (popular prefixes)  →  Autocomplete service (stateless) → in-memory Trie shards (by prefix)
                                                                    ↑ periodic snapshot load
Data pipeline: search logs → Kafka → stream/batch aggregation (counts with time decay, filter blocked terms)
               → build Trie with top-K per node → versioned snapshot in object storage → serving nodes hot-swap
Trending path: streaming top-K (Count-Min Sketch + heap) for the last hour → merged at query time
```

#### Deep dives
**Trie with precomputed top-K**: each node stores the top K completions for its prefix, so a query is O(length of prefix) to reach the node, then return its list with no subtree traversal. Updating top-K lists is done offline when building the trie (bottom-up merge of the children's top-K).

**Sharding**: by prefix (first 1–2 characters, rebalanced by traffic, since "s" is much bigger than "x"), or replicate the whole trie when it fits in memory per node (simpler; scale by replicas).

**Building and freshness**: a batch job (hourly or daily) aggregates query counts with **time decay** (recent searches weigh more), filters (offensive, PII, low counts), builds the trie, and serializes a snapshot; serving nodes load the new version and swap atomically (blue/green). For trending queries (news events), a streaming path computes heavy hitters over the last N minutes and merges them into the results.

**Latency tricks**: client debounce (wait until the user pauses typing) and a client cache (backspace hits the cache); CDN caching of popular short prefixes (they're identical for everyone in a locale); HTTP keep-alive and HTTP/2; return small payloads.

**Personalisation**: blend the global top-K with the user's recent searches (stored per user) at query time; it's a re-ranking step.

**Typo tolerance**: fuzzy matching via edit distance over the trie (a bounded search) or a spell-correction stage. Costly, so apply it only when there are no or few results.

#### Bottlenecks, failures and trade-offs
- Memory: compress the trie (radix trees, succinct structures), keep only frequent queries.
- Hot prefixes ("a", "i"): served from the CDN or client caches.
- Freshness vs cost: full rebuilds hourly plus a streaming trending overlay.
- Safety: filtering pipeline and blocklists, a rapid takedown mechanism (a hot-patch blocklist applied at serve time).

#### Follow-up questions
?? Why precompute top-K at each trie node instead of traversing the subtree?
A subtree traversal for short prefixes ("a") touches millions of nodes, far too slow for per-keystroke latency. Precomputing makes each lookup O(prefix length), at the cost of memory and offline compute, which is a good trade for a read-dominated system.

?? How do you get a breaking news query ("earthquake delhi") into suggestions within minutes?
A streaming pipeline over recent query logs (Kafka + Flink) computes trending heavy hitters per locale using Count-Min Sketch plus a min-heap over sliding windows; the results go to a small "trending" index merged with the trie results at query time, with safety filtering applied.

#### Interview simulation
Clarify the scale (keystroke QPS), latency and freshness. Estimate (it leads to in-memory serving plus caching). Draw the **offline build pipeline** and the **online serving path** separately. Deep-dive on the **trie with top-K**, **sharding**, and **freshness (batch plus streaming trending)**. Mention client debounce and CDN caching; these are cheap but often forgotten wins.
