## Building blocks II | P3 | must

### Consistent hashing

#### Core idea
**Consistent hashing** maps both **keys** and **nodes** onto the same circular hash space (a "ring"). A key belongs to the first node clockwise from it. When a node is added or removed, only the keys in that node's segment move, about **1/N of the keys** instead of nearly all of them (as with `hash % N`).

#### How it works
```
          0
     N3 ●───── k1 → N1
   /              \
 k4 → N3          ● N1
  |                |
   \   k3 → N2   /
     ●───── k2 → N2
     N2
```
- Hash each node (e.g. `hash(nodeId)`) onto a ring of 2^32 or 2^64 positions.
- For a key, compute `hash(key)` and walk clockwise to the first node: `TreeMap.ceilingEntry(hash)`, wrapping around to `firstEntry()`.
- **Virtual nodes (vnodes)**: each physical node gets 100–200 positions on the ring. This evens out the load (without vnodes, random positions give very uneven segments) and, when a node fails, spreads its load across *all* the remaining nodes instead of dumping it on one neighbour. Vnodes can also be weighted by capacity.
- **Replication**: store each key on the next R distinct physical nodes clockwise (Dynamo, Cassandra).

```java
class ConsistentHashRing<T> {
    private final TreeMap<Long, T> ring = new TreeMap<>(); private final int vnodes;
    ConsistentHashRing(int vnodes) { this.vnodes = vnodes; }
    void add(T node) { for (int i = 0; i < vnodes; i++) ring.put(hash(node + "#" + i), node); }
    void remove(T node) { for (int i = 0; i < vnodes; i++) ring.remove(hash(node + "#" + i)); }
    T nodeFor(String key) {
        if (ring.isEmpty()) throw new IllegalStateException("no nodes");
        Map.Entry<Long, T> e = ring.ceilingEntry(hash(key));
        return (e != null ? e : ring.firstEntry()).getValue();
    }
    private static long hash(String s) {          // use a good 64-bit hash (MurmurHash3/xxHash) in practice
        long h = 1125899906842597L; for (char c : s.toCharArray()) h = 31 * h + c; return h ^ (h >>> 33);
    }
}
```
**Alternatives**: **rendezvous hashing** (highest random weight: for each key, pick the node with the highest `hash(key, node)`; simple, no ring, O(N) per lookup), **jump consistent hash** (Google: O(1) memory, nodes numbered 0..N−1, only supports adding or removing at the end), and **fixed partitions + mapping table** (Kafka, Elasticsearch, Redis Cluster's 16,384 hash slots).

#### Real-world example
**Amazon Dynamo** and **Cassandra** use consistent hashing with vnodes to distribute data and replicas. **Redis Cluster** uses 16,384 fixed **hash slots** (`CRC16(key) % 16384`) assigned to nodes; resharding moves slots. **Discord** and many chat systems route a channel or guild to the node that holds its state using consistent hashing, so a node failure only reassigns that node's channels.

#### Interview questions
?? Why is `hash(key) % N` bad for distributed caches?
When N changes (scaling or failure), almost every key maps to a different node: a massive cache-miss storm that can overload the database. Consistent hashing moves only ~1/N of the keys.

?? What problem do virtual nodes solve?
Uneven distribution (a few random points on the ring create very different segment sizes) and uneven failover (a failed node's entire load would go to its single clockwise neighbour). With many vnodes per server, load is statistically balanced, and failover spreads across all nodes. Heterogeneous hardware can be weighted with more vnodes.

#### Tricky questions
?? Consistent hashing gives even key distribution, but one node is still overloaded. Why?
**Hot keys**: even distribution of keys isn't even distribution of *traffic*. One celebrity key gets 1,000× the traffic. Fixes: replicate hot keys to several nodes and read randomly, add a local cache in front, split the key.

#### Interview simulation
In any design with a distributed cache or partitioned store, mention it: "Keys are distributed with consistent hashing with virtual nodes, so adding cache nodes during a sale only remaps about 1/N of the keys and doesn't stampede the database." Be ready to code the TreeMap ring in about 5 minutes if asked; it's a popular follow-up.

### Search and Elasticsearch

#### Core idea
Full-text search needs an **inverted index**: a map from each **term** to the list of documents containing it (a posting list). **Elasticsearch/OpenSearch** (built on Apache Lucene) provide distributed inverted indexes with relevance scoring, fuzzy matching, filters and aggregations. They're used *alongside* a primary database, not instead of it.

#### How it works
**Indexing pipeline**: document → **analyser** (tokeniser + filters: lowercase, stop words, stemming "running" → "run", synonyms, edge n-grams for autocomplete) → terms → posting lists (doc ids, term frequency, positions).
```
"Dolo 650 Tablet"  →  [dolo] [650] [tablet]
term "dolo"   → [doc1, doc7, doc42]
term "tablet" → [doc1, doc3, doc7, ...]
query "dolo tablet" → intersect/union posting lists → score → top K
```
**Relevance scoring**: **BM25** (the default): a term matters more if it's frequent in the doc (with saturation), rare across the corpus (IDF), and the doc is short (length normalisation). Combine it with business signals (popularity, availability, margin) through `function_score` or a re-ranking stage, or learning to rank.

**Architecture**
- An index is split into **primary shards** (fixed at creation) plus **replica shards** (for availability and read throughput), spread across nodes.
- A query goes to a **coordinating node**, which scatters it to one copy of each shard; each returns its top K; the coordinator merges and fetches the documents.
- **Near-real-time**: new documents become searchable after a **refresh** (default 1s), when Lucene opens a new segment. Segments are immutable and periodically **merged**.
- Updates are delete + reinsert internally (expensive for frequently updated fields).

**Keeping ES in sync with the primary DB**
1. Dual write from the app (simple, but risks inconsistency when one write fails).
2. **CDC**: DB → Debezium → Kafka → indexer → ES (reliable, ordered per key, replayable). Preferred.
3. Periodic batch reindex (for full rebuilds; use aliases for zero-downtime swaps).

**Other features**: filters (cached bitsets, no scoring), aggregations (facets: brand counts, price ranges), autocomplete (edge n-grams or completion suggesters), typo tolerance (fuzzy matching via Levenshtein automata), geo queries, and vector search (kNN, for hybrid semantic search).

#### Real-world example
**Medicine search at 1mg-like scale**: Postgres is the source of truth for the catalogue; changes flow through Kafka to an Elasticsearch index with analysers for drug names (synonyms: "paracetamol" ⇄ "acetaminophen", brand ⇄ salt), phonetic and fuzzy matching for misspellings ("dollo"), and boosting by availability and popularity. Your "Elasticsearch" skill plus search latency work makes this a natural deep-dive to prepare.

#### Interview questions
?? Why not just use `LIKE '%term%'` in SQL?
A leading wildcard can't use a B-tree index, so it's a full scan. There's no relevance ranking, no stemming, synonyms or typo tolerance, and no facets. Postgres has full-text search (`tsvector` + GIN) and trigram indexes, which work for moderate needs, while Elasticsearch scales horizontally with richer relevance and aggregation features.

?? How do you keep a search index consistent with the database?
Treat the DB as the source of truth and feed ES asynchronously through CDC/Kafka, with idempotent upserts keyed by document id (and a version for ordering, so an older event can't overwrite a newer document). Accept a second or so of lag; for "just edited" items, read critical fields from the DB. Periodically reconcile or reindex using aliases.

#### Tricky questions
?? Why can't you change the number of primary shards of an existing index?
Document routing is `hash(_routing) % number_of_primary_shards`, so changing it would invalidate where every document lives. You must reindex into a new index (or use the split/shrink APIs, which only allow multiples or factors). Plan shard counts by expected size (aim for roughly 10–50GB per shard).

?? Deep pagination (`from: 10000, size: 20`) is slow or forbidden. Why?
Each shard must produce its top `from + size` results and the coordinator sorts them all, so cost grows with depth (`index.max_result_window`, 10,000 by default). Use `search_after` (cursor-based) for deep scrolling, or the point-in-time API.

#### Interview simulation
**Interviewer:** "Design product search for an e-commerce site."

**Clarify:** "What's the catalogue size? Query volume? Languages? Typo tolerance needed? Personalisation? How fresh must stock and price be?"

**Answer:** Catalogue DB → CDC → Kafka → indexer → ES (analysers, synonyms, edge n-grams for autocomplete); a search service in front (query parsing, spell correction, filters and facets, business boosting); a separate autocomplete path (a prefix index or a trie of popular queries cached in Redis); price and stock fetched live or from a fast cache at render time, because the search index lags; click logs feeding learning to rank. Mention index aliasing for reindexes and the shard sizing.

### Blob and object storage

#### Core idea
**Object storage** (AWS S3, GCS, Azure Blob, MinIO) stores large unstructured files (images, videos, documents, backups, logs) as **objects** in buckets, addressed by key, with effectively unlimited capacity and very high durability (S3: eleven 9s). Databases store **metadata and the object's key**, never the large binary itself.

#### How it works
- An object = key + bytes + metadata. Operations: PUT, GET (including byte **ranges**), DELETE, LIST by prefix. There's no in-place partial update (you rewrite the object).
- Durability through replication or erasure coding across availability zones. Strong read-after-write consistency on S3 since Dec 2020.
- **Storage classes and lifecycle policies**: Standard → Infrequent Access → Glacier (cheaper storage, costlier or slower retrieval), with automatic transitions and expiry.
- **Multipart upload**: large files go in parallel parts (5MB–5GB each), retryable per part, assembled on completion.
- **Pre-signed URLs**: the backend signs a time-limited URL so **clients upload or download directly** to S3, keeping big bytes off your servers.
- Serve publicly via a **CDN** in front of the bucket (origin access control so the bucket stays private).
- Events: object created → notification (SQS, Lambda) → processing pipeline (thumbnails, virus scan, transcoding, PDF text extraction).

**Typical upload flow**
```
1. Client → API: POST /uploads {filename, size, type}
2. API: validate, create metadata row (status=PENDING), return pre-signed PUT URL (+ object key)
3. Client → S3: PUT bytes directly (multipart for big files)
4. S3 event → queue → worker: verify, scan, generate thumbnails/transcode, update metadata status=READY
5. Readers get CDN URLs (signed if private)
```

#### Real-world example
Your **NeuronixAI** pipeline: "PDF extraction from S3, chunking, embeddings." Users upload PDFs via pre-signed URLs; an S3 event (or your Kafka "document uploaded" event) triggers async processing: extract text, chunk, embed, store vectors in pgvector, mark the document READY. The API never streams the file bytes itself. Draw exactly this in interviews.

#### Interview questions
?? Why not store images in the database as BLOBs?
It bloats the DB (backups, replication and the buffer cache all suffer), it's expensive storage, there's no CDN integration, and app servers must stream the bytes. Object storage is cheaper, effectively infinite, durable, and integrates with CDNs and pre-signed URLs. The DB keeps just the key, metadata and access control.

?? How do you let users upload large files reliably?
Pre-signed multipart uploads directly to object storage: the client splits the file, uploads the parts in parallel with retries (resumable), then completes the upload. The server tracks the upload state in metadata and processes the file asynchronously after an S3 event notification.

#### Tricky questions
?? How do you secure private files served via a CDN?
Keep the bucket private (only the CDN can read it, via origin access control), and give users **signed URLs or signed cookies** with a short expiry, generated after the app checks authorisation. Never make the bucket public just to serve files.

#### Interview simulation
In designs involving media (WhatsApp images, Instagram, YouTube, Dropbox), state the pattern immediately: "metadata in the DB, bytes in object storage, uploads via pre-signed URLs, async processing on upload events, delivery via CDN." Then estimate storage and bandwidth. That covers 30% of those designs in one sentence.

### Message queues vs event streams

#### Core idea
Asynchronous messaging **decouples** producers from consumers in time and availability, **absorbs spikes** (buffering) and enables **fan-out**. There are two families:
- **Message queues** (RabbitMQ, SQS, ActiveMQ): messages are **work items**. A consumer takes one, processes it, acks it, and it's **deleted**. Competing consumers share the work.
- **Event streams / logs** (Kafka, Kinesis, Pulsar, Redis Streams): messages are **events appended to a durable log**. Consumers track their own **offset**, many independent consumer groups can read the same events, and events can be **replayed**.

#### How it works
| | Queue (RabbitMQ/SQS) | Log (Kafka) |
|---|---|---|
| Retention | until acked | time- or size-based (days to forever), independent of consumption |
| Consumers | competing; each message to one consumer | consumer groups; each group gets all events; within a group, partitions are split |
| Ordering | FIFO per queue (SQS FIFO per group id); weakened with competing consumers | strict per partition |
| Replay | no | yes (reset offsets) |
| Routing | rich (RabbitMQ exchanges: direct, topic, fanout) | by topic plus a key → partition |
| Throughput | 10Ks/s per queue | millions per second per cluster |
| Per-message features | delays, priorities, TTL, per-message ack/nack, DLQ | batching; DLQ by convention |
| Best for | task distribution, jobs, RPC-ish workflows | event-driven architecture, CDC, analytics pipelines, event sourcing |

**Delivery semantics**: *at-most-once* (ack before processing: can lose), **at-least-once** (ack after processing: can duplicate, the usual choice), *exactly-once* (Kafka transactions within Kafka; otherwise at-least-once + idempotent consumers).

**Patterns**
- **Work queue**: a background job (send email, generate PDF).
- **Pub/sub fan-out**: an "OrderPlaced" event consumed by inventory, notifications, analytics and loyalty, each independently.
- **Load levelling**: a queue in front of a slow service absorbs a 10× spike.
- **DLQ**: after N failed attempts, park the message for inspection.
- **Delayed / retry queues**: retry after a backoff without blocking the main flow.
- **Outbox**: reliably publish events as part of a DB transaction (see Distributed systems).

#### Real-world example
**Your Tata 1mg work**: "integrated Kafka for reliable event-driven service communication." The typical shape: the order service publishes `OrderPlaced` (key = orderId, so per-order ordering); inventory, notification and analytics consumer groups each process it independently; consumers are idempotent (dedupe by event id), with retries and a DLQ topic. NeuronixAI uses Kafka for **async document processing**, a work-queue use of a log.

#### Interview questions
?? Kafka vs RabbitMQ: how do you choose?
Kafka for high-throughput event streams, multiple independent consumers, replay, ordering per key, event sourcing or CDC, and long retention. RabbitMQ (or SQS) for task queues with per-message acks, priorities, delays, flexible routing and lower operational overhead at moderate scale. Many companies run both.

?? What does "at-least-once" imply for consumers?
Duplicates will happen (a consumer processes a message, then crashes before committing the offset or ack, so it's redelivered). Consumers must be **idempotent**: dedupe on a message or event id (a processed-ids table updated in the same DB transaction as the side effect), or use naturally idempotent operations (upserts, set-status-if-not-already).

#### Tricky questions
?? You need strict ordering per user but high parallelism. How?
Partition by user_id: all events for a user go to one partition (ordered), and different users spread across many partitions processed in parallel by the consumer group. Within a consumer, don't process one partition's messages concurrently unless you keep per-key ordering (e.g. per-key executors).

?? Why might adding consumers not increase Kafka throughput?
In a consumer group, each partition is consumed by at most one consumer. If the topic has 6 partitions, the 7th consumer sits idle. Increase the number of partitions (planning ahead, since repartitioning changes key placement), or parallelise processing inside consumers.

#### Interview simulation
When you introduce async processing in a design, specify: "**What** goes on the queue (an event or a command), the **key** (for ordering), the **delivery guarantee** (at-least-once), **idempotency** in consumers, **retries + DLQ**, and **monitoring consumer lag**." Example: "Order events go to Kafka keyed by orderId; the notification consumer group is idempotent on eventId; failures retry 3 times with backoff then go to a DLQ topic; we alert on lag above 1 minute."

### API gateway and service discovery

#### Core idea
- An **API gateway** is the single entry point for client traffic to a microservice system. It handles cross-cutting concerns (routing, authentication, rate limiting, TLS, request transformation, aggregation) so services don't each reimplement them.
- **Service discovery** lets services find each other's network locations dynamically as instances scale, move and fail.

#### How it works
**API gateway responsibilities**
- Routing (`/orders/** → order-service`), API versioning.
- Authentication (validate JWTs), coarse authorisation (scopes), API keys and quotas.
- Rate limiting, request size limits, WAF integration.
- TLS termination, compression, CORS.
- Request/response transformation, protocol translation (REST → gRPC).
- **Aggregation / BFF (Backend-for-Frontend)**: one call from the mobile app fans out to several services and composes the response. Often a separate BFF per client type (mobile, web).
- Observability: access logs, metrics, trace-id injection.
- Examples: Kong, AWS API Gateway, Apigee, Spring Cloud Gateway, Envoy/Istio ingress, Nginx.

**Pitfalls**: the gateway becomes a **bottleneck or SPOF** (scale it horizontally, keep it stateless); a **"god gateway"** full of business logic (keep business logic in services); extra latency (a hop, typically about 1–5ms).

**Service discovery**
- **Client-side**: services register in a registry (Eureka, Consul, etcd); clients query it and load-balance themselves (Spring Cloud LoadBalancer, gRPC).
- **Server-side**: clients call a stable address (a load balancer or a Kubernetes Service DNS name); the platform routes to healthy instances.
- **Kubernetes**: Services plus CoreDNS (`orders.default.svc.cluster.local`) and readiness-based endpoints. That's discovery built in, so Eureka is rarely needed on Kubernetes.
- **Service mesh** (Istio, Linkerd): a sidecar proxy per pod handles discovery, L7 load balancing, retries, timeouts, mTLS and telemetry, with no library code needed.

#### Real-world example
**Netflix** pioneered the gateway (Zuul) and client-side discovery (Eureka + Ribbon) pattern on AWS; much of the industry has since moved to Kubernetes-native discovery plus Envoy-based gateways and meshes. A typical Indian e-commerce stack: AWS ALB → Kong or Spring Cloud Gateway (JWT validation, rate limits) → services on EKS discovered via Kubernetes Services.

#### Interview questions
?? Why use an API gateway instead of exposing services directly?
One stable entry point that hides the internal topology; centralised authentication, rate limiting and TLS; fewer client round trips via aggregation or a BFF; independent evolution of internal services; consistent logging and metrics. The cost is an extra hop and a component that must be highly available.

?? Client-side vs server-side discovery?
Client-side: the client fetches the instance list and balances itself. One less hop and smarter balancing, but every client needs the library logic (it's language-specific). Server-side: the client calls a fixed endpoint (a load balancer or DNS) and the infrastructure routes. Simpler clients, but an extra hop. Kubernetes and meshes make server-side or sidecar approaches the common default.

#### Tricky questions
?? Should JWT validation happen at the gateway, at each service, or both?
Validating at the gateway rejects bad traffic early. Services should still verify the token (or a gateway-signed internal token) and do fine-grained authorisation, because internal traffic can bypass the gateway (zero-trust). At a minimum, services must check authorisation on resources they own.

#### Interview simulation
In HLD diagrams, draw "Clients → CDN → API Gateway → services" and list the gateway's jobs in one line: "auth, rate limiting, routing, request ids." If there's a mobile app with complex screens, add "a BFF aggregates calls for the home screen to cut mobile round trips." Don't spend more than a minute here unless asked.

### Distributed rate limiting

#### Core idea
Rate limiting protects services from overload and abuse, and enforces fair usage and quotas. In a distributed system with many API servers, the limiter must share **state** (counts or tokens) across instances, which adds a shared store, latency and failure-mode decisions. (The LLD track covers single-node algorithms.)

#### How it works
**Design dimensions**
- **Key**: user id, API key, IP, endpoint, tenant, or combinations (per user per endpoint).
- **Algorithm**: token bucket (bursts OK), sliding window counter (smooth), fixed window (simple, edge bursts).
- **Where**: edge/CDN/WAF (IP-based, DDoS), API gateway (API keys, plans), service (per-user business limits), and outbound (respect partner limits).

**Redis-based implementation** (the standard answer)
```lua
-- token bucket in Redis (atomic via Lua): KEYS[1]=bucket key; ARGV: capacity, refill_per_ms, now_ms, cost
local b = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local cap, rate, now, cost = tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3]), tonumber(ARGV[4])
local tokens = tonumber(b[1]) or cap
local ts = tonumber(b[2]) or now
tokens = math.min(cap, tokens + (now - ts) * rate)
local allowed = tokens >= cost
if allowed then tokens = tokens - cost end
redis.call('HSET', KEYS[1], 'tokens', tokens, 'ts', now)
redis.call('PEXPIRE', KEYS[1], math.ceil(cap / rate) * 2)
return allowed and 1 or 0
```
- Lua makes read-modify-write atomic (no race between instances).
- Shard by key across a Redis Cluster; there's about 1ms of added latency per request.
- **Sliding window counter**: `INCR rl:{key}:{window}` with `EXPIRE`, and combine the current and previous window counts.

**Scaling and resilience**
- **Fail open vs fail closed** when Redis is down: usually fail open (allow traffic, so availability wins) for normal API limits, fail closed for security-critical limits (login attempts, OTP sends).
- **Local + global hybrid**: each node allows up to `limit / N` locally and syncs periodically. That removes the per-request Redis hop at the cost of slight inaccuracy. Good for very high QPS.
- **Hot keys**: one huge tenant's key on one Redis shard, so use local pre-aggregation.
- **Response**: `429 Too Many Requests` with `Retry-After` and the `RateLimit-*` headers.

#### Real-world example
**Stripe** described running several limiters together: a request rate limiter (token bucket per user), a concurrent-requests limiter, and **load shedders** that drop low-priority traffic (e.g. analytics) first when the system is under stress, all backed by Redis. **GitHub's API** returns `X-RateLimit-Remaining` headers so clients can adapt.

#### Interview questions
?? Design a rate limiter for an API used by many servers.
Clarify the keys, limits, accuracy and latency budget. Then: a gateway- or middleware-level check → Redis Cluster with an atomic Lua token bucket per key → 429 + headers on rejection. Rules come from a config store (per plan), cached locally. Fail-open policy, monitoring of rejections, and a hybrid local/global approach at extreme scale.

?? Why use a Lua script instead of GET then SET?
Two instances could both GET the same count, both decide "allowed", and both SET: a race that over-admits. Lua scripts execute atomically on Redis (single-threaded execution), so the check-and-update is a single step. `INCR` alone is atomic too, for fixed-window counters.

#### Tricky questions
?? With a global limit of 1,000/s split across 10 servers, why not just give each server 100/s locally?
Traffic isn't evenly spread: one server may receive more of a given user's requests (sticky connections, uneven load balancing), unfairly rejecting them while capacity sits unused elsewhere. And when servers scale up or down, the per-node limits must change. It's fine as an approximation; for accuracy, a shared store or periodic redistribution is needed.

#### Interview simulation
Expect it as a full HLD question. Structure: requirements (keys, limits, accuracy, latency) → algorithm choice with its trade-off → where it runs → data store (Redis + Lua) → the rules config → failure handling (fail open or closed) → the client contract (429, Retry-After) → observability. Tie it to your OnTheMove experience with rate limiting.

### Probabilistic data structures and geo indexes

#### Core idea
At large scale, exact answers can be expensive. **Probabilistic data structures** give approximate answers using tiny memory, and **geospatial indexes** make "what's near me?" queries fast. They show up often in HLD deep dives (unique visitors, trending topics, nearby drivers).

#### How it works
**Bloom filter**: "is X in the set?" → "definitely not" or "probably yes".
- A bit array of m bits plus k hash functions. Add: set k bits. Query: if any of the k bits is 0, the item is definitely absent.
- **False positives are possible, false negatives aren't.** Plain Bloom filters can't delete (counting Bloom filters can).
- About 10 bits per element gives about a 1% false-positive rate.
- Uses: avoid disk lookups for non-existent keys (Cassandra and RocksDB check a Bloom filter per SSTable), **cache penetration protection**, "have we crawled this URL?", "is this username taken?" (with a DB confirmation).

**HyperLogLog**: approximate **count of distinct elements** (cardinality).
- About 12KB estimates billions of distinct items with ~0.8% error (Redis `PFADD`/`PFCOUNT`). HLLs can be merged (union across days or shards).
- Uses: unique visitors per page per day, distinct search queries.

**Count-Min Sketch**: approximate **frequency** of items in a stream (overestimates, never underestimates).
- A 2D array of counters with d hash rows; take the minimum across the rows.
- Uses: heavy hitters / trending hashtags (combined with a top-K heap), approximate per-key counts in rate limiting.

**Geospatial indexing**
- **Geohash**: interleave latitude and longitude bits into a base-32 string. Nearby points share prefixes (`tdr1y…` is Bengaluru). Prefix length means precision (6 chars ≈ 1.2km × 0.6km). Nearby search = the user's cell plus its 8 neighbours (to handle edges). Store it in a DB index or Redis.
- **Quadtree**: recursively split 2D space into 4 quadrants until each holds ≤ K points. It adapts to density (dense cities get small cells), and suits in-memory indexes.
- **Uber H3**: a hexagonal hierarchical grid (hexagons have uniform neighbour distances), used for surge pricing zones and supply/demand analysis.
- **Google S2**: maps the sphere onto a cube, with a Hilbert curve for cell ids. Used by Google Maps, MongoDB, and others.
- **Redis GEO**: `GEOADD drivers 77.59 12.97 d1`, `GEOSEARCH drivers FROMLONLAT 77.6 12.97 BYRADIUS 3 km ASC COUNT 20`. Internally a sorted set scored by a 52-bit geohash.
- **PostGIS**: R-tree (GiST) indexes for complex geo queries.

#### Real-world example
**Medium** uses Bloom filters to avoid recommending articles a user has already read. **Reddit** counts unique post views with HyperLogLog in Redis. **Twitter**-style trending uses Count-Min Sketch plus heaps over sliding windows. **Uber**, **Swiggy** and **Zomato** use geo-indexes (H3, geohash) to find nearby drivers and delivery partners and to define serviceability zones.

#### Interview questions
?? How would you count unique visitors per page per day for a site with a billion page views?
An exact set per page per day would need huge memory. Use **HyperLogLog** per (page, day) in Redis: `PFADD page:{id}:{date} userId`, then `PFCOUNT`. About 12KB per key with ~1% error, and you can merge days for weekly counts (`PFMERGE`). If exact counts are required for billing, use batch processing over the logs instead.

?? How does a Bloom filter help a database?
LSM-tree databases (Cassandra, RocksDB) have many SSTable files. Before reading a file from disk to look for a key, they check that file's Bloom filter; if it says "definitely not here", the disk read is skipped. That dramatically reduces read amplification for missing keys.

?? How do you find the nearest 10 drivers to a user?
Index driver locations with geohash, H3 or Redis GEO. Query the user's cell and its neighbouring cells (expanding rings if there aren't enough results), filter by availability and vehicle type, sort by distance (or better, by ETA from a routing service), and take the top K. Driver locations update every few seconds, so the index must handle frequent updates (in-memory, sharded by region).

#### Tricky questions
?? Why must a geohash-based search also check neighbouring cells?
Two points can be very close but on opposite sides of a cell boundary, sharing no prefix. Searching only the user's own cell would miss them. Including the 8 neighbours fixes this edge effect.

#### Interview simulation
Drop these in when they fit, with one line of justification: "To avoid hitting the DB for non-existent short codes, a Bloom filter of existing codes sits in front." "Unique viewers per video are tracked with HyperLogLog, about 12KB per video per day." "Nearby drivers come from an H3-cell index in memory, sharded by city." Precise, well-placed details like these are strong signals.
