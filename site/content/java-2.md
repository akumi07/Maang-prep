## Modern Java (8–21) | P2

### Lambdas, functional interfaces and method references

#### Core idea
A **lambda** is a concise way to pass behaviour as data. It's an implementation of a **functional interface** (an interface with one abstract method). Method references (`String::length`) are shorthand lambdas.

#### How it works
- Core functional interfaces in `java.util.function`:

| Interface | Signature | Example |
|---|---|---|
| `Supplier<T>` | `() -> T` | `() -> new ArrayList<>()` |
| `Consumer<T>` | `T -> void` | `System.out::println` |
| `Function<T,R>` | `T -> R` | `String::length` |
| `Predicate<T>` | `T -> boolean` | `s -> s.isEmpty()` |
| `BiFunction<T,U,R>` | `(T,U) -> R` | `Integer::sum` |
| `UnaryOperator<T>` / `BinaryOperator<T>` | `T -> T` / `(T,T) -> T` | `String::trim` |
| Primitive specialisations | `IntFunction`, `ToIntFunction`, `IntPredicate`… | avoid boxing |

- **Four kinds of method reference**: static (`Integer::parseInt`), bound instance (`user::getName`), unbound instance (`String::toUpperCase`, where the first argument becomes the receiver), and constructor (`ArrayList::new`).
- **Under the hood**: lambdas are **not** anonymous inner classes. The compiler emits an `invokedynamic` instruction. At first call, `LambdaMetafactory` spins up a lightweight class, and non-capturing lambdas are cached as singletons. Inside a lambda, `this` means the enclosing instance; in an anonymous class it means the anonymous object.
- **Captured variables** must be effectively final.
- **Composition**: `Predicate.and/or/negate`, `Function.andThen/compose`, `Comparator.comparing().thenComparing()`.

#### Real-world example
Spring Security's DSL is lambda-based: `http.authorizeHttpRequests(a -> a.requestMatchers("/admin/**").hasRole("ADMIN").anyRequest().authenticated())`. Your retry helper might take a `Supplier<T>` so any call can be retried: `retry(() -> inventoryClient.reserve(sku), 3)`.

#### Interview questions
?? What's the difference between a lambda and an anonymous inner class?
A lambda has no own `this` (it refers to the enclosing instance) and no state. It compiles via `invokedynamic` with no separate `.class` file, and non-capturing lambdas are cached. An anonymous class creates a new object each time, has its own `this`, can hold fields, can implement interfaces with several methods, and can extend classes.

?? Can a lambda throw a checked exception?
Only if the functional interface's method declares it. `Function.apply` doesn't, so you must catch inside the lambda, wrap it in an unchecked exception, or define your own `ThrowingFunction` interface.

#### Tricky questions
?? Why does this fail to compile? `int count = 0; list.forEach(x -> count++);`
`count` is captured and must be effectively final. Use `list.size()`, a stream `count()`, or (as a last resort) an `AtomicInteger`.

?? Is `Comparator.comparing(User::getAge)` boxing-free?
No. It boxes `int` to `Integer`. Use `Comparator.comparingInt(User::getAge)` to avoid boxing on hot paths.

#### Interview simulation
**Interviewer:** "Write a generic retry utility."

**Clarify:** "Which exceptions are retryable? Fixed or exponential backoff? Should it be sync or async?"

**Answer:**
```java
static <T> T retry(Supplier<T> call, int maxAttempts, Duration base, Predicate<Throwable> retryable) {
    for (int attempt = 1; ; attempt++) {
        try { return call.get(); }
        catch (RuntimeException e) {
            if (attempt >= maxAttempts || !retryable.test(e)) throw e;
            long sleep = (long) (base.toMillis() * Math.pow(2, attempt - 1) * (0.5 + Math.random()));
            try { Thread.sleep(sleep); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); throw e; }
        }
    }
}
```
Then mention jitter, idempotency (only retry safe operations), preserving the interrupt flag, and that in production you'd use Resilience4j.

### Streams API

#### Core idea
A **stream** is a lazy pipeline of operations over a data source: a source, zero or more **intermediate** operations (`filter`, `map`, `sorted`), and one **terminal** operation (`collect`, `forEach`, `reduce`). Nothing runs until the terminal operation is called.

#### How it works
- **Laziness and fusion**: elements flow one at a time through the whole pipeline (`filter → map → collect` per element), not stage by stage. Short-circuiting operations (`findFirst`, `anyMatch`, `limit`) stop early.
- **Stateless vs stateful**: `filter`/`map` are stateless. `sorted`/`distinct` are stateful and must buffer elements; `sorted` needs all of them first.
- **Single use**: a stream can be consumed once; reusing it throws `IllegalStateException`.
- **Key collectors**:
```java
Map<String, List<Order>> byCity = orders.stream().collect(groupingBy(Order::city));
Map<String, Long> countByCity = orders.stream().collect(groupingBy(Order::city, counting()));
Map<String, Double> revenue = orders.stream()
    .collect(groupingBy(Order::city, summingDouble(Order::amount)));
Map<Boolean, List<Order>> bigSmall = orders.stream().collect(partitioningBy(o -> o.amount() > 1000));
Map<String, Order> byId = orders.stream()
    .collect(toMap(Order::id, Function.identity(), (a, b) -> a));   // merge fn avoids IllegalStateException on duplicates
String csv = names.stream().collect(joining(","));
// top 3 products by revenue
products.stream().sorted(comparingDouble(Product::revenue).reversed()).limit(3).toList();
```
- `flatMap` flattens nested structures: `orders.stream().flatMap(o -> o.items().stream())`.
- **Parallel streams** split the work using `Spliterator` and run it in the **common ForkJoinPool** (size = cores − 1). They help only for large, CPU-bound, easily splittable work (arrays, ranges), never for I/O. Because they share one global pool, a blocking task in a parallel stream starves every other parallel stream in the JVM.

#### Real-world example
Building a search response: `results.stream().filter(Product::inStock).map(mapper::toDto).sorted(byRelevance).limit(20).toList()`. The **bad** example is calling an HTTP service inside `.parallelStream().map(...)`: it blocks common-pool threads and throttles every other parallel stream (and `CompletableFuture` default async calls) in the app. Use `CompletableFuture` with a dedicated I/O executor instead (the approach that gave the 40% latency cut at Tata 1mg).

#### Interview questions
?? Intermediate vs terminal operations?
Intermediate operations return a new Stream and are lazy (`map`, `filter`, `sorted`, `peek`). Terminal operations trigger execution and produce a result or side effect (`collect`, `reduce`, `forEach`, `count`, `findFirst`). Without a terminal operation, nothing executes.

?? `map` vs `flatMap`?
`map` transforms each element into exactly one element. `flatMap` transforms each element into a stream and concatenates the results (one-to-many). Example: `List<Order>` → all items is `flatMap(o -> o.getItems().stream())`.

?? When should you NOT use parallel streams?
For small collections, I/O-bound work, operations with side effects or shared mutable state, ordered operations on large data (`limit` and `findFirst` are costly in parallel), or `LinkedList` sources (they split poorly). Also in servers, where the common pool is shared by everything.

#### Tricky questions
?? What does this print? `Stream.of(1,2,3).peek(System.out::print).count();`
On Java 9+ it may print **nothing**. `count()` can compute the size directly from a SIZED source and skip the pipeline. Never rely on `peek` for side effects; it's for debugging.

?? `toMap` throws `IllegalStateException: Duplicate key`. Why, and how do you fix it?
Two elements mapped to the same key. Provide a merge function: `toMap(k, v, (a, b) -> a)`. Also, `toMap` throws an NPE on null **values**.

?? Is `Stream.toList()` the same as `collect(Collectors.toList())`?
No. `toList()` (Java 16) returns an **unmodifiable** list. `Collectors.toList()` returns a mutable `ArrayList` in practice (but that isn't guaranteed).

#### Interview simulation
**Interviewer:** "Given a list of transactions, find the top 3 customers by total spend in the last 30 days."

**Clarify:** "Can amounts be refunds or negative? Is the time zone the server's or the customer's? And how should ties be broken?"

**Answer:**
```java
Instant cutoff = Instant.now().minus(30, ChronoUnit.DAYS);
List<String> top3 = txns.stream()
    .filter(t -> t.time().isAfter(cutoff))
    .collect(groupingBy(Txn::customerId, summingLong(Txn::amountPaise)))
    .entrySet().stream()
    .sorted(Map.Entry.<String, Long>comparingByValue().reversed().thenComparing(Map.Entry.comparingByKey()))
    .limit(3).map(Map.Entry::getKey).toList();
```
Mention that money is kept in paise as `long` (no floating point), that time is O(n + c log c) where c is the number of customers, and that in production this would be a SQL `GROUP BY ... ORDER BY ... LIMIT 3`.

### Optional done right

#### Core idea
`Optional<T>` is a container that may or may not hold a value. It was designed as a **return type** that makes "might be absent" explicit, so callers can't forget the null check.

#### How it works
```java
Optional<User> u = repo.findById(id);
String city = u.map(User::getAddress).map(Address::getCity).orElse("Unknown");
User user = u.orElseThrow(() -> new UserNotFoundException(id));
u.ifPresentOrElse(this::greet, this::logMissing);
```
- `orElse(x)` **always evaluates** `x`, even when a value is present. `orElseGet(() -> x)` evaluates lazily. Use `orElseGet` when the default is expensive (a DB call, object creation).
- `Optional.of(null)` throws an NPE; `Optional.ofNullable(x)` is safe.
- `get()` without `isPresent()` defeats the purpose. Prefer `orElseThrow()` (Java 10), which reads as intent.

**Do's and don'ts**
- ✅ Return type of query-like methods (`findById`).
- ❌ Fields (Optional isn't `Serializable`, and it adds an allocation), method parameters (callers end up passing `Optional.empty()`), and collections (return an empty list instead).
- ❌ `Optional<List<X>>`: just return an empty list.
- ❌ Returning `null` from a method whose return type is Optional.

#### Real-world example
Spring Data's `findById` returns `Optional<T>`. A controller does `repo.findById(id).map(mapper::toDto).map(ResponseEntity::ok).orElseGet(() -> ResponseEntity.notFound().build())`, which reads cleanly with no null checks.

#### Interview questions
?? What is the difference between orElse and orElseGet?
`orElse(value)`: the value is computed eagerly, before the call, whether or not it's needed. `orElseGet(supplier)`: the supplier runs only if the Optional is empty. The classic bug is `opt.orElse(createDefaultUserInDb())`, which inserts a row even when the user exists.

?? Why shouldn't Optional be used as a field or parameter?
It wasn't designed for it: it's not serialisable, it adds an object per field, and parameters force callers to wrap values. Overloads or nullable parameters with clear docs are cleaner. Its intended use is return values.

#### Tricky questions
?? Can an Optional itself be null?
Technically yes, if someone returns `null` from an Optional-typed method, but that's a serious bug. Code reviewers and static analysis should forbid it.

#### Interview simulation
If asked "How do you avoid NullPointerExceptions?", answer with layers: Optional for return values, validated constructors (`Objects.requireNonNull`), empty collections instead of null, `@NonNull` annotations plus static analysis (NullAway/SpotBugs), and Java 14's helpful NPE messages for debugging.

### Records, sealed classes and pattern matching

#### Core idea
Modern Java (14–21) added features for **data-oriented programming**:
- **Records** (16): concise immutable data carriers.
- **Sealed classes** (17): restrict which classes can extend a type.
- **Pattern matching** for `instanceof` (16) and `switch` (21), plus **record patterns** (21): deconstruct objects safely.

#### How it works
**Records**
```java
public record OrderDto(String id, long amountPaise, List<String> items) {
    public OrderDto {                                   // compact constructor: validate / normalise
        Objects.requireNonNull(id);
        if (amountPaise < 0) throw new IllegalArgumentException("negative amount");
        items = List.copyOf(items);                     // defensive copy → deep-ish immutability
    }
}
```
Records get private final fields, a canonical constructor, accessors (`id()`, not `getId()`), and `equals`/`hashCode`/`toString`. They're implicitly final and can't extend a class (they implicitly extend `java.lang.Record`), but they can implement interfaces and have static and instance methods.

**Sealed hierarchy + exhaustive switch**
```java
public sealed interface PaymentResult permits Success, Declined, Pending {}
public record Success(String txnId) implements PaymentResult {}
public record Declined(String reason) implements PaymentResult {}
public record Pending(Duration retryAfter) implements PaymentResult {}

String message(PaymentResult r) {
    return switch (r) {                                  // no default needed: compiler knows all cases
        case Success s -> "Paid: " + s.txnId();
        case Declined(String reason) -> "Declined: " + reason;            // record pattern
        case Pending p when p.retryAfter().toSeconds() > 60 -> "Try later";  // guard
        case Pending p -> "Processing";
    };
}
```
If someone adds a new `PaymentResult` subtype, every switch that doesn't handle it **fails to compile**. That's safer than `instanceof` chains or the visitor pattern.

**Other bits:** `var` (local type inference, Java 10), text blocks `"""…"""` (15), switch expressions with `->` and `yield` (14), and helpful NullPointerException messages (14).

#### Real-world example
DTOs and Kafka event payloads as records: `record OrderPlaced(String orderId, String userId, Instant at)`. Jackson supports records natively. Domain results like `PaymentResult` as a sealed hierarchy replace "error codes in strings" with type-checked handling.

#### Interview questions
?? Are records truly immutable?
Shallowly. The fields are final, but a field holding a mutable `List` can still be mutated unless you defensively copy it (`List.copyOf`) in the compact constructor.

?? Can a record be a JPA entity?
Not well. JPA needs a no-arg constructor, mutable fields and proxyable (non-final) classes. Records suit DTOs, projections (Spring Data supports record projections) and value objects, not entities.

?? Why use sealed classes instead of an enum?
Enum constants are singletons with the same fields. Sealed subtypes can each carry **different data** (`Success` has `txnId`, `Pending` has `retryAfter`) while staying a closed, exhaustively checkable set.

#### Tricky questions
?? Can you override a record's accessor or equals?
Yes. You can declare `id()` explicitly (it must be public and return the same type), and you can override `equals`/`hashCode`, but you should rarely need to.

#### Interview simulation
If asked "What's new in Java 17/21 that you use?", pick three with a real use: records for DTOs and events, sealed interfaces with pattern-matching switch for domain results, and virtual threads for blocking I/O at scale (next topic). Specifics beat a feature list.

### Virtual threads (Project Loom)

#### Core idea
**Virtual threads** (final in Java 21) are lightweight threads managed by the JVM rather than the OS. You can have **millions** of them, so the simple *thread-per-request blocking style* scales like async code, without callbacks or reactive chains.

#### How it works
- A **platform thread** wraps an OS thread: about 1MB of stack, an expensive context switch, so practical limits are in the thousands.
- A **virtual thread** is a Java object whose stack lives on the heap as chunks. It runs ("mounts") on a small pool of **carrier threads** (a ForkJoinPool sized to the CPU cores).
- When a virtual thread blocks on I/O (socket read, `Thread.sleep`, `BlockingQueue.take`, `Lock.lock`), the JVM **unmounts** it, saving its stack, and the carrier runs another virtual thread. When the I/O completes, it's rescheduled.
- **Pinning**: a virtual thread *can't unmount* while inside a `synchronized` block or a native call (true up to Java 23; Java 24 removes pinning for `synchronized`). Blocking while pinned holds a carrier, so with few carriers throughput collapses. Fix it on Java 21 by using `ReentrantLock` instead of `synchronized` around blocking I/O. Detect it with `-Djdk.tracePinnedThreads=full`.
- **Don't pool virtual threads.** Create one per task: `Executors.newVirtualThreadPerTaskExecutor()`. Limit concurrency to a downstream with a `Semaphore`, not a pool size.
- **ThreadLocal** works but is costly with millions of threads; **ScopedValue** is the newer alternative (preview).
- Virtual threads help **I/O-bound** concurrency. They don't make CPU-bound code faster.

```java
try (var exec = Executors.newVirtualThreadPerTaskExecutor()) {
    List<Future<Price>> fs = skus.stream()
        .map(s -> exec.submit(() -> pricingClient.get(s)))   // blocking HTTP call, cheap per thread
        .toList();
    for (var f : fs) prices.add(f.get());
}
// Spring Boot 3.2+: spring.threads.virtual.enabled=true → Tomcat handles each request on a virtual thread
```

#### Real-world example
An API gateway or BFF that fans out to 5 downstream services per request: with 200 Tomcat platform threads and 300ms downstream latency, throughput caps at about 660 req/s, even if the CPU is idle. With virtual threads, each request blocks cheaply and throughput is limited by the downstreams and the CPU, not by thread count. Netflix and others reported issues with pinning on `synchronized` in libraries during adoption, which is a good detail to mention.

#### Interview questions
?? How are virtual threads different from reactive programming (WebFlux)?
Both achieve high concurrency for I/O-bound work. Reactive uses non-blocking APIs and callback/operator chains: efficient, but hard to read, debug and profile (stack traces are fragmented). Virtual threads let you write plain blocking code and get similar scalability, with normal stack traces, debuggers and `try/catch`. Reactive still offers backpressure and streaming operators that Loom doesn't replace.

?? Should you replace all thread pools with virtual threads?
For I/O-bound tasks, yes (`newVirtualThreadPerTaskExecutor`). For CPU-bound work, keep a bounded platform pool sized to the cores. Pools that existed only to *limit* concurrency (e.g. max 20 DB calls) should become semaphores, and the DB connection pool still caps real concurrency.

#### Tricky questions
?? What is thread pinning and why does it matter?
When a virtual thread blocks inside `synchronized` (pre-Java 24) or native code, it can't release its carrier thread. With carriers equal to the core count, a few pinned threads stall everything. Use `ReentrantLock` and check with JFR's `jdk.VirtualThreadPinned` event.

?? With virtual threads, will 10,000 concurrent requests overwhelm the database?
They can try. Virtual threads remove the *thread* bottleneck, so the next bottleneck (the Hikari pool, DB connections, downstream rate limits) becomes visible. Requests will queue on `getConnection()` and time out. Size pools and add semaphores and backpressure deliberately.

#### Interview simulation
**Interviewer:** "Our service is I/O-bound and runs out of threads under load. What would you do?"

**Clarify:** "What's the Java version? Is the stack Spring MVC or WebFlux? What are the downstreams: DB, HTTP, Kafka? And what are the current thread-pool and connection-pool sizes?"

**Answer:** First confirm with metrics (thread dumps showing threads WAITING on socket reads, the busy-thread count at max, the CPU low). The options, in increasing effort: tune timeouts so threads aren't held by slow calls; parallelise independent calls with `CompletableFuture`; on Java 21, enable virtual threads (`spring.threads.virtual.enabled=true`), checking for pinning; keep a bounded connection pool and a semaphore per downstream. Explain why you'd avoid jumping straight to WebFlux: rewrite cost and debugging complexity.

## Concurrency & multithreading | P2 | must

### Threads, lifecycle and Runnable vs Callable

#### Core idea
A **thread** is an independent path of execution within a process, sharing the heap with other threads but having its own stack and program counter. Java threads (platform threads) map 1:1 to OS threads.

#### How it works
**Lifecycle (`Thread.State`)**
```
NEW ──start()──▶ RUNNABLE ◀──────────────────────────┐
                   │  waiting for monitor lock ▶ BLOCKED ─┘ (gets lock)
                   │  wait()/join()/park()     ▶ WAITING ─┘ (notify/unpark)
                   │  sleep(t)/wait(t)/join(t) ▶ TIMED_WAITING ─┘
                   ▼
               TERMINATED (run() returns or throws)
```
- `RUNNABLE` covers both "running" and "ready to run" (including blocked in native I/O, from the JVM's point of view).
- `BLOCKED` specifically means waiting to enter a `synchronized` block. `WAITING` means waiting for another thread's action.

**Creating work**
- `Runnable`: `void run()`, can't return a value or throw checked exceptions.
- `Callable<V>`: `V call() throws Exception`. Submit it to an executor to get a `Future<V>`.
- `start()` creates a new thread that calls `run()`. Calling `run()` directly just runs it on the **current** thread.
- **Daemon threads** don't keep the JVM alive (`setDaemon(true)` before start), and are used for background housekeeping.
- **Interruption** is cooperative: `t.interrupt()` sets a flag. Blocking methods (`sleep`, `wait`, `join`, `BlockingQueue.take`) throw `InterruptedException` and **clear the flag**. Correct handling: either propagate the exception, or restore the flag with `Thread.currentThread().interrupt()`. Never swallow it.

#### Real-world example
A thread dump (`jstack <pid>` or `/actuator/threaddump`) during an outage shows 200 Tomcat threads in `TIMED_WAITING` at `SocketInputStream.read` inside the payment client, which means a slow downstream with no proper timeout. Reading thread states is the first step in most "service is hanging" investigations.

#### Interview questions
?? What's the difference between calling start() and run()?
`start()` asks the JVM to create a new OS thread that then executes `run()`. Calling `run()` directly is an ordinary method call on the current thread, with no concurrency. Calling `start()` twice throws `IllegalThreadStateException`.

?? sleep() vs wait()?
`sleep` is a static method on `Thread`. It pauses the current thread and **keeps any locks** it holds. `wait` is a method on `Object`. It must be called while holding that object's monitor, **releases the lock**, and waits for `notify`/`notifyAll` (or a timeout). It's used for condition waiting.

?? How do you stop a thread?
Never use `Thread.stop()` (deprecated and unsafe: it releases locks mid-update, leaving objects corrupted). Use cooperative cancellation: check `Thread.currentThread().isInterrupted()` or a `volatile boolean running` flag in the loop, and call `interrupt()` to wake blocking calls. With executors, use `future.cancel(true)` or `shutdownNow()`, which interrupt.

#### Tricky questions
?? What happens if you catch InterruptedException and do nothing?
The interrupt status is cleared, so code higher up (like an executor trying to shut down) never learns the thread was asked to stop. Shutdown hangs and cancellation breaks. Always restore it with `Thread.currentThread().interrupt()` or rethrow.

?? Can a thread be in BLOCKED state while waiting for a ReentrantLock?
No. Threads waiting on `ReentrantLock` are parked via `LockSupport.park`, so they show as `WAITING`/`TIMED_WAITING`. `BLOCKED` is only for intrinsic `synchronized` monitors. It's a useful detail when reading thread dumps.

#### Interview simulation
**Interviewer:** "Your service hangs. How do you investigate?"

**Clarify:** "Is it fully hung or just slow? Is CPU high or low? Does it affect all endpoints or one?"

**Answer flow:** Take 3 thread dumps about 5 seconds apart (`jstack`, `jcmd <pid> Thread.print`). Look for: many threads `BLOCKED` on the same monitor (lock contention), threads stuck in socket reads (missing timeouts), the deadlock section (jstack detects monitor deadlocks automatically), and an exhausted pool (all workers busy, queue growing). High CPU suggests an infinite loop or GC, so check `top -H` for the hot thread ID, convert it to hex, and find it in the dump. Low CPU suggests waiting on I/O or locks.

### synchronized, monitors and wait/notify

#### Core idea
Every Java object has an intrinsic lock (a **monitor**). `synchronized` gives **mutual exclusion** (one thread at a time in the critical section) and **visibility** (changes made inside are visible to the next thread that acquires the same lock).

#### How it works
- `synchronized` instance method: locks `this`. `static synchronized`: locks the `Class` object. `synchronized (obj) { … }`: locks `obj`.
- **Reentrant**: a thread holding a lock can re-acquire it (its hold count increments), so recursive calls don't self-deadlock.
- **Memory semantics**: releasing a monitor *happens-before* every subsequent acquire of the same monitor. Writes before the unlock are visible after the lock.
- Lock implementation: the JVM uses a lightweight lock (CAS on the object header's mark word) and inflates to a heavyweight OS-backed monitor under contention. (Biased locking was deprecated in 15 and removed in 18.)
- **wait/notify** (must be called while holding the monitor, else `IllegalMonitorStateException`):

```java
class BoundedBuffer<T> {
    private final Queue<T> q = new ArrayDeque<>(); private final int cap;
    BoundedBuffer(int cap) { this.cap = cap; }
    public synchronized void put(T x) throws InterruptedException {
        while (q.size() == cap) wait();        // ALWAYS a while loop (spurious wakeups + re-check)
        q.add(x); notifyAll();
    }
    public synchronized T take() throws InterruptedException {
        while (q.isEmpty()) wait();
        T x = q.poll(); notifyAll(); return x;
    }
}
```
- Why `while` not `if`: **spurious wakeups** are allowed by the spec, and with `notifyAll` another consumer may have taken the item first.
- `notify` wakes one arbitrary waiter. With mixed waiters (producers and consumers on one monitor) it can wake the wrong kind and stall. `notifyAll` is safer; `Condition` objects (next topic) let you keep separate wait sets.

#### Real-world example
Lazy init of a shared expensive resource (a connection to a legacy system) behind `synchronized`. In modern code most `synchronized`-plus-`wait/notify` is replaced by `java.util.concurrent` (BlockingQueue, CountDownLatch), but interviewers still ask you to write producer-consumer with wait/notify to test fundamentals.

#### Interview questions
?? What does synchronized guarantee beyond mutual exclusion?
**Visibility and ordering.** Unlock happens-before a later lock of the same monitor, so changes made under the lock are visible to the next holder, and writes can't be reordered across the lock boundaries. Without it, another thread might see stale values cached in registers or CPU caches.

?? Why must wait() be called inside a synchronized block?
To avoid a lost-wakeup race. Checking the condition and going to sleep must be atomic with respect to the notifier. Holding the monitor guarantees nobody can change the condition and call notify between your check and your `wait()`. The JVM enforces it with `IllegalMonitorStateException`.

?? Can two threads execute two different synchronized methods of the same object at once?
No. Both lock `this`. A synchronized instance method and a **static** synchronized method can, though, because they use different locks (`this` vs `Class`).

#### Tricky questions
?? Is synchronizing on a String literal or a boxed Integer a good idea?
No. String literals are interned and shared JVM-wide, and small Integers are cached, so unrelated code may lock the same object, causing surprising contention or deadlocks. Lock on a `private final Object lock = new Object()`.

?? Does synchronized on a non-final field work?
If the field is reassigned, threads may lock different objects and there's no exclusion. Lock objects must be final.

#### Interview simulation
**Interviewer:** "Print numbers 1 to N alternately from two threads: odd and even."

**Clarify:** "Exactly two threads? Strictly alternating output? And what is N?"

**Answer:**
```java
class OddEven {
    private int n = 1; private final int max; private final Object lock = new Object();
    OddEven(int max) { this.max = max; }
    void run(boolean odd) {
        synchronized (lock) {
            while (n <= max) {
                if ((n % 2 == 1) == odd) { System.out.println(Thread.currentThread().getName() + " " + n++); lock.notifyAll(); }
                else try { lock.wait(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
            }
            lock.notifyAll();   // let the other thread exit
        }
    }
}
// new Thread(() -> p.run(true), "odd").start(); new Thread(() -> p.run(false), "even").start();
```
Narrate the while-loop re-check, why it's `notifyAll`, and the final `notifyAll` that prevents the other thread from waiting forever. Offer the `Semaphore` version as an alternative.

### Java Memory Model, volatile and happens-before

#### Core idea
CPUs and compilers **reorder** instructions and **cache** values for speed. The **Java Memory Model (JMM)** defines when a write by one thread is guaranteed to be visible to another. The key relation is **happens-before**: if A happens-before B, then A's effects are visible to B.

#### How it works
**Happens-before rules (the important ones):**
1. Program order: each action in a thread happens-before later actions in that thread.
2. Monitor: unlocking happens-before every later lock of the same monitor.
3. **volatile**: a write to a volatile field happens-before every later read of that field.
4. Thread start: `t.start()` happens-before anything in `t`. Join: everything in `t` happens-before `t.join()` returns.
5. Transitivity: if A hb B and B hb C, then A hb C.
6. Final fields: values set in the constructor are visible after construction (if `this` didn't escape).
7. `java.util.concurrent`: putting into a concurrent collection, or submitting to an executor, happens-before the corresponding take or execution.

**volatile**
- Guarantees **visibility** (reads see the latest write) and **ordering** (it prevents reordering around it: a release/acquire fence).
- Does **not** guarantee **atomicity** of compound actions: `count++` on a volatile is still a race (read, add, write).
- Good for: status flags, one-writer/many-reader values, and safe publication (double-checked locking).

```java
class Worker implements Runnable {
    private volatile boolean running = true;     // without volatile the loop may never see false
    public void stop() { running = false; }
    public void run() { while (running) doWork(); }
}
```

**Double-checked locking (correct form)**
```java
private static volatile Config instance;
static Config get() {
    Config c = instance;
    if (c == null) {
        synchronized (Config.class) {
            c = instance;
            if (c == null) instance = c = new Config();
        }
    }
    return c;
}
```
Without `volatile`, `instance = new Config()` can be reordered as allocate → publish the reference → run the constructor, so another thread sees a non-null **half-constructed** object.

#### Real-world example
A config hot-reload: a background thread loads new settings and assigns them to a `volatile Settings current` field. Request threads read `current` without locks. Because `Settings` is immutable and the reference is volatile, readers always see a fully built old or new object, never a mix. (`AtomicReference` gives the same guarantee plus CAS.)

#### Interview questions
?? What is the difference between volatile and synchronized?
`volatile` gives visibility and ordering for a single variable, with no locking and no atomicity for compound operations. `synchronized` gives mutual exclusion **and** visibility for everything inside the block, at the cost of blocking. Use volatile for flags and published references; use locks or atomics for read-modify-write.

?? Is `volatile int count; count++` thread-safe?
No. `count++` is three steps (read, increment, write). Two threads can read the same value and both write value+1. Use `AtomicInteger.incrementAndGet()` or `LongAdder`.

?? What is "safe publication"?
Making an object visible to other threads such that they see its fully constructed state. The ways to do it: initialise from a static initialiser; store it in a volatile field or `AtomicReference`; store it in a final field of a properly constructed object; or store it in a field guarded by a lock, or in a concurrent collection.

#### Tricky questions
?? Why might this loop never terminate even though another thread sets `stop = true` (non-volatile)?
```java
while (!stop) { }  // stop is a plain boolean
```
The JIT can hoist the read out of the loop (`if (!stop) while(true){}`) since nothing in the loop changes `stop` from this thread's point of view. Without a happens-before edge, the other thread's write may never be observed. Make it volatile.

?? Are reads and writes of `long` and `double` atomic?
Not guaranteed for non-volatile 64-bit values: the JLS allows "word tearing" into two 32-bit writes. Declaring them `volatile` makes them atomic. On modern 64-bit JVMs they're atomic in practice, but the spec only guarantees it for volatile.

#### Interview simulation
**Interviewer:** "Explain volatile with a scenario where it's needed and one where it's insufficient."

**Answer:** Needed: the stop flag polled by a worker thread (visibility). Insufficient: a counter incremented by many threads (atomicity), so use `AtomicInteger` or `LongAdder`. Then explain happens-before in one sentence and mention double-checked locking as the classic pattern requiring volatile. The scenario-based structure is what scores here.

### Locks: ReentrantLock, ReadWriteLock, StampedLock

#### Core idea
`java.util.concurrent.locks` provides explicit locks with features `synchronized` lacks: **tryLock with timeout**, **interruptible** acquisition, **fairness**, **multiple condition variables**, and **read/write separation**.

#### How it works
**ReentrantLock**
```java
private final ReentrantLock lock = new ReentrantLock();
void transfer() {
    if (!lock.tryLock(200, TimeUnit.MILLISECONDS)) throw new BusyException();
    try { /* critical section */ }
    finally { lock.unlock(); }         // ALWAYS in finally
}
```
- Built on `AbstractQueuedSynchronizer` (AQS): an `int state` plus a FIFO queue of parked threads, using CAS on state to acquire.
- `new ReentrantLock(true)` is **fair** (FIFO, no barging), but has much lower throughput. The default is unfair (barging allowed, faster).
- `lockInterruptibly()` lets a waiting thread be cancelled.
- **Conditions**: `Condition notFull = lock.newCondition(), notEmpty = lock.newCondition();` give separate wait sets (better than `notifyAll` on one monitor). This is how `ArrayBlockingQueue` is built.

**ReentrantReadWriteLock**
- Many readers **or** one writer. Good when reads dominate and the critical section is non-trivial.
- A write lock can be downgraded to a read lock (acquire read, then release write); **upgrading read → write deadlocks**.
- It can starve writers under constant reads (unfair mode), and it carries overhead: for tiny critical sections a plain lock is often faster.

**StampedLock** (Java 8)
- Adds **optimistic reads**: get a stamp without locking, read the fields, then `validate(stamp)`. If a write happened, retry with a real read lock. Very fast for read-mostly data.
- It's **not reentrant** and has no conditions, so it's easy to misuse.

```java
double distanceFromOrigin() {
    long stamp = sl.tryOptimisticRead();
    double cx = x, cy = y;
    if (!sl.validate(stamp)) {
        stamp = sl.readLock();
        try { cx = x; cy = y; } finally { sl.unlockRead(stamp); }
    }
    return Math.hypot(cx, cy);
}
```

#### Real-world example
An in-memory catalogue or pricing snapshot read by thousands of requests per second and refreshed every 5 minutes: a `ReadWriteLock`, or better, an immutable snapshot swapped through a `volatile` or `AtomicReference` (no lock on reads at all). For the "max N concurrent jobs" type of limit, use a `Semaphore`, not a lock.

#### Interview questions
?? ReentrantLock vs synchronized: when do you use which?
`synchronized` is simpler, can't be forgotten in an unlock, and the JVM optimises it well. Use `ReentrantLock` when you need tryLock/timeouts (deadlock avoidance), interruptible waiting, fairness, multiple conditions, or (on Java 21) to avoid virtual-thread pinning around blocking I/O. Always `unlock()` in `finally`.

?? What is lock fairness and its trade-off?
A fair lock grants access in arrival order, preventing starvation, but every handoff requires waking the next queued thread (a context switch), so throughput can be an order of magnitude lower. Unfair locks let a running thread "barge" in, which is better for throughput.

#### Tricky questions
?? Can a ReadWriteLock deadlock a single thread?
Yes. Holding the read lock and requesting the write lock (an upgrade) blocks forever, because the write lock waits for all readers, including yourself.

?? Why does ReentrantLock need `unlock()` in finally but synchronized doesn't?
`synchronized` is block-structured: the JVM releases the monitor on any exit, including exceptions. An explicit lock is just a method call, so an exception between `lock()` and `unlock()` would leave it held forever.

#### Interview simulation
**Interviewer:** "Thousands of reads and occasional updates to a shared config map. How do you make it thread-safe?"

**Clarify:** "How often do updates happen? Do readers need the whole map to be consistent, or just individual keys? How big is the map?"

**Answer ladder:** (1) Infrequent updates and whole-map consistency: immutable `Map.copyOf` snapshots swapped through `volatile`/`AtomicReference` (copy-on-write), giving lock-free reads. (2) Frequent per-key updates: `ConcurrentHashMap`. (3) Complex multi-field invariants with heavy reads: `ReadWriteLock` or `StampedLock` optimistic reads. Explain why (1) is usually best and simplest.

### Atomic variables and CAS

#### Core idea
**CAS (compare-and-swap)** is a CPU instruction (`LOCK CMPXCHG` on x86): "if the value at address X is still A, set it to B; tell me whether it worked." Atomic classes build **lock-free** thread-safe operations on top of it.

#### How it works
- `AtomicInteger`, `AtomicLong`, `AtomicBoolean`, `AtomicReference<V>`, plus array variants.
- `incrementAndGet()` is a CAS loop: read the current value, compute the new one, CAS, retry on failure. Since Java 8 the JIT turns `getAndAdd` into a single `LOCK XADD` instruction.
- `updateAndGet(fn)` and `accumulateAndGet(x, fn)` take a function that may be called **multiple times** on contention, so it must be side-effect free.
- **ABA problem**: a value changes A→B→A between your read and your CAS, so the CAS succeeds though the state changed. It matters for lock-free stacks and pointer reuse. Fix it with `AtomicStampedReference` (a version stamp).
- **LongAdder**: under heavy contention, a single `AtomicLong` makes all threads fight over one cache line. `LongAdder` keeps a base value plus an array of cells (threads hash to different cells) and `sum()` adds them up. It's far better for **counters/metrics with many writers and rare reads**, but `sum()` isn't an atomic snapshot.
- `VarHandle` (Java 9) is the low-level API underneath (CAS, acquire/release modes) that replaced `sun.misc.Unsafe`.

```java
AtomicReference<Config> cfg = new AtomicReference<>(initial);
cfg.updateAndGet(old -> old.withTimeout(500));        // lock-free immutable update
LongAdder requests = new LongAdder(); requests.increment(); long total = requests.sum();
```

#### Real-world example
Micrometer counters and Caffeine statistics use `LongAdder`-style striped counters. A rate limiter's token bucket can be lock-free with `AtomicLong` holding packed state and a CAS loop. A "has this job already started?" guard is `if (started.compareAndSet(false, true)) run();`, so exactly one thread wins.

#### Interview questions
?? What is CAS and why is it better than locking in some cases?
CAS updates a variable atomically without blocking. Losers retry instead of sleeping. With low to moderate contention it avoids context switches and deadlocks, and it can't suffer priority inversion. Under very high contention, retries burn CPU; striping (`LongAdder`) or locks can then be better.

?? AtomicLong vs LongAdder?
`AtomicLong`: one value, exact reads, CAS operations available. Best for sequence numbers or when you need `compareAndSet`. `LongAdder`: striped cells, much higher write throughput under contention, but reads are sums and no CAS. Best for statistics counters.

#### Tricky questions
?? Is `if (atomic.get() == 0) atomic.set(1);` atomic?
No. It's check-then-act across two operations. Use `atomic.compareAndSet(0, 1)`.

?? Explain the ABA problem with a concrete example.
In a lock-free stack, thread 1 reads top=A (next=B) and is preempted. Thread 2 pops A, pops B, then pushes A back. Thread 1's CAS(top, A → B) succeeds because top is A again, but B was removed, so the stack is corrupted. A version stamp detects that A was replaced.

#### Interview simulation
**Interviewer:** "Implement a thread-safe counter that's hit by 64 threads millions of times per second."

**Answer:** Start with `synchronized` (correct but slow), then `AtomicLong` (lock-free, but cache-line contention), then `LongAdder` (striped, scales). Mention that `sum()` is eventually consistent, which is fine for metrics. This progression shows understanding rather than recall.

### ExecutorService and thread pools

#### Core idea
Creating a thread per task is expensive and unbounded. A **thread pool** reuses a fixed set of threads to run tasks from a queue. `ExecutorService` is Java's abstraction for submitting tasks and managing their lifecycle.

#### How it works
**ThreadPoolExecutor parameters**: the most-asked concurrency question.
```java
new ThreadPoolExecutor(
    corePoolSize,      // threads kept alive even when idle
    maximumPoolSize,   // upper limit
    keepAliveTime, unit, // idle time before non-core threads die
    workQueue,         // where tasks wait
    threadFactory,     // name threads! ("payment-worker-%d")
    rejectionHandler); // what to do when saturated
```
**Task admission order:**
1. If running threads < core: start a new thread.
2. Otherwise **queue** the task.
3. If the queue is full and threads < max: start a non-core thread.
4. If the queue is full and threads = max: **reject**.

So with an **unbounded queue** (`LinkedBlockingQueue()`), the pool never grows past core and **never rejects**: tasks pile up until OOM. That's exactly what `Executors.newFixedThreadPool(n)` creates.

**Rejection policies**: `AbortPolicy` (throws, the default), `CallerRunsPolicy` (the submitting thread runs it, which is natural backpressure), `DiscardPolicy`, and `DiscardOldestPolicy`.

**Executors factory pitfalls**
| Factory | Queue / max | Risk |
|---|---|---|
| `newFixedThreadPool(n)` | unbounded LinkedBlockingQueue | queue grows to OOM |
| `newCachedThreadPool()` | SynchronousQueue, max = Integer.MAX_VALUE | thread explosion |
| `newSingleThreadExecutor()` | unbounded | same as fixed |
| `newScheduledThreadPool(n)` | delay heap | — |
| `newVirtualThreadPerTaskExecutor()` | none (a virtual thread per task) | limit downstream concurrency yourself |

**Sizing (Brian Goetz's formula)**: `threads = cores × targetUtilisation × (1 + waitTime/computeTime)`.
- CPU-bound: about `cores` (or cores + 1).
- I/O-bound: for example 8 cores with 90ms waiting per 10ms of compute gives 8 × (1 + 9) = **80 threads**. Then validate with load tests, and remember downstream limits (DB pool size).

**Shutdown**: `shutdown()` stops accepting tasks and finishes the queued ones. `awaitTermination(t)` waits. `shutdownNow()` interrupts running tasks and returns the queued ones. In Java 19+, `ExecutorService` is `AutoCloseable` (try-with-resources).

#### Real-world example
At Tata 1mg-style search, the parallel enrichment calls (price, stock, offers) used a dedicated bounded pool: core=max=32 (sized from about 4ms CPU and about 40ms I/O per call on 4 cores, then load-tested), `ArrayBlockingQueue(500)`, `CallerRunsPolicy`, and named threads `search-enrich-%d`. Using the common ForkJoinPool instead would have let a slow downstream starve unrelated async work.

#### Interview questions
?? Explain how ThreadPoolExecutor decides between creating a thread, queuing, and rejecting.
Core threads first, then the queue, then extra threads up to max, then rejection. The unintuitive part: extra threads beyond core are created **only when the queue is full**. So a large or unbounded queue means you effectively never exceed core size.

?? Why is `Executors.newFixedThreadPool` discouraged in production?
It uses an unbounded queue. Under a traffic spike or a slow downstream, tasks accumulate without limit, latency explodes, and memory runs out, with no rejection to signal overload. Use an explicit `ThreadPoolExecutor` with a bounded queue and a rejection policy, plus metrics on queue size.

?? How do you size a thread pool for I/O-bound tasks?
Use the wait/compute ratio formula as a starting point, bounded by downstream capacity (DB connections, rate limits), then load-test while watching latency percentiles and queue depth. Name your threads and export pool metrics.

#### Tricky questions
?? You submit a task with `submit()` and it throws. Where does the exception go?
It's captured in the `Future`. It surfaces only as an `ExecutionException` from `future.get()`. If nobody calls `get()`, it vanishes silently. With `execute()` it goes to the `UncaughtExceptionHandler`.

?? Can a thread pool deadlock with itself?
Yes: **thread starvation deadlock**. Tasks in a bounded pool submit subtasks to the *same* pool and block waiting on them. If all threads are waiting, the subtasks never run. Use separate pools per stage, or `ForkJoinPool`, which is designed for nested waits (work stealing).

?? What does CallerRunsPolicy do to an HTTP request thread?
It makes the Tomcat thread run the task itself. That provides backpressure (it slows intake), but it also increases that request's latency and can tie up request threads. It's often acceptable, but it's a trade-off to state explicitly.

#### Interview simulation
**Interviewer:** "Design the thread pool for a service that calls three downstream APIs per request."

**Clarify first:** "What's the peak RPS? What latency do the downstreams have (p50/p99) and what are their rate limits? What's our latency SLO? Is the Java version 21+?"

**Answer flow:** Calculate concurrency with Little's Law (concurrency = RPS × latency, e.g. 500 rps × 3 calls × 0.08s = 120 in-flight calls). Choose a bounded pool of about 120–150 with a bounded queue (about 2× pool) and `AbortPolicy` mapped to 503, or `CallerRunsPolicy` for backpressure. Use per-downstream bulkheads so one slow API can't take all the threads. Add timeouts shorter than the SLO and metrics (active threads, queue depth, rejections). Alternative on Java 21: virtual threads plus a per-downstream `Semaphore`.

### CompletableFuture

#### Core idea
`CompletableFuture<T>` represents an asynchronous result you can **compose**: chain transformations, combine several futures, and handle errors without blocking threads while waiting.

#### How it works
```java
ExecutorService io = ...; // dedicated pool for blocking I/O

CompletableFuture<Price> price = CompletableFuture.supplyAsync(() -> pricing.get(sku), io);
CompletableFuture<Stock> stock = CompletableFuture.supplyAsync(() -> inventory.get(sku), io);
CompletableFuture<Offer> offer = CompletableFuture.supplyAsync(() -> offers.get(sku), io)
        .completeOnTimeout(Offer.NONE, 80, TimeUnit.MILLISECONDS);   // degrade gracefully

CompletableFuture<ProductView> view = price.thenCombine(stock, Pair::of)
        .thenCombine(offer, (ps, o) -> new ProductView(ps.first(), ps.second(), o))
        .orTimeout(200, TimeUnit.MILLISECONDS)
        .exceptionally(ex -> ProductView.fallback(sku));
```
| Method | Use |
|---|---|
| `supplyAsync / runAsync` | start async work (**pass your executor!**) |
| `thenApply(f)` | transform the result (like `map`) |
| `thenCompose(f)` | chain another async call (like `flatMap`, avoids nested futures) |
| `thenCombine(other, f)` | combine two independent results |
| `allOf(...)` / `anyOf(...)` | wait for all or any |
| `exceptionally(f)` | recover from an error |
| `handle((r, ex) -> …)` | handle both success and failure |
| `whenComplete` | side effect (e.g. logging), result unchanged |
| `orTimeout` / `completeOnTimeout` | Java 9 timeouts |
| `join()` vs `get()` | `join` throws an unchecked `CompletionException`; `get` throws checked exceptions |

- **Which thread runs `thenApply`?** If the future is already complete, the *calling* thread runs it; otherwise the thread that completes the future does. The `*Async` variants run on the given executor (or the common pool).
- **Default executor** is `ForkJoinPool.commonPool()`, which is sized for CPU work. **Never** run blocking I/O there.
- Exceptions are wrapped in `CompletionException`; unwrap with `ex.getCause()`.
- `cancel(true)` does **not** interrupt the underlying task; it only completes the future exceptionally.

#### Real-world example
This is exactly your resume line: "cut medicine search API latency by 40% using CompletableFuture." The likely story: the search endpoint called price, inventory and offers **sequentially** (≈ 40 + 50 + 30 = 120ms). Making them parallel with `supplyAsync` on a dedicated pool and combining them with `allOf`/`thenCombine` made latency the **max** of the three (≈ 50ms), plus `completeOnTimeout` so a slow offers service degrades instead of failing. Be ready to whiteboard this.

#### Interview questions
?? thenApply vs thenCompose?
`thenApply` takes a function returning a plain value: `CF<T> → CF<U>`. `thenCompose` takes a function returning a `CompletableFuture`, and flattens it: `CF<T> → CF<U>` instead of `CF<CF<U>>`. Use `thenCompose` when the next step is itself async (fetch the user, then fetch their orders).

?? How do you wait for a list of futures and collect their results?
```java
CompletableFuture<Void> all = CompletableFuture.allOf(fs.toArray(new CompletableFuture[0]));
CompletableFuture<List<T>> results = all.thenApply(v -> fs.stream().map(CompletableFuture::join).toList());
```
`allOf` returns `Void`, so you join each future afterwards (they're all already done, so nothing blocks).

?? What happens to exceptions in a CompletableFuture chain?
They skip subsequent `thenApply`/`thenAccept` stages and propagate to the first `exceptionally`, `handle` or `whenComplete`, or to `join()`/`get()`. If nobody handles them or calls join, they're silently lost, so always end chains with handling or logging.

#### Tricky questions
?? Why did using supplyAsync without an executor slow down unrelated parts of the app?
It defaults to the common ForkJoinPool (cores − 1 threads), which is shared by parallel streams and other async code. Blocking I/O tasks occupy those few threads, so everything else queues behind them. Always pass a dedicated executor for blocking work.

?? Does `future.cancel(true)` stop the HTTP call running inside supplyAsync?
No. CompletableFuture has no link to the executing thread. Cancellation just completes the future with `CancellationException`. Use HTTP client timeouts, or an interruptible task with a plain `Future` from an executor.

?? `allOf` completes exceptionally if one future fails. Do the others stop?
No. They keep running. `allOf` just reports failure once all have completed. For fail-fast, you'd have to cancel the others manually (which, again, doesn't interrupt them).

#### Interview simulation
**Interviewer:** "Your resume says you cut latency by 40% with CompletableFuture. Walk me through it."

**Prepare this answer cold:**
1. **Problem**: "Medicine search did 3–4 sequential downstream calls for enrichment; p95 was about X ms."
2. **Diagnosis**: "Tracing showed most time was waiting on I/O, with the calls independent of each other."
3. **Change**: "Parallelised them with `supplyAsync` on a dedicated bounded pool, combined with `allOf`, added per-call timeouts with fallbacks via `completeOnTimeout`, and propagated the MDC trace ID into the pool threads."
4. **Pitfalls handled**: "No common pool; pool sized from measured latency; exceptions mapped so a non-critical service failure didn't fail search."
5. **Result**: "p95 dropped about 40%, measured over a week of production traffic via Grafana."
6. **What I'd do differently**: "On Java 21, virtual threads with structured concurrency would simplify it."

Have real numbers ready. Interviewers always ask "how did you measure it?"

### Synchronizers: CountDownLatch, CyclicBarrier, Semaphore, Phaser

#### Core idea
Higher-level coordination tools from `java.util.concurrent`, so you rarely need `wait/notify`:
- **CountDownLatch**: wait until N events have happened. One-shot.
- **CyclicBarrier**: N threads wait for each other at a point, then all proceed. Reusable.
- **Semaphore**: limit how many threads access a resource at once (N permits).
- **Phaser**: a flexible, reusable barrier with a dynamic number of parties.

#### How it works
```java
// CountDownLatch: main waits for 3 services to warm up
CountDownLatch ready = new CountDownLatch(3);
services.forEach(s -> exec.submit(() -> { s.warmUp(); ready.countDown(); }));
if (!ready.await(30, TimeUnit.SECONDS)) throw new IllegalStateException("warm-up timeout");

// CyclicBarrier: 4 workers compute a chunk, then merge, repeat
CyclicBarrier barrier = new CyclicBarrier(4, () -> mergePartialResults());   // barrier action
// each worker: computeChunk(); barrier.await();

// Semaphore: at most 10 concurrent calls to a rate-limited partner API
Semaphore permits = new Semaphore(10);
if (!permits.tryAcquire(100, TimeUnit.MILLISECONDS)) throw new TooBusyException();
try { partnerApi.call(); } finally { permits.release(); }
```
| | CountDownLatch | CyclicBarrier | Semaphore |
|---|---|---|---|
| Who waits | one or more waiters for N events | N parties for each other | threads for a permit |
| Reusable | No | Yes (resets after tripping) | Yes |
| Count changes | down only | fixed parties | acquire/release |
| Failure | — | a broken barrier if one party is interrupted or times out | — |

Semaphore permits aren't tied to threads: any thread can release (unlike a lock). That's useful, but it makes over-releasing a bug.

#### Real-world example
- **Semaphore**: a bulkhead around a third-party SMS gateway that allows only 20 concurrent connections. Resilience4j's `SemaphoreBulkhead` is exactly this.
- **CountDownLatch**: integration tests that wait until a Kafka consumer has processed N messages before asserting.
- **CyclicBarrier**: load-test tools releasing N simulated users at the same instant.

#### Interview questions
?? CountDownLatch vs CyclicBarrier?
A latch is one-shot. Some threads wait for a count to reach zero, and the counting threads don't wait. A barrier is reusable: all N threads wait for each other, then proceed together, with an optional barrier action. "Wait for events" means a latch; "rendezvous of peers" means a barrier.

?? How would you limit concurrent access to a resource to 5 threads?
`Semaphore(5)`: `acquire()` before use and `release()` in `finally`. Use `tryAcquire(timeout)` to fail fast instead of piling up waiters.

#### Tricky questions
?? What happens if a thread waiting at a CyclicBarrier is interrupted?
The barrier becomes **broken**. The interrupted thread gets `InterruptedException` and all other waiting threads get `BrokenBarrierException`. You must `reset()` it before reuse.

?? Is a Semaphore with 1 permit the same as a lock?
It gives mutual exclusion, but it's **not reentrant** (the same thread acquiring twice deadlocks) and has no ownership (another thread can release it). A lock is safer for mutual exclusion. A binary semaphore suits signalling between threads.

#### Interview simulation
**Interviewer:** "Start 10 worker threads, but make sure they all start processing at exactly the same moment, and the main thread knows when they've all finished."

**Answer:** Two latches. `startSignal = new CountDownLatch(1)`: each worker awaits it, and main counts it down once all are created. `doneSignal = new CountDownLatch(10)`: each worker counts down when finished, and main awaits it. That's the Javadoc's canonical example, so state it confidently.

### BlockingQueue and producer-consumer

#### Core idea
A `BlockingQueue` is a thread-safe queue where `put` **blocks when full** and `take` **blocks when empty**. It's the standard way to hand work between threads (producer-consumer), and it provides **backpressure** for free.

#### How it works
| Method family | Full/empty behaviour |
|---|---|
| `add` / `remove` | throw an exception |
| `offer` / `poll` | return false / null immediately |
| `offer(e, t)` / `poll(t)` | wait up to a timeout |
| `put` / `take` | block indefinitely |

Implementations:
- `ArrayBlockingQueue`: bounded array, a **single lock** with two conditions. Predictable memory.
- `LinkedBlockingQueue`: optionally bounded (**unbounded by default!**), with **two locks** (put lock, take lock), so producers and consumers don't contend. Higher throughput.
- `SynchronousQueue`: capacity zero, each put waits for a take (a direct handoff). Used by `newCachedThreadPool`.
- `PriorityBlockingQueue`: unbounded heap. `DelayQueue`: elements become available after a delay.
- `LinkedTransferQueue`: the producer can wait until a consumer receives the item.

```java
BlockingQueue<Event> q = new ArrayBlockingQueue<>(10_000);
// producer (e.g. HTTP thread)
if (!q.offer(evt, 5, TimeUnit.MILLISECONDS)) metrics.dropped.increment();   // never block request threads forever
// consumer
while (!Thread.currentThread().isInterrupted()) {
    Event e = q.take();
    List<Event> batch = new ArrayList<>(); batch.add(e); q.drainTo(batch, 499);   // batch for efficiency
    sink.write(batch);
}
// shutdown: interrupt consumer, or put a "poison pill" sentinel event
```

#### Real-world example
Async audit logging or analytics events: request threads drop events into a bounded queue, and a background consumer batches them into Kafka or a DB every 500 items or 100ms. Logback's `AsyncAppender` works this way (it drops lower-level logs when the queue is 80% full). Kafka's producer also buffers records in memory batches, a similar idea.

#### Interview questions
?? Why use a bounded queue?
An unbounded queue hides overload: if producers outpace consumers, memory grows until OOM and latency becomes huge. A bounded queue forces a decision when full (block, drop, reject or caller-runs), which is **backpressure**.

?? How do you gracefully stop a consumer thread?
Either interrupt it (`take()` throws `InterruptedException`, and the loop exits), or enqueue a **poison pill** sentinel object that tells the consumer to stop after draining the earlier items. The poison pill guarantees all previously queued items are processed.

#### Tricky questions
?? ArrayBlockingQueue vs LinkedBlockingQueue performance?
LBQ uses separate put and take locks, so a producer and a consumer can proceed concurrently, which usually gives higher throughput. But it allocates a node per element (GC pressure). ABQ uses one lock and no per-element allocation, so memory and latency are more predictable. Benchmark for your case.

#### Interview simulation
**Interviewer:** "Implement producer-consumer."

**Clarify:** "May I use `java.util.concurrent`, or do you want it from scratch with wait/notify or locks? How many producers and consumers? Is the buffer bounded?"

Provide the BlockingQueue version first (30 seconds), then the `ReentrantLock` + two `Condition`s version if asked from scratch:
```java
final Lock lock = new ReentrantLock(); final Condition notFull = lock.newCondition(), notEmpty = lock.newCondition();
void put(T x) throws InterruptedException {
    lock.lock(); try { while (q.size() == cap) notFull.await(); q.add(x); notEmpty.signal(); } finally { lock.unlock(); }
}
T take() throws InterruptedException {
    lock.lock(); try { while (q.isEmpty()) notEmpty.await(); T x = q.poll(); notFull.signal(); return x; } finally { lock.unlock(); }
}
```
Point out that two conditions allow `signal()` instead of `signalAll()`, because only the right kind of thread is woken.

### Deadlock, livelock and starvation

#### Core idea
- **Deadlock**: threads wait for each other forever (each holds a resource the other needs).
- **Livelock**: threads keep changing state in response to each other but make no progress (like two people stepping aside in the same direction repeatedly).
- **Starvation**: a thread never gets the resource because others keep winning (unfair locks, priorities, a long-running greedy thread).

#### How it works
**Coffman conditions**: deadlock requires all four:
1. Mutual exclusion.
2. Hold and wait.
3. No preemption.
4. Circular wait.

Break any one and deadlock is impossible.

**Classic Java deadlock:**
```java
void transfer(Account from, Account to, long amt) {
    synchronized (from) { synchronized (to) { from.debit(amt); to.credit(amt); } }
}
// Thread 1: transfer(A, B)   Thread 2: transfer(B, A) → each holds one lock, waits for the other
```
**Prevention strategies:**
- **Lock ordering** (breaks circular wait): always lock the account with the smaller id first.
- **tryLock with timeout** (breaks hold-and-wait): back off and retry with random jitter to avoid livelock.
- **Single lock / coarser granularity**: simpler, but less concurrency.
- **Avoid calling alien methods while holding a lock** (callbacks, listeners, remote calls).

```java
void transfer(Account a, Account b, long amt) {
    Account first = a.id() < b.id() ? a : b, second = first == a ? b : a;
    synchronized (first) { synchronized (second) { a.debit(amt); b.credit(amt); } }
}
```
**Detection**: `jstack` prints "Found one Java-level deadlock" for monitors and ReentrantLocks. Programmatically, `ThreadMXBean.findDeadlockedThreads()`.

**Database deadlocks** follow the same theory. Two transactions update rows in opposite order; the DB detects the cycle and aborts one (Postgres: `deadlock detected`). Fix: update rows in a consistent order (e.g. `ORDER BY id` in `SELECT … FOR UPDATE`), keep transactions short, and retry the victim.

#### Real-world example
A wallet service doing peer-to-peer transfers hit Postgres deadlocks under load when two users paid each other simultaneously (A→B and B→A). The fix was locking both wallet rows in **ascending wallet_id order** with `SELECT … FOR UPDATE`, plus a retry on serialization or deadlock errors.

#### Interview questions
?? How do you prevent deadlocks?
Enforce a global lock ordering; use `tryLock` with a timeout and back off; hold locks for the shortest time; never call external code (I/O, callbacks) while holding locks; prefer higher-level concurrency utilities and immutable data. For DBs: consistent row-lock ordering and short transactions.

?? How would you detect a deadlock in production?
Thread dumps (`jstack`/`jcmd Thread.print`, or the Actuator threaddump endpoint) show the cycle explicitly. Monitoring can call `ThreadMXBean.findDeadlockedThreads()` periodically. Symptoms: requests hang and CPU stays low.

#### Tricky questions
?? Can deadlock happen with a single lock?
With non-reentrant locks, yes: a thread re-acquiring a lock it holds (a `Semaphore(1)` or `StampedLock`) blocks on itself. Also, a thread can wait forever on a condition that is never signalled. That's a hang, though technically not a lock cycle.

?? How does tryLock with random backoff avoid livelock?
If both threads back off for the same fixed time, they collide again and again (livelock). Random jitter makes it likely that one of them retries first and succeeds.

#### Interview simulation
**Interviewer:** "Write a money transfer between two accounts that's thread-safe and deadlock-free."

**Clarify:** "Is it in-memory or database-backed? Can the same account appear on both sides? Do we need overdraft checks?"

**Answer:** The lock-ordering code above (handle `a == b` by rejecting it), a balance check inside the locks, and amounts in `long` paise. Then lift it to the DB version: one transaction, `SELECT … FOR UPDATE` on both rows ordered by id, check the balance, update both, commit, with retries on deadlock (SQLSTATE 40P01). An alternative is a single atomic `UPDATE … SET balance = balance - ? WHERE id = ? AND balance >= ?`, checking the affected row count. That shows both in-memory and production thinking.

### ThreadLocal

#### Core idea
`ThreadLocal<T>` gives **each thread its own independent copy** of a variable. It's useful for per-thread context (request ID, user, transaction) and for non-thread-safe objects that are expensive to create (the old `SimpleDateFormat` case).

#### How it works
- Each `Thread` object has a `ThreadLocalMap`, keyed by the `ThreadLocal` instance (held through a **weak reference**) with the value held by a **strong reference**.
- `get()` looks up the current thread's map. There's no contention and no locks.
- **Memory leak risk**: in a thread **pool**, threads live forever. If you `set()` and never `remove()`, the value stays reachable from the pool thread forever. Worse, the next request on that thread **sees the previous request's value** (a data leak between users!). Always clear in `finally`:

```java
private static final ThreadLocal<RequestContext> CTX = new ThreadLocal<>();
try { CTX.set(ctx); chain.doFilter(req, res); }
finally { CTX.remove(); }
```
- With weak keys, if the `ThreadLocal` object itself is gone, its entry has a null key but a still strongly held value; it's cleaned up only lazily on later map operations.
- `InheritableThreadLocal` copies values to child threads at creation, but not to pooled threads reused later.
- **Async pitfall**: ThreadLocal values don't follow your task into `CompletableFuture` or executor threads. You must capture and restore them (e.g. a `TaskDecorator` in Spring, or MDC copy).

#### Real-world example
- **Spring** stores the current transaction (`TransactionSynchronizationManager`), the security context (`SecurityContextHolder`), and the request attributes (`RequestContextHolder`) in ThreadLocals. That's why `@Transactional` and `SecurityContextHolder.getContext()` don't work automatically inside `CompletableFuture.supplyAsync(...)`.
- **SLF4J MDC** (the trace ID in every log line) is ThreadLocal-based. When you parallelised the 1mg search with a custom executor, logs from pool threads lacked the trace ID until a decorator copied the MDC map.

#### Interview questions
?? What is a ThreadLocal memory leak and how do you avoid it?
In thread pools, threads outlive requests. A value set into a ThreadLocal stays referenced by the thread's map until removed, so large objects (or classloaders, in app servers) can't be garbage-collected, and stale values bleed into later requests. Always call `remove()` in `finally`, typically in a filter or interceptor.

?? Why doesn't SecurityContextHolder work inside an async task?
Its default strategy is a ThreadLocal on the request thread. The async task runs on a different thread with an empty context. Fixes: `DelegatingSecurityContextExecutor`, the `MODE_INHERITABLETHREADLOCAL` strategy (careful with pools), or pass the user explicitly.

#### Tricky questions
?? Are ThreadLocals a good idea with virtual threads?
They work, but with millions of virtual threads, per-thread copies of heavy objects multiply memory use, and caching expensive objects in ThreadLocals stops making sense when threads aren't reused. Java's `ScopedValue` is designed for immutable, bounded-lifetime context with virtual threads.

#### Interview simulation
If asked "How do you propagate a request ID across your service, including async calls and Kafka?": a filter reads or creates `X-Request-Id` and puts it in MDC; MDC is cleared in `finally`; a `TaskDecorator` on executors copies the MDC into pool threads; outbound HTTP calls add the header via an interceptor; Kafka producers put it in record headers and consumers restore it into MDC. In modern stacks, OpenTelemetry handles this context propagation automatically.

### Classic concurrency coding problems

#### Core idea
Interviewers often ask you to *write* concurrent code in 20–30 minutes. The most common: print alternately (odd/even, or "ABC" across 3 threads), a bounded blocking queue, a thread-safe singleton, a rate-limited executor, dining philosophers, and parallel sum or merge. The skills tested are correct waiting conditions, no lost wakeups, a clean shutdown, and explaining your choices.

#### How it works
**1. Three threads print A, B, C in order N times (Semaphore chain)**
```java
Semaphore a = new Semaphore(1), b = new Semaphore(0), c = new Semaphore(0);
Runnable pa = () -> { for (int i=0;i<N;i++){ a.acquireUninterruptibly(); System.out.print("A"); b.release(); } };
Runnable pb = () -> { for (int i=0;i<N;i++){ b.acquireUninterruptibly(); System.out.print("B"); c.release(); } };
Runnable pc = () -> { for (int i=0;i<N;i++){ c.acquireUninterruptibly(); System.out.print("C"); a.release(); } };
```
**2. Thread-safe singleton**: prefer, in order: an **enum singleton** (serialisation and reflection-safe), the **holder idiom** (lazy, with thread safety from class-init guarantees), then volatile double-checked locking.
```java
public class Registry {
    private Registry() {}
    private static class Holder { static final Registry INSTANCE = new Registry(); }
    public static Registry get() { return Holder.INSTANCE; }   // class init happens once, thread-safely, on first call
}
```
**3. Dining philosophers**: 5 philosophers and 5 forks; naive "pick left then right" deadlocks. Fixes: resource ordering (pick the lower-numbered fork first), at most 4 seated (a `Semaphore(4)`), or tryLock with backoff.

**4. Parallel sum with ForkJoin**
```java
class SumTask extends RecursiveTask<Long> {
    final int[] a; final int lo, hi; static final int CUTOFF = 10_000;
    SumTask(int[] a, int lo, int hi) { this.a = a; this.lo = lo; this.hi = hi; }
    protected Long compute() {
        if (hi - lo <= CUTOFF) { long s = 0; for (int i = lo; i < hi; i++) s += a[i]; return s; }
        int mid = (lo + hi) >>> 1;
        SumTask left = new SumTask(a, lo, mid); left.fork();
        return new SumTask(a, mid, hi).compute() + left.join();   // compute right here, join left
    }
}
long total = ForkJoinPool.commonPool().invoke(new SumTask(arr, 0, arr.length));
```
Work stealing: idle workers steal tasks from the tail of busy workers' deques.

**5. Web crawler with concurrency limit**: a `ConcurrentHashMap.newKeySet()` for visited URLs (`add` returns false if already present, which makes the check atomic), a bounded executor, and a `Phaser` or counter to know when all work is done.

#### Real-world example
These map to real code: ordered handoff appears in pipeline stages; the holder idiom is how lazy singletons are written in libraries; ForkJoin underpins parallel streams; and the crawler pattern (visited set plus bounded workers) is how batch jobs fan out over IDs.

#### Interview questions
?? What's the best way to implement a singleton in Java?
An enum (`enum Registry { INSTANCE; }`): it's thread-safe, serialisation-safe and reflection-safe. If lazy loading with a class is needed, use the holder idiom. In Spring apps you rarely write singletons; beans are singletons by default and easier to test.

?? How does work stealing in ForkJoinPool work?
Each worker has a deque. It pushes and pops its own tasks LIFO from the head (good cache locality). Idle workers steal FIFO from the tail of other workers' deques, which takes the larger, older subtasks and reduces contention.

#### Tricky questions
?? In the A/B/C printer, what happens if you use `notify()` with one shared lock instead of semaphores?
`notify` wakes an arbitrary waiter, possibly the wrong thread, which goes back to waiting, and then nobody wakes the right one. That's a hang. Use `notifyAll` with a `while (turn != me)` check, or separate semaphores or conditions.

#### Interview simulation
**Interviewer:** "Write a program where 3 threads print 1 to 30 in round-robin."

**Clarify:** "Thread 1 prints 1, 4, 7…? Must it be strictly in order?"

**Approach out loud:** "I'll keep a shared counter and a turn variable guarded by one lock. Each thread waits while `turn != myId`, prints, increments, sets `turn = (turn+1)%3`, and calls `notifyAll`. All three exit when the counter passes 30, with one last `notifyAll`." Write it, then mention the `Semaphore`-chain alternative and its benefit: no spurious wakeups of the wrong threads.
