## Kafka deep dive | P3 | must

### Kafka architecture: topics, partitions, replication and ISR

#### Core idea
**Apache Kafka** is a distributed, partitioned, replicated **commit log**. Producers append records to **topics**; topics are split into **partitions** (ordered, append-only logs) spread across **brokers**; consumers read at their own pace by tracking **offsets**. Records are retained by time or size regardless of whether they've been consumed.

#### How it works
```
Topic "orders" (3 partitions, RF=3)
 P0: [0][1][2][3][4][5]...   leader: broker1, followers: broker2, broker3
 P1: [0][1][2][3]...         leader: broker2, followers: broker3, broker1
 P2: [0][1][2][3][4]...      leader: broker3, followers: broker1, broker2
```
- **Partition** = the unit of parallelism, ordering and storage. Order is guaranteed **only within a partition**.
- **Record**: key, value, headers, timestamp. `partition = hash(key) % numPartitions` (murmur2) when a key is present, so the same key always goes to the same partition (as long as the partition count doesn't change).
- **Replication**: each partition has one **leader** (it handles all reads and writes; followers can serve reads since KIP-392 with rack-aware fetching) and followers that replicate it. **Replication factor (RF)** is usually 3.
- **ISR (In-Sync Replicas)**: the replicas caught up with the leader (within `replica.lag.time.max.ms`). Only ISR members can become leader (unless unclean leader election is enabled, which risks data loss).
- **High watermark**: the offset up to which all ISR replicas have the data. Consumers only see records below the HW (committed records).
- **Durability settings**: `acks=all` + `min.insync.replicas=2` with RF=3 means a write succeeds only when at least 2 replicas have it, so it survives one broker failure with no loss. If the ISR drops below 2, producers get `NotEnoughReplicas` (choosing consistency over availability).
- **Storage**: each partition is a directory of **segment files** (append-only plus offset and time indexes). Writes are sequential I/O; reads use the OS page cache and **zero-copy** `sendfile`. That's why Kafka is fast on commodity disks.
- **Controller**: manages partition leadership and metadata. Kafka 3.x introduced **KRaft** (Raft-based metadata quorum) replacing ZooKeeper; **Kafka 4.0 (2025) removed ZooKeeper support entirely**.

#### Real-world example
**LinkedIn** (where Kafka was born) processes trillions of messages per day. **Uber** uses Kafka as the backbone for trip events, surge pricing and logs. In your 1mg work, an `orders` topic keyed by order id with RF=3 and `acks=all` is the correct, durable configuration. Be ready to say why each setting exists.

#### Interview questions
?? How does Kafka guarantee ordering?
Only within a partition: records with the same key go to the same partition and are appended in order; a consumer reads the partition sequentially. There's no global order across partitions. Producer retries could reorder records unless idempotence is enabled (which preserves order with up to 5 in-flight requests).

?? What do `acks=all` and `min.insync.replicas` do together?
`acks=all`: the leader acknowledges only after all current ISR replicas have the record. `min.insync.replicas=2`: if fewer than 2 replicas are in sync, the write is rejected. Together with RF=3, an acknowledged write exists on at least 2 brokers, so a single broker failure loses nothing.

?? Why is Kafka so fast?
Sequential disk writes (append-only log), batching and compression of records, zero-copy transfer from the page cache to the socket, the OS page cache instead of a JVM heap cache, partition-level parallelism, and consumers pulling in batches.

#### Tricky questions
?? What's the risk of `unclean.leader.election.enable=true`?
If all ISR replicas are down, an out-of-sync replica can become leader, losing the records it didn't have, and consumers may see offsets reused with different data. It trades durability for availability. Keep it false for important data.

?? Can you increase partitions for a keyed topic safely?
You *can*, but `hash(key) % N` changes, so new records for a key may land in a different partition than the old ones, breaking per-key ordering across the change. Plan partition counts upfront (with headroom), or migrate to a new topic.

#### Interview simulation
If you use Kafka in a design, specify its configuration in one breath: "Topic `order-events`, keyed by orderId for per-order ordering, 24 partitions (consumer parallelism headroom), RF=3, acks=all, min.insync.replicas=2, idempotent producer, 7-day retention." Interviewers recognise production experience in that sentence.

### Kafka producers

#### Core idea
The producer client batches records per partition, compresses them and sends them to partition leaders. Its configuration decides **durability**, **ordering**, **throughput** and **latency**.

#### How it works
**Send path**: `send(record)` → serializer → partitioner (key hash, or the sticky partitioner for keyless records) → appended to a per-partition **batch** in the record accumulator → the sender thread ships batches when `batch.size` is full or `linger.ms` elapses → the leader writes them → the ack returns per `acks`.

**Key settings**
| Setting | Meaning | Typical |
|---|---|---|
| `acks` | 0 (fire and forget), 1 (leader only), all (all ISR) | `all` for important data |
| `enable.idempotence` | dedupes retries via producer id + sequence numbers | `true` (the default since 3.0) |
| `retries` / `delivery.timeout.ms` | how long to keep retrying | default retries=MAX, timeout 120s |
| `max.in.flight.requests.per.connection` | concurrent unacked batches | ≤ 5 with idempotence (order kept) |
| `linger.ms` | wait to fill batches | 5–20ms for throughput (default 5ms in Kafka 4.0) |
| `batch.size` | max batch bytes per partition | 16–64KB+ |
| `compression.type` | none/gzip/snappy/lz4/zstd | lz4 or zstd |
| `buffer.memory` / `max.block.ms` | memory for unsent records; block when full | backpressure on the producer |

- **Synchronous vs asynchronous sends**: `send().get()` blocks (slow); use callbacks to handle failures asynchronously.
- **Transactions** (`transactional.id`): atomically write to several partitions or topics and commit consumer offsets, for exactly-once read-process-write.
- **Error handling**: retriable errors (leader change, timeout) are retried automatically; non-retriable ones (record too large, serialization) go to your callback, where you log, DLQ or alert. Never silently ignore callback exceptions.

#### Real-world example
A high-volume clickstream producer uses `acks=1`, `linger.ms=50`, `compression.type=zstd` and large batches (throughput over strict durability; losing a few clicks is OK). A payments event producer uses `acks=all`, idempotence on, transactions or an outbox, and alerting on callback failures (no loss tolerated). Same tool, opposite configurations.

#### Interview questions
?? How does the idempotent producer prevent duplicates?
The broker assigns each producer a producer id (PID), and the producer numbers its records per partition. If a retry resends a batch the broker already wrote (the ack was lost), the broker sees the duplicate sequence number and discards it while still acknowledging. It's scoped to a producer session; across restarts you need transactions (a stable `transactional.id`) or application-level idempotency.

?? How do you increase producer throughput?
Larger batches (`batch.size`), a little linger (`linger.ms` 10–50ms), compression (lz4/zstd), async sends with callbacks, enough partitions so writes spread across brokers, and appropriately sized `buffer.memory`. The trade-off is a little more latency.

#### Tricky questions
?? Your producer sends with `acks=all` but you still lost data. How?
Possible causes: `min.insync.replicas=1` (the ISR shrank to just the leader, which then died); unclean leader election enabled; the send failed and the callback error was ignored (the record never got in); the app crashed with records still in the producer buffer (not flushed); using fire-and-forget code paths. Check every link.

#### Interview simulation
If asked "How do you make sure order events are never lost?", answer: the outbox in the DB transaction (survives app crashes and Kafka downtime) → Debezium or a relay with an idempotent producer, `acks=all`, RF=3, `min.insync.replicas=2` → consumers commit offsets after processing and are idempotent → monitoring of producer errors and consumer lag. That's the end-to-end chain.

### Kafka consumers, consumer groups and offsets

#### Core idea
Consumers **pull** records from partitions. A **consumer group** shares the work of a topic: each partition is assigned to exactly one consumer in the group, so the group processes the topic in parallel while preserving per-partition order. Each group tracks its own **offsets** (its progress), so many groups can independently read the same topic.

#### How it works
```
Topic orders: P0 P1 P2 P3 P4 P5
Group "inventory" (3 consumers): C1←P0,P1  C2←P2,P3  C3←P4,P5
Group "analytics" (2 consumers): A1←P0,P1,P2  A2←P3,P4,P5      (independent offsets)
```
- Max useful parallelism in a group = the number of partitions (extra consumers sit idle).
- **Offsets** are committed to the internal `__consumer_offsets` topic. **Commit after processing** gives at-least-once; commit before processing gives at-most-once.
- **Auto-commit** (`enable.auto.commit=true`, every 5s) can commit offsets of records not yet processed (loss on crash) or reprocess on rebalance. Prefer **manual commits** after processing (sync or async; in Spring Kafka, `AckMode.RECORD` or `BATCH`).
- `auto.offset.reset`: `earliest` or `latest` for a group with no committed offset.
- **Poll loop**: `poll()` returns batches; processing must finish within `max.poll.interval.ms` (default 5 min), or the consumer is considered dead and its partitions are revoked. Heartbeats run on a background thread (`session.timeout.ms`).
- **Lag** = log end offset − committed offset per partition. It's the key health metric (Burrow, Kafka exporter, Prometheus).

**Error handling patterns**
- **Retry topics**: on failure, publish to `orders.retry.5s`, then `orders.retry.1m`, then `orders.DLT`, so the main partition isn't blocked (non-blocking retries; Spring Kafka `@RetryableTopic`). The trade-off is per-key ordering for the retried messages.
- **Blocking retries** (retry in place with backoff) preserve ordering but stall the partition.
- **Poison pills** (undeserialisable records): an `ErrorHandlingDeserializer` routes them to the DLT instead of crash-looping.

```java
@KafkaListener(topics = "order-events", groupId = "inventory", concurrency = "6")
public void onOrder(OrderEvent e, Acknowledgment ack) {
    if (processed.exists(e.eventId())) { ack.acknowledge(); return; }     // idempotency
    inventoryService.reserve(e);                                          // local DB tx also stores eventId
    ack.acknowledge();                                                    // commit after success
}
```

#### Real-world example
A notification consumer group lagged by 2 hours during a sale because each record made a slow SMS provider call synchronously. Fixes: increase partitions and consumer concurrency, batch provider calls, move slow external calls to async workers, and alert on lag. Lag dashboards are standard in every Kafka-using team, so mention them.

#### Interview questions
?? How do consumer groups provide scalability and fault tolerance?
Partitions are distributed among the group's members, so adding consumers (up to the partition count) increases parallelism. If a consumer dies, its partitions are reassigned to the others (a rebalance), which resume from the last committed offsets. Different groups get independent copies of the stream.

?? At-least-once vs at-most-once vs exactly-once in consumers?
At-most-once: commit the offset, then process (a crash loses the record). At-least-once: process, then commit (a crash re-delivers, so dedupe). Exactly-once: Kafka transactions for Kafka-to-Kafka processing, or at-least-once plus idempotent/transactional sinks (storing offsets in the same DB transaction as the results).

#### Tricky questions
?? Your consumer keeps rebalancing and reprocessing the same records. Why?
Processing a batch takes longer than `max.poll.interval.ms`, so the consumer is kicked out, its partitions move, and its uncommitted work is redone elsewhere, repeatedly. Fixes: lower `max.poll.records`, speed up processing or move slow work off the poll thread (carefully, with offset management), raise `max.poll.interval.ms`, and use cooperative rebalancing.

?? You have 6 partitions and 10 consumers in a group. What happens?
6 consumers get a partition each; 4 are idle (hot standbys). To use all 10, you'd need ≥ 10 partitions.

#### Interview simulation
When you design consumers, say: "Consumer group per downstream concern; concurrency matched to partitions; manual commit after processing; idempotent handler keyed on eventId; non-blocking retry topics with a DLT; lag alerting." And if ordering matters for the retried events, say you'd use blocking retries for those keys, or park subsequent events for the same key. That level of nuance is impressive.

### Ordering, rebalancing and delivery guarantees in practice

#### Core idea
Real Kafka systems must handle three subtle issues: **keeping per-entity order** when processing in parallel and retrying, **rebalancing** without duplicate or lost work, and achieving **effectively-once** results end to end.

#### How it works
**Ordering**
- Choose the key = the entity whose events must stay ordered (orderId, userId, accountId).
- Inside a consumer, if you parallelise processing across threads, do it **per key** (hash the key to a single-thread executor), never randomly.
- Retries via retry topics break ordering for the retried key; if strict order matters, use blocking retries for that partition, or a "parking" pattern (once a key fails, buffer its later events until it recovers).
- **Hot keys** (one key with huge volume) bottleneck one partition. Split the entity if possible, or accept it.

**Rebalancing**
- Triggered by consumers joining or leaving, crashes, poll-interval violations, or subscription changes.
- **Eager rebalancing** (the old default): all consumers revoke all partitions, then reassign: a stop-the-world pause.
- **Cooperative incremental rebalancing** (`CooperativeStickyAssignor`): only the partitions that move are revoked, so others keep working.
- **Static membership** (`group.instance.id`): a restarted consumer (rolling deploy) gets its partitions back without a rebalance if it returns within the session timeout.
- **KIP-848** (the new consumer group protocol, generally available in Kafka 4.0): broker-driven incremental assignment, with far less disruption.
- Commit offsets in `onPartitionsRevoked` to avoid reprocessing after a rebalance.

**End-to-end exactly-once options**
1. Kafka → Kafka (stream processing): transactions plus `read_committed` (Kafka Streams `processing.guarantee=exactly_once_v2`).
2. Kafka → DB: store the results and the consumed offsets **in the same DB transaction**; on startup, seek to the stored offsets.
3. Kafka → any side effect: idempotent operations or a dedup table keyed by event id.

#### Real-world example
A ride-hailing trip-events pipeline keys by tripId so `TripStarted` is always processed before `TripEnded`. Consumers fan out to per-key executor threads for parallelism within a partition. During deploys, static membership plus cooperative rebalancing avoided the minute-long processing pauses that used to cause ETA staleness.

#### Interview questions
?? How do you parallelise processing within a single partition without losing order?
Dispatch records to N worker queues by `hash(key) % N`, so the same key always goes to the same worker (in order) while different keys run in parallel. Commit an offset only when all earlier records in that partition are done (track the lowest unfinished offset). Libraries such as Confluent Parallel Consumer implement this.

?? What happens to in-flight work during a rebalance?
Partitions may be revoked mid-processing. If offsets weren't committed, the new owner reprocesses from the last committed offset (duplicates, so idempotency is needed). Commit synchronously on revocation, stop processing revoked partitions, and use cooperative rebalancing to minimise the disruption.

#### Tricky questions
?? Is per-partition ordering preserved if the producer retries with idempotence disabled and max.in.flight > 1?
No. Batch 1 fails and is retried while batch 2 succeeds, so batch 2 is written before batch 1. Enable idempotence (it keeps order with up to 5 in-flight requests) or set max in-flight to 1.

#### Interview simulation
If the interviewer asks "how do you guarantee events for the same order are processed in order, and exactly once?", answer: "Key by orderId (partition ordering); idempotent producer; in the consumer, per-key serial processing; offsets committed after processing; effects deduped by eventId in the same DB transaction; blocking retries for those keys to keep order, with a DLT after N attempts plus an alert." Crisp and complete.

### Kafka vs RabbitMQ vs SQS

#### Core idea
All three move messages between services, but with different models. Choosing well is a common interview question ("why Kafka here?").

#### How it works
| | **Kafka** | **RabbitMQ** | **AWS SQS** |
|---|---|---|---|
| Model | distributed log, pull | broker with queues and exchanges, push | managed queue, pull (long polling) |
| Retention | time or size based; replayable | until acked | up to 14 days, until deleted |
| Ordering | per partition | per queue (single consumer) | FIFO queues: per message group; standard: best effort |
| Multiple consumers of the same data | consumer groups, each gets everything | fanout exchange → copies per queue | needs SNS fan-out to multiple queues |
| Throughput | very high (millions/s) | high (tens of thousands/s per queue) | standard: nearly unlimited; FIFO: limited per group |
| Routing | topic + key | rich (direct, topic, headers exchanges) | none (SNS filtering) |
| Delays, priorities, TTL | not native | yes (plugins or features) | delay queues, visibility timeout |
| Ops | heavier (managed: MSK, Confluent) | moderate | zero (fully managed) |
| Exactly-once | transactions within Kafka | no (idempotent consumers) | FIFO dedup window (5 min) |
| Best for | event streaming, CDC, analytics, event sourcing, logs | task queues, complex routing, RPC patterns, per-message acks | simple decoupled jobs on AWS, serverless |

**Also**: Google Pub/Sub, Azure Service Bus, **Apache Pulsar** (separates storage via BookKeeper; tiered storage; both queue and stream semantics), Redis Streams (lightweight streams), NATS (very low latency messaging).

#### Real-world example
A common combination: **Kafka** for domain events (orders, payments, user activity) consumed by many services and analytics; **SQS** (or RabbitMQ) for job queues like "generate invoice PDF" or "resize image" processed by autoscaled workers; **SNS + SQS** fan-out on AWS for simple pub-sub. NeuronixAI's async document processing could use either Kafka (already in the stack) or SQS (simpler to operate on AWS); be ready to justify the choice.

#### Interview questions
?? When would you pick RabbitMQ over Kafka?
For traditional work queues needing per-message acknowledgement, delayed or priority messages, complex routing (topic patterns, headers), request-reply patterns, and moderate throughput where operational simplicity matters. Kafka shines when you need a replayable event history, many independent consumers, high throughput and per-key ordering.

?? What is the SQS visibility timeout?
When a consumer receives a message, it becomes invisible to others for the visibility timeout. If the consumer deletes it before the timeout, it's done; otherwise it reappears for redelivery (at-least-once). Set it longer than the processing time, and extend it for long jobs. After `maxReceiveCount` deliveries, a redrive policy moves it to a DLQ.

#### Tricky questions
?? Can Kafka replace a task queue where each job takes 10 minutes?
It's awkward: long processing blocks the partition (head-of-line blocking) and risks exceeding `max.poll.interval.ms`, causing rebalances. There are no per-message acks or visibility timeouts. Use a job queue (SQS or RabbitMQ) or a workflow engine for long tasks; Kafka can carry the *event* that triggers them.

#### Interview simulation
When you choose a broker in HLD, justify it in one line: "Kafka, because we need multiple independent consumers (inventory, notifications, analytics), replay for rebuilding projections, and per-order ordering at ~20K events/s." Or: "SQS, because it's a simple background job queue on AWS, we want zero ops, and we need per-message retry with a DLQ."

### Retention, log compaction and dead-letter topics

#### Core idea
Kafka offers two retention models: **delete** (keep records for a time or size, then drop old segments) and **compact** (keep at least the **latest value per key**, which turns a topic into a durable changelog or table). **Dead-letter topics (DLTs)** hold records that repeatedly fail processing, so they don't block the stream.

#### How it works
**Delete retention**: `retention.ms` (e.g. 7 days) and/or `retention.bytes` per partition; deletion happens per **segment**, so a segment is removed only once all its records are older than retention.

**Log compaction** (`cleanup.policy=compact`)
```
Before:  k1:v1  k2:a  k1:v2  k3:x  k2:b  k1:v3
After:   k3:x   k2:b  k1:v3          (latest per key; offsets preserved, gaps allowed)
Tombstone: k2:null → after delete.retention.ms, k2 removed entirely
```
- Uses: the latest state per entity (user profiles, configs), **Kafka Streams state store changelogs**, `__consumer_offsets` itself, CDC topics (the latest row per primary key), rebuilding caches on startup by reading the whole compacted topic.
- `cleanup.policy=compact,delete` combines both (keep the latest per key, but drop anything older than retention).

**Dead-letter topics**
- After N failed attempts (blocking or non-blocking retries), publish the record to `<topic>.DLT` with headers: original topic, partition, offset, exception class and message, attempt count, timestamps.
- Alert on DLT volume; build tooling to **inspect, fix and replay** DLT records back to the main topic after the bug is fixed.
- Don't use the DLT for transient errors (downstream down): retry with backoff or pause the consumer instead. The DLT is for poison or invalid messages.

**Tiered storage** (KIP-405, production-ready in Kafka 3.9): older segments are offloaded to object storage (S3), so retention can be months or years cheaply while brokers keep only recent data locally.

#### Real-world example
A "product-catalog" compacted topic keyed by productId lets a new search-indexing service bootstrap by consuming from the beginning: it gets exactly the latest version of every product without reading years of history, then keeps up with live changes. That's the same principle by which Kafka Streams restores its state stores.

#### Interview questions
?? What is log compaction and when would you use it?
Kafka retains at least the most recent record for each key, deleting older values in the background. Use it when the topic represents the **current state** of entities (a changelog) rather than a history of events: configuration, user profiles, CDC snapshots, stream processing state. Consumers can rebuild the full current state by reading from the start.

?? How do you handle a message that always fails processing?
Bounded retries with backoff, then route it to a DLT with error metadata; the consumer continues with the next record; alert on DLT arrivals; investigate, fix the code or data, and replay from the DLT. Ensure the replay is idempotent.

#### Tricky questions
?? Can a consumer of a compacted topic still see intermediate values?
Yes. Compaction runs asynchronously on non-active segments, so recent records (the active segment, plus segments not yet cleaned) may still include multiple versions per key. Consumers must handle seeing several updates per key; compaction only guarantees *at least* the latest.

#### Interview simulation
Use compaction when designing state distribution: "Driver profiles are published to a compacted topic keyed by driverId, so any new service can bootstrap the full current set, then stay updated." And always mention a DLT plus alerting and a replay tool for consumers. These operational details signal production experience.

## Redis deep dive | P3 | must

### Redis data structures and their use cases

#### Core idea
**Redis** is an in-memory data structure server: single-threaded command execution (I/O threads optional since 6.0), sub-millisecond latency, and rich types. Knowing **which structure fits which problem** is what interviewers test.

#### How it works
| Type | Commands | Complexity | Use cases |
|---|---|---|---|
| **String** | GET/SET/INCR/SETNX/SETEX | O(1) | cache values, counters, distributed locks, idempotency keys, rate-limit counters |
| **Hash** | HSET/HGET/HINCRBY/HGETALL | O(1) per field | objects (user session, product summary), per-entity counters |
| **List** | LPUSH/RPOP/LRANGE/BLPOP/LTRIM | O(1) ends | simple queues, recent-items lists (`LPUSH` + `LTRIM 0 99`) |
| **Set** | SADD/SISMEMBER/SINTER/SCARD | O(1) membership | unique visitors (exact, small), tags, mutual friends (SINTER), dedup |
| **Sorted Set (ZSet)** | ZADD/ZINCRBY/ZRANGE/ZRANGEBYSCORE/ZREVRANK | O(log n) | **leaderboards**, priority queues, delayed jobs (score = run-at time), sliding-window rate limits (score = timestamp), timelines |
| **Stream** | XADD/XREADGROUP/XACK/XPENDING | O(1) append | lightweight event log with consumer groups and acks |
| **Bitmap** | SETBIT/GETBIT/BITCOUNT | O(1) / O(n) | daily active users (bit per user id), feature flags per user |
| **HyperLogLog** | PFADD/PFCOUNT/PFMERGE | O(1) | approximate unique counts (~0.81% error, 12KB) |
| **Geo** | GEOADD/GEOSEARCH | O(log n) | nearby drivers or stores |
| **Pub/Sub** | PUBLISH/SUBSCRIBE | | fire-and-forget broadcast (no persistence: offline subscribers miss messages) |

**Internals**: small collections use compact encodings (listpack) and convert to full structures past thresholds; sorted sets are a **skip list + hash table**. Keys can have TTLs (`EXPIRE`); expiry is lazy (on access) plus active (random sampling).

**Atomicity**: single commands are atomic; `MULTI/EXEC` transactions (with `WATCH` for optimistic locking); **Lua scripts** (`EVAL`) or Redis 7 **functions** for atomic multi-step logic.

**Pitfalls**: big keys (a 10M-member set blocks Redis on delete; use `UNLINK` or chunk it), `KEYS *` in production (O(N), blocks; use `SCAN`), hot keys, unbounded growth without TTLs.

#### Real-world example
**Leaderboards** for a fantasy sports app (Dream11-style): `ZINCRBY contest:42 15 user:7` on each scoring event, `ZREVRANGE contest:42 0 99 WITHSCORES` for the top 100, `ZREVRANK contest:42 user:7` for a user's rank, all O(log n) for millions of users. **Your 1mg soft-TTL cache**: a hash `{payload, softExpiry}` per search key with a hard TTL via `EXPIRE`, plus `SET lock:refresh:{key} NX PX 5000` so only one instance refreshes.

#### Interview questions
?? How would you implement a leaderboard with Redis?
A sorted set per leaderboard: `ZADD`/`ZINCRBY` to update scores, `ZREVRANGE … WITHSCORES` for the top N, `ZREVRANK` for a member's rank, `ZSCORE` for a score. All O(log n). For ties, encode the tie-breaker into the score (score × 1e6 + (MAX − timestamp)) or keep a secondary ordering. For huge leaderboards, shard by region or bucket and merge.

?? Why is Redis single-threaded yet so fast?
All data is in memory, commands are simple and fast data-structure operations, and a single thread avoids locking and context-switch overhead. Event-loop networking (epoll) handles many connections, and Redis 6+ can use I/O threads for socket reads and writes. The CPU per command is tiny, so one core handles 100K+ ops/s. The flip side is that one slow command blocks everyone.

#### Tricky questions
?? Why should you avoid `KEYS pattern` and big `DEL`s in production?
`KEYS` scans the whole keyspace in O(N) on the main thread, blocking all other clients (latency spikes or timeouts). Use `SCAN` (an incremental cursor). Deleting a huge collection with `DEL` frees memory synchronously, which also blocks. Use `UNLINK` (async free) or delete it in chunks.

?? Is Redis Pub/Sub good for reliable notifications?
No. Messages are delivered only to currently connected subscribers, with no persistence or acks; a disconnected subscriber misses messages. Use Redis Streams (with consumer groups and acks) or Kafka for reliability. Pub/Sub is fine for ephemeral fan-out, like WebSocket server broadcast, where missing a message is tolerable or recoverable.

#### Interview simulation
When you put Redis in a design, name the **structure**: "a sorted set per contest for the leaderboard", "a hash per session with a 30-minute TTL", "HyperLogLog per page per day for uniques", "a GEO set per city for driver locations". Saying just "Redis" for everything sounds shallow; naming structures shows depth.

### Redis persistence: RDB and AOF

#### Core idea
Redis is in-memory, but it can persist data to disk for restart recovery:
- **RDB**: point-in-time **snapshots** of the dataset at intervals.
- **AOF (Append-Only File)**: logs **every write command**; replayed on restart.
- Both can be combined. Many cache-only deployments disable persistence entirely.

#### How it works
**RDB**
- `BGSAVE` **forks** the process; the child writes the snapshot while the parent keeps serving (OS **copy-on-write**: memory grows only by the pages modified during the snapshot).
- Pros: compact files, fast restarts, good for backups. Cons: you lose writes since the last snapshot (minutes). Forking a large dataset can cause latency spikes, and memory overhead under heavy writes.

**AOF**
- Every write is appended. `appendfsync`: `always` (fsync every write: safest, slowest), **`everysec`** (the default compromise: lose at most about 1s), `no` (the OS decides).
- **AOF rewrite** (`BGREWRITEAOF`) compacts the log in the background, again through a fork.
- Pros: much less data loss. Cons: bigger files, slower restarts (replaying commands). Redis 7 uses a multi-part AOF (a base RDB plus incremental AOF files).

**Hybrid** (`aof-use-rdb-preamble yes`): the rewritten AOF starts with an RDB snapshot followed by AOF commands, giving fast loads and minimal loss.

**Choosing**
- Pure cache (data can be rebuilt from the DB): no persistence, or RDB for warm restarts.
- Redis as a primary store for important data (sessions, rate-limit state, leaderboards): AOF everysec plus replicas. Remember that async replication can still lose recent writes on failover.
- Redis isn't a replacement for a durable database where losing a second of writes is unacceptable (e.g. money).

#### Real-world example
After a Redis node restarted with no persistence, a **cold cache** sent the full read traffic to Postgres and caused an outage (a cache avalanche). The team enabled RDB snapshots for warm restarts and added DB-side rate limiting plus gradual traffic ramp-up after cache restarts.

#### Interview questions
?? RDB vs AOF: which would you use?
For a cache, RDB (or none). For data you care about, AOF with `everysec` (lose at most about 1s), usually with RDB preambles for faster recovery, plus replicas and backups of RDB files. If even one second of loss is unacceptable, Redis shouldn't be the system of record.

?? How does Redis snapshot without blocking clients?
It forks a child process, which inherits a copy-on-write view of memory and writes the snapshot to disk, while the parent continues serving requests. Only pages modified during the snapshot get duplicated. The fork itself can take noticeable time for very large heaps (page table copying), so monitor `latest_fork_usec`.

#### Tricky questions
?? Why might a Redis instance using 20GB need much more memory during BGSAVE?
Copy-on-write: under a heavy write load during the snapshot, many pages are modified and duplicated, potentially doubling memory use in the worst case. Leave headroom (e.g. use only about 50–60% of RAM for data), and disable Transparent Huge Pages (larger pages mean more copying).

#### Interview simulation
If Redis holds important state in your design, say: "Redis with AOF everysec plus one replica per shard; we accept losing about a second of rate-limit or session data on a failure, since the source of truth for critical data is Postgres." That shows you know Redis's durability limits.

### Redis replication, Sentinel and Cluster

#### Core idea
- **Replication**: a primary asynchronously replicates to replicas (for read scaling and failover candidates).
- **Sentinel**: monitors primary/replica sets and performs **automatic failover** (for a single-shard setup).
- **Redis Cluster**: **shards** data across multiple primaries using **16,384 hash slots**, each with replicas and built-in failover. It scales memory and throughput horizontally.

#### How it works
**Replication**: a replica connects, does a full sync (an RDB transfer), then receives a stream of commands; partial resync after short disconnects (replication backlog). It's **asynchronous**, so acknowledged writes can be lost on failover (`WAIT numreplicas timeout` can force acks, but it isn't true consensus).

**Sentinel**: several sentinel processes (at least 3) monitor the primary. If a quorum agrees it's down, they elect a leader sentinel, which promotes a replica and reconfigures the others; clients ask the sentinels for the current primary address.

**Redis Cluster**
- `slot = CRC16(key) mod 16384`; slots are assigned to primaries (e.g. 3 primaries with about 5,461 slots each).
- Clients are cluster-aware: they cache the slot map and follow **MOVED/ASK** redirects.
- **Multi-key operations** (MGET, transactions, Lua) only work if all keys are in the **same slot**. Use **hash tags**: `{user:42}:profile` and `{user:42}:cart` hash only `user:42`.
- Resharding moves slots between nodes online. Failover: replicas of a failed primary get promoted through cluster consensus.
- Typical ceiling: about 1,000 nodes; per-node memory sizes of 10s of GB are common.

**Managed options**: AWS ElastiCache/MemoryDB (MemoryDB adds a durable multi-AZ transaction log for strong durability), Redis Enterprise, GCP Memorystore. Note: after Redis's 2024 licence change, the Linux Foundation fork **Valkey** became widely adopted (AWS and Google support it); Redis 8 later added the AGPL as an option.

#### Real-world example
A large Redis Cluster serving session and cart data for a sale: 12 primaries with 1 replica each, client-side hash tags so each user's keys share a slot (atomic Lua cart operations), and a hot-key issue on a "flash deal" counter mitigated by a local cache and by splitting the counter into N sub-keys summed on read.

#### Interview questions
?? How does Redis Cluster distribute keys?
CRC16 of the key (or of its hash tag, the part inside `{}`) modulo 16,384 gives a slot; each slot is owned by one primary. Clients route commands directly to the owner and handle MOVED redirects when slots migrate.

?? How do you run a multi-key Lua script on Redis Cluster?
All keys used must map to the same slot, so design keys with a shared hash tag (`{order:123}:items`, `{order:123}:total`). Otherwise the cluster rejects the operation with CROSSSLOT.

#### Tricky questions
?? Can Redis failover lose acknowledged writes?
Yes. Replication is asynchronous, so the primary acks the client before the replicas receive the write. If the primary dies just then, the promoted replica lacks those writes. `WAIT` reduces the window but doesn't guarantee consistency under all failures. For durable, consistent writes, use a database (or MemoryDB, with its transaction log).

#### Interview simulation
When Redis is central to a design at scale, say: "Redis Cluster with N shards (each primary plus replica across AZs), keys designed with hash tags for per-user atomic operations, and client-side handling of failover. We treat Redis data as recoverable (rebuildable from the DB) except for X, where we accept about 1s of loss." That covers scaling, atomicity and durability.

### Distributed locks with Redis (and the Redlock debate)

#### Core idea
Redis is commonly used for distributed locks because it's fast and simple: `SET key value NX PX ttl`. You need to know how to do it **correctly**, and the **limits** of Redis locks for correctness-critical cases. (The Distributed systems track covers fencing in general.)

#### How it works
**Single-instance lock**
```
ACQUIRE:  SET lock:{resource} <uuid> NX PX 30000        → OK = acquired, nil = busy
RELEASE (Lua, atomic check-and-delete):
  if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end
```
- A **unique value per holder**, so you never release someone else's lock (if yours expired and they acquired it).
- **TTL**, so a crashed holder doesn't block forever.
- **Renewal (watchdog)**: extend the TTL periodically while working (Redisson does this automatically every TTL/3).
- **Retry** with backoff plus jitter when the lock is busy, or fail fast.

**Redlock**: acquire the same lock on a majority (e.g. 3 of 5) of **independent** Redis masters within a time much shorter than the TTL; the lock is valid for TTL − elapsed − clock drift. It's designed to survive single-node failures (a single-instance lock is lost if the primary fails before replicating it).

**The debate (Kleppmann vs antirez)**: Redlock depends on timing assumptions (bounded clock drift, bounded process pauses, bounded network delay). A long GC pause or clock jump can let two clients believe they hold the lock. Without **fencing tokens** (which Redlock doesn't provide), it's unsafe for **correctness**. Antirez's position: it's fine under practical assumptions. The practical takeaway: Redis locks are for **efficiency** (avoiding duplicate work); for correctness, use fencing, consensus-based coordination (etcd, ZooKeeper), DB constraints, or idempotency.

#### Real-world example
**Cache refresh lock** (your soft-TTL pattern): `SET refresh:{key} NX PX 5000` so only one instance recomputes an expensive search result. If two instances occasionally both refresh, it's harmless (the same data), so a Redis lock is perfect here. **Payout processing**: double execution means money lost, so don't rely on a Redis lock alone; use a unique DB constraint on (seller, period) plus PSP idempotency keys.

#### Interview questions
?? Why must the lock value be unique and the release done via Lua?
If client A's lock expires and B acquires it, a naive `DEL` by A would delete B's lock. Comparing the value (A's uuid) and deleting only if it matches must be atomic, otherwise the key could change between the GET and the DEL. Lua guarantees atomicity.

?? What happens if the lock holder's work takes longer than the TTL?
The lock expires and another client can acquire it, so both work concurrently. Mitigations: a watchdog that renews the TTL while the holder is alive and working; fencing tokens checked by the resource; idempotent work. Note that renewal can't help during a full process pause (GC), which is why fencing matters.

#### Tricky questions
?? Your Redis lock is on a primary with an async replica. The primary fails right after you acquire. What happens?
The replica may not have received the lock key; it's promoted, and another client can acquire the same lock. Mutual exclusion is violated. This is the motivation for Redlock (independent masters) or consensus-based locks.

#### Interview simulation
If you propose a Redis lock, immediately qualify it: "This lock prevents duplicate refresh work; correctness doesn't depend on it, because the write is idempotent." If the interviewer pushes on correctness: "For strict mutual exclusion I'd use an etcd lease with the revision as a fencing token, checked by the storage layer." That progression wins this debate-style question.

### Redis patterns: caching, sessions, rate limiting, queues and leaderboards

#### Core idea
Most real Redis usage falls into a handful of patterns. Knowing their **exact implementation** (keys, structures, TTLs, atomicity) lets you add Redis to designs credibly.

#### How it works
**1. Cache-aside with stampede protection (soft TTL)**
```
GET cache:search:{q}  → {payload, softExp}
  hit & now < softExp            → return payload
  hit & now >= softExp           → return payload; if SET lock:{q} NX PX 5000 → async refresh
  miss                            → single-flight load from DB; SET cache:search:{q} … EX hardTTL(+jitter)
```
**2. Session store**: `HSET session:{sid} userId 42 roles "USER" …` + `EXPIRE session:{sid} 1800`, refreshed on activity (sliding expiration). Spring Session Redis does this.

**3. Rate limiting**: fixed window `INCR rl:{user}:{minute}` + `EXPIRE 60`; a token bucket via Lua; a sliding log via ZSET (`ZADD`, `ZREMRANGEBYSCORE` for the old entries, `ZCARD`).

**4. Leaderboards / top-K**: ZSET with `ZINCRBY`, `ZREVRANGE`, `ZREVRANK`. Daily boards: `lb:{yyyymmdd}`, `ZUNIONSTORE` for weekly boards.

**5. Delayed jobs**: `ZADD delayed {runAtEpochMs} {jobId}`; workers poll `ZRANGEBYSCORE delayed 0 now LIMIT 0 100` and claim each with `ZREM` (atomic per job: whoever's ZREM returns 1 owns it). Or use Lua to claim in batches.

**6. Queues / streams**: `LPUSH` + `BRPOP` for simple queues (no ack: if a worker dies, the job is lost; use `LMOVE` to a processing list for reliability); **Streams** with consumer groups (`XREADGROUP`, `XACK`, `XPENDING`/`XCLAIM` for stuck messages).

**7. Deduplication / idempotency**: `SET idem:{key} "IN_PROGRESS" NX EX 86400`, then overwrite with the response.

**8. Counters and analytics**: `HINCRBY stats:{day} pageviews 1`; bitmaps for DAU (`SETBIT dau:{day} {userId} 1`, `BITCOUNT`); HyperLogLog for uniques.

**9. Feature flags / config**: hashes read with local caching; pub/sub to notify config changes.

**10. Geo**: `GEOADD drivers:{city} lng lat driverId`, `GEOSEARCH … BYRADIUS 3 km ASC COUNT 20`.

#### Real-world example
**Twitter** historically kept home timelines in Redis lists (each user's timeline as a list of tweet ids, capped at about 800 entries). That's the fan-out-on-write pattern you'll use in the news feed design. **GitHub** used Redis for job queues (Resque). Many Indian startups run sessions, OTP rate limiting and leaderboards on ElastiCache.

#### Interview questions
?? How would you implement OTP rate limiting (max 3 OTPs per phone per 10 minutes, 10 per day)?
Two counters: `INCR otp:{phone}:10m` with `EXPIRE 600` on the first increment, and `INCR otp:{phone}:day` with `EXPIRE 86400`, checked atomically in a Lua script (reject if either exceeds its limit). Store the OTP itself hashed with a short TTL (`SET otp:code:{phone} <hash> EX 300`) and count verification attempts to block brute force.

?? How do you build a reliable job queue on Redis?
Use Redis Streams: `XADD jobs * …`; workers `XREADGROUP GROUP workers c1 COUNT 10 BLOCK 5000 STREAMS jobs >`; `XACK` after success; a reaper uses `XPENDING` plus `XCLAIM`/`XAUTOCLAIM` to take over messages idle too long (a crashed worker); a delivery count past a threshold goes to a dead-letter stream. Or the list-based `LMOVE` pattern. For heavy needs, use a real broker.

#### Tricky questions
?? Your Redis memory keeps growing. What do you check?
Keys without TTLs (`INFO keyspace`, sampling with `--bigkeys` and `--memkeys`, `MEMORY USAGE`), unbounded lists or streams (use `LTRIM`, `XADD MAXLEN ~`), fragmentation (`mem_fragmentation_ratio`; `activedefrag`), the eviction policy (`noeviction` means writes fail when full), and client output buffers (slow pub/sub subscribers). Fix the TTLs, cap the collections, and set `maxmemory` and a policy.

#### Interview simulation
When you add Redis to a design, specify the key schema and TTLs: "`session:{sid}` hash with a 30-minute sliding TTL; `rl:{apiKey}` token bucket via Lua; `lb:{contestId}` ZSET; `cache:product:{id}` with a 10-minute TTL ± 10% jitter." This precision turns a vague box into a credible component.

### Cache invalidation and consistency with Redis

#### Core idea
"There are only two hard things in computer science: cache invalidation and naming things." When data lives in both a database and Redis, you must decide **how and when the cache learns about changes**, and **how much staleness** each use case tolerates.

#### How it works
**Strategies, from simplest to strongest**
1. **TTL only**: data can be stale up to the TTL. Simple and self-healing. Good for catalogues and configs (minutes of staleness OK).
2. **Delete on write (cache-aside)**: after the DB commit, `DEL` the key; the next read repopulates it. Races exist (a stale repopulation), so keep a TTL as a safety net.
3. **Delayed double delete**: delete before and after the DB write, the second after a short delay (e.g. 500ms) to catch a racing stale repopulation.
4. **Write-through**: update the cache in the same code path after a successful DB write. Beware concurrent writers (use versions).
5. **Versioned values**: store `{version, data}`; update only if the incoming version is greater (a Lua compare-and-set). Out-of-order updates can't regress the cache.
6. **CDC-driven invalidation**: Debezium streams DB changes → Kafka → a cache invalidator deletes or updates keys. Reliable (no missed invalidations when the app crashes after commit), ordered per key, and decoupled from app code.
7. **Lease-based (Facebook memcache)**: on a miss, the cache issues a lease token; only the lease holder may set the value, and a delete invalidates outstanding leases. This prevents both stale sets and thundering herds.

**Multi-level caches (local L1 + Redis L2)**: local caches must be invalidated too. Use short local TTLs (5–30s), or broadcast invalidations via Redis pub/sub or Kafka to all instances.

**Never cache**: data requiring read-after-write correctness for money or inventory decisions (read from the DB primary), and highly personalised data with low reuse (low hit ratio, wasted memory).

#### Real-world example
**Facebook's "Scaling Memcache at Facebook" paper (2013)** describes leases to prevent stale sets and thundering herds, and **mcsqueal**, which tails the MySQL commit log to broadcast invalidations to memcache clusters across regions. That's CDC invalidation at massive scale. Your soft-TTL design addresses the herd side of the same problem.

#### Interview questions
?? A product's price was updated, but users see the old price for several minutes. How do you fix it?
The cache isn't invalidated on update (or the TTL is long). Add explicit invalidation on the write path (delete after commit), or better, CDC-driven invalidation so every change path (admin tools, batch jobs) triggers it. Shorten the TTL for price fields or split volatile fields (price, stock) into separate, short-TTL keys. Keep the checkout price verified against the DB.

?? Why delete the cache key instead of updating it on writes?
Concurrent writers can update the cache in a different order than the DB commits, leaving the cache with an older value permanently (until the TTL). Deleting forces a fresh load. Updating is safe only with version checks or a single writer.

#### Tricky questions
?? Even with delete-after-write, a stale value ends up in the cache. Explain the race.
Reader R misses the cache and reads the DB (old value) → Writer W updates the DB and deletes the cache key → R writes the old value into the cache. Now the cache is stale until the TTL. Fixes: a short TTL, delayed double delete, leases, versioned sets, or CDC invalidation arriving after R's set.

#### Interview simulation
For every cached entity in your design, state three things: "**TTL** (10 min ± jitter), **invalidation** (CDC-driven delete on change), **staleness tolerance** (fine for descriptions; prices are re-validated at checkout)." It shows you've thought about correctness, not just speed.
