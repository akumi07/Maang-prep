## Distributed systems | P3 | must

### CAP and PACELC

#### Core idea
- **CAP theorem**: when a **network partition** (P) happens, a distributed data store must choose between **Consistency** (every read sees the latest write: linearizability) and **Availability** (every request to a non-failed node gets a non-error response). You can't have both *during a partition*. Partitions are inevitable in practice, so the real choice is **CP or AP under partition**.
- **PACELC** extends it: if **P**artition, choose **A** or **C**; **E**lse (normal operation), choose **L**atency or **C**onsistency. This captures the everyday trade-off: synchronous replication (consistency) costs latency.

#### How it works
| System | Under partition | Normal operation | Notes |
|---|---|---|---|
| Postgres/MySQL single primary with sync failover | CP (minority side can't write) | EC | |
| Spanner, CockroachDB, etcd, ZooKeeper | CP | EC | consensus (Paxos/Raft) |
| Cassandra, DynamoDB (default), Riak | AP | EL | tunable: Cassandra `QUORUM` reads+writes → more consistent |
| MongoDB (majority write concern) | CP-ish | EC | |

- "CA" systems don't really exist in distributed settings: you can't opt out of partitions.
- CAP's "consistency" means **linearizability**, not ACID's "C".
- The choice can be **per operation**: a shopping cart can be AP (merge carts later), checkout or payment CP.

#### Real-world example
**Amazon's Dynamo paper (2007)**: the shopping cart was designed to be **always writable** (AP), because rejecting an "add to cart" during a partition loses revenue. Conflicting cart versions are merged later (union of items), so occasionally a deleted item reappears, which was acceptable. **Banking ledgers** choose CP: better to reject a transfer than to allow a double spend.

#### Interview questions
?? Explain the CAP theorem with an example.
Two replicas of a bank balance in different datacentres, and the network between them fails. A withdrawal arrives at replica A. If A accepts it without coordinating with B (available), B may also accept a withdrawal, giving inconsistency (overdraft). If A refuses until it can coordinate (consistent), the system is unavailable for that request. You must pick per use case.

?? What does PACELC add?
Even without partitions, there's a constant trade-off between latency and consistency: waiting for replicas to acknowledge (strong consistency) adds latency, while replying immediately (low latency) risks stale reads. Most of a system's life is spent in the "else" branch, so this matters more day-to-day.

#### Tricky questions
?? Is a system "CP" unavailable all the time?
No. It's unavailable only on the minority side of a partition (or until a new leader is elected). Normally it's fully available. Likewise, "AP" systems are consistent most of the time and diverge only during partitions or lag.

?? Can you have strong consistency and low latency globally?
Not fully: the speed of light makes cross-region consensus cost round trips (~100–200ms). Spanner uses TrueTime plus commit wait, and reads at snapshots can be local. Typical mitigations: keep data close to its users (partition by region) and use strong consistency only where needed.

#### Interview simulation
In every HLD, state the consistency choice **per data type**: "Likes and view counts are eventually consistent (AP; a few seconds of staleness is fine). Payments and inventory decrements are strongly consistent (CP), on a single-leader relational DB with transactions." Saying it per data type, not one blanket answer, is what interviewers want.

### Consistency models and quorums

#### Core idea
A consistency model is a **contract** about what values reads can return relative to writes, from strongest (behaves like a single copy) to weakest (eventually converges). Choosing the weakest model your use case tolerates gives the best latency and availability.

#### How it works
| Model | Guarantee | Example |
|---|---|---|
| **Linearizability (strong)** | every operation appears to take effect atomically at one point between its start and end; reads see the latest write | etcd, ZooKeeper writes, Spanner, a single-leader DB read from the leader |
| **Sequential consistency** | all nodes see operations in the same order, consistent with each client's program order (not necessarily real time) | |
| **Causal consistency** | causally related operations are seen in order by everyone; concurrent ones may differ | a comment never appears before the post it replies to |
| **Read-your-writes** | a client always sees its own writes | your profile edit shows after refresh |
| **Monotonic reads** | a client never sees older data after seeing newer | no "time travel" between refreshes |
| **Eventual consistency** | if writes stop, all replicas converge eventually | DNS, Cassandra ONE, like counts |

**Quorums (leaderless replication)**: N replicas, a write waits for W acks, a read queries R replicas.
- **R + W > N** gives overlapping sets, so reads see the latest acknowledged write (e.g. N=3, W=2, R=2: Cassandra `QUORUM`/`QUORUM`).
- W=1, R=N: fast writes, slow reads. W=N, R=1: fast reads, but writes fail if any node is down.
- Cassandra's `LOCAL_QUORUM` keeps quorums within a datacentre for latency.
- Caveats: *sloppy quorums* (hinted handoff, writing to non-home nodes during failures) weaken the guarantee; concurrent writes need conflict resolution (last-write-wins by timestamp loses data; vector clocks or CRDTs keep both).

**Conflict-free Replicated Data Types (CRDTs)**: data structures that merge deterministically (G-Counter, PN-Counter, OR-Set, LWW-Register), so replicas can accept writes independently and always converge. Used in Riak, Redis Enterprise active-active, and collaborative editing (Automerge, Yjs).

#### Real-world example
**Instagram/Facebook likes**: eventual consistency with counters aggregated asynchronously, since a like count off by a few for seconds is harmless. **WhatsApp message order within a chat**: causal ordering per conversation (sequence numbers per chat). **Inventory decrement at checkout**: linearizable (a single-leader row update or a conditional write).

#### Interview questions
?? Strong vs eventual consistency: give examples where each is appropriate.
Strong: account balances, inventory reservation, unique username registration, leader election, distributed locks. Eventual: social counters, feeds, search indexes, analytics, recommendation data, DNS. The deciding question: what's the cost of a stale or conflicting read?

?? With N=3, how would you configure W and R for a read-heavy system needing consistency?
W=3, R=1 makes reads fastest, but writes fail if any replica is down. W=2, R=2 (quorum) balances it and tolerates one node failure for both reads and writes. Usually choose quorum for both, and use local-DC quorums in multi-region setups.

#### Tricky questions
?? R + W > N but you still read stale data. How?
Possible causes: sloppy quorums during failures (the write went to substitute nodes); a write that failed partially (reached fewer than W nodes but wasn't rolled back, so some reads see it and some don't); concurrent writes with last-write-wins clock skew; read repair not yet applied. Quorums give probabilistic, not strict, linearizability in Dynamo-style systems.

#### Interview simulation
When the interviewer asks "what consistency do you need here?", answer with a **specific model plus a reason**: "For the chat timeline, causal ordering per conversation is enough. I'll assign sequence numbers per conversation at the server. For the 'last seen' status, eventual consistency is fine." That shows you understand the models beyond strong vs eventual.

### Consensus, Raft and leader election

#### Core idea
**Consensus** lets a group of nodes agree on a value, or an ordered log of commands, even if some nodes crash, as long as a **majority** is alive. It's the foundation of leader election, distributed configuration (etcd, ZooKeeper), and strongly consistent replicated databases. **Raft** is the understandable consensus algorithm used widely today (etcd, Consul, CockroachDB, TiKV, Kafka's KRaft).

#### How it works
**Raft basics**
- Nodes are **followers**, **candidates** or a **leader**. Time is divided into **terms** (monotonically increasing epochs).
- **Leader election**: followers expect heartbeats from the leader. On a randomised election timeout (150–300ms), a follower becomes a candidate, increments the term, votes for itself and requests votes. It wins with a **majority**. Randomised timeouts make split votes rare.
- **Log replication**: clients send commands to the leader, which appends them to its log and replicates them to followers. An entry is **committed** once stored on a majority, and then it's applied to the state machine. Followers with conflicting entries are overwritten by the leader's log.
- **Safety**: a candidate can only win if its log is at least as up to date as a majority's (so committed entries are never lost). At most one leader per term.
- **Fault tolerance**: 2f+1 nodes tolerate f failures (3 nodes tolerate 1, 5 tolerate 2). Even numbers add no tolerance.

**Leader election uses in practice**
- Only one instance should run a cron job or own a partition: acquire a **lease** in etcd, ZooKeeper or Consul (or the Kubernetes Lease API), renew it periodically, and step down if renewal fails.
- Database failover managers (Patroni uses etcd or Consul for the Postgres leader key).
- Kafka: the KRaft controller quorum (replacing ZooKeeper; Kafka 4.0 removed ZooKeeper entirely); partition leaders are chosen from the ISR.

**Paxos**: the original consensus algorithm (Lamport), notoriously hard to understand. Multi-Paxos is used in Google Chubby and Spanner. **ZAB** is ZooKeeper's protocol.

#### Real-world example
**Kubernetes** stores all cluster state in **etcd** (Raft). That's why control-plane etcd clusters run 3 or 5 members. Losing a majority makes the API server unable to write, though running pods keep running. **Kubernetes controllers** (scheduler, controller manager) use Lease objects for leader election so only one active replica acts.

#### Interview questions
?? Why do consensus systems use an odd number of nodes?
A majority is needed to make progress. 3 nodes need 2 (tolerating 1 failure); 4 nodes need 3 (still tolerating only 1); 5 nodes need 3 (tolerating 2). An even count adds cost and coordination without extra fault tolerance, and can split evenly in a partition.

?? How would you ensure only one instance of a service runs a scheduled job?
Leader election through a coordination service: acquire a lease or lock (etcd lease, ZooKeeper ephemeral node, Kubernetes Lease, or a DB row lock with expiry like ShedLock), renew it periodically, and run the job only while holding it. Make the job idempotent and use fencing tokens, because a paused leader may not know it lost the lease.

#### Tricky questions
?? Can a Raft cluster have two leaders at the same time?
At most one leader **per term**. During a partition, an old leader in the minority may still *think* it's leader (an older term) while the majority elects a new leader in a higher term. The old leader can't commit anything (no majority), and when it hears of the higher term it steps down. But clients talking to it might get stale reads unless reads also go through the log or the leader confirms its leadership (ReadIndex, or lease-based reads).

#### Interview simulation
You'll rarely implement Raft, but you'll **use** consensus. When your design needs a single coordinator (a scheduler leader, a partition owner, a config store), say: "Leader election via etcd leases (Raft underneath, 3 nodes, tolerates 1 failure); the work is idempotent and fenced with the lease revision, in case an old leader wakes up after a GC pause." That's the right level of depth for most HLD rounds.

### Distributed locks and fencing tokens

#### Core idea
A **distributed lock** ensures only one process across many machines does something at a time (processing a job, updating a resource). It's harder than a local lock because processes can **pause** (GC, VM stalls), **crash**, or be **partitioned** while holding it. So locks must **expire** (leases), and an expired holder might still act. **Fencing tokens** make that safe.

#### How it works
**Implementations**
1. **Redis** `SET lock:res <uniqueValue> NX PX 30000` to acquire with a TTL; release with a Lua script that deletes the key **only if** the value matches (so you don't delete someone else's lock).
2. **Database**: a row lock (`SELECT … FOR UPDATE`, or Postgres advisory locks) held within a transaction; or a lock table with `locked_until` (ShedLock).
3. **ZooKeeper/etcd**: ephemeral sequential nodes or leases. The lock is released automatically when the session dies, and you get a monotonically increasing revision usable as a fencing token. Strongest consistency.

**The pause problem**
```
Client A acquires lock (TTL 30s) → A has a 40s GC pause → lock expires
Client B acquires lock → B writes to storage
A wakes up, still believes it holds the lock → A writes to storage → corruption
```
**Fencing token fix**: each lock acquisition returns an increasing number (33, 34, …). The client sends it with every write; the **storage rejects writes with a token lower than the highest it has seen**. A's token 33 is rejected after B wrote with 34. That needs the protected resource to check tokens (a version column `WHERE fence_token < :token`).

**Redlock** (Redis's multi-node lock algorithm): acquire on a majority of N independent Redis masters within a time limit. It's debated: Martin Kleppmann argued it's unsafe for correctness without fencing, because it relies on timing assumptions. The guidance: use Redis locks for **efficiency** (avoiding duplicate work, where an occasional double execution is tolerable); for **correctness**, use consensus-backed locks plus fencing, or design for idempotency.

**Often better: avoid locks**: use conditional writes (`UPDATE … WHERE version = ?`), unique constraints, single-writer partitioning (route all work for a key to one consumer via Kafka partitions), or idempotent operations.

#### Real-world example
A payout job running on 3 instances must not pay a seller twice. A weak design is a Redis lock alone. A strong design: partition the payout work by seller via a queue (single consumer per partition), make each payout idempotent with a unique `(seller_id, period)` constraint, and use a payment-provider idempotency key. Even if two workers run, only one payout can be created.

#### Interview questions
?? How do you implement a distributed lock with Redis correctly?
`SET key token NX PX ttl`, where the token is unique per holder; do the work within the TTL (or renew it with a watchdog, like Redisson's); release via a Lua script that compares the token before deleting. Know the limits: pauses beyond the TTL break mutual exclusion, so use fencing tokens or idempotent operations when correctness matters.

?? What is a fencing token?
A monotonically increasing number issued with each lock grant. The protected resource records the highest token it has accepted and rejects requests carrying a lower one. That way, a client that lost its lock (expired during a pause) can't corrupt data, even if it believes it still holds the lock.

#### Tricky questions
?? Why can't you just make the lock TTL very long to avoid expiry during pauses?
If the holder crashes, the resource stays locked until the TTL expires, hurting availability. Long TTLs trade safety issues for liveness issues. Use moderate TTLs with renewal (heartbeats) plus fencing.

#### Interview simulation
When a design needs "only one worker does X", show the progression: "First choice is to avoid the lock: partition the work so one consumer owns each key, and make operations idempotent with a unique constraint. If we need a lock, an etcd lease with fencing tokens checked by the datastore. Redis SET NX is fine where duplicate work is just wasteful, not harmful." That nuance is very senior.

### Idempotency and delivery semantics

#### Core idea
In distributed systems, messages and requests can be **lost, duplicated or reordered**, and the sender often can't tell which (a timeout is ambiguous). Therefore:
- Delivery is **at-most-once** (may lose) or **at-least-once** (may duplicate). **Exactly-once delivery** isn't achievable in general.
- What you *can* build is **exactly-once processing (effect)**: at-least-once delivery + **idempotent** handling.

#### How it works
**Making operations idempotent**
1. **Natural idempotency**: `SET status = 'SHIPPED'`, an upsert by key, or `PUT` semantics. Repeating has no extra effect.
2. **Idempotency keys**: the client supplies a unique key per logical operation; the server records the key with the result and returns the stored result on repeats (see the Spring APIs lesson).
3. **Dedup table in the same transaction**: the consumer inserts `processed_events(event_id)` (unique) in the same DB transaction as its side effect. A duplicate fails the insert, so it's skipped.
4. **Conditional / versioned updates**: `UPDATE … WHERE version = :expected` or `WHERE status = 'PENDING'`.
5. **Monotonic sequence numbers per key**: ignore events with a sequence ≤ the last applied one (also handles reordering).

**Kafka specifics**
- **Idempotent producer** (`enable.idempotence=true`, the default in recent clients): the broker dedupes retries from the same producer session via producer id plus sequence numbers. No duplicates from producer retries.
- **Transactions**: atomically write to multiple partitions **and** commit consumer offsets (read-process-write within Kafka). Consumers with `isolation.level=read_committed` see only committed data. That gives "exactly-once semantics" (EOS) for Kafka-to-Kafka pipelines (Kafka Streams).
- **External side effects** (DB writes, emails, payments) still need idempotency on your side.

**Retries and timeouts**: a timeout means "unknown outcome". Retrying a non-idempotent operation risks duplicates, so either make it idempotent or query its status before retrying.

#### Real-world example
**Payment webhooks** (Razorpay, Stripe) are delivered at least once and may arrive out of order (`payment.captured` before `payment.authorized`). Robust handlers: verify the signature → insert the event id into a dedup table → apply only valid **state transitions** (ignore regressions) → return 200 quickly and process asynchronously. Your Stripe integration experience fits right here.

#### Interview questions
?? Can you have exactly-once delivery?
Not in general across unreliable networks: the sender can't distinguish "lost" from "slow", so it must either risk losing (no retry) or duplicating (retry). Systems achieve **effectively-once processing** with at-least-once delivery plus idempotent or deduplicating consumers, or with transactional coupling of consumption and output (Kafka EOS within Kafka).

?? How do you make a Kafka consumer that writes to a database idempotent?
Include a unique event id (or use topic-partition-offset as the id). In one DB transaction, insert the id into a `processed_events` table (unique constraint) and apply the change. On a duplicate key, skip. Optionally store the consumed offset in the same DB transaction (and seek to it on startup), which gives exactly-once effects for that sink.

#### Tricky questions
?? An idempotency key prevents duplicate charges. But what if two different requests legitimately want the same charge (the user buys the same item twice)?
The key identifies a **logical operation**, not the payload. The client generates a new key for each new purchase intent and reuses it only for retries of the same intent. A server can also detect key reuse with a different payload and reject it.

#### Interview simulation
Any time you draw a queue or a retry in a design, add one sentence: "Delivery is at-least-once, so the consumer is idempotent: it dedupes on eventId within the same transaction as its write." And for client-facing writes: "POST /orders takes an Idempotency-Key." Those two sentences prevent the most common follow-up attack.

### Distributed transactions: 2PC vs Saga

#### Core idea
When one business operation spans **multiple services or databases** (order + payment + inventory + shipping), you can't use a single ACID transaction. Two families of solutions:
- **Two-phase commit (2PC)**: atomic commit across participants via a coordinator. Strong, but blocking and fragile.
- **Saga**: a sequence of **local transactions**, each publishing an event or command for the next; on failure, run **compensating transactions** to undo the earlier steps. Eventually consistent and resilient. This is the standard approach for microservices.

#### How it works
**2PC**
```
Coordinator → all participants: PREPARE   (each locks resources, writes redo/undo, votes YES/NO)
If all YES → COMMIT to all ; if any NO/timeout → ABORT to all
```
- Problems: **blocking**. If the coordinator crashes after PREPARE, participants hold locks until it recovers. It's latency-heavy, reduces availability (every participant must be up), and needs XA support (rare among modern services and NoSQL stores).
- Used inside databases (distributed SQL such as Spanner and CockroachDB use variants built on consensus), rarely between microservices.

**Saga**
- Example: Place order → Reserve inventory → Charge payment → Create shipment.
- On failure: Charge payment fails → compensate: release inventory → cancel order.
- **Choreography**: each service listens to events and reacts (`OrderCreated` → inventory reserves → `InventoryReserved` → payment charges…). Decoupled, but the flow is implicit and hard to trace; cyclic dependencies are a risk.
- **Orchestration**: a central **orchestrator** (a saga state machine) tells each service what to do and tracks progress. The flow is explicit, easier to monitor and change; the orchestrator is a component to keep highly available. Tools: Temporal, Camunda, AWS Step Functions, Netflix Conductor.

**Saga design rules**
- Each step is a **local ACID transaction** plus a reliable message (the **outbox** pattern).
- **Compensations** must be idempotent and semantically undo (a refund, not a deletion of history). Some steps can't be compensated (an email was sent), so put them **last** (pivot transaction ordering).
- **Isolation is lost**: other transactions see intermediate states (an order PENDING). Use semantic locks (status fields), commutative updates, and re-reading values.
- Timeouts for every step; retries with idempotency.

```
Orchestrated saga state machine:
ORDER_CREATED → RESERVING_STOCK → (ok) CHARGING → (ok) SCHEDULING_SHIPMENT → COMPLETED
                      │ fail                 │ fail → RELEASING_STOCK → CANCELLED
                      └→ CANCELLED
```

#### Real-world example
**Uber** built Cadence (now Temporal) to orchestrate long-running workflows such as trip lifecycles and payments. **E-commerce checkout** at Flipkart or Amazon-like companies uses sagas: inventory is reserved (with a TTL), payment is captured asynchronously, and compensation releases stock or triggers a refund when payment fails. Travel booking (flight + hotel + car) is the classic textbook saga.

#### Interview questions
?? Why not use 2PC between microservices?
It couples the availability of all services (any one down blocks everyone), holds locks across network round trips (poor throughput), blocks if the coordinator fails mid-protocol, and requires XA support that most modern datastores and message brokers lack. Sagas trade isolation for availability and scalability.

?? Choreography vs orchestration?
Choreography: services react to each other's events with no central controller. Good for simple flows with few steps, and highly decoupled. Orchestration: an orchestrator drives the steps explicitly. Better for complex flows (many steps, branching, timeouts, compensations), visibility, and changing the process in one place. Many teams prefer orchestration (Temporal) for business-critical multi-step workflows.

#### Tricky questions
?? A compensation step itself fails (e.g. a refund API is down). What now?
Compensations must be **retried until they succeed** (idempotent, with backoff), persisted in the saga state so they survive crashes, and escalated to a human or a reconciliation process after N attempts (a DLQ plus alerting). A saga must always eventually reach a terminal state.

?? How do you prevent another user from buying the stock that's "reserved" during a saga?
Reservation is itself a state change in the inventory DB (available decreases, reserved increases), so other orders see reduced availability. That's a **semantic lock**. Reservations have expiry so abandoned sagas release the stock.

#### Interview simulation
**Interviewer:** "Order, payment and inventory are separate services. How do you keep them consistent?"

**Answer:** "A saga, orchestrated by an order workflow (Temporal or a state machine in the order service). Steps: create order PENDING (local transaction plus an outbox event), reserve inventory with a TTL, authorise payment with an idempotency key, confirm the order. Failure paths compensate in reverse: release inventory, void or refund the payment. All messages are at-least-once with idempotent handlers. The saga state is persisted, so the orchestrator resumes after crashes. A reconciliation job catches stuck sagas." Then draw the state machine. This is a top-5 senior backend question.

### Transactional outbox and CDC

#### Core idea
The **dual-write problem**: a service must update its database **and** publish an event (to Kafka). Doing two separate writes can fail halfway: the DB commits but the publish fails (the event is lost), or the publish succeeds but the DB rolls back (a phantom event). The **transactional outbox** solves it by writing the event into an **outbox table in the same DB transaction**, then relaying it to the broker. **CDC (Change Data Capture)** streams DB changes from the database's log.

#### How it works
**Outbox**
```sql
BEGIN;
  INSERT INTO orders (...) VALUES (...);
  INSERT INTO outbox (id, aggregate_type, aggregate_id, type, payload, created_at)
       VALUES (uuid, 'order', :orderId, 'OrderPlaced', :json, now());
COMMIT;      -- both or neither
```
Then a **relay** publishes outbox rows to Kafka:
1. **Polling publisher**: a background job selects unpublished rows (`FOR UPDATE SKIP LOCKED`), publishes them, and marks them sent. Simple, but adds DB load and latency (the polling interval).
2. **Log-tailing CDC** (preferred at scale): **Debezium** reads the DB's WAL or binlog and emits outbox inserts to Kafka (Debezium has a dedicated outbox event router). Low latency, no polling load.

Properties: **at-least-once** publishing (the relay may publish and crash before marking), so consumers dedupe by event id. Ordering per aggregate is preserved by using `aggregate_id` as the Kafka key.

**CDC more broadly**: stream every insert, update and delete from the DB log to Kafka. Uses: keeping search indexes, caches and data warehouses in sync; migrating databases (stream old to new); building read models (CQRS); invalidating caches reliably.

**Inbox pattern** (the consumer side): record received message ids in an inbox table in the same transaction as the processing, for deduplication.

#### Real-world example
Shopify, Zalando and many others use Debezium-based CDC to feed Kafka from MySQL or Postgres. In your 1mg-style stack: the order service writes the order plus an outbox row; Debezium publishes `OrderPlaced`; the notification, analytics and search-indexing consumers update their own stores. No event is lost even if Kafka was briefly down, because the outbox holds it.

#### Interview questions
?? What's the dual-write problem and how does the outbox pattern solve it?
Writing to the DB and the broker separately isn't atomic, so a crash between them leaves the systems inconsistent. The outbox makes the event part of the same local DB transaction as the state change; a separate process reliably relays committed outbox rows to the broker, so events are published if and only if the transaction committed (at least once).

?? Polling publisher vs CDC for the outbox?
Polling: simple, no extra infrastructure, but it adds query load and latency, and needs careful locking for multiple relay instances. CDC (Debezium): low latency and scalable, with no polling queries, but it adds Kafka Connect/Debezium infrastructure and requires DB log access (logical replication slots, which must be monitored, because a stuck slot makes WAL pile up).

#### Tricky questions
?? Why not just publish to Kafka after the DB commit in the same method?
If the process crashes (or Kafka is unavailable) after the commit but before the publish, the event is lost forever, and downstream services never learn about the order. Retrying in memory doesn't survive crashes. The outbox persists the intent durably.

?? A Postgres logical replication slot used by Debezium stops being consumed. What happens?
Postgres retains WAL for the slot indefinitely, so the disk fills up and the primary can go down. Monitor slot lag (`pg_replication_slots`), set `max_slot_wal_keep_size` (PG13+), and alert.

#### Interview simulation
Whenever your design says "service X updates its DB and publishes an event", add: "via the transactional outbox, relayed by Debezium CDC, keyed by aggregate id for ordering; consumers dedupe by event id." Interviewers frequently probe "what if Kafka is down when you publish?" and this answer closes it.

### CQRS and event sourcing

#### Core idea
- **CQRS (Command Query Responsibility Segregation)**: separate the **write model** (commands that change state, enforcing invariants) from the **read model(s)** (queries optimised for display), often in different stores, kept in sync through events.
- **Event sourcing**: instead of storing the current state, store the **sequence of events** that led to it (`MoneyDeposited`, `MoneyWithdrawn`). The current state is derived by replaying the events. The event log is the source of truth.

They're often used together but are independent ideas.

#### How it works
**CQRS**
```
Commands → Write service → normalized write DB (Postgres) ──events/CDC──▶ projectors
                                                                   ├─▶ Elasticsearch (search view)
Queries ←──────────────────────────────────────────────────────────┼─▶ Redis (dashboard counters)
                                                                   └─▶ Cassandra (per-user timeline)
```
- Each read model is shaped for one query (denormalised), giving fast reads and independent scaling.
- **Cost**: eventual consistency between the write and read sides (UIs must handle "just updated" lag), and more moving parts.

**Event sourcing**
- An append-only event store, per aggregate stream: `account-42: [Opened, Deposited(500), Withdrew(200)]` → balance 300.
- **Snapshots** every N events avoid replaying everything.
- **Benefits**: a complete audit trail, temporal queries ("what was the state on March 1?"), debugging by replay, new read models built by replaying history, and natural integration through events.
- **Costs**: event schema evolution (versioning, upcasting old events), eventual consistency of projections, complex querying (you need projections), GDPR deletion is hard (crypto-shredding: encrypt per-user data and delete the key), and a learning curve.
- Optimistic concurrency on append: `append(stream, events, expectedVersion)`.

**When to use**: CQRS when read and write needs differ greatly (complex queries, high read volume, multiple views). Event sourcing for domains where history *is* the business: ledgers, accounting, audit-heavy workflows, logistics tracking. Not for simple CRUD.

#### Real-world example
**Banking and payment ledgers** are naturally event-sourced: a double-entry journal of immutable entries, with balances as projections. **Git** is event sourcing for code (commits). **Kafka-based architectures** often apply CQRS: a service's DB changes stream out to build search indexes, analytics tables and caches, which is exactly what your Kafka plus Elasticsearch experience enables.

#### Interview questions
?? What problems does CQRS solve, and what does it cost?
It lets you optimise and scale reads and writes independently: complex or denormalised read views (search, dashboards) without compromising the normalised write model that enforces invariants. Costs: eventual consistency between the models, synchronisation infrastructure (events or CDC), more code and operations, and the need to handle replaying and rebuilding projections.

?? How do you handle schema changes in event sourcing?
Events are immutable, so never rewrite them. Version the events (`OrderPlacedV2`); write **upcasters** that transform old events to the new shape at read time; keep consumers tolerant (ignore unknown fields); for big changes, migrate by copying and transforming into a new stream, with care.

#### Tricky questions
?? A user deletes their account (GDPR) but their data is in immutable events. What do you do?
Crypto-shredding: encrypt personal fields with a per-user key stored separately, and delete the key to make the data unreadable. Or keep personal data out of events (store references) and delete it from the separate store. Plan for this upfront.

#### Interview simulation
Use CQRS naturally in designs: "The write path stores orders in Postgres; an event stream projects them into an Elasticsearch index for the seller search screen and into Redis counters for the dashboard. These read models are eventually consistent within a couple of seconds." Mention event sourcing only where history matters (a wallet ledger). Using it everywhere is a red flag of over-engineering.

### Time and ordering: clocks, logical and vector clocks

#### Core idea
Distributed machines **don't share a clock**. Physical clocks drift and get adjusted by NTP (they can even jump backwards). So you can't reliably order events across machines by wall-clock timestamps. **Logical clocks** capture *causality* instead: if event A could have influenced event B, A is ordered before B.

#### How it works
- **Physical clocks**: NTP keeps skew to a few milliseconds typically (more under bad conditions). Two events 1ms apart on different machines can't be ordered reliably by timestamp. **Last-write-wins (LWW)** based on timestamps can silently drop the "later" write if clocks are skewed.
- **Monotonic clocks** (`System.nanoTime()`): never go backwards, but are only meaningful within one machine. Use them for timeouts and durations; wall clocks for human-facing times.
- **Lamport clocks**: each node keeps a counter; increment on each event; send it with messages; on receive, `counter = max(local, received) + 1`. If A → B (causally) then L(A) < L(B). The reverse doesn't hold: concurrent events also get ordered (arbitrarily). This gives a total order (with node id tie-breaking) consistent with causality.
- **Vector clocks**: each node keeps a vector of counters, one per node. They can tell **"happened-before"** apart from **"concurrent"**: V(A) < V(B) if every element is ≤ and at least one is <; otherwise they're concurrent, so there's a conflict to resolve. Used in Dynamo/Riak for conflict detection. The cost is a vector size that grows with the number of nodes.
- **Hybrid Logical Clocks (HLC)**: physical time plus a logical counter. They stay close to wall time and preserve causality (CockroachDB, MongoDB).
- **TrueTime (Spanner)**: GPS and atomic clocks give a time **interval** [earliest, latest] with bounded uncertainty (~1–7ms). Spanner waits out the uncertainty before committing ("commit wait"), achieving externally consistent (linearizable) transactions globally.

#### Real-world example
**Cassandra** resolves conflicting writes by timestamp (LWW). With clock skew between servers, a delete can be overwritten by an "earlier" write that has a later timestamp. That's why Cassandra deployments monitor NTP closely and why read-modify-write patterns are discouraged there. **Chat apps** use server-assigned per-conversation sequence numbers, not client timestamps, to order messages.

#### Interview questions
?? Why can't you rely on timestamps to order events in a distributed system?
Clocks on different machines drift and are corrected by NTP, which can make time jump forwards or backwards. Skew of milliseconds or more means two events can get timestamps in the wrong order relative to their real or causal order. Ordering must come from a single sequencer (a leader or partition), logical clocks, or bounded-uncertainty clocks (TrueTime).

?? Lamport clock vs vector clock?
A Lamport clock gives a single number per event, consistent with causality (causes have smaller numbers), but can't tell whether two events are concurrent. Vector clocks track per-node counters and can detect concurrency (and therefore conflicts), at the cost of larger metadata.

#### Tricky questions
?? How does Kafka provide ordering without synchronised clocks?
Within a partition, the single leader broker assigns **offsets** sequentially, so it acts as the sequencer. There's no global order across partitions. If you need ordering for an entity, put all its events in one partition (key by entity id).

#### Interview simulation
When ordering matters in your design (chat messages, event processing), say how you get it: "Each conversation is owned by one partition or sequencer that assigns monotonically increasing sequence numbers; clients order by sequence number, not by device timestamps, because device clocks are unreliable." That prevents a classic follow-up trap.

### Failure handling: timeouts, retries, backpressure and cascading failures

#### Core idea
In distributed systems, **partial failure is normal**: some components are slow or down while others work. Systems must be designed so that a failure stays **contained**, the system **degrades gracefully**, and it **recovers** automatically. The biggest outages usually come from **cascading failures** and **retry storms**, not from the initial fault.

#### How it works
**Toolkit (most covered in the Spring Resilience lesson; here's the system view)**
- **Timeouts everywhere**, budgeted end to end (deadline propagation: each hop gets the remaining time).
- **Retries**: few, with exponential backoff and jitter; only idempotent operations; **retry budgets** (e.g. at most 10% extra load); retry at one layer only.
- **Circuit breakers**: stop calling failing dependencies, fail fast.
- **Bulkheads**: isolate resources per dependency or per tenant.
- **Backpressure**: when overloaded, signal upstream to slow down (bounded queues, 429/503, reactive streams demand, TCP flow control) instead of buffering without limit.
- **Load shedding**: reject low-priority work early when near capacity (prioritise checkout over recommendations). Drop requests that have already exceeded their deadline (they're pointless).
- **Graceful degradation / fallbacks**: serve cached or stale data, default values, or hide features.
- **Queues for spikes**: async processing absorbs bursts (with monitoring of lag).
- **Idempotency** to make retries safe.
- **Health checks and auto-recovery**: restart unhealthy instances; remove them from load balancers.
- **Chaos engineering**: inject failures in controlled ways to verify resilience (Netflix Chaos Monkey).

**How cascading failure happens**
```
DB slows ↓ → service A threads wait longer → A's pool exhausts → A times out to its callers
→ callers retry (3x load!) → A even more overloaded → its health checks fail → LB removes instances
→ remaining instances get more load → total collapse ("death spiral")
```
Breakers, timeouts, retry budgets, load shedding and bulkheads each break a link in this chain.

**Metastable failures**: the system stays down even after the trigger is gone, because recovery load (retries, cold caches, reconnect storms) keeps it overloaded. Fixes: shed load aggressively, add jittered reconnects, warm caches, and bring traffic back in stages.

#### Real-world example
**AWS us-east-1 outage (Dec 2021)**: an automated scaling activity triggered a surge of connection activity that overwhelmed internal networking devices, and retries made the congestion worse, causing widespread impact for hours. **Facebook's 2010 outage**: a bad config value caused every client to query the DB to "fix" its cache, a feedback loop that required shutting the site down to break. Lesson: retries and automated fixes can amplify failures.

#### Interview questions
?? How do you prevent a retry storm?
Limit retries (2–3) with exponential backoff plus jitter; use retry budgets or token buckets for retries; retry at only one layer; circuit breakers to stop retrying a dead dependency; respect `Retry-After`; make servers shed load early with fast 503s rather than slow timeouts.

?? What is backpressure?
A mechanism for a consumer to signal that it's overwhelmed so the producer slows down, instead of the system buffering without bound (leading to latency explosions and OOM). Examples: bounded queues that block or reject, TCP windows, Reactive Streams `request(n)`, 429 responses, Kafka consumers naturally pulling at their own pace.

#### Tricky questions
?? Why is "fail fast" often better than "wait longer" during overload?
Waiting ties up resources (threads, connections, memory) on requests that will probably fail or that the user has already abandoned, increasing the overload. Failing fast frees the resources, lets callers fall back, and keeps the service responsive for the requests it *can* handle.

#### Interview simulation
At the end of every HLD, run a **failure pass**: "If the payment service is slow, checkout times out at 2s, the circuit opens, and orders go to PENDING_PAYMENT with async retries. If Redis is down, we read from the DB with a rate limiter to protect it. If Kafka is down, the outbox buffers events. If a region fails, DNS fails over to the standby region." Interviewers love an unprompted failure walkthrough.

### Unique ID generation

#### Core idea
Distributed systems need **unique IDs** generated without a single bottleneck. Desirable properties vary: global uniqueness, **sortable by time** (good for B-tree inserts, pagination and debugging), compact (64-bit vs 128-bit), non-guessable (security), and generated with no coordination.

#### How it works
| Approach | Size | Sortable | Coordination | Notes |
|---|---|---|---|---|
| DB auto-increment | 64-bit | yes | single DB (bottleneck/SPOF) | simple; leaks volume; hard with sharding |
| DB with step offsets | 64-bit | roughly | per-shard config | shard k uses k, k+N, k+2N… (Flickr ticket servers) |
| **UUIDv4** | 128-bit | **no** (random) | none | great uniqueness; poor B-tree locality; 36-char strings |
| **UUIDv7** | 128-bit | yes (ms timestamp prefix) | none | RFC 9562 (2024); a good default now |
| ULID | 128-bit | yes | none | base32, lexicographically sortable |
| **Snowflake** | 64-bit | yes | worker id assignment | Twitter's design |
| Segment/batch allocation | 64-bit | roughly | DB hands out ranges | each server takes 1,000 IDs at a time (Leaf by Meituan) |

**Snowflake layout (64 bits)**
```
| 1 bit sign | 41 bits ms since custom epoch (~69 years) | 10 bits worker id (1024 workers) | 12 bits sequence (4096/ms/worker) |
```
```java
class Snowflake {
    private static final long EPOCH = 1704067200000L;       // 2024-01-01
    private final long workerId; private long lastMs = -1, seq = 0;
    Snowflake(long workerId) { if (workerId < 0 || workerId > 1023) throw new IllegalArgumentException(); this.workerId = workerId; }
    synchronized long next() {
        long now = System.currentTimeMillis();
        if (now < lastMs) throw new IllegalStateException("clock moved backwards");   // or wait until lastMs
        if (now == lastMs) { seq = (seq + 1) & 4095; if (seq == 0) while ((now = System.currentTimeMillis()) <= lastMs) { } }
        else seq = 0;
        lastMs = now;
        return ((now - EPOCH) << 22) | (workerId << 12) | seq;
    }
}
```
- Worker ids are assigned via config, ZooKeeper/etcd, or derived from the pod ordinal.
- **Clock going backwards** (NTP adjustment) risks duplicates: refuse, or wait, or keep a logical "last timestamp".
- Up to 4,096 IDs per ms per worker, about 4M per second per worker.

**Short public IDs** (e.g. URL shorteners): base62-encode a numeric ID, or use random tokens checked for collisions. Avoid exposing sequential IDs where enumeration is a risk (IDOR scraping).

#### Real-world example
**Twitter** created Snowflake for tweet IDs (time-sortable, so the timeline can sort by id). **Discord** uses Snowflake ids for messages, users and channels (you can extract the creation time from any Discord id). **Instagram** encoded the shard id into each ID (41 bits time, 13 bits logical shard, 10 bits sequence) generated inside Postgres via PL/pgSQL, so the ID itself says where the data lives.

#### Interview questions
?? Design a unique ID generator for a distributed system.
Clarify: 64-bit or 128-bit? Must be time-sortable? Throughput? Then propose Snowflake: timestamp + worker id + sequence; worker ids from a coordination service; handle clock rollback; capacity 4K per ms per worker. Mention UUIDv7 as a coordination-free alternative when 128-bit is OK.

?? Why are random UUIDv4 primary keys bad for database performance?
Random values insert into random positions in the B-tree index, causing page splits, poor cache locality and index bloat (especially with clustered primary keys in InnoDB). Time-ordered IDs (UUIDv7, Snowflake, ULID) append near the end of the index.

#### Tricky questions
?? What happens to Snowflake if two machines get the same worker id?
They can generate identical IDs in the same millisecond with the same sequence. Worker id assignment must be unique: use leases from etcd/ZooKeeper (and a worker refuses to generate if its lease is lost), or derive it deterministically from a unique pod ordinal in a StatefulSet.

#### Interview simulation
In designs that need IDs (tweets, orders, short URLs, messages), state the choice in one line with its reason: "Snowflake-style 64-bit ids: time-sortable for pagination and index locality, generated locally with no DB round trip." It's a small detail that signals experience.
