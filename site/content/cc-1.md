## The round | P2 | must

### What the code comprehension round looks like

#### Core idea
A new interview format at top companies replaces one classic "solve this LeetCode problem" round. You get an **unfamiliar, multi-file codebase** (a few hundred lines with planted flaws) and have to **read it, find bugs, add a feature, and optimise**, often with an **AI assistant** available that you must use critically. It tests the day-to-day job: working in code someone else wrote.

#### How it works
| Company | Format (as publicly reported) |
|---|---|
| **Google** (pilot from May 2026, L3/L4) | 60 min in CoderPad on a 200–500 line multi-file codebase with intentional flaws. Stages: fix bugs → implement a feature in the existing architecture → performance optimisation. Gemini sits in a side panel. It replaces one of the two coding rounds. |
| **Meta** (AI-enabled coding round) | 60 min with a file explorer, editor and AI chat (a choice of models). The AI can't edit files, so you read, judge and paste. Staged: fix bugs, add a feature, optimise. **Verification and communication** weigh the most. |
| Others (Stripe "bug bash", Uber/Atlassian code review rounds) | Same core skill: read someone else's code fast and reason about it out loud. |

**What gets you rejected**
- Asking the AI "find the bug" before forming your own hypothesis.
- Pasting AI output without reading or testing it.
- Working silently.
- Rewriting large parts of the code instead of making minimal, targeted fixes.

**What scores**
- A fast mental map of the codebase, narrated.
- Hypothesis → evidence → minimal fix → verify.
- Precise, scoped AI prompts with every output checked.
- A feature that follows the existing architecture and style.
- Optimisation reasoning in terms of complexity and trade-offs.

Sources: reporting by Final Round AI and techinterview.org (secondhand). Confirm the exact format with your recruiter.

#### Real-world example
This round mirrors your real work at TCS: "resolved downstream integration issues through log analysis and root-cause investigation." You routinely read unfamiliar client code, form hypotheses from logs, and make careful fixes. Treat that experience as your preparation story.

#### Interview questions
?? How is this different from a normal coding round?
A normal round asks you to write an algorithm from scratch on a blank editor. This round gives you existing code and asks you to understand, debug and extend it: reading speed, debugging method, judgement about minimal changes, and tool use are what's assessed. DSA knowledge still helps in the optimisation stage.

#### Tricky questions
?? Should you use the AI assistant at all?
Yes. Not using it can look like a missed signal in an AI-fluency evaluation. Use it deliberately: to explain an unfamiliar API, to write a test for your hypothesis, or to review your fix for missed paths. Never hand it the thinking. Always say what you're asking and how you'll verify the answer.

#### Interview simulation
**Opening (say this):** "I'll spend the first few minutes mapping the code: entry points, data models and the main flow. Then I'll run the tests to see what fails. For each bug, I'll state a hypothesis before changing anything. I'll use the assistant for specific things, like writing a reproduction test, and I'll verify everything it gives me."

### The 60-minute approach

#### Core idea
A repeatable time plan keeps you from drowning in an unfamiliar codebase. The structure: **map → run → debug → extend → optimise → wrap up**, narrating throughout.

#### How it works
| Time | Step | What to do and say |
|---|---|---|
| 0–8 min | **Map** | Open every file. Find the entry point, the data models, and how a request flows. Say it: "This is X; Y calls Z; state lives in W." Note anything suspicious without fixing it yet. |
| 8–12 min | **Run** | Run the tests or main. Read the failing assertions *before* reading code: they point at symptoms. |
| 12–30 min | **Debug** | For each bug: hypothesis → evidence (a print, a small test) → minimal fix → rerun. Use the AI to confirm or to write a test, not to guess. |
| 30–48 min | **Feature** | Ask clarifying questions. Follow the existing style and layering. Add a test for the new behaviour. |
| 48–58 min | **Optimise** | State the current complexity, the bottleneck, the better structure, and the trade-off (memory, consistency). |
| Last 2 min | **Wrap** | What you fixed, what's still risky, what you'd do with more time. |

**Reading techniques**
- **Top-down**: start from the entry point and follow one request end to end.
- **Data-first**: understand the models (the classes holding state) before the logic that mutates them.
- **Summarise each function in one sentence** before moving on. If you can't, read it again.
- **Follow the state**: who reads and who writes each shared field? Shared mutable state is where bugs live.
- **Trust tests, not names**: a method called `safeAdd` may not be safe.

#### Real-world example
On-call debugging follows the same flow: an alert (failing test) → map the service quickly → hypothesis from symptoms → targeted evidence (logs, metrics) → minimal fix → verify → postmortem notes (the wrap-up).

#### Interview questions
?? You find three bugs in the first 5 minutes of reading. Do you fix them immediately?
Note them, but finish mapping first (it takes a few more minutes), because understanding the whole flow may change how you fix them, or reveal that they're related. Then fix them in order of impact, one at a time, verifying each.

#### Tricky questions
?? A test fails, and you find a fix that makes it pass. Are you done?
Not yet. Check that the fix addresses the root cause, not the symptom (e.g. special-casing the test input), that it doesn't break other tests, and that similar code elsewhere doesn't have the same bug. Say this out loud.

#### Interview simulation
Practise narrating like this: "I think the oversell happens because `reserve` reads, checks and writes in separate steps. To confirm, I'll write a test with 50 threads reserving the last 5 units. If more than 5 succeed, that's the bug. The fix is an atomic update, and I'll rerun the same test to verify."

### Bug-hunting checklist

#### Core idea
Planted bugs come from a small, predictable set of categories. Scan every codebase against this checklist; it turns "staring at code" into a systematic search.

#### How it works
**Logic and arithmetic**
- Off-by-one errors, wrong loop bounds, `<` vs `<=`.
- Integer division (`discount / 100` is 0), overflow (`a + b` on large ints, `(lo + hi) / 2`), floating point for money.
- Wrong operator or precedence, inverted conditions.

**Null and empty handling**
- Null returns from `map.get`, empty collections, empty strings.
- Immutable collections returned (`List.of()`, `Map.of()`) and later mutated, giving `UnsupportedOperationException`.

**Collections and state**
- Mutation while iterating (ConcurrentModificationException).
- Exposing internal mutable state (returning the live inner map).
- Mutable keys in HashMap/HashSet; `equals` without `hashCode`.
- `==` on objects (Integer above 127, Strings), BigDecimal `equals` vs `compareTo`.

**Concurrency**
- Check-then-act races (`if (!map.containsKey(k)) map.put(…)`).
- Read-modify-write on shared counters.
- Non-thread-safe collections shared across threads.
- Missing `volatile` (double-checked locking, stop flags).
- Locks not released in `finally`, inconsistent lock ordering.

**Resources and error paths**
- Resources or reservations not released on the error path.
- Swallowed exceptions; `return` in `finally`.
- Retries without idempotency (double charge).
- Missing timeouts.

**Spring and JPA specifics**
- `@Transactional` self-invocation or on private methods.
- N+1 queries, lazy loading outside a session.
- Remote calls inside DB transactions.

#### Real-world example
Most real production bugs you'll see at work are in this list: a race on a counter, a reservation not released when payment fails, a swallowed exception hiding a failure, an N+1 query. Interviewers plant these exact kinds of bugs because they're realistic.

#### Interview questions
?? What's the first thing you look for in shared state?
Who reads and writes it, from which threads, and whether every read-modify-write sequence is atomic. Then whether internal state escapes the class (returned or passed by reference) where callers could mutate it.

#### Tricky questions
?? The code uses `ConcurrentHashMap`. Is it thread-safe?
Each individual operation is, but sequences of operations aren't (check-then-act, get-then-put). Look for compound operations and replace them with `merge`, `compute` or `putIfAbsent`.

#### Interview simulation
When you start reading, say: "I'll scan for the usual suspects: shared state and races, error paths that don't clean up, null and empty handling, and arithmetic like integer division." Interviewers like to hear a system rather than random searching.

### Reading unfamiliar code fast: a 4-week plan

#### Core idea
Reading speed is a trainable skill. The plan below runs alongside your DSA and LLD preparation (weeks 7–9 of the main plan), about 30–45 minutes a day.

#### How it works
| Week | Focus | Practice |
|---|---|---|
| **1: Reading speed** | Read good code daily | 30 min/day: one class from Guava, Caffeine or OkHttp. Write a one-line summary per method *before* checking the docs. Do the trace and explain questions in this track. |
| **2: Debugging** | Find planted bugs | One find-the-bug question a day, timed at 10 min. Clone Spring PetClinic, plant 3 bugs for a friend (or ask an AI to plant them), then find theirs. |
| **3: Multi-file** | Whole-codebase work | Do the full mock (checkout service) timed at 60 min, speaking aloud, recording yourself. Fix a "good first issue" in a small open-source Java repo end to end. |
| **4: AI fluency** | Tool use | The AI drills below. Redo the mock using an AI assistant, logging every prompt and whether you verified the output. Two mocks with a peer. |

**Good codebases to read**
- **Spring PetClinic**: a layered Spring app, close to interview size.
- **Caffeine** cache, **Guava `collect`** package: clean, well-tested Java.
- **OkHttp interceptors**: chain of responsibility in real life.
- **Your own past projects**: re-read code you wrote 6+ months ago as if a stranger wrote it.

#### Real-world example
Senior engineers onboard to new codebases quickly because they've practised exactly this: entry points first, data models next, one flow end to end, then the details. The plan builds the same habit.

#### Interview questions
?? How do you get productive in a large unfamiliar codebase at work?
Run it locally; trace one important request end to end (with a debugger or logs); read the data models and the tests; draw a quick diagram; make a small change and see what breaks; ask owners targeted questions. Avoid trying to read everything.

#### Tricky questions
?? Is it a good idea to refactor code you don't understand yet?
No. Understand it first, add tests around the behaviour you'll touch, then make minimal changes. In the interview, refactoring is a distraction unless asked.

#### Interview simulation
If asked "How do you approach code you've never seen?", describe the map → run → trace one flow → summarise → hypothesise process, with a short real example from your TCS client projects.

### Using the AI assistant well

#### Core idea
In AI-enabled rounds, the assistant is a tool you're evaluated on using **well**: precise prompts, critical evaluation of its output, and understanding every line you change. Over-reliance is penalised.

#### How it works
**Prompts that score well**
> "In `InventoryService.reserve`, I think two threads can both read available = 5 and both reserve 5. Write a JUnit test using an ExecutorService with 50 threads that reproduces the oversell."

> "Here's my fix for releasing reservations on failure. List any path where a reservation can still leak."

> "Explain only what `removeEldestEntry` does in LinkedHashMap and when it's called. Don't change my code."

**Prompts that score badly**
> "Find all the bugs in this code." / "Implement the feature." / "Make it faster."

**Drills**
1. For each find-the-bug question: write your hypothesis first, then ask an AI to write a failing test for it. Check that the test actually fails for the right reason.
2. Ask an AI to fix a bug, then find one thing wrong or missing in its fix (there usually is: no test, the wrong scope, changed behaviour).
3. Ask an AI to summarise a Guava class. Compare it with your own summary and note what it got wrong.
4. Practise narrating: "I'm asking the AI X because Y; I'll verify by Z."

#### Real-world example
Your resume lists Claude, Cursor, ChatGPT and Copilot for AI-assisted coding, debugging and testing. Interviewers may ask how you use them day to day. A good answer: for boilerplate and tests, for explaining unfamiliar APIs, and for reviewing your own changes; always with your own understanding and verification, never blindly committing generated code.

#### Interview questions
?? How do you verify AI-generated code?
Read every line; check it against the requirement and the edge cases; run it with tests, including one that would fail if the code were wrong; check for changed behaviour elsewhere; and confirm it matches the existing code style and architecture.

#### Tricky questions
?? The AI's fix makes the failing test pass. What could still be wrong?
It might special-case the test input, hide the symptom (catch and ignore an exception), change behaviour elsewhere, introduce a race or a performance problem, or miss other occurrences of the same bug. Verification means more than one green test.

#### Interview simulation
Say what you're doing with the assistant every time: "I'm going to ask it to write a concurrency test for my hypothesis. I'll check that the test fails on the current code before I fix anything." That narration is itself scored.

## Practice set | P2 | must

### A. Trace the output

#### A1. Integer caching (easy)
```java
Integer a = 127, b = 127;
Integer c = 128, d = 128;
System.out.println(a == b);
System.out.println(c == d);
System.out.println(c.equals(d));
```
?? Show answer
`true`, `false`, `true`. Autoboxing uses `Integer.valueOf`, which caches -128 to 127. So 127 gives the same object, while 128 creates two objects and `==` compares references. Always use `equals` for wrappers. This is a real bug source when comparing IDs stored as `Long`.

#### A2. String pool (easy)
```java
String s1 = "java";
String s2 = new String("java");
String s3 = s2.intern();
System.out.println(s1 == s2);
System.out.println(s1 == s3);
```
?? Show answer
`false`, `true`. `new String` creates a heap object outside the pool; `intern()` returns the pooled instance, which is the same one the literal uses.

#### A3. finally vs return (medium)
```java
static int f() {
    int x = 1;
    try { return x; }
    finally { x = 2; }
}
static int g() {
    try { throw new RuntimeException(); }
    finally { return 3; }
}
System.out.println(f() + " " + g());
```
?? Show answer
`1 3`. In `f` the return value is evaluated (1) before `finally` runs, so changing `x` doesn't affect it. In `g`, a `return` in `finally` overrides and swallows the exception. That's why returning from finally is flagged in code review.

#### A4. List.remove overloads (medium)
```java
List<Integer> list = new ArrayList<>(List.of(10, 20, 30, 1));
list.remove(1);
list.remove(Integer.valueOf(1));
System.out.println(list);
```
?? Show answer
`[10, 30]`. `remove(1)` picks `remove(int index)` and removes 20. `remove(Integer.valueOf(1))` picks `remove(Object)` and removes the value 1.

#### A5. Lazy streams (medium)
```java
Stream.of("a", "b", "c")
      .filter(s -> { System.out.print(s); return true; });
System.out.println("done");

Stream.of("a", "b", "c")
      .peek(System.out::print)
      .map(String::toUpperCase)
      .findFirst();
```
?? Show answer
Prints `done` then `a`. The first pipeline has no terminal operation, so nothing runs. The second is processed element by element and short-circuits at the first match, so only `a` passes through `peek`.

#### A6. char arithmetic (easy)
```java
System.out.println('a' + 'b' + "c");
System.out.println("c" + 'a' + 'b');
System.out.println(1 + 2 + "3" + 4 + 5);
```
?? Show answer
`195c`, `cab`, `3345`. Evaluation is left to right. Two chars add as ints (97 + 98) until a String appears; after that everything concatenates.

### B. Find and fix the bug

#### B1. Lower bound that hangs (medium)
```java
// Return the first index i where a[i] >= target (a is sorted).
// If every element is smaller, return a.length.
static int lowerBound(int[] a, int target) {
    int lo = 0, hi = a.length - 1;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (a[mid] < target) lo = mid;
        else hi = mid;
    }
    return lo;
}
```
?? Show answer
- `lo = mid` causes an infinite loop when `hi = lo + 1` and `a[lo] < target`, because mid rounds down to lo. Use `lo = mid + 1`.
- `hi` should start at `a.length`, or the function can never return `a.length` as the contract says.
- Minor: use `lo + (hi - lo) / 2` to avoid overflow.
- Test with: `[1,3]` target 2, target 5, empty array.

#### B2. Expiring sessions (easy)
```java
Map<String, Long> sessions = new HashMap<>();

void evictExpired(long now) {
    for (String id : sessions.keySet()) {
        if (sessions.get(id) < now) {
            sessions.remove(id);
        }
    }
}
```
?? Show answer
Removing from a HashMap while iterating its key set throws `ConcurrentModificationException` (the iterator is fail-fast). Fix: `sessions.values().removeIf(exp -> exp < now);` or use the iterator's `remove()`. If other threads touch the map, it also needs `ConcurrentHashMap`.

#### B3. Lost map entry (medium)
```java
class Point {
    int x, y;
    Point(int x, int y) { this.x = x; this.y = y; }
    @Override public boolean equals(Object o) {
        return o instanceof Point p && p.x == x && p.y == y;
    }
    @Override public int hashCode() { return Objects.hash(x, y); }
}

Map<Point, String> grid = new HashMap<>();
Point p = new Point(1, 2);
grid.put(p, "tree");
p.x = 5;
System.out.println(grid.get(p));
System.out.println(grid.get(new Point(1, 2)));
```
?? Show answer
Both print `null`. The key was mutated after insertion, so its hash changed. `get(p)` looks in the bucket for (5,2), and `get(new Point(1,2))` finds the right bucket but `equals` fails against the mutated key. The entry is now unreachable, which is a memory leak. Fix: make keys immutable (`final` fields or a `record`).

#### B4. Lazy singleton (medium)
```java
public class ConfigLoader {
    private static ConfigLoader instance;
    private final Map<String, String> props;

    private ConfigLoader() { props = loadFromDisk(); }

    public static ConfigLoader get() {
        if (instance == null) {
            synchronized (ConfigLoader.class) {
                if (instance == null) {
                    instance = new ConfigLoader();
                }
            }
        }
        return instance;
    }
}
```
?? Show answer
Double-checked locking without `volatile`. The write to `instance` can be reordered before the constructor finishes, so another thread can see a non-null but partially built object. Fix: declare `private static volatile ConfigLoader instance`, or use the holder-class idiom / an enum singleton.

#### B5. Word counter under load (medium)
```java
private final Map<String, Integer> counts = new ConcurrentHashMap<>();

// called from many request threads
public void record(String word) {
    if (!counts.containsKey(word)) {
        counts.put(word, 0);
    }
    counts.put(word, counts.get(word) + 1);
}
```
?? Show answer
Each call is thread-safe on its own, but the sequence isn't atomic (check-then-act and read-modify-write). Two threads can read 4 and both write 5, losing an increment. Fix: `counts.merge(word, 1, Integer::sum);`. For very hot keys, a `ConcurrentHashMap<String, LongAdder>` with `computeIfAbsent(...).increment()`.

#### B6. Missing transaction (medium)
```java
@Service
public class OrderService {
    private final OrderRepository repo;
    private final InventoryClient inventory;

    public void placeAll(List<Order> orders) {
        for (Order o : orders) {
            placeOne(o);
        }
    }

    @Transactional
    public void placeOne(Order o) {
        repo.save(o);
        inventory.deduct(o.getSku(), o.getQty()); // may throw
    }
}
```
?? Show answer
`placeOne` is called from inside the same bean, so the call skips the Spring proxy and `@Transactional` does nothing. If `deduct` throws, the saved order isn't rolled back. Fixes: move `placeOne` to another bean, inject self, or use `TransactionTemplate`. Also worth mentioning: a remote call inside a DB transaction holds a connection open, and the remote side effect can't be rolled back (outbox or saga territory).

#### B7. Slow dashboard (medium)
```java
@Entity
class Order {
    @Id Long id;
    @OneToMany(mappedBy = "order", fetch = FetchType.LAZY)
    List<OrderItem> items;
}

public int totalItems() {
    int total = 0;
    for (Order o : orderRepo.findAll()) {
        total += o.getItems().size();
    }
    return total;
}
```
?? Show answer
- N+1 queries: one query for orders, then one per order to load items.
- `findAll()` loads every order into memory.
- Outside a transaction, the lazy access can throw `LazyInitializationException`.
- Fix: a single aggregate query, e.g. `select count(i) from OrderItem i`. If you need entities, use a fetch join or `@EntityGraph`, with pagination.

#### B8. Price comparison (easy)
```java
Set<BigDecimal> seen = new HashSet<>();
seen.add(new BigDecimal("2.0"));
System.out.println(seen.contains(new BigDecimal("2.00")));

boolean isFree(BigDecimal price) {
    return price.equals(BigDecimal.ZERO);
}
```
?? Show answer
Prints `false`. `BigDecimal.equals` compares scale too, so 2.0 and 2.00 differ, and `isFree(new BigDecimal("0.00"))` returns false. Use `compareTo(...) == 0`, or `stripTrailingZeros()` before putting values in hash-based collections.

#### B9. Payment retry (hard)
```java
public void pay(String userId, long amountPaise) {
    for (int attempt = 0; attempt < 3; attempt++) {
        try {
            gateway.charge(userId, amountPaise);
            return;
        } catch (TimeoutException e) {
            // try again
        }
    }
}
```
?? Show answer
- A timeout doesn't mean the charge failed. Retrying can double-charge. Pass an idempotency key generated once per payment, and the gateway dedupes.
- After 3 failures the method returns normally, so the caller thinks payment succeeded. Throw or return a status.
- No backoff or jitter; immediate retries pile onto a struggling gateway.
- Exception swallowed with no logging.
- Better: on timeout, query payment status by idempotency key before retrying.

### C. Explain what this code does

#### C1. Mystery bit loop (easy)
```java
static int f(int n) {
    int c = 0;
    while (n != 0) {
        n &= n - 1;
        c++;
    }
    return c;
}
```
?? Show answer
Counts set bits (popcount), using Kernighan's trick: `n & (n - 1)` clears the lowest set bit. Runs in O(number of set bits). Edge case: negative input works and counts bits in the 32-bit two's-complement form (e.g. -1 returns 32). Same as `Integer.bitCount`.

#### C2. Map subclass (medium)
```java
class X<K, V> extends LinkedHashMap<K, V> {
    private final int cap;
    X(int cap) {
        super(16, 0.75f, true);
        this.cap = cap;
    }
    @Override
    protected boolean removeEldestEntry(Map.Entry<K, V> eldest) {
        return size() > cap;
    }
}
```
?? Show answer
An LRU cache with capacity `cap`. The `true` flag sets access order, so `get` moves an entry to the end; after each insert, the eldest (least recently used) is evicted once size exceeds cap. O(1) get/put. Not thread-safe: even `get` mutates internal order, so concurrent use needs external locking or a library like Caffeine.

#### C3. Request gate (medium)
```java
class Gate {
    private final long capacity;
    private final double refillPerMs;
    private double tokens;
    private long last = System.currentTimeMillis();

    Gate(long capacity, double refillPerMs) {
        this.capacity = capacity;
        this.refillPerMs = refillPerMs;
    }

    synchronized boolean tryAcquire() {
        long now = System.currentTimeMillis();
        tokens = Math.min(capacity, tokens + (now - last) * refillPerMs);
        last = now;
        if (tokens >= 1) { tokens -= 1; return true; }
        return false;
    }
}
```
?? Show answer
A token-bucket rate limiter: refills lazily based on elapsed time, allows bursts up to `capacity`. Edge cases to raise: it starts with 0 tokens, so the first requests are rejected (initialize `tokens = capacity` if bursts at startup are fine); `currentTimeMillis` can jump with clock changes, so `nanoTime` is safer; `synchronized` is a bottleneck under heavy contention; it's per-instance, so it doesn't work across multiple servers (needs Redis or similar).

#### C4. Short and dense (hard)
```java
static int g(int[] a) {
    int[] t = new int[a.length];
    int len = 0;
    for (int x : a) {
        int i = Arrays.binarySearch(t, 0, len, x);
        if (i < 0) i = -(i + 1);
        t[i] = x;
        if (i == len) len++;
    }
    return len;
}
```
?? Show answer
Length of the longest strictly increasing subsequence, in O(n log n). `t[k]` holds the smallest possible tail of an increasing subsequence of length k+1. A duplicate value returns a found index and overwrites in place, so equal values don't extend the sequence. Note: `t` isn't the actual subsequence, just tails.

### D. Full mock: checkout service (60 minutes)

#### How to run this mock
Four files, one flow: add items to a cart, check out, reserve stock, charge payment. Do it timed and speaking aloud. **Stage 1**: find every bug (there are at least 4). **Stage 2**: build the feature. **Stage 3**: answer the optimisation question. Don't open the answers until you've finished each stage.

#### Product.java
```java
public record Product(String id, String name, long pricePaise) {}
```

#### InventoryService.java
```java
public class InventoryService {
    private final Map<String, Integer> stock = new ConcurrentHashMap<>();

    public void addStock(String productId, int qty) {
        stock.merge(productId, qty, Integer::sum);
    }

    public boolean reserve(String productId, int qty) {
        int available = stock.getOrDefault(productId, 0);
        if (available < qty) return false;
        stock.put(productId, available - qty);
        return true;
    }

    public void release(String productId, int qty) {
        stock.merge(productId, qty, Integer::sum);
    }
}
```

#### CartService.java
```java
public class CartService {
    private final Map<String, Map<String, Integer>> carts = new HashMap<>();
    private final Map<String, Product> catalog;

    public CartService(Map<String, Product> catalog) {
        this.catalog = catalog;
    }

    public void add(String userId, String productId, int qty) {
        carts.computeIfAbsent(userId, k -> new HashMap<>())
             .merge(productId, qty, Integer::sum);
    }

    public Map<String, Integer> items(String userId) {
        return carts.getOrDefault(userId, Map.of());
    }

    public long total(String userId, int discountPercent) {
        long total = 0;
        for (var e : items(userId).entrySet()) {
            total += catalog.get(e.getKey()).pricePaise() * e.getValue();
        }
        return total - total * (discountPercent / 100);
    }
}
```

#### OrderService.java
```java
public class OrderService {
    private final InventoryService inventory;
    private final CartService carts;
    private final PaymentGateway payments; // charge() throws PaymentException

    public OrderService(InventoryService i, CartService c, PaymentGateway p) {
        this.inventory = i; this.carts = c; this.payments = p;
    }

    public String checkout(String userId, int discountPercent) {
        Map<String, Integer> items = carts.items(userId);
        for (var e : items.entrySet()) {
            if (!inventory.reserve(e.getKey(), e.getValue())) {
                throw new IllegalStateException("Out of stock: " + e.getKey());
            }
        }
        long amount = carts.total(userId, discountPercent);
        String paymentId = payments.charge(userId, amount);
        items.clear();
        return paymentId;
    }
}
```

#### Stage 1 answers: bugs
?? Show the bugs
1. **Oversell race** in `reserve`: read, check and put are separate steps, so two threads can both reserve the last unit. Fix with an atomic update, e.g. a CAS loop with `stock.replace(id, old, old - qty)`, or `compute` returning whether it succeeded.
2. **Discount never applied**: `discountPercent / 100` is integer division, so it's 0 for anything below 100. Use `total * discountPercent / 100` (or BigDecimal with explicit rounding). Also validate 0–100.
3. **Reservation leak**: if the 2nd item is out of stock, the 1st item's reservation is never released. Same if `charge` throws. Track what you reserved and release it in a catch/finally on failure.
4. **Empty cart**: `items()` returns `Map.of()` for a new user, so checkout charges 0 and then `clear()` throws `UnsupportedOperationException`. Reject empty carts up front.
5. **Leaking internal state**: `items()` returns the live inner map, so `OrderService` clears the cart by mutating another service's data. Add `CartService.clear(userId)` and return an unmodifiable copy.
6. **Thread safety**: `carts` is a plain HashMap shared across requests. Use ConcurrentHashMap (inner maps too).
7. **Unknown product**: `catalog.get` returns null → NPE in `total`. Validate in `add`.
8. **Ordering**: total is computed after reserving; if the cart changes concurrently, you could charge for items you didn't reserve. Snapshot the cart once at the start.

#### Stage 2: feature
**Task:** add `cancelOrder(orderId)` that refunds the payment and releases stock. Calling it twice must not refund twice.

?? Show what a strong answer covers
Store an `Order` (id, userId, item snapshot, paymentId, status) at checkout; cancel only from status PAID; flip the status atomically (CAS or a synchronized state transition) before refunding, so a double call is a no-op; release exactly the snapshotted quantities; decide what happens if the refund fails (keep the status CANCEL_PENDING and retry). Ask: partial cancellation? A cancellation window after shipping?

#### Stage 3: optimisation
**Question:** checkout now handles 2,000 requests/sec, carts have up to 50 items, and the hot path is slow. What would you change?

?? Show the points to hit
Reserving items one by one means many atomic operations and a messy rollback; sort product IDs to avoid lock-ordering deadlocks if you move to locks; batch reservation; move inventory to a store with atomic decrement (Redis `DECRBY` with a Lua check, or a DB `UPDATE ... SET qty = qty - ? WHERE qty >= ?`); add a reservation TTL so abandoned reservations expire; make payment async with an outbox if the gateway is slow. State the trade-off: stronger consistency costs latency.
