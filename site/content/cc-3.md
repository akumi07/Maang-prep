## Mock interviews: Medium | P2 | must

### M1. LRU cache behind a product service

#### Brief
A product service caches product lookups in a hand-written LRU cache (a HashMap plus a doubly linked list), because the team didn't want a dependency. **Rules**: capacity N entries; `get` marks the entry most recently used; `put` on an existing key updates the value and recency; when full, evict the least recently used. The service is called from many request threads. **Symptom**: memory grows past capacity in production, and hot products get evicted. Time box: 45 minutes.

#### Files
```java
// LruCache.java
public class LruCache<K, V> {
    private final class Node { K key; V val; Node prev, next; Node(K k, V v) { key = k; val = v; } }
    private final int capacity;
    private final Map<K, Node> map = new HashMap<>();
    private final Node head = new Node(null, null), tail = new Node(null, null);   // head = most recent

    public LruCache(int capacity) { this.capacity = capacity; head.next = tail; tail.prev = head; }

    public V get(K key) {
        Node n = map.get(key);
        return n == null ? null : n.val;
    }

    public void put(K key, V val) {
        if (map.size() > capacity) {
            Node lru = tail.prev;
            unlink(lru);
        }
        Node n = new Node(key, val);
        addFirst(n);
        map.put(key, n);
    }

    public int size() { return map.size(); }
    private void unlink(Node n) { n.prev.next = n.next; n.next.prev = n.prev; }
    private void addFirst(Node n) { n.next = head.next; n.prev = head; head.next.prev = n; head.next = n; }
}
```
```java
// ProductService.java
public class ProductService {
    private final LruCache<String, String> cache = new LruCache<>(2);
    private final Function<String, String> db;
    private int dbCalls = 0;

    public ProductService(Function<String, String> db) { this.db = db; }

    public String product(String id) {
        String p = cache.get(id);
        if (p == null) { p = db.apply(id); dbCalls++; cache.put(id, p); }
        return p;
    }
    public int dbCalls() { return dbCalls; }
    public int cacheSize() { return cache.size(); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        ProductService s = new ProductService(id -> "product-" + id);
        s.product("A"); s.product("B"); s.product("A");   // A is now most recent
        s.product("C");                                   // should evict B (LRU), keep A
        s.product("A");                                   // should be a cache hit
        System.out.println("db calls: expected 3, got " + s.dbCalls());
        System.out.println("cache size: expected 2, got " + s.cacheSize());
        LruCache<String, Integer> c = new LruCache<>(2);
        c.put("x", 1); c.put("x", 2);
        System.out.println("size after updating same key: expected 1, got " + c.size());
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **`get` doesn't update recency**: on a hit, `unlink(n); addFirst(n);`. Without it, the cache is FIFO, and hot items get evicted.
2. **Eviction doesn't remove from the map**: `unlink(lru)` alone leaves the key in `map`, so the map grows without bound (the memory leak) and a later `get` returns an evicted value. Add `map.remove(lru.key)`.
3. **Capacity check is off by one**: `map.size() > capacity` evicts only when already over capacity. Use `>=` (and only when inserting a **new** key).
4. **`put` on an existing key creates a duplicate node**: the old node stays in the list. If the key exists: update `val`, move to front, return.
5. **Not thread-safe**: the service is called from many threads; concurrent `put`s corrupt the linked list (lost nodes, cycles). Make `get`/`put` `synchronized` (even `get` mutates order), or use Caffeine. `dbCalls++` is also a race (`AtomicInteger`).

Also: concurrent misses for the same id cause duplicate DB calls (a cache stampede): see Stage 3.

#### Stage 2: add a feature
**Task**: add a time-to-live: entries older than 5 minutes are treated as misses.

?? Show a strong solution
Store `long writtenAtNanos` in each node (from an injectable time source). In `get`, if `now - writtenAt > ttl`, unlink, remove from the map, and return null (lazy expiry). Refresh `writtenAt` on `put`. Lazy expiry keeps dead entries in memory until touched or evicted, which is fine with an LRU bound. Mention Caffeine's `expireAfterWrite` as the production answer.

#### Stage 3: optimise
**Question**: during a sale, 500 concurrent requests for the same new product all miss and hit the DB.

?? Show the points to hit
Single-flight: keep a `ConcurrentHashMap<String, CompletableFuture<String>> inFlight`; the first miss creates the future and loads; others wait on the same future; remove it when done. Or Caffeine's `get(key, loader)`, which already coalesces loads per key. Also consider stale-while-revalidate (serve the old value while one request refreshes) and a distributed cache (Redis) so instances share it.

#### Interview simulation
**Ask**: "Is this cache shared across threads? Should a put on an existing key count as a use?" Map the data structure aloud ("map for O(1) lookup, list for recency, head is most recent"), then test each operation mentally with capacity 2.

### M2. Per-user API rate limiter

#### Brief
A filter limits each API key to `limit` requests per 1-second fixed window. **Rules**: the window resets every second; rejected requests must not count; the limiter is shared by all request threads; keys that stop sending must not leak memory forever. **Symptom**: users get rejected far too often after the first second, limits are exceeded under load, and memory grows with each new API key. Time box: 45 minutes.

#### Files
```java
// Window.java
public class Window { long windowStart; int count; }
```
```java
// FixedWindowLimiter.java
public class FixedWindowLimiter {
    private final int limit;
    private final Map<String, Window> windows = new HashMap<>();
    private final LongSupplier clockMillis;

    public FixedWindowLimiter(int limit, LongSupplier clockMillis) { this.limit = limit; this.clockMillis = clockMillis; }

    public boolean allow(String apiKey) {
        long nowSec = clockMillis.getAsLong() / 1000;
        Window w = windows.get(apiKey);
        if (w == null) { w = new Window(); w.windowStart = nowSec; windows.put(apiKey, w); }
        if (nowSec - w.windowStart > 1000) { w.windowStart = nowSec; w.count = 0; }
        w.count++;
        return w.count <= limit;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        long[] now = {10_000};
        FixedWindowLimiter rl = new FixedWindowLimiter(2, () -> now[0]);
        System.out.println(rl.allow("k") + " " + rl.allow("k") + " " + rl.allow("k") + "  (expected true true false)");
        now[0] += 1_000;                       // next second
        System.out.println("next second: expected true, got " + rl.allow("k"));
        // concurrency: 8 threads x 1000 requests within one window, limit 100
        FixedWindowLimiter shared = new FixedWindowLimiter(100, () -> 50_000);
        AtomicInteger allowed = new AtomicInteger();
        ExecutorService ex = Executors.newFixedThreadPool(8);
        for (int t = 0; t < 8; t++) ex.submit(() -> { for (int i = 0; i < 1000; i++) if (shared.allow("hot")) allowed.incrementAndGet(); });
        ex.shutdown(); ex.awaitTermination(10, TimeUnit.SECONDS);
        System.out.println("allowed under concurrency: expected 100, got " + allowed.get());
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Unit mismatch**: `nowSec - windowStart > 1000` compares seconds with 1000, so the window effectively lasts ~17 minutes. Use `nowSec != w.windowStart` (a new second means a new window).
2. **Rejected requests are counted**: `count++` before the check means a client hammering the API stays blocked (and the count grows). Only increment when allowed: `if (w.count >= limit) return false; w.count++; return true;`.
3. **`HashMap` shared across threads**: concurrent `put`s can corrupt it. Use `ConcurrentHashMap` with `computeIfAbsent`.
4. **Check-then-act on the window**: the reset and increment aren't atomic, so concurrent requests over-admit (the demo shows more than 100). Synchronise on the window object for the read-modify-write, or use `compute` per key.
5. **Memory leak**: every API key ever seen stays in the map. Evict idle keys (Caffeine `expireAfterAccess`, or a periodic sweep removing windows older than a few seconds).

Also mention the fixed-window burst problem (2× the limit across a boundary) and the clock source (`nanoTime` for intervals).

#### Stage 2: add a feature
**Task**: different limits per plan (FREE: 5/s, PRO: 50/s), and return how many requests remain plus when the window resets (for `RateLimit-*` headers).

?? Show a strong solution
Inject a `Function<String, Plan> planOf` and a `Map<Plan, Integer> limits`. Return a `Decision(boolean allowed, int remaining, long resetEpochMillis)` instead of a boolean, keeping `allow()` as a thin wrapper so existing callers compile. The reset is `(windowStart + 1) * 1000`. Cache plan lookups (they hit the DB otherwise).

#### Stage 3: optimise
**Question**: the API now runs on 30 instances behind a load balancer. How do you enforce a global per-key limit?

?? Show the points to hit
Shared state in Redis: `INCR rl:{key}:{epochSecond}` plus `EXPIRE 2` in a pipeline or Lua script (atomic), or a token bucket in Lua. Discuss the latency per request (about 1ms), fail open vs closed when Redis is down, hot keys, and a local-plus-global hybrid for very high QPS. A sliding window counter or token bucket avoids the fixed-window boundary burst.

#### Interview simulation
**Ask**: "Should rejected requests count towards the limit? Is the limit per instance or global? What should happen when the limiter's store is down?" Prove the concurrency bug with a test like the demo's executor block, and explain why `HashMap` plus non-atomic updates over-admit.

### M3. Order state machine

#### Brief
An order service moves orders through `CREATED → PAID → SHIPPED → DELIVERED`, with `CANCELLED` allowed only before shipping. Listeners (email, analytics) are notified **after** a transition is saved. The payment gateway may send the same "paid" callback twice. Cancelling a paid order refunds the full amount. **Symptom**: shipped orders get cancelled, duplicate emails go out, and customers get emails for orders that failed to save. Time box: 45 minutes.

#### Files
```java
// OrderStatus.java
public enum OrderStatus { CREATED, PAID, SHIPPED, DELIVERED, CANCELLED }
```
```java
// Order.java
public class Order {
    final String id; final long amountPaise; OrderStatus status = OrderStatus.CREATED; long refundedPaise;
    Order(String id, long amountPaise) { this.id = id; this.amountPaise = amountPaise; }
}
```
```java
// OrderRepository.java
public interface OrderRepository { Order find(String id); void save(Order o); }
```
```java
// OrderService.java
public class OrderService {
    private static final Map<OrderStatus, Set<OrderStatus>> ALLOWED = Map.of(
        OrderStatus.CREATED, Set.of(OrderStatus.PAID, OrderStatus.CANCELLED),
        OrderStatus.PAID, Set.of(OrderStatus.SHIPPED, OrderStatus.CANCELLED),
        OrderStatus.SHIPPED, Set.of(OrderStatus.DELIVERED, OrderStatus.CANCELLED),
        OrderStatus.DELIVERED, Set.of(),
        OrderStatus.CANCELLED, Set.of());

    private final OrderRepository repo;
    private final List<BiConsumer<Order, OrderStatus>> listeners = new ArrayList<>();

    public OrderService(OrderRepository repo) { this.repo = repo; }
    public void onTransition(BiConsumer<Order, OrderStatus> l) { listeners.add(l); }

    public void transition(String orderId, OrderStatus to) {
        Order o = repo.find(orderId);
        if (!ALLOWED.get(o.status).contains(to) && o.status != to) throw new IllegalStateException(o.status + " -> " + to);
        OrderStatus from = o.status;
        o.status = to;
        listeners.forEach(l -> l.accept(o, from));
        repo.save(o);
    }

    public void cancel(String orderId) {
        Order o = repo.find(orderId);
        if (o.status == OrderStatus.PAID) o.refundedPaise = o.amountPaise / 2;
        transition(orderId, OrderStatus.CANCELLED);
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Map<String, Order> store = new HashMap<>();
        OrderRepository repo = new OrderRepository() {
            public Order find(String id) { return store.get(id); }
            public void save(Order o) { if (o.id.startsWith("fail")) throw new RuntimeException("db down"); store.put(o.id, o); }
        };
        OrderService svc = new OrderService(repo);
        List<String> emails = new ArrayList<>();
        svc.onTransition((o, from) -> emails.add(o.id + ":" + from + "->" + o.status));

        store.put("o1", new Order("o1", 10_000));
        svc.transition("o1", OrderStatus.PAID);
        svc.transition("o1", OrderStatus.PAID);          // duplicate gateway callback
        System.out.println("emails after duplicate PAID: expected 1, got " + emails.size());
        svc.transition("o1", OrderStatus.SHIPPED);
        try { svc.cancel("o1"); System.out.println("cancel after SHIPPED: expected exception, but it succeeded"); }
        catch (IllegalStateException e) { System.out.println("cancel after SHIPPED rejected (good)"); }

        store.put("o2", new Order("o2", 10_000));
        svc.transition("o2", OrderStatus.PAID); svc.cancel("o2");
        System.out.println("refund: expected 10000, got " + store.get("o2").refundedPaise);

        store.put("fail1", new Order("fail1", 500)); emails.clear();
        try { svc.transition("fail1", OrderStatus.PAID); } catch (RuntimeException e) { }
        System.out.println("emails for failed save: expected 0, got " + emails.size());
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **The transition table allows SHIPPED → CANCELLED**: the spec says cancel only before shipping. The table is the single source of truth, so the bug hides in data, not code. Remove `CANCELLED` from SHIPPED's set (and add a table-driven test of every allowed and forbidden edge).
2. **Same-state "transitions" are allowed and notify listeners**: `|| o.status != to` lets a duplicate PAID through as a no-op transition that still emails. Treat `o.status == to` as an idempotent no-op: return early without notifying.
3. **Listeners run before the save**: if `save` fails, the customer has already been emailed. Save first, then notify (better: an outbox so notifications are sent only after commit, reliably).
4. **Refund is half the amount**: `amountPaise / 2` should be the full amount per the spec. Also the refund is set **before** the transition is validated, so a failed cancel leaves a refund recorded on the object.
5. **State mutated before persistence**: `o.status = to` changes the shared object even if `save` throws, so in-memory state diverges from the DB. Copy or roll back on failure (or reload).

#### Stage 2: add a feature
**Task**: support partial shipments: an order with several items can be `PARTIALLY_SHIPPED`; cancelling it refunds only the unshipped items.

?? Show a strong solution
Add `PARTIALLY_SHIPPED` with transitions PAID → PARTIALLY_SHIPPED → SHIPPED, and PARTIALLY_SHIPPED → CANCELLED (cancel the remainder). Track shipped quantities per line; the refund = Σ unshipped qty × unit price (minus proportional discounts, which is the clarifying question). Keep the transition table the single source of truth, and add tests for every allowed and disallowed edge (a table-driven test).

#### Stage 3: optimise
**Question**: notifications must never be lost, and must never be sent for a rolled-back change.

?? Show the points to hit
Transactional outbox: in the same DB transaction as the status update, insert an `order_events` row; a relay (polling or Debezium CDC) publishes to Kafka; email and analytics consumers are idempotent by event id. Duplicate gateway callbacks are handled by idempotent transitions plus a unique payment reference. Optimistic locking (`@Version`) prevents two concurrent transitions from overwriting each other.

#### Interview simulation
**Ask**: "Should a duplicate callback be an error or a no-op? Do listeners need to run after commit? Is the refund always full?" Draw the state diagram first; it makes bug 1 obvious.

### M4. Job retry worker

#### Brief
A background worker processes jobs from a queue with retries. **Rules**: each job gets at most `maxAttempts` attempts in total (first try plus retries); the backoff doubles each retry starting at 100ms and is capped at 30s; after the last failed attempt the job goes to the dead-letter list; the worker must stop promptly when interrupted (shutdown). **Symptom**: jobs are attempted the wrong number of times, failed jobs vanish, very long sleeps happen after many retries, and shutdown hangs. Time box: 50 minutes.

#### Files
```java
// Job.java
public record Job(String id, Runnable task) {}
```
```java
// Backoff.java
public class Backoff {
    static final long BASE_MS = 100, CAP_MS = 30_000;
    public static long delayMs(int attempt) {        // attempt = 1 for first retry
        int delay = 100 << attempt;
        return Math.min(delay, CAP_MS);
    }
}
```
```java
// RetryWorker.java
public class RetryWorker {
    private final int maxAttempts;
    private final List<String> deadLetters = new ArrayList<>();
    final List<Long> sleeps = new ArrayList<>();
    private final LongConsumer sleeper;

    public RetryWorker(int maxAttempts, LongConsumer sleeper) { this.maxAttempts = maxAttempts; this.sleeper = sleeper; }

    public boolean process(Job job) {
        for (int attempt = 0; attempt <= maxAttempts; attempt++) {
            try {
                job.task().run();
                return true;
            } catch (Exception e) {
                long d = Backoff.delayMs(attempt);
                sleeps.add(d);
                sleeper.accept(d);
            }
        }
        return false;
    }

    public void runLoop(BlockingQueue<Job> queue) {
        while (true) {
            try {
                Job j = queue.take();
                process(j);
            } catch (InterruptedException e) {
                // keep going
            }
        }
    }
    public List<String> deadLetters() { return deadLetters; }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        AtomicInteger calls = new AtomicInteger();
        RetryWorker w = new RetryWorker(3, ms -> {});
        boolean ok = w.process(new Job("j1", () -> { calls.incrementAndGet(); throw new RuntimeException("boom"); }));
        System.out.println("attempts: expected 3, got " + calls.get() + "; result " + ok);
        System.out.println("dead letters: expected [j1], got " + w.deadLetters());
        System.out.println("sleeps between attempts: expected [100, 200], got " + w.sleeps);
        System.out.println("delay for attempt 40: expected 30000, got " + Backoff.delayMs(40));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Too many attempts**: `attempt <= maxAttempts` starting from 0 runs `maxAttempts + 1` times. Use `attempt = 1; attempt <= maxAttempts`.
2. **Sleeps after the final failure**: the worker waits for nothing after the last attempt. Only back off if another attempt follows.
3. **Failed jobs are never dead-lettered**: after the loop, add `deadLetters.add(job.id())` (with the last exception for diagnosis).
4. **Backoff overflow and off-by-one**: `100 << attempt` is an `int` shift: for attempt ≥ 25 it overflows (it can go negative, and `Math.min` then returns a negative delay), and it starts at 200 for attempt 1. Use `long d = BASE_MS << Math.min(attempt - 1, 20)` (clamp the exponent), then `Math.min(d, CAP_MS)`, plus jitter.
5. **Interrupts are swallowed**: `runLoop` catches `InterruptedException` and loops forever, so shutdown hangs. Restore the flag and exit: `Thread.currentThread().interrupt(); return;`. Also, `process` catches `Exception` from the task, so a sleep interruption inside the sleeper should also stop retries.

Also: retrying non-retryable errors (validation errors) wastes attempts. Classify exceptions.

#### Stage 2: add a feature
**Task**: only retry transient failures (`TransientException`); fail immediately on anything else. Record the attempt history per job for the dead-letter view.

?? Show a strong solution
Catch the exception, check `e instanceof TransientException` (or a `Predicate<Throwable> retryable` injected for flexibility); non-retryable goes straight to the DLQ with attempt count 1. Keep `List<Attempt(int n, Instant at, String error)>` per job and store it with the dead letter. Keep the defaults backward compatible (retry everything if no predicate is given).

#### Stage 3: optimise
**Question**: this worker now runs on 10 instances consuming from Kafka. A job takes 5 minutes to fail 3 times because of backoff, blocking its partition.

?? Show the points to hit
Blocking retries hold up the partition (head-of-line blocking) and risk `max.poll.interval.ms` rebalances. Use non-blocking retry topics (`jobs.retry.1s`, `.10s`, `.1m`, then `jobs.DLT`), with the delay enforced by the retry consumer (Spring Kafka `@RetryableTopic`). Jobs must be idempotent because of at-least-once delivery. If ordering per key matters, retries need special handling (park subsequent events for that key).

#### Interview simulation
**Ask**: "Does maxAttempts include the first try? Should we sleep after the final failure? Which errors are retryable?" Then fix the loop bounds, the DLQ and the backoff together, and treat interruption as a separate concern.

### M5. Idempotent event consumer

#### Brief
A payments consumer receives events at least once (duplicates possible) from several consumer threads. **Rules**: each event id must be applied exactly once to the wallet balance; if applying fails (e.g. the wallet is locked), the event must be retried later and **not** treated as processed; memory for seen ids must stay bounded (keep ids for 24 hours). **Symptom**: occasional double credits, lost credits after transient failures, and the service's memory grows daily. Time box: 50 minutes.

#### Files
```java
// Event.java
public record Event(String id, String walletId, long amountPaise) {}
```
```java
// Wallets.java
public class Wallets {
    private final Map<String, Long> balances = new ConcurrentHashMap<>();
    private final Set<String> locked = ConcurrentHashMap.newKeySet();
    public void lock(String w) { locked.add(w); }
    public void unlock(String w) { locked.remove(w); }
    public void credit(String walletId, long amt) {
        if (locked.contains(walletId)) throw new IllegalStateException("wallet locked");
        balances.merge(walletId, amt, Long::sum);
    }
    public long balance(String w) { return balances.getOrDefault(w, 0L); }
}
```
```java
// DedupConsumer.java
public class DedupConsumer {
    private final Set<String> seen = new HashSet<>();
    private final Wallets wallets;
    public DedupConsumer(Wallets wallets) { this.wallets = wallets; }

    /** returns true if the event should be acked */
    public boolean handle(Event e) {
        if (seen.contains(e.id())) return true;
        seen.add(e.id());
        try {
            wallets.credit(e.walletId(), e.amountPaise());
        } catch (RuntimeException ex) {
            return true;
        }
        return true;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        Wallets w = new Wallets(); DedupConsumer c = new DedupConsumer(w);
        w.lock("w1");
        boolean ack = c.handle(new Event("e1", "w1", 500));
        w.unlock("w1");
        c.handle(new Event("e1", "w1", 500));          // redelivery after transient failure
        System.out.println("ack while locked: expected false, got " + ack);
        System.out.println("balance after redelivery: expected 500, got " + w.balance("w1"));

        Wallets w2 = new Wallets(); DedupConsumer c2 = new DedupConsumer(w2);
        ExecutorService ex = Executors.newFixedThreadPool(8);
        for (int i = 0; i < 2000; i++) { String id = "evt-" + (i % 500); ex.submit(() -> c2.handle(new Event(id, "w2", 1))); }
        ex.shutdown(); ex.awaitTermination(10, TimeUnit.SECONDS);
        System.out.println("500 unique events delivered 4x concurrently: expected 500, got " + w2.balance("w2"));
    }
}
```

#### Stage 1: find and fix the bugs
There are 4 planted bugs.

?? Show the bugs
1. **Marked as seen before processing**: if `credit` fails, the id is already in `seen`, so the redelivery is skipped: the credit is lost. Mark it seen only after success.
2. **Failures are acked**: the catch returns `true`, so the broker won't redeliver. Return `false` (nack, or let the exception propagate to the retry mechanism).
3. **Check-then-act race on a `HashSet`**: two threads can both see "not seen" and both credit (double credit), and `HashSet` isn't thread-safe at all. Use an atomic claim, `ConcurrentHashMap.newKeySet().add(id)` (returns false if present), combined with releasing the claim on failure, or better, make the dedup and the credit one atomic unit (see below).
4. **Unbounded memory**: `seen` grows forever. Keep ids with a TTL (Caffeine `expireAfterWrite(24h)`, or a time-bucketed set), sized for the redelivery window.

The real fix in production: store processed event ids **in the same database transaction** as the balance update (`INSERT INTO processed_events(id)` with a unique constraint plus `UPDATE wallets…`), so dedup and effect can't diverge, even across restarts and instances.

#### Stage 2: add a feature
**Task**: support debit events that must not take the balance below zero; a rejected debit must be dead-lettered, not retried forever.

?? Show a strong solution
Add `type` to the event. For a debit, use `balances.compute(walletId, (k, v) -> …)` to atomically check `v >= amount`, throwing a `NonRetryableException` (insufficient funds) otherwise. The consumer distinguishes retryable (wallet locked: nack) from non-retryable (insufficient funds: mark processed and dead-letter with a reason). Every outcome must be recorded for audit.

#### Stage 3: optimise
**Question**: the consumer runs on 6 instances; the in-memory `seen` set doesn't work across them. What's your design?

?? Show the points to hit
Dedup state must be shared and durable: a unique-keyed `processed_events` table written in the same DB transaction as the balance change (the strongest), or Redis `SET NX EX` as a first-line filter plus DB constraints. Partitioning by walletId in Kafka also keeps a wallet's events on one consumer (ordering, fewer races). Clean up old processed ids by partitioning the table by day and dropping old partitions.

#### Interview simulation
**Ask**: "What delivery guarantee does the broker give? Is a failed credit retryable? How long can duplicates arrive after the original?" Prove bug 3 with a concurrent test (as in the demo), then explain why in-memory dedup isn't enough across instances.

### M6. Cursor and offset pagination API

#### Brief
An orders API returns orders newest first, 20 per page. **Rules**: `page` is 1-based; `hasMore` is true only if another page exists; ordering must be deterministic even when two orders share a timestamp (tie-break by id descending); the cursor version returns orders strictly older than the cursor. **Symptom**: page 1 skips the newest orders, the last page says `hasMore=true`, and infinite scroll shows duplicates. Time box: 45 minutes.

#### Files
```java
// OrderRow.java
public record OrderRow(long id, Instant createdAt) {}
```
```java
// Page.java
public record Page(List<OrderRow> items, boolean hasMore, String nextCursor) {}
```
```java
// OrderPager.java
public class OrderPager {
    private final List<OrderRow> all;     // pretend this is the DB table
    public OrderPager(List<OrderRow> all) { this.all = all; }

    private List<OrderRow> sorted() {
        List<OrderRow> s = new ArrayList<>(all);
        s.sort(Comparator.comparing(OrderRow::createdAt).reversed());
        return s;
    }

    public Page byOffset(int page, int size) {
        List<OrderRow> s = sorted();
        int from = page * size;
        int to = Math.min(from + size, s.size());
        List<OrderRow> items = from >= s.size() ? List.of() : s.subList(from, to);
        return new Page(items, to <= s.size(), null);
    }

    public Page byCursor(String cursor, int size) {
        List<OrderRow> s = sorted();
        List<OrderRow> out = new ArrayList<>();
        Instant before = cursor == null ? Instant.MAX : Instant.parse(cursor);
        for (OrderRow r : s) {
            if (!r.createdAt().isAfter(before) && out.size() < size) out.add(r);
        }
        String next = out.isEmpty() ? null : out.get(out.size() - 1).createdAt().toString();
        return new Page(out, out.size() == size, next);
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Instant t = Instant.parse("2026-10-01T10:00:00Z");
        List<OrderRow> rows = new ArrayList<>();
        for (int i = 1; i <= 5; i++) rows.add(new OrderRow(i, t.plusSeconds(i)));
        rows.add(new OrderRow(6, t.plusSeconds(5)));                 // same timestamp as id 5
        OrderPager p = new OrderPager(rows);
        System.out.println("page 1 (size 2): expected ids [6, 5], got " + p.byOffset(1, 2).items().stream().map(OrderRow::id).toList());
        System.out.println("page 3 hasMore: expected false, got " + p.byOffset(3, 2).hasMore());
        Page c1 = p.byCursor(null, 2);
        Page c2 = p.byCursor(c1.nextCursor(), 2);
        System.out.println("cursor page 1: " + c1.items().stream().map(OrderRow::id).toList() + "  cursor page 2: " + c2.items().stream().map(OrderRow::id).toList()
            + "  (expected [6, 5] then [4, 3])");
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **1-based page treated as 0-based**: `from = page * size` skips the first page. Use `(page - 1) * size`, and validate `page >= 1`, `1 <= size <= 100`.
2. **`hasMore` is always true**: `to <= s.size()` is always true. Use `to < s.size()`.
3. **Non-deterministic ties**: sorting only by `createdAt` leaves orders with equal timestamps in arbitrary order between requests. Add `.thenComparing(OrderRow::id, Comparator.reverseOrder())`.
4. **Cursor includes the boundary row**: `!isAfter(before)` means `<=`, so the last row of page 1 reappears on page 2 (duplicates). It must be strictly older, and with ties the cursor needs both fields: `(createdAt, id) < (cursorTime, cursorId)`. Encode both in an opaque cursor (base64 of `createdAt|id`).
5. **`hasMore` for cursors guesses**: `out.size() == size` is wrong when exactly `size` rows remain. Fetch `size + 1` rows and use the extra one only to set `hasMore`.

Also: the cursor should be opaque (base64) and validated; a malformed cursor gives a 400, not a 500.

#### Stage 2: add a feature
**Task**: add a status filter (`?status=DELIVERED`) to both endpoints without breaking existing cursors.

?? Show a strong solution
Apply the filter before paging. Cursors must encode the filter (or be bound to it), otherwise a client could mix cursors across filters, giving inconsistent pages. Put a version and the filter hash in the cursor payload and reject mismatches. In SQL: `WHERE status = ? AND (created_at, id) < (?, ?) ORDER BY created_at DESC, id DESC LIMIT size+1`, with an index on `(status, created_at DESC, id DESC)`.

#### Stage 3: optimise
**Question**: the table has 200M rows; page 5,000 with offset pagination takes 8 seconds.

?? Show the points to hit
`OFFSET 99,980` makes the DB scan and discard ~100K index entries per request. Use keyset (cursor) pagination with a composite index, so every page is an index range seek (constant time at any depth). Offset pages can be capped (e.g. max 50 pages) for admin UIs. Avoid exact `COUNT(*)` on huge tables (approximate counts or none).

#### Interview simulation
**Ask**: "Is page 1-based? How must ties be ordered? Can items be inserted while users paginate?" Then show why offset paging duplicates or skips under inserts and why keyset with a tie-breaker fixes it.

### M7. Group expense splitter

#### Brief
A trip-expense app splits bills. **Rules**: amounts are in paise; EQUAL split gives any remainder paise to the first participants so the shares sum exactly to the total; PERCENT split requires percentages summing to exactly 100; the payer's own share creates no debt; `netBalances` returns, per person, what they're owed (positive) or owe (negative), and the sum over everyone must be zero. **Symptom**: totals drift by a paisa or two, invalid percentages slip through, and the payer appears to owe themselves. Time box: 45 minutes.

#### Files
```java
// Share.java
public record Share(String person, long paise) {}
```
```java
// Splitter.java
public class Splitter {
    public List<Share> equal(long total, List<String> people) {
        long each = total / people.size();
        List<Share> out = new ArrayList<>();
        for (String p : people) out.add(new Share(p, each));
        return out;
    }

    public List<Share> percent(long total, Map<String, Double> pct) {
        double sum = 0;
        for (double v : pct.values()) sum += v;
        if (sum > 100.0) throw new IllegalArgumentException("percent must sum to 100");
        List<Share> out = new ArrayList<>();
        pct.forEach((p, v) -> out.add(new Share(p, (long) (total * v / 100))));
        return out;
    }
}
```
```java
// Ledger.java
public class Ledger {
    private final Map<String, Long> net = new HashMap<>();
    public void record(String payer, List<Share> shares) {
        for (Share s : shares) {
            net.merge(s.person(), -s.paise(), Long::sum);
            net.merge(payer, s.paise(), Long::sum);
        }
    }
    public Map<String, Long> netBalances() { return net; }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Splitter sp = new Splitter();
        List<Share> eq = sp.equal(10_000, List.of("a", "b", "c"));
        System.out.println("equal shares sum: expected 10000, got " + eq.stream().mapToLong(Share::paise).sum());
        try { sp.percent(10_000, Map.of("a", 30.0, "b", 30.0)); System.out.println("60% total accepted: expected rejection"); }
        catch (IllegalArgumentException e) { System.out.println("60% rejected (good)"); }
        Map<String, Double> pct = new LinkedHashMap<>(); pct.put("a", 33.3); pct.put("b", 33.3); pct.put("c", 33.4);
        List<Share> ps = sp.percent(10_001, pct);
        System.out.println("percent shares sum: expected 10001, got " + ps.stream().mapToLong(Share::paise).sum());
        Ledger l = new Ledger();
        l.record("a", eq);
        System.out.println("net: " + l.netBalances() + "  expected a owed 6666 (b -3333, c -3333 after remainder rules)");
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **EQUAL split loses the remainder**: 10,000 / 3 = 3,333 each, which sums to 9,999. Give `total % n` extra paise to the first `rem` people.
2. **PERCENT validation only rejects > 100**: less than 100 slips through. Require exactly 100, but not with `double` equality (33.3 + 33.3 + 33.4 isn't exactly 100.0 in binary). Use integer basis points (3330 + 3330 + 3340 = 10000) or BigDecimal.
3. **PERCENT shares are truncated**: `(long)(total * v / 100)` drops fractions, so the shares don't sum to the total. Compute all but the last with floor and give the last person `total − allocated` (or distribute the remainder by largest fractional part).
4. **The payer owes themselves**: recording the payer's own share adds −x and +x for the same person (net zero, but it creates a phantom self-entry, and with non-equal shares the pairwise view breaks). Skip `s.person().equals(payer)`.
5. **`netBalances` exposes the internal map**: callers can mutate the ledger. Return `Map.copyOf(net)`.

Also: validate `people` is non-empty (division by zero) and there are no duplicates in the participants list.

#### Stage 2: add a feature
**Task**: "settle up": compute a minimal-ish list of payments that clears all balances.

?? Show a strong solution
Split the net balances into creditors (positive) and debtors (negative), put them in max-heaps by absolute value, and repeatedly match the largest debtor with the largest creditor for `min(owed, owes)`, pushing back the remainders. That's at most n−1 payments. State that the true minimum is NP-hard (subset-sum style) and greedy is what real apps use. Verify that the sum of net balances is zero before settling (an invariant check).

#### Stage 3: optimise
**Question**: users want to edit or delete old expenses, and the group has 2,000 expenses.

?? Show the points to hit
Don't mutate running balances in place. Store expenses as an immutable ledger (append-only entries); edits are a reversal entry plus a new entry; balances are derived (cached and recomputed incrementally on change). That gives an audit trail and correctness under edits. Recomputing 2,000 expenses is trivial; scale isn't the issue, correctness is.

#### Interview simulation
**Ask**: "Who gets the leftover paise? Must percentages be exact, and in what precision? Can the payer be excluded from the split?" Fix the money arithmetic first (invariant: shares sum to the total), then the ledger.

### M8. In-memory text search index

#### Brief
A help-centre search indexes articles with an inverted index. **Rules**: search is case-insensitive and ignores punctuation; stopwords (`the, a, an, of, to, is`) are ignored at both index and query time; a multi-word query returns articles containing **all** non-stopword terms (AND); removing an article removes it from the results; searches must not change the index. **Symptom**: "Refund" finds nothing while "refund" works; after a few searches, unrelated queries return fewer results; deleted articles still appear. Time box: 50 minutes.

#### Files
```java
// Tokenizer.java
public class Tokenizer {
    static final Set<String> STOP = Set.of("the", "a", "an", "of", "to", "is");
    public List<String> tokens(String text) {
        List<String> out = new ArrayList<>();
        for (String w : text.split(" ")) if (!STOP.contains(w)) out.add(w);
        return out;
    }
}
```
```java
// SearchIndex.java
public class SearchIndex {
    private final Map<String, Set<Integer>> postings = new HashMap<>();
    private final Map<Integer, String> docs = new HashMap<>();
    private final Tokenizer tok = new Tokenizer();

    public void add(int id, String text) {
        docs.put(id, text);
        for (String t : tok.tokens(text)) postings.computeIfAbsent(t, k -> new HashSet<>()).add(id);
    }

    public void remove(int id) { docs.remove(id); }

    public Set<Integer> search(String query) {
        Set<Integer> result = null;
        for (String t : query.toLowerCase().split(" ")) {
            Set<Integer> ids = postings.getOrDefault(t, Set.of());
            if (result == null) result = ids; else result.retainAll(ids);
        }
        return result == null ? Set.of() : result;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        SearchIndex idx = new SearchIndex();
        idx.add(1, "How to request a Refund.");
        idx.add(2, "Refund policy for cancelled orders");
        idx.add(3, "Track your orders");
        System.out.println("'refund': expected [1, 2], got " + idx.search("refund"));
        System.out.println("'refund orders': expected [2], got " + idx.search("refund orders"));
        System.out.println("'orders' after previous query: expected [2, 3], got " + idx.search("orders"));
        System.out.println("'the refund': expected [1, 2], got " + idx.search("the refund"));
        idx.remove(2);
        System.out.println("'policy' after removing 2: expected [], got " + idx.search("policy"));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Indexing is case-sensitive**: the query is lowercased, but the documents aren't, so "Refund" is indexed as `Refund`. Normalise both through the same tokenizer (lowercase with `Locale.ROOT`).
2. **Punctuation stays attached**: "Refund." isn't "refund". Split on non-alphanumerics: `text.toLowerCase(Locale.ROOT).split("[^\\p{L}\\p{N}]+")` and skip empty tokens.
3. **The query doesn't use the tokenizer**: stopwords in the query ("the") have no postings, so the AND result is empty. Run the query through `tok.tokens()` too.
4. **`retainAll` mutates the index**: `result = ids` aliases the posting set, and `retainAll` then deletes ids from the index itself. Copy: `result = new HashSet<>(ids)`. (With `Set.of()` it would throw `UnsupportedOperationException` instead.)
5. **`remove` leaves postings behind**: re-tokenize the stored text and remove the id from each posting set (dropping empty sets), or filter results against `docs`.

#### Stage 2: add a feature
**Task**: rank results by relevance (term frequency) instead of returning an unordered set.

?? Show a strong solution
Change postings to `Map<String, Map<Integer, Integer>>` (term → doc → count). The score per doc = Σ over query terms of tf × idf, where idf = log(N / df) (rare terms weigh more); length normalisation is a bonus (BM25). Return a `List<Hit(id, score)>` sorted by score desc, then by id. Keep `search()` returning a set for the existing callers, or deprecate it.

#### Stage 3: optimise
**Question**: the help centre grows to 2 million articles in 12 languages, with typo tolerance required.

?? Show the points to hit
Move to Elasticsearch/OpenSearch: per-language analysers (stemming, stopwords), fuzzy matching, BM25 scoring, sharding and replicas. Feed it from the article DB via CDC/Kafka. Keep the in-house index only if requirements are tiny. Intersect posting lists smallest-first to speed up AND queries if you keep your own.

#### Interview simulation
**Ask**: "Are search and indexing supposed to share normalisation? Should stopwords be ignored in queries? Should search be read-only?" Bug 4 (aliasing) is the one interviewers love: prove it by running two searches in sequence, as the demo does.

### M9. Concurrent parking garage

#### Brief
A multi-gate garage allocates the lowest-numbered free spot that fits the vehicle (CAR fits CAR or LARGE spots, TRUCK fits only LARGE). Gates run on separate threads. **Rules**: no two vehicles get the same spot; leaving frees exactly the vehicle's spot; the fee is ₹20 per started hour, minimum 1 hour. **Symptom**: occasional double allocation, the wrong spot freed on exit, and some fees are short. Time box: 50 minutes.

#### Files
```java
// Spot.java
public class Spot {
    final int number; final String size;   // "CAR" or "LARGE"
    String occupiedBy;                      // plate or null
    Spot(int number, String size) { this.number = number; this.size = size; }
}
```
```java
// Garage.java
public class Garage {
    private final List<Spot> spots;
    private final Map<String, Integer> spotOfPlate = new ConcurrentHashMap<>();

    public Garage(List<Spot> spots) { this.spots = spots; }

    private boolean fits(String vehicle, Spot s) {
        return vehicle.equals(s.size) || vehicle.equals("CAR");
    }

    public Integer park(String plate, String vehicle) {
        for (Spot s : spots) {
            if (s.occupiedBy == null && fits(vehicle, s)) {
                s.occupiedBy = plate;
                spotOfPlate.put(plate, spots.indexOf(s));
                return s.number;
            }
        }
        return null;
    }

    public void leave(String plate) {
        Integer n = spotOfPlate.remove(plate);
        if (n != null) spots.get(n - 1).occupiedBy = null;
    }

    public static long feePaise(Duration parked) {
        long hours = parked.toHours();
        return Math.max(1, hours) * 2_000;
    }
    public List<String> plates() { return spots.stream().map(s -> s.occupiedBy).filter(Objects::nonNull).toList(); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        System.out.println("fee 61 min: expected 4000, got " + Garage.feePaise(Duration.ofMinutes(61)));
        Garage g = new Garage(new ArrayList<>(List.of(new Spot(1, "CAR"), new Spot(2, "LARGE"), new Spot(3, "CAR"))));
        g.park("KA01", "CAR"); g.park("KA02", "CAR");
        g.leave("KA02");
        System.out.println("after KA02 leaves, KA01 should still be parked: occupied plates = " + g.plates() + " (expected [KA01])");
        System.out.println("truck gets the free LARGE spot: expected 2, got " + g.park("KA03", "TRUCK"));
        // concurrency: 1000 spots, 2000 cars from 16 threads -> exactly 1000 parked, no spot shared
        List<Spot> many = new ArrayList<>(); for (int i = 1; i <= 1000; i++) many.add(new Spot(i, "CAR"));
        Garage big = new Garage(many); Set<Integer> given = ConcurrentHashMap.newKeySet(); AtomicInteger dup = new AtomicInteger();
        ExecutorService ex = Executors.newFixedThreadPool(16);
        for (int i = 0; i < 2000; i++) { String plate = "P" + i; ex.submit(() -> { Integer n = big.park(plate, "CAR"); if (n != null && !given.add(n)) dup.incrementAndGet(); }); }
        ex.shutdown(); ex.awaitTermination(20, TimeUnit.SECONDS);
        System.out.println("duplicate spot assignments: expected 0, got " + dup.get());
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Trucks can never park**: `fits` returns true when the vehicle name equals the spot size (`"TRUCK".equals("LARGE")` is false) or when the vehicle is a car, so a truck never fits anywhere. Encode the rule explicitly as data: `CAR → {CAR, LARGE}`, `TRUCK → {LARGE}`.
2. **Index vs number confusion**: `park` stores the list *index* (0-based), and `leave` does `get(n - 1)`, freeing the wrong spot (or index −1). Store the `Spot` reference (or its number) and free that exact object.
3. **Race in `park`**: check `occupiedBy == null` then set it is check-then-act. Two gates can claim the same spot (the demo shows duplicates). Use `AtomicReference<String> occupiedBy` with `compareAndSet(null, plate)`, or synchronise allocation.
4. **Fee rounding**: `toHours()` truncates, so 61 minutes is charged as 1 hour. Started hours: `(minutes + 59) / 60`, minimum 1.
5. **`occupiedBy` visibility**: plain fields written by one thread and read by others without synchronisation may not be visible. The CAS fix (atomics) also fixes visibility.

Also: the same plate parking twice isn't prevented (check `spotOfPlate.putIfAbsent`).

#### Stage 2: add a feature
**Task**: EV spots with chargers: EVs prefer EV spots but can use CAR spots; non-EVs may only use EV spots when nothing else is free.

?? Show a strong solution
Make the fit rules an ordered preference list per vehicle type: `EV → [EV, CAR, LARGE]`, `CAR → [CAR, LARGE, EV]`, `TRUCK → [LARGE]`. Allocation iterates the preference order, and within each size picks the lowest free spot (keep a per-size `ConcurrentSkipListSet` of free spot numbers: `pollFirst()` is atomic and O(log n)). That replaces the linear scan too.

#### Stage 3: optimise
**Question**: 20 garages, 5,000 spots each, with a central backend and display boards showing live free counts.

?? Show the points to hit
A per-garage free-spot structure (per size, sorted) in memory or Redis (`ZPOPMIN` on a sorted set of free spot numbers gives an atomic claim); a DB as the source of truth with `UPDATE spots SET plate=? WHERE id=? AND plate IS NULL`; counters per size updated on claim and release; boards subscribe to change events (WebSocket/MQTT). Partition by garage, since garages are independent.

#### Interview simulation
**Ask**: "Is spot number the same as list position? Can a truck use multiple car spots? What does 'started hour' mean at exactly 60 minutes?" Then write a concurrent test like the demo to prove the race before fixing it.

### M10. Layered configuration loader

#### Brief
A service loads configuration from three layers: built-in defaults < config file < environment variables (env wins). Env names map from keys by uppercasing and replacing `.` with `_` (`db.pool.size` ↔ `DB_POOL_SIZE`). `getInt` returns the default when a key is missing and throws a clear error when the value isn't a number. The loaded config is cached; `reload()` re-reads it. **Symptom**: env overrides are ignored, callers accidentally change config for everyone, and a missing key crashes with an NPE. Time box: 45 minutes.

#### Files
```java
// ConfigSource.java
public interface ConfigSource { Map<String, String> load(); }
```
```java
// ConfigLoader.java
public class ConfigLoader {
    private final Map<String, String> defaults;
    private final ConfigSource file;
    private final Map<String, String> env;
    private Map<String, String> cache;

    public ConfigLoader(Map<String, String> defaults, ConfigSource file, Map<String, String> env) {
        this.defaults = defaults; this.file = file; this.env = env;
    }

    public Map<String, String> all() {
        if (cache == null) {
            Map<String, String> merged = new HashMap<>();
            for (String key : defaults.keySet()) {
                String envName = key.toUpperCase().replace("-", "_");
                if (env.containsKey(envName)) merged.put(key, env.get(envName));
            }
            merged.putAll(file.load());
            merged.putAll(defaults);
            cache = merged;
        }
        return cache;
    }

    public int getInt(String key, int defaultValue) {
        return Integer.parseInt(all().get(key));
    }

    public void reload() { /* re-read on next access */ }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Map<String, String> defaults = Map.of("db.pool.size", "10", "http.port", "8080");
        Map<String, String> fileValues = new HashMap<>(Map.of("db.pool.size", "20"));
        ConfigLoader c = new ConfigLoader(defaults, () -> new HashMap<>(fileValues), Map.of("DB_POOL_SIZE", "50"));
        System.out.println("db.pool.size: expected 50 (env wins), got " + c.all().get("db.pool.size"));
        c.all().put("http.port", "1");
        System.out.println("http.port after a caller mutated the map: expected 8080, got " + c.all().get("http.port"));
        try { System.out.println("missing key: expected 30, got " + c.getInt("timeout.seconds", 30)); }
        catch (Exception e) { System.out.println("missing key crashed: " + e); }
        fileValues.put("http.port", "9090"); c.reload();
        System.out.println("after reload: expected 9090, got " + c.all().get("http.port"));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Precedence reversed**: `putAll(file)` then `putAll(defaults)` means the defaults overwrite everything. Order: defaults, then file, then env.
2. **Env name mapping is wrong**: it replaces `-` instead of `.`, so `DB_POOL_SIZE` is never found. Use `key.toUpperCase(Locale.ROOT).replace('.', '_').replace('-', '_')`. And env is only checked for keys in `defaults`: keys only present in the file can't be overridden (iterate the union of keys).
3. **Mutable shared cache**: `all()` returns the internal map, so any caller can change config for everyone. Return `Map.copyOf(merged)` (and build the cache as an immutable map).
4. **`getInt` ignores the default and NPEs on missing keys**: `parseInt(null)` throws `NumberFormatException` ("Cannot parse null string"). Return the default if missing; on a bad value throw `IllegalStateException("Config 'x' must be an integer, was 'abc'")`.
5. **`reload()` does nothing**: set `cache = null` (and with concurrent readers, make `cache` volatile, or swap in an immutable map atomically).

#### Stage 2: add a feature
**Task**: support typed, validated config objects, e.g. `DbConfig(int poolSize, Duration timeout)` with validation at startup (fail fast).

?? Show a strong solution
A binder method `<T> T bind(String prefix, Function<Map<String,String>, T> factory)`, or reflection over a record's components: read `prefix + "." + component`, convert types (int, Duration via `Duration.parse` or "30s" style), validate ranges, and collect all errors before failing with one clear message. Point out that this is exactly what Spring's `@ConfigurationProperties` + `@Validated` does, so in a Spring app you'd use that.

#### Stage 3: optimise
**Question**: 200 services need runtime config changes (feature flags) without restarts.

?? Show the points to hit
A config service (Spring Cloud Config, Consul, AWS AppConfig, or a feature-flag service) with clients polling (with ETags) or receiving pushes; the config is swapped atomically as an immutable snapshot; changes are versioned and audited, with gradual rollout and quick rollback. Secrets don't belong in this channel (use a secret manager).

#### Interview simulation
**Ask**: "What's the exact precedence? How are env names derived? Is reload expected to be thread-safe?" Write the precedence as a one-line test before touching the code.

### M11. Warehouse robot path finder

#### Brief
A warehouse robot moves on a grid (`.` free, `#` shelf) one cell at a time in 4 directions. `shortestPath` returns the minimum number of moves from start to target, 0 if they're the same cell, or −1 if unreachable. The grid can be 2,000 × 2,000. **Symptom**: wrong distances (off by one), an `ArrayIndexOutOfBoundsException` near the edges, and it's extremely slow on large open floors. Time box: 45 minutes.

#### Files
```java
// Cell.java
public record Cell(int r, int c) {}
```
```java
// PathFinder.java
public class PathFinder {
    private static final int[][] DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};

    public int shortestPath(char[][] grid, Cell start, Cell target) {
        int rows = grid.length, cols = grid[0].length;
        boolean[][] visited = new boolean[rows][cols];
        Deque<int[]> queue = new ArrayDeque<>();
        queue.add(new int[]{start.r(), start.c(), 0});
        while (!queue.isEmpty()) {
            int[] cur = queue.poll();
            int r = cur[0], c = cur[1], d = cur[2];
            if (visited[r][c]) continue;
            visited[r][c] = true;
            if (r == target.r() && c == target.c()) return d + 1;
            for (int[] dir : DIRS) {
                int nr = r + dir[0], nc = c + dir[1];
                if (grid[nr][nc] != '#' && nr >= 0 && nc >= 0 && nr < rows && nc < cols) {
                    queue.add(new int[]{nr, nc, d + 1});
                }
            }
        }
        return 0;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        char[][] g = { "..#".toCharArray(), "...".toCharArray(), "#..".toCharArray() };
        PathFinder pf = new PathFinder();
        System.out.println("same cell: expected 0, got " + safe(() -> pf.shortestPath(g, new Cell(1, 1), new Cell(1, 1))));
        System.out.println("(1,1)->(1,2): expected 1, got " + safe(() -> pf.shortestPath(g, new Cell(1, 1), new Cell(1, 2))));
        System.out.println("(0,0)->(2,2): expected 4, got " + safe(() -> pf.shortestPath(g, new Cell(0, 0), new Cell(2, 2))));
        char[][] blocked = { ".#".toCharArray(), "#.".toCharArray() };
        System.out.println("unreachable: expected -1, got " + safe(() -> pf.shortestPath(blocked, new Cell(0, 0), new Cell(1, 1))));
    }
    static String safe(java.util.concurrent.Callable<Integer> c) { try { return String.valueOf(c.call()); } catch (Exception e) { return "CRASH " + e.getClass().getSimpleName(); } }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Off by one**: returning `d + 1` when the target is dequeued. The distance carried with the cell is already the number of moves: return `d` (so the same cell is 0).
2. **Bounds checked after indexing**: `grid[nr][nc]` is evaluated before the bounds checks, so edges crash. Check bounds first: `nr >= 0 && nr < rows && nc >= 0 && nc < cols && grid[nr][nc] != '#'`.
3. **Unreachable returns 0**: it should return −1.
4. **Visited marked on dequeue instead of enqueue**: the same cell is enqueued many times (up to 4× per cell, and much worse on open floors): huge queues, slow and memory-hungry. Mark visited when enqueuing.
5. **Start or target on a shelf or out of range isn't validated**: decide the behaviour (−1, or an exception) and check upfront.

Performance note: `int[]` allocations per cell are fine; for 4M cells, a flat `int[]` queue and a `byte[]` visited array cut GC pressure.

#### Stage 2: add a feature
**Task**: some cells are slow zones (`~`) costing 3 moves to enter. Return the minimum cost.

?? Show a strong solution
With weights, BFS no longer gives the shortest path. Use Dijkstra (a priority queue by cost) or **0-1/BFS-with-buckets**: since weights are 1 or 3, a small bucket queue (Dial's algorithm) is linear time. Track `dist[r][c]` and relax neighbours when a cheaper cost is found. Keep the BFS for the all-weights-equal case if it's measurably faster.

#### Stage 3: optimise
**Question**: 300 robots plan paths every second on the same 2,000 × 2,000 grid, and they must avoid each other.

?? Show the points to hit
Precomputation (distance fields to popular targets like packing stations, computed by BFS from the target once and reused), A* with a Manhattan heuristic for point-to-point queries, hierarchical path finding (divide the grid into regions). For collisions: time-expanded planning or reservation tables (cooperative A*), which is real multi-agent path finding territory (Amazon Robotics-style).

#### Interview simulation
**Ask**: "Is the distance the number of moves or cells visited? What if the target is a shelf? Diagonals allowed?" Walk through the 3×3 demo grid by hand to pin down the off-by-one before touching code.

### M12. Notification batcher

#### Brief
To reduce costs, push notifications are batched: `add` buffers messages, and a batch is sent when the buffer reaches `batchSize` or every `flushInterval` by a scheduler thread, whichever comes first. `close()` must send everything remaining. If sending fails, the messages must not be lost (they go back to the buffer for the next attempt). **Symptom**: occasional lost messages, batches larger than configured, and missing messages at shutdown. Time box: 50 minutes.

#### Files
```java
// Sender.java
public interface Sender { void send(List<String> batch) throws IOException; }
```
```java
// Batcher.java
public class Batcher implements AutoCloseable {
    private final int batchSize;
    private final Sender sender;
    private List<String> buffer = new ArrayList<>();
    private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();

    public Batcher(int batchSize, Duration flushInterval, Sender sender) {
        this.batchSize = batchSize; this.sender = sender;
        scheduler.scheduleAtFixedRate(this::flush, flushInterval.toMillis(), flushInterval.toMillis(), TimeUnit.MILLISECONDS);
    }

    public void add(String msg) {
        buffer.add(msg);
        if (buffer.size() > batchSize) flush();
    }

    public void flush() {
        if (buffer.isEmpty()) return;
        List<String> toSend = buffer;
        buffer = new ArrayList<>();
        try {
            sender.send(toSend);
        } catch (IOException e) {
            System.err.println("send failed: " + e.getMessage());
        }
    }

    @Override public void close() { scheduler.shutdown(); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        List<List<String>> sent = Collections.synchronizedList(new ArrayList<>());
        AtomicBoolean failNext = new AtomicBoolean(true);
        Sender s = batch -> { if (failNext.getAndSet(false)) throw new IOException("provider 503"); sent.add(new ArrayList<>(batch)); };
        Batcher b = new Batcher(3, Duration.ofHours(1), s);
        for (int i = 1; i <= 4; i++) b.add("m" + i);      // first flush fails
        b.add("m5");
        b.close();
        int total = sent.stream().mapToInt(List::size).sum();
        System.out.println("batches: " + sent + "  (expected every message m1..m5 delivered, batches of at most 3)");
        System.out.println("delivered: expected 5, got " + total);
        System.out.println("max batch size: expected <= 3, got " + sent.stream().mapToInt(List::size).max().orElse(0));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Batch size off by one**: `buffer.size() > batchSize` flushes at 4 for a size of 3. Use `>=`.
2. **Failed sends lose messages**: the buffer is swapped out before sending, and on `IOException` the batch is just logged. Put the failed batch back at the front of the buffer (respecting the order and the size limit), and retry later with backoff (or send to a dead-letter store after N attempts).
3. **Not thread-safe**: `add` (caller threads) and `flush` (scheduler thread) both touch `buffer` without synchronisation: lost messages, `ConcurrentModificationException`, or a corrupted list. Guard both with a lock, but don't hold it during the network call: swap the buffer under the lock, send outside it.
4. **`close()` doesn't flush**: remaining messages are dropped at shutdown. Stop the scheduler, await termination, then do a final flush (with retries).
5. **Batches can exceed the size**: re-queued messages plus new ones can produce a batch larger than `batchSize`. Send in chunks of at most `batchSize`.

#### Stage 2: add a feature
**Task**: messages for the same user within the batch window should be merged into one ("You have 3 new messages").

?? Show a strong solution
Buffer by user: `LinkedHashMap<String, List<String>>`. At flush, produce one combined notification per user (the template is decided by count). `batchSize` now applies to users per send. Preserve the arrival order of users. Tests: 3 messages for one user give one notification; mixed users stay in order.

#### Stage 3: optimise
**Question**: the batcher runs on 20 instances, and messages must survive an instance crash.

?? Show the points to hit
An in-memory buffer is lost on a crash. Put messages on a durable queue first (Kafka/SQS), and batch in the consumer: poll up to N messages or wait T, send, then commit offsets or delete messages only after success (at-least-once, so the provider call should carry an idempotency key, or duplicates must be acceptable). Provider rate limits apply per instance and globally.

#### Interview simulation
**Ask**: "What's the guarantee: at-most-once or at-least-once? Can a batch exceed the size after a retry? What happens on shutdown?" Then draw the two threads (callers and scheduler) touching the buffer, which makes bug 3 obvious.
