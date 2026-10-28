## Mock interviews: Hard | P3 | must

### H1. Concurrent money transfers

#### Brief
A wallet service moves money between accounts on many threads. **Rules**: a transfer debits the source and credits the destination atomically; it fails if the source would go negative; transfers to the same account are rejected; the total money in the system is constant; every successful transfer is appended to an audit log. **Symptom**: under load the service occasionally hangs forever, totals drift, and the audit log has fewer entries than successful transfers. Time box: 60 minutes.

#### Files
```java
// Account.java
public class Account {
    final String id; long balancePaise;
    Account(String id, long balancePaise) { this.id = id; this.balancePaise = balancePaise; }
}
```
```java
// TransferService.java
public class TransferService {
    private final Map<String, Account> accounts;
    private final List<String> audit = new ArrayList<>();

    public TransferService(Map<String, Account> accounts) { this.accounts = accounts; }

    public boolean transfer(String fromId, String toId, long amount) {
        Account from = accounts.get(fromId), to = accounts.get(toId);
        if (from.balancePaise < amount) return false;
        synchronized (from) {
            synchronized (to) {
                from.balancePaise -= amount;
                to.balancePaise += amount;
            }
        }
        audit.add(fromId + "->" + toId + ":" + amount);
        return true;
    }

    public long total() { return accounts.values().stream().mapToLong(a -> a.balancePaise).sum(); }
    public int auditSize() { return audit.size(); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        Map<String, Account> accts = new HashMap<>();
        for (int i = 0; i < 4; i++) accts.put("a" + i, new Account("a" + i, 1_000));
        TransferService svc = new TransferService(accts);
        AtomicInteger ok = new AtomicInteger();
        ExecutorService ex = Executors.newFixedThreadPool(8);
        for (int i = 0; i < 20_000; i++) {
            String f = "a" + (i % 4), t = "a" + ((i * 7 + 1) % 4);
            ex.submit(() -> { if (svc.transfer(f, t, 50)) ok.incrementAndGet(); });
        }
        ex.shutdown();
        boolean finished = ex.awaitTermination(5, TimeUnit.SECONDS);
        System.out.println("finished without deadlock: " + finished);
        System.out.println("total: expected 4000, got " + svc.total());
        System.out.println("audit entries: expected " + ok.get() + ", got " + svc.auditSize());
        System.out.println("negative balances: " + accts.values().stream().filter(a -> a.balancePaise < 0).count() + " (expected 0)");
        System.exit(0);
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Deadlock**: thread 1 locks A then B, thread 2 locks B then A. Acquire locks in a global order (e.g. by account id): `Account first = from.id.compareTo(to.id) < 0 ? from : to;`.
2. **Balance check outside the lock**: check-then-act. Two transfers both see enough money, then both debit, so balances go negative. Move the check inside the locks.
3. **Same-account transfer**: `transfer("a1", "a1", x)` should be rejected explicitly (with ordered locking it would work by reentrancy, but it's a business error and wastes an audit entry).
4. **Audit list isn't thread-safe**: concurrent `ArrayList.add` loses entries or throws. Use a concurrent queue or add inside a lock. Also it's appended outside the critical section, so the audit order can differ from the transfer order.
5. **`total()` reads balances without locks**: a concurrent reader can see a debit without the matching credit (and reads of plain `long` fields without synchronisation have no visibility guarantees). Either accept a fuzzy total for monitoring or take a consistent snapshot (lock all accounts in order, or use a DB transaction).

Also: unknown account ids give an NPE (validate), and amounts must be positive.

#### Stage 2: add a feature
**Task**: support a daily debit limit per account (₹50,000), enforced atomically with the transfer.

?? Show a strong solution
Track `debitedToday` and the date it applies to inside `Account`. Inside the ordered locks: reset the counter if the date changed (`LocalDate.now(clock)` in the account's zone), check `debitedToday + amount <= limit` and the balance, then apply both. Everything that's part of the decision must be read and written under the same lock(s). Test with concurrent transfers just under the limit.

#### Stage 3: optimise
**Question**: this becomes a real service on Postgres with 5 instances. How do you keep transfers correct?

?? Show the points to hit
One DB transaction per transfer: `SELECT … FOR UPDATE` on both rows **in id order** (deadlock avoidance), check the balance, update both, insert a ledger entry (double entry), commit; retry on serialization or deadlock errors (40001/40P01). Or conditional updates (`UPDATE … SET balance = balance - :amt WHERE id = :from AND balance >= :amt`, checking the affected row count). An idempotency key per transfer request prevents duplicates on client retries.

#### Interview simulation
**Ask**: "Is a transfer to the same account allowed? Must `total()` be exact while transfers run? Is the audit order important?" Prove the deadlock with a thread dump (`jstack` shows "Found one Java-level deadlock") or the demo's timeout, then fix lock ordering first, since other fixes don't matter while it hangs.

### H2. Async price aggregator

#### Brief
A product page calls three pricing providers in parallel (each a blocking HTTP call of ~100–300ms) and shows the lowest price. **Rules**: the total latency budget is 400ms; a provider that fails or times out is skipped; if all fail, return an "unavailable" result; blocking calls must not run on the common ForkJoinPool. **Symptom**: one slow provider makes the page take 10 seconds; one failing provider makes the whole page fail; under load, unrelated parallel streams slow down. Time box: 60 minutes.

#### Files
```java
// PriceProvider.java
public interface PriceProvider { String name(); long quotePaise(String sku) throws Exception; }   // blocking network call
```
```java
// PriceAggregator.java
public class PriceAggregator {
    private final List<PriceProvider> providers;
    public PriceAggregator(List<PriceProvider> providers) { this.providers = providers; }

    public OptionalLong bestPrice(String sku) {
        List<Long> quotes = new ArrayList<>();
        List<CompletableFuture<Void>> futures = new ArrayList<>();
        for (PriceProvider p : providers) {
            futures.add(CompletableFuture.supplyAsync(() -> {
                try { return p.quotePaise(sku); }
                catch (Exception e) { throw new RuntimeException(e); }
            }).thenAccept(quotes::add));
        }
        CompletableFuture.allOf(futures.toArray(new CompletableFuture[0])).join();
        return quotes.stream().mapToLong(Long::longValue).min();
    }
}
```
```java
// Demo.java
public class Demo {
    static PriceProvider p(String name, long price, long delayMs, boolean fail) {
        return new PriceProvider() {
            public String name() { return name; }
            public long quotePaise(String sku) throws Exception { Thread.sleep(delayMs); if (fail) throw new IOException(name + " 503"); return price; }
        };
    }
    public static void main(String[] args) {
        PriceAggregator agg = new PriceAggregator(List.of(p("fast", 9_900, 100, false), p("broken", 9_000, 50, true), p("slow", 9_500, 3_000, false)));
        long t0 = System.currentTimeMillis();
        try { System.out.println("best: expected 9900 within ~400ms, got " + agg.bestPrice("SKU1")); }
        catch (Exception e) { System.out.println("failed: " + e.getClass().getSimpleName() + " " + e.getMessage()); }
        System.out.println("elapsed ms: " + (System.currentTimeMillis() - t0));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **No timeout**: `allOf(...).join()` waits for the slowest provider. Use `completeOnTimeout`/`orTimeout` per provider (or a deadline for the whole operation) so slow providers are skipped after the budget.
2. **One failure fails everything**: an exceptional future makes `allOf().join()` throw `CompletionException`. Handle per provider: `.handle((v, ex) -> ex == null ? OptionalLong.of(v) : OptionalLong.empty())` and log the failure with the provider name.
3. **Blocking work on the common pool**: `supplyAsync` without an executor runs blocking HTTP on `ForkJoinPool.commonPool()` (cores − 1 threads), starving parallel streams and other async code app-wide. Pass a dedicated bounded executor sized for I/O.
4. **Non-thread-safe result list**: `quotes::add` runs on several pool threads concurrently on an `ArrayList`, which can lose or corrupt entries. Don't share mutable state: have each future return its value and collect after completion (`futures.stream().map(CompletableFuture::join)`).
5. **No "all failed" result**: the spec wants an explicit unavailable result. `OptionalLong.empty()` is fine, but callers must render it (document it), and you should distinguish "all failed" from "no quotes" for monitoring.

Also: timeouts in `CompletableFuture` don't cancel the underlying HTTP call. Set HTTP client timeouts too, or the threads stay busy.

#### Stage 2: add a feature
**Task**: cache each provider's quote for 30 seconds per SKU, and serve the stale quote if the provider fails (stale-if-error, up to 10 minutes old).

?? Show a strong solution
A per-provider cache `Map<String sku, Quote(price, fetchedAt)>` (Caffeine with `expireAfterWrite(10m)`): if the quote is fresher than 30s, use it without calling; otherwise call; on success update it; on failure or timeout, use the cached quote if it's younger than 10 minutes, flagged as stale. Add single-flight per (provider, sku) to avoid stampedes. Tests use an injectable clock.

#### Stage 3: optimise
**Question**: 3,000 product page views per second, each fanning out to 3 providers. How do you size and protect this?

?? Show the points to hit
Concurrency ≈ 3,000 × 3 × 0.2s = 1,800 in-flight calls, so a thread pool of that size is heavy. Options: virtual threads (Java 21) with a semaphore per provider (bulkhead), or a non-blocking HTTP client. Add circuit breakers per provider (Resilience4j), the caches from Stage 2 (most traffic served without calls), and request coalescing. Monitor per-provider latency, error rate and breaker state.

#### Interview simulation
**Ask**: "What's the latency budget? Is a partial answer acceptable? Should we cancel slow calls or let them finish and cache?" Show the 3-second elapsed time from the demo as evidence first, then fix the timeout and per-provider error handling together.

### H3. TTL key-value cache with background expiry

#### Brief
A cache stores entries with a time-to-live. A background thread removes expired entries every 100ms. **Rules**: `get` never returns an expired value; overwriting a key with a new TTL must keep the new value even if the old entry's expiry passes; the cleaner must not crash or block readers; the cache is used by many threads. **Symptom**: freshly written values sometimes disappear, the cleaner thread occasionally dies with an exception, and expired values are sometimes returned. Time box: 60 minutes.

#### Files
```java
// Entry.java
public class Entry { final String value; final long expiresAtMillis; Entry(String v, long e) { value = v; expiresAtMillis = e; } }
```
```java
// TtlCache.java
public class TtlCache implements AutoCloseable {
    private final Map<String, Entry> map = new HashMap<>();
    private final Map<String, Long> expiryIndex = new HashMap<>();
    private final ScheduledExecutorService cleaner = Executors.newSingleThreadScheduledExecutor();
    private final LongSupplier clock;

    public TtlCache(LongSupplier clockMillis) {
        this.clock = clockMillis;
        cleaner.scheduleAtFixedRate(this::evictExpired, 100, 100, TimeUnit.MILLISECONDS);
    }

    public void put(String key, String value, long ttlMillis) {
        long exp = clock.getAsLong() + ttlMillis;
        map.put(key, new Entry(value, exp));
        expiryIndex.putIfAbsent(key, exp);
    }

    public String get(String key) {
        Entry e = map.get(key);
        return e == null ? null : e.value;
    }

    void evictExpired() {
        long now = clock.getAsLong();
        for (Map.Entry<String, Long> en : expiryIndex.entrySet()) {
            if (en.getValue() <= now) { map.remove(en.getKey()); expiryIndex.remove(en.getKey()); }
        }
    }

    @Override public void close() { cleaner.shutdownNow(); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        long[] now = {1_000};
        TtlCache c = new TtlCache(() -> now[0]);
        c.put("k", "v1", 100);
        now[0] = 1_150;
        System.out.println("expired read before cleaner runs: expected null, got " + c.get("k"));
        c.put("k", "v2", 10_000);                 // overwrite with a long TTL
        c.evictExpired();
        System.out.println("after overwrite + cleanup: expected v2, got " + c.get("k"));
        c.put("a", "1", 1); c.put("b", "2", 1); c.put("c", "3", 1);
        now[0] = 50_000;
        try { c.evictExpired(); System.out.println("cleanup of several keys ok"); }
        catch (Exception e) { System.out.println("cleaner crashed: " + e); }
        c.close();
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **`get` ignores expiry**: between cleaner runs, expired values are returned. Check `e.expiresAtMillis <= now`, and return null (removing it with `map.remove(key, e)` so you don't delete a newer value).
2. **The expiry index keeps the old expiry on overwrite**: `putIfAbsent` leaves the first TTL in place, so the cleaner deletes the freshly written value. Store the expiry inside the entry and have the cleaner compare against the *current* entry (`map.computeIfPresent(k, (key, cur) -> cur.expiresAtMillis <= now ? null : cur)`), or just drop the separate index.
3. **Removing during iteration**: `expiryIndex.remove` inside a for-each over its entry set throws `ConcurrentModificationException`, and an uncaught exception in `scheduleAtFixedRate` **silently cancels all future runs**, so the cleaner dies forever. Use `entrySet().removeIf(...)` (or an iterator's remove) and catch everything inside the scheduled task.
4. **Not thread-safe**: two `HashMap`s mutated by request threads and the cleaner concurrently (corruption, lost updates, infinite loops under resize). Use `ConcurrentHashMap` and do the per-key decision atomically (`computeIfPresent`).
5. **Full scan every 100ms**: O(n) per run is expensive with millions of keys. Use a `DelayQueue`/priority queue of (expiry, key) and remove only due items (verifying the current entry's expiry), or Redis-style random sampling.

Also: the clock should be monotonic (`System.nanoTime`) for TTLs; `currentTimeMillis` can jump.

#### Stage 2: add a feature
**Task**: add `getOrLoad(key, ttl, loader)` that loads missing or expired values **once** even when 100 threads ask at the same time.

?? Show a strong solution
Use a `ConcurrentHashMap<String, CompletableFuture<String>> loading`: `loading.computeIfAbsent(key, k -> CompletableFuture.supplyAsync(() -> loader.apply(k), executor))`; when it completes, put the value with the TTL and remove the future from `loading` (in `whenComplete`); everyone joins the same future. If the load fails, remove the future so the next caller retries, and don't cache the failure (or cache it briefly). Don't call the loader inside `computeIfAbsent` of the main map (it holds the bin lock during a slow call).

#### Stage 3: optimise
**Question**: memory is limited to 2GB and entries vary from 100 bytes to 1MB.

?? Show the points to hit
Bound the cache by weight, not count: a size-aware eviction policy (Caffeine `maximumWeight` with a weigher), W-TinyLFU or LRU eviction, and metrics for hit rate and evictions. Avoid storing huge values in-process (put them in Redis or object storage and cache references). Consider off-heap storage only if GC pauses become a measured problem.

#### Interview simulation
**Ask**: "Is it acceptable to return a value that expired 50ms ago? What happens when a key is overwritten before its old TTL fires? Which threads touch the maps?" Bug 3's subtle consequence (`scheduleAtFixedRate` silently stops after an exception) is what impresses interviewers: say it explicitly.

### H4. Bounded buffer with wait/notify

#### Brief
A legacy log pipeline uses a hand-written bounded buffer between producer threads (request handlers) and consumer threads (writers). Shutdown is signalled with a poison pill. **Rules**: `put` blocks while full, `take` blocks while empty; every message is consumed exactly once; on shutdown each consumer must stop after draining; interrupts must stop a blocked thread. **Symptom**: rare `NoSuchElementException`s and lost messages with several consumers; shutdown hangs with more than one consumer. Time box: 60 minutes.

#### Files
```java
// BoundedBuffer.java
public class BoundedBuffer<T> {
    private final Deque<T> items = new ArrayDeque<>();
    private final int capacity;
    public BoundedBuffer(int capacity) { this.capacity = capacity; }

    public synchronized void put(T item) {
        if (items.size() == capacity) {
            try { wait(); } catch (InterruptedException e) { }
        }
        items.addLast(item);
        notify();
    }

    public synchronized T take() {
        if (items.isEmpty()) {
            try { wait(); } catch (InterruptedException e) { }
        }
        T item = items.removeFirst();
        notify();
        return item;
    }
}
```
```java
// LogPipeline.java
public class LogPipeline {
    static final String POISON = "__STOP__";
    private final BoundedBuffer<String> buffer = new BoundedBuffer<>(2);
    final AtomicInteger written = new AtomicInteger();

    public Thread startConsumer() {
        Thread t = new Thread(() -> {
            while (true) {
                String m = buffer.take();
                if (m == POISON) return;
                written.incrementAndGet();
            }
        });
        t.start();
        return t;
    }

    public void log(String m) { buffer.put(m); }
    public void shutdown() { buffer.put(POISON); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        LogPipeline lp = new LogPipeline();
        List<Thread> consumers = new ArrayList<>();
        for (int i = 0; i < 3; i++) consumers.add(lp.startConsumer());
        ExecutorService producers = Executors.newFixedThreadPool(4);
        for (int i = 0; i < 4_000; i++) { String m = "line-" + i; producers.submit(() -> lp.log(m)); }
        producers.shutdown(); producers.awaitTermination(10, TimeUnit.SECONDS);
        lp.shutdown();
        for (Thread t : consumers) t.join(2_000);   // watch stderr: consumer threads may die with exceptions
        System.out.println("written: expected 4000, got " + lp.written.get());
        System.out.println("consumers still alive after shutdown: expected 0, got " + consumers.stream().filter(Thread::isAlive).count());
        System.exit(0);
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **`if` instead of `while` around `wait()`**: after waking (spurious wakeup, or another consumer took the item first), the condition may no longer hold, giving `removeFirst` on an empty deque (`NoSuchElementException`) or overfilling the buffer. Always `while (condition) wait();`.
2. **`notify()` with mixed waiters**: producers and consumers wait on the same monitor; `notify` may wake the wrong kind (a producer waking another producer), and the right thread never wakes, so throughput stalls or hangs. Use `notifyAll()` (or a `ReentrantLock` with separate `notFull`/`notEmpty` conditions).
3. **Interrupts are swallowed**: a blocked thread can't be stopped, and the flag is lost. Propagate `InterruptedException` (declare it) or restore the flag and exit.
4. **One poison pill for three consumers**: only one consumer stops; the others block forever. Put one pill per consumer (or have the consumer that sees the pill re-insert it for the others).
5. **Poison pill compared with `==`**: works only while the same interned literal instance is used; any copied or deserialised "__STOP__" string won't match. Use a dedicated sentinel object or `.equals`. (Better: a typed message with a STOP kind.)

Also the obvious modern fix: replace the class with `ArrayBlockingQueue` (`put`/`take`), which is correct and well tested.

#### Stage 2: add a feature
**Task**: make `log()` non-blocking for request threads: if the buffer stays full for 5ms, drop DEBUG/INFO messages (counting the drops) but always keep WARN/ERROR.

?? Show a strong solution
Add `boolean offer(T item, long timeout, TimeUnit unit)` (wait with a deadline: `while (full) { if (remaining <= 0) return false; wait(remainingMillis); }`). `log` uses `offer` for low levels and increments a `dropped` counter on failure, and `put` (blocking) for WARN/ERROR. Expose the drop count as a metric. That's exactly how Logback's `AsyncAppender` behaves (discarding threshold).

#### Stage 3: optimise
**Question**: the pipeline must handle 500K log lines per second.

?? Show the points to hit
Monitor contention: a single lock caps throughput. Use `LinkedBlockingQueue` (separate put and take locks), or a lock-free ring buffer (LMAX Disruptor, which Log4j2 async loggers use), batch consumers (`drainTo`) writing many lines per I/O call, and avoid per-message allocation and formatting on the hot path. Back-pressure policy (drop vs block) is a product decision.

#### Interview simulation
**Ask**: "How many producers and consumers? Is dropping messages ever acceptable? How is shutdown signalled?" Name the classic rule out loud ("always wait in a while loop") and draw the producer/consumer wait sets to explain bug 2.

### H5. Snowflake-style ID generator

#### Brief
An order service generates 64-bit, time-sortable IDs: 41 bits of milliseconds since a custom epoch, 10 bits of worker id (0–1023), 12 bits of sequence (0–4095 per millisecond). **Rules**: IDs are unique across workers and threads; IDs from one worker increase monotonically; if more than 4,096 IDs are requested in one millisecond, wait for the next millisecond; if the clock moves backwards, refuse (or wait) rather than risk duplicates. **Symptom**: duplicate IDs in production after an NTP adjustment and under high load; IDs from different workers sometimes collide. Time box: 60 minutes.

#### Files
```java
// IdGenerator.java
public class IdGenerator {
    static final long EPOCH = 1_704_067_200_000L;    // 2024-01-01T00:00:00Z
    private final long workerId;
    private long lastMs = -1;
    private long sequence = 0;
    private final LongSupplier clock;

    public IdGenerator(long workerId, LongSupplier clockMillis) { this.workerId = workerId; this.clock = clockMillis; }

    public long next() {
        long now = clock.getAsLong();
        if (now == lastMs) {
            sequence++;
        }
        lastMs = now;
        return ((now - EPOCH) << 22) | (workerId << 12) | sequence;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        long[] t = {1_800_000_000_000L};
        IdGenerator g = new IdGenerator(7, () -> t[0]);
        Set<Long> ids = new HashSet<>();
        for (int i = 0; i < 5_000; i++) ids.add(g.next());          // 5000 ids in the same millisecond
        System.out.println("unique ids in one ms burst: expected 5000, got " + ids.size());
        t[0] += 1; long a = g.next(); t[0] -= 5; long b = g.next();  // clock moves backwards by 5 ms
        System.out.println("monotonic after clock went back: expected b > a, got " + (b > a));
        IdGenerator w1 = new IdGenerator(1, () -> 1_800_000_000_101L), w1025 = new IdGenerator(1025, () -> 1_800_000_000_101L);
        System.out.println("worker 1 vs worker 1025 collide: expected false, got " + (w1.next() == w1025.next()));
        IdGenerator shared = new IdGenerator(3, System::currentTimeMillis); Set<Long> conc = ConcurrentHashMap.newKeySet();
        ExecutorService ex = Executors.newFixedThreadPool(8);
        for (int i = 0; i < 50_000; i++) ex.submit(() -> conc.add(shared.next()));
        ex.shutdown(); ex.awaitTermination(10, TimeUnit.SECONDS);
        System.out.println("unique ids from 8 threads: expected 50000, got " + conc.size());
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Sequence never resets in a new millisecond**: it keeps growing until it overflows the 12 bits into the worker bits. Reset `sequence = 0` when `now > lastMs`.
2. **Sequence overflow isn't handled**: after 4,095 in one ms, `sequence` spills into the worker-id bits, giving duplicates with other workers. Mask it (`sequence = (sequence + 1) & 4095`) and when it wraps to 0, spin until the next millisecond.
3. **Clock going backwards**: after an NTP adjustment, `now < lastMs` reuses old timestamps, so the same IDs can be generated again. Detect it: throw (alert) or wait until `now >= lastMs` for small drifts, and never set `lastMs` backwards.
4. **Worker id isn't validated**: 1025 doesn't fit in 10 bits and overlaps other bits, so worker 1025 collides with worker 1. Validate `0 <= workerId < 1024` in the constructor (and assign worker ids uniquely through a coordinator or pod ordinal).
5. **Not thread-safe**: `lastMs` and `sequence` are updated without synchronisation, so concurrent callers produce duplicates. Make `next()` `synchronized` (fast enough: millions per second), or use a CAS loop on a packed state.

#### Stage 2: add a feature
**Task**: add `static Instant timestampOf(long id)` and `static long workerOf(long id)` for debugging, and expose a base62 string form for public URLs.

?? Show a strong solution
`timestampOf = Instant.ofEpochMilli((id >>> 22) + EPOCH)`, `workerOf = (id >>> 12) & 1023`, sequence = `id & 4095`. Base62: repeatedly `id % 62` into an alphabet, reversed (handle 0). Note that public IDs leak creation time and volume; if that's sensitive, use a separate random public id.

#### Stage 3: optimise
**Question**: Kubernetes autoscales the service from 3 to 300 pods. How are worker ids assigned safely?

?? Show the points to hit
Static config doesn't scale. Options: a StatefulSet pod ordinal; leasing an id from etcd/ZooKeeper/Redis (`SET worker:{n} pod NX EX 30` with heartbeats; stop generating if the lease is lost); or a DB table of leases. With 300 pods, 10 bits (1,024) suffice; plan for more by re-partitioning bits. Alternatively, UUIDv7 needs no coordination at all, at 128 bits.

#### Interview simulation
**Ask**: "What should happen when the clock goes backwards: fail or wait? How are worker ids assigned? What throughput per worker?" Explain the bit layout on the board; each bug maps to one field (sequence, worker, timestamp) plus concurrency.

### H6. Seat hold service for live events

#### Brief
A ticketing service lets users hold seats for 10 minutes while paying. **Rules**: `hold(user, seats)` is all-or-nothing: if any seat is unavailable, nothing is held; a seat is available if it's free or its hold has expired; `confirm(holdId, user)` books the seats only if the hold is still valid **and** belongs to that user; holds from many users arrive concurrently. **Symptom**: partial holds lock seats nobody can buy, users confirm other people's holds, expired holds still block seats, and double bookings happen during big launches. Time box: 60 minutes.

#### Files
```java
// SeatState.java
public class SeatState { String holder; String holdId; Instant holdExpiresAt; boolean booked; }
```
```java
// HoldService.java
public class HoldService {
    private final Map<String, SeatState> seats = new HashMap<>();
    private final Map<String, List<String>> holds = new HashMap<>();
    private final Clock clock;
    private final Duration holdFor = Duration.ofMinutes(10);

    public HoldService(Clock clock, List<String> seatIds) {
        this.clock = clock;
        seatIds.forEach(s -> seats.put(s, new SeatState()));
    }

    private boolean available(SeatState s) {
        return !s.booked && (s.holder == null || s.holdExpiresAt.isAfter(clock.instant()));
    }

    public String hold(String user, List<String> seatIds) {
        String holdId = UUID.randomUUID().toString();
        for (String id : seatIds) {
            SeatState s = seats.get(id);
            if (!available(s)) return null;
            s.holder = user; s.holdId = holdId; s.holdExpiresAt = clock.instant().plus(holdFor);
        }
        holds.put(holdId, seatIds);
        return holdId;
    }

    public boolean confirm(String holdId, String user) {
        List<String> ids = holds.get(holdId);
        if (ids == null) return false;
        for (String id : ids) seats.get(id).booked = true;
        return true;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        Instant[] now = {Instant.parse("2026-11-01T18:00:00Z")};
        Clock clock = new Clock() {
            public ZoneId getZone() { return ZoneOffset.UTC; }
            public Clock withZone(ZoneId z) { return this; }
            public Instant instant() { return now[0]; }
        };
        HoldService hs = new HoldService(clock, List.of("A1", "A2", "A3"));
        String h1 = hs.hold("alice", List.of("A1", "A2"));
        System.out.println("bob holds A2+A3 while A2 is held: expected null, got " + hs.hold("bob", List.of("A3", "A2")));
        System.out.println("carol can hold A3 alone: expected a hold id, got " + hs.hold("carol", List.of("A3")));
        System.out.println("mallory confirms alice's hold: expected false, got " + hs.confirm(h1, "mallory"));
        HoldService hs2 = new HoldService(clock, List.of("B1"));
        hs2.hold("dev", List.of("B1"));
        now[0] = now[0].plus(Duration.ofMinutes(11));
        System.out.println("B1 after dev's hold expired: expected a hold id, got " + hs2.hold("eve", List.of("B1")));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Partial holds**: seats are marked one by one, and if a later seat is unavailable the method returns null, leaving the earlier seats held by a hold id nobody knows. Check all seats first, then mark them all (all-or-nothing).
2. **Expiry logic inverted**: `holdExpiresAt.isAfter(now)` means "the hold is still active", but it's used as "available". It should be `!s.holdExpiresAt.isAfter(now)` (the hold has expired). As written, valid holds look available and expired holds block.
3. **`confirm` doesn't check the owner or expiry**: anyone with a hold id can confirm, and an expired hold can still be confirmed (after another user re-held the seat: a double booking). Verify `user` matches the holder and that each seat still carries this `holdId` with an unexpired time, all inside the same critical section.
4. **Not thread-safe**: two users holding the same seat concurrently can both pass `available` and both mark it. Synchronise the whole hold and confirm operations (per event, or locks per seat in sorted order), or use atomic conditional updates in the DB/Redis.
5. **Confirmed holds aren't cleaned up and unknown seat ids crash**: `seats.get(id)` NPEs for an unknown seat; remove the hold id after confirm (or mark it used) so confirm is idempotent but can't be replayed for other seats.

#### Stage 2: add a feature
**Task**: a user may hold at most 6 seats per event at a time, and releasing a hold must free its seats immediately.

?? Show a strong solution
Track active holds per user (`Map<String user, Set<String> holdIds>`); within the same lock as `hold`, count the user's currently held seats (ignoring expired ones) plus the new request, and reject over 6. `release(holdId, user)` verifies ownership, clears the seats that still carry that holdId, and removes the hold. Remember lazy expiry: expired holds don't need a sweeper for correctness, but a sweeper helps the seat-map display.

#### Stage 3: optimise
**Question**: a stadium concert sells 60,000 seats with 2 million users arriving at 10:00:00.

?? Show the points to hit
A virtual waiting room admitting users at a controlled rate; seat holds in Redis with a Lua script (`SET seat:{event}:{id} holdId NX PX 600000` for all seats, rolling back on any failure) or Postgres conditional updates; a seat map served from a cached bitmap with frequent refresh; "best available" auto-allocation for the hottest sections to reduce contention; payments with the hold TTL and automatic refunds if confirmation fails after expiry; bot protection.

#### Interview simulation
**Ask**: "Is the hold all-or-nothing? What exactly does 'expired' mean at the boundary second? Can a different user confirm with the hold id?" Walk through a timeline with two users, as in the demo; the expiry inversion (bug 2) becomes obvious when you say it in words.

### H7. Spring order placement service

#### Brief
A Spring Boot order service saves orders, reserves stock in the same Postgres database, calls an external payment gateway, and sends a confirmation email. **Rules**: an order and its stock reservation must commit or roll back together; a declined payment must leave no order and no reservation; the email is sent only after the transaction commits; bulk import places each order in its own transaction. **Symptom**: declined payments leave orders behind, a failed reservation in bulk import rolls back nothing, customers get emails for orders that don't exist, and the DB connection pool runs dry under load. Time box: 60 minutes. (This mock uses Spring annotations; read it as you would in a real codebase.)

#### Files
```java
// PaymentDeclinedException.java
public class PaymentDeclinedException extends Exception {
    public PaymentDeclinedException(String m) { super(m); }
}
```
```java
// OrderService.java
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class OrderService {
    private final OrderRepository orders;
    private final StockRepository stock;
    private final PaymentClient payments;     // HTTP call to the gateway, 200ms–5s
    private final EmailClient email;

    public OrderService(OrderRepository o, StockRepository s, PaymentClient p, EmailClient e) {
        this.orders = o; this.stock = s; this.payments = p; this.email = e;
    }

    @Transactional
    public Order place(OrderRequest req) throws PaymentDeclinedException {
        Order order = orders.save(Order.pending(req));
        stock.reserve(req.sku(), req.qty());               // throws IllegalStateException if not enough stock
        payments.charge(order.id(), req.amountPaise());     // throws PaymentDeclinedException
        order.markPaid();
        email.sendConfirmation(order);
        return order;
    }

    public void importAll(List<OrderRequest> reqs) {
        for (OrderRequest r : reqs) {
            try { placeOne(r); }
            catch (Exception e) { log("import failed for " + r + ": " + e.getMessage()); }
        }
    }

    @Transactional
    private void placeOne(OrderRequest r) {
        orders.save(Order.pending(r));
        stock.reserve(r.sku(), r.qty());
    }

    private void log(String s) { System.out.println(s); }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Checked exception commits**: `PaymentDeclinedException extends Exception`, and by default `@Transactional` rolls back only on unchecked exceptions, so a declined payment **commits** the pending order and the stock reservation. Use `@Transactional(rollbackFor = PaymentDeclinedException.class)`, or make it unchecked.
2. **Self-invocation and a private method**: `importAll` calls `placeOne` on `this`, bypassing the Spring proxy, and `placeOne` is private, so no transaction is ever applied. Each repository call auto-commits on its own; a failed reservation leaves the saved order behind. Move `placeOne` to another bean (public), or use `TransactionTemplate` per item.
3. **Remote call inside the DB transaction**: the payment call (up to 5s) holds a DB connection and row locks for its whole duration, so under load the Hikari pool is exhausted. And the charge can't be rolled back if the commit later fails. Reserve and save in a short transaction, call the gateway outside it, then confirm in a second transaction (with an idempotency key on the charge and compensation on failure: a saga).
4. **Email sent before commit**: `sendConfirmation` runs inside the transaction; if the commit fails afterwards, the customer has an email for an order that doesn't exist. Send after commit: `@TransactionalEventListener(phase = AFTER_COMMIT)`, or better, the outbox pattern so it's also reliable.
5. **Exceptions swallowed in bulk import**: catching `Exception` and only logging hides systematic failures (and would also hide transaction-rollback-only errors). Collect failures into a result report and surface them; keep importing the others.

Bonus: no idempotency on `place` (client retries create duplicate orders: add an idempotency key), and `charge` should send the order id as the gateway's idempotency key.

#### Stage 2: add a feature
**Task**: handle the gateway's asynchronous "payment captured" webhook instead of a synchronous charge.

?? Show a strong solution
`place` creates the order PENDING_PAYMENT plus the reservation (with a TTL) in one transaction and returns a payment session. The webhook handler verifies the signature, dedupes on the gateway event id (a unique table), and in a transaction moves the order to PAID (a conditional update `WHERE status = 'PENDING_PAYMENT'`), writing an outbox event for email. An expiry job cancels unpaid orders after 15 minutes and releases the stock. Late success after expiry triggers an automatic refund.

#### Stage 3: optimise
**Question**: at peak, 400 orders per second arrive and the pool has 20 connections.

?? Show the points to hit
Keep transactions short (no remote calls inside); each transaction is a few ms, so 20 connections handle a lot. Measure `hikaricp.connections.pending`. Use conditional stock updates instead of read-then-write (no long row locks). Batch the import with chunked transactions. Make email and other side effects asynchronous through the outbox and Kafka.

#### Interview simulation
**Ask**: "Are orders and stock in the same database? Is the payment synchronous? What should happen to stock if the payment is declined?" Name the proxy model early: "these annotations only work through the Spring proxy". Interviewers plant exactly these four `@Transactional` traps.

### H8. Consistent hashing router

#### Brief
A cache client routes keys to cache nodes using a consistent hash ring with 100 virtual nodes per server. **Rules**: a key goes to the first virtual node clockwise from its hash (wrapping around); removing a server removes all its virtual nodes; adding or removing one server out of N remaps roughly 1/N of the keys; `replicasFor(key, 2)` returns 2 **distinct physical** servers. **Symptom**: an exception for some keys, a removed node still receives traffic, load is very uneven, and both "replicas" are often the same server. Time box: 60 minutes.

#### Files
```java
// HashRing.java
public class HashRing {
    private final TreeMap<Integer, String> ring = new TreeMap<>();
    private final int vnodes;
    public HashRing(int vnodes) { this.vnodes = vnodes; }

    private int hash(String s) { return s.hashCode(); }

    public void addNode(String node) {
        for (int i = 0; i < vnodes; i++) ring.put(hash(node + i), node);
    }

    public void removeNode(String node) {
        ring.remove(hash(node));
    }

    public String nodeFor(String key) {
        return ring.ceilingEntry(hash(key)).getValue();
    }

    public int vnodeCount() { return ring.size(); }

    public List<String> replicasFor(String key, int n) {
        List<String> out = new ArrayList<>();
        Integer h = hash(key);
        for (Map.Entry<Integer, String> e : ring.tailMap(h).entrySet()) {
            if (out.size() == n) break;
            out.add(e.getValue());
        }
        return out;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        HashRing r = new HashRing(100);
        r.addNode("cache-1"); r.addNode("cache-2"); r.addNode("cache-3");
        int crashes = 0; Map<String, Integer> load = new TreeMap<>();
        for (int i = 0; i < 30_000; i++) {
            try { load.merge(r.nodeFor("user:" + i), 1, Integer::sum); } catch (Exception e) { crashes++; }
        }
        System.out.println("crashes: expected 0, got " + crashes + "; load " + load + " (expected roughly 10000 each)");
        r.removeNode("cache-2");
        System.out.println("virtual nodes after removing cache-2: expected 200, got " + r.vnodeCount());
        System.out.println("replicas for a key: expected 2 distinct servers, got " + r.replicasFor("user:42", 2));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **No wrap-around**: `ceilingEntry` returns null for hashes above the highest vnode, giving an NPE. Fall back to `ring.firstEntry()`.
2. **`removeNode` removes one entry that doesn't even exist**: vnodes were added as `node + i`, but removal hashes `node`. Remove all `vnodes` entries using the same naming as `addNode`.
3. **Poor hash function**: `String.hashCode` on `"cache-1" + i` produces clustered, sequential values (strings differing only in the last characters hash close together), so vnodes bunch up and the load is very uneven. Use a well-mixed hash (MurmurHash3/xxHash 64-bit, or at least an MD5/SHA-based hash folded to a long). Use `long` keys in the TreeMap.
4. **Replicas aren't distinct and don't wrap**: consecutive vnodes often belong to the same server, and `tailMap` doesn't wrap past the end. Walk clockwise (wrapping), skipping servers already chosen, until n distinct physical servers are found (or all servers are used).
5. **Hash collisions between vnodes overwrite each other**: `ring.put` silently replaces another node's vnode when two hashes collide (likely with 32-bit `hashCode`). Use 64-bit hashes and detect collisions (keep the existing entry, or rehash with a suffix).

Also: the ring isn't thread-safe if nodes change while other threads route. Build a new immutable ring on change and swap it via a volatile reference (copy-on-write).

#### Stage 2: add a feature
**Task**: weighted nodes: a server with 2× memory should get about 2× the keys.

?? Show a strong solution
Give each node `weight × baseVnodes` virtual nodes (store the weight so removal removes the same count). Validate the distribution with a test that routes 1M keys and checks each node's share is within a tolerance of its weight share. Mention that changing a weight remaps only the added or removed vnodes' ranges.

#### Stage 3: optimise
**Question**: 1M lookups per second per client process, and nodes change rarely.

?? Show the points to hit
`TreeMap` lookup is O(log V) with pointer chasing. Precompute a sorted `long[] hashes` and a parallel `String[] owners` array and use `Arrays.binarySearch` (cache-friendly), rebuilt on membership changes and swapped atomically. Alternatives: jump consistent hash (O(1) memory, no ring) when nodes are numbered, or fixed slots (Redis Cluster's 16,384 slots) mapped to nodes, with O(1) lookup.

#### Interview simulation
**Ask**: "What hash function is acceptable? Must replicas be on different physical servers (and racks/AZs)? Can membership change concurrently with lookups?" Draw the ring with the wrap-around point; bug 1 and the replica-wrap issue jump out.

### H9. Streaming top-K error aggregator

#### Brief
An observability service reads error events from many threads and reports the top K most frequent error signatures over the **last 5 minutes**. **Rules**: counts older than 5 minutes must drop out; the top K is ordered by count descending, ties by signature; memory must stay bounded even with millions of distinct signatures per day; the report must not block ingestion for long. **Symptom**: the report shows the *least* frequent errors, counts never decrease, memory grows all day, and counts are slightly off under load. Time box: 60 minutes.

#### Files
```java
// ErrorAggregator.java
public class ErrorAggregator {
    private final Map<String, Integer> counts = new HashMap<>();
    private final LongSupplier clockMillis;

    public ErrorAggregator(LongSupplier clockMillis) { this.clockMillis = clockMillis; }

    public void record(String signature) {
        counts.put(signature, counts.getOrDefault(signature, 0) + 1);
    }

    public int countOf(String signature) { return counts.getOrDefault(signature, 0); }

    public List<String> topK(int k) {
        PriorityQueue<Map.Entry<String, Integer>> heap =
            new PriorityQueue<>((a, b) -> b.getValue() - a.getValue());       // intended: keep the k largest
        for (Map.Entry<String, Integer> e : counts.entrySet()) {
            heap.offer(e);
            if (heap.size() > k) heap.poll();
        }
        List<String> out = new ArrayList<>();
        while (!heap.isEmpty()) out.add(heap.poll().getKey());
        return out;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        long[] now = {0};
        ErrorAggregator agg = new ErrorAggregator(() -> now[0]);
        for (int i = 0; i < 50; i++) agg.record("DB_TIMEOUT");
        for (int i = 0; i < 30; i++) agg.record("NPE_CHECKOUT");
        for (int i = 0; i < 5; i++) agg.record("RATE_LIMITED");
        System.out.println("top 2: expected [DB_TIMEOUT, NPE_CHECKOUT], got " + agg.topK(2));
        now[0] += 6 * 60_000;                          // 6 minutes later
        for (int i = 0; i < 40; i++) agg.record("CACHE_MISS");
        System.out.println("top 1 after window moved: expected [CACHE_MISS], got " + agg.topK(1));
        ErrorAggregator conc = new ErrorAggregator(() -> 0);
        ExecutorService ex = Executors.newFixedThreadPool(8);
        for (int i = 0; i < 40_000; i++) ex.submit(() -> conc.record("X"));
        ex.shutdown(); ex.awaitTermination(10, TimeUnit.SECONDS);
        System.out.println("concurrent count: expected 40000, got " + conc.topK(1) + " with count " + conc.countOf("X"));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Heap orientation is inverted**: to keep the k largest, you need a **min-heap** of size k (poll removes the smallest). The comparator `b - a` builds a max-heap, so `poll()` throws away the largest each time, leaving the smallest. Use `Comparator.comparingInt(Map.Entry::getValue)` (plus a tie-break), then reverse the output.
2. **Output order**: polling a min-heap yields ascending counts; reverse the list (and apply the tie-break by signature).
3. **No time window**: counts accumulate forever. Keep per-minute buckets (a ring of 5 maps, or `Map<signature, int[5]>` indexed by minute) and drop buckets older than 5 minutes; the report sums the live buckets. Use the injected clock (it's unused, which is a hint).
4. **Not thread-safe**: `HashMap` with get-then-put from 8 threads loses increments and can corrupt the map. Use `ConcurrentHashMap<String, LongAdder>` (or `merge`), per bucket.
5. **Unbounded memory**: millions of distinct signatures are kept all day. The window eviction fixes most of it; for bounded memory with heavy cardinality, use a Count-Min Sketch plus a small top-K heap (approximate heavy hitters), and normalise signatures (strip ids and numbers from messages so the same error groups together).

Also: once you add buckets, `countOf` must sum the signature across the live buckets only.

#### Stage 2: add a feature
**Task**: alert when any signature's count in the last 5 minutes is 5× its average over the previous hour.

?? Show a strong solution
Keep 60 one-minute buckets per signature (or hourly aggregates) so you can compute the baseline (sum over minutes 6–65, divided by 12 for a per-5-minute average). On each report tick, compare the current 5-minute count against `5 × baseline` with a minimum count threshold (to avoid alerting on 1 vs 0). Dedupe alerts per signature (edge-triggered), and include samples in the alert.

#### Stage 3: optimise
**Question**: 2 million error events per second across 50 services.

?? Show the points to hit
Pre-aggregate at the source (each service counts per signature per 10s and ships counts, not raw events), stream into Kafka keyed by signature, aggregate in a stream processor (Flink/Kafka Streams with tumbling or sliding windows), and keep top-K per window in a small store (Redis sorted set). Sampling plus sketches if cardinality is huge. This is the "metrics/logging system" HLD problem in miniature.

#### Interview simulation
**Ask**: "Is the window sliding or tumbling? Is an approximate top-K acceptable? How many distinct signatures per day?" Point out that the injected clock is never used (a strong hint the window is missing), then fix the heap orientation, then the window.

### H10. Payment webhook handler

#### Brief
A payment provider sends webhooks (`payment.authorized`, `payment.captured`, `payment.failed`) with an HMAC-SHA256 signature of the **raw request body** in a header. **Rules**: reject requests whose signature doesn't match, using a constant-time comparison; the same event id may arrive several times (process once); events can arrive out of order, and a payment's status must never move backwards (CAPTURED must not become AUTHORIZED); the captured amount must match the order amount. **Symptom**: valid webhooks are rejected after a library upgrade, duplicates double-ship orders, and some captured payments revert to authorized. Time box: 60 minutes.

#### Files
```java
// WebhookEvent.java
public record WebhookEvent(String eventId, String type, String paymentId, Long amountPaise) {}
```
```java
// SignatureVerifier.java
public class SignatureVerifier {
    private final byte[] secret;
    public SignatureVerifier(String secret) { this.secret = secret.getBytes(StandardCharsets.UTF_8); }

    public String sign(String payload) throws Exception {
        javax.crypto.Mac mac = javax.crypto.Mac.getInstance("HmacSHA256");
        mac.init(new javax.crypto.spec.SecretKeySpec(secret, "HmacSHA256"));
        return HexFormat.of().formatHex(mac.doFinal(payload.getBytes(StandardCharsets.UTF_8)));
    }

    public boolean verify(String reserializedJson, String signatureHeader) throws Exception {
        return sign(reserializedJson).equals(signatureHeader);
    }
}
```
```java
// WebhookHandler.java
public class WebhookHandler {
    enum Status { CREATED, AUTHORIZED, CAPTURED, FAILED }
    private final Map<String, Status> payments = new ConcurrentHashMap<>();
    private final Map<String, Long> orderAmounts;
    private final Set<String> processed = ConcurrentHashMap.newKeySet();
    final List<String> shipments = Collections.synchronizedList(new ArrayList<>());

    public WebhookHandler(Map<String, Long> orderAmounts) { this.orderAmounts = orderAmounts; }

    public void handle(WebhookEvent e) {
        switch (e.type()) {
            case "payment.authorized" -> payments.put(e.paymentId(), Status.AUTHORIZED);
            case "payment.captured" -> {
                if (e.amountPaise() == orderAmounts.get(e.paymentId())) {
                    payments.put(e.paymentId(), Status.CAPTURED);
                    shipments.add(e.paymentId());
                }
            }
            case "payment.failed" -> payments.put(e.paymentId(), Status.FAILED);
        }
        processed.add(e.eventId());
    }
    public Status status(String paymentId) { return payments.get(paymentId); }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) throws Exception {
        SignatureVerifier v = new SignatureVerifier("whsec_test");
        String raw = "{\"id\":\"evt_1\",  \"type\":\"payment.captured\"}";       // provider's exact bytes (note the spacing)
        String header = v.sign(raw);
        String reserialized = "{\"id\":\"evt_1\",\"type\":\"payment.captured\"}"; // what our JSON library re-emits
        System.out.println("valid webhook verified: expected true, got " + v.verify(reserialized, header));

        WebhookHandler h = new WebhookHandler(Map.of("pay_1", 125_000L, "pay_2", 100L));
        h.handle(new WebhookEvent("evt_1", "payment.captured", "pay_1", 125_000L));
        System.out.println("shipments for a correct Rs 1,250 capture: expected 1, got " + Collections.frequency(h.shipments, "pay_1"));
        WebhookEvent captured = new WebhookEvent("evt_2", "payment.captured", "pay_2", 100L);
        h.handle(captured); h.handle(captured);                                   // provider retry
        System.out.println("shipments after a provider retry: expected 1, got " + Collections.frequency(h.shipments, "pay_2"));
        h.handle(new WebhookEvent("evt_0", "payment.authorized", "pay_2", null));  // late, out-of-order event
        System.out.println("status after late 'authorized': expected CAPTURED, got " + h.status("pay_2"));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Signing the re-serialized JSON instead of the raw body**: re-serialising changes whitespace and key order, so valid signatures fail (exactly what happens after a JSON library upgrade). Verify the HMAC over the exact raw request bytes, before parsing.
2. **Non-constant-time comparison**: `String.equals` returns early on the first different character, which leaks timing information. Use `MessageDigest.isEqual(expectedBytes, providedBytes)`. Also check a timestamp header (reject events older than a few minutes) to stop replays.
3. **Dedup check is missing (and recorded after processing)**: `processed` is written but never checked, so retries ship twice. Claim the event id atomically **before** the side effects (`if (!processed.add(e.eventId())) return;`), and in a real system persist it in the same DB transaction as the state change.
4. **Status can move backwards**: a late `payment.authorized` overwrites CAPTURED. Only allow forward transitions (`CREATED → AUTHORIZED → CAPTURED`, any non-terminal → FAILED), e.g. by ranking the states and using `payments.merge(id, new, (old, n) -> rank(n) > rank(old) ? n : old)`, or a conditional DB update.
5. **`Long == Long` amount comparison**: `e.amountPaise() == orderAmounts.get(...)` compares references for boxed `Long`s outside −128..127, so a correct capture of 125,000 can fail the check (no shipment), and a null amount NPEs. Use `Objects.equals` (or unbox explicitly after null checks), and alert on a mismatch rather than silently ignoring it.

Also: return 2xx quickly and do slow work asynchronously (providers retry on timeouts); unknown event types should be acknowledged and logged, not rejected.

#### Stage 2: add a feature
**Task**: handle partial captures and refunds (`payment.refunded` with an amount), keeping the order's net paid amount correct.

?? Show a strong solution
Model money movements as ledger entries per payment (captured +X, refunded −Y), deduped by event id, so the net amount = Σ entries. Status is derived: fully refunded if net = 0 after a capture. Validate that refunds never exceed the captured total. Emit domain events (OrderRefunded) via the outbox. Out-of-order refunds before the capture event can be held as pending entries until the capture arrives.

#### Stage 3: optimise
**Question**: the provider sends 2,000 webhooks per second during a sale, and processing includes DB writes and calls to the order service.

?? Show the points to hit
Verify the signature and enqueue to Kafka (keyed by paymentId for per-payment ordering) within milliseconds, then return 200; consumers process with dedup in the DB (unique event id) and state-machine updates; order notifications via the outbox. Scale consumers by partitions. Reconciliation against the provider's settlement reports catches anything missed.

#### Interview simulation
**Ask**: "Does the provider sign the raw body? Can events arrive out of order or more than once? What's the timeout before the provider retries?" These three questions show you know webhooks in production; most candidates only test the happy path.
