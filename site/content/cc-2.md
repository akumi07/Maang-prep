## Mock interviews: Easy | P2 | must

### How to use the mock bank

#### Core idea
This bank has **32 full mocks** in the format of the code comprehension / AI-assisted coding round: a small multi-file codebase with planted bugs, a feature to add, and an optimisation or extension question. They're grouped by difficulty:

| Level | Mocks | Time box | What's planted |
|---|---|---|---|
| **Easy** | E1–E10 | 30–40 min | 3–5 bugs: off-by-one, null handling, integer division, wrong comparisons, collection misuse |
| **Medium** | M1–M12 | 45–60 min | 4–5 bugs incl. state bugs, races, aliasing, retry/idempotency mistakes |
| **Hard** | H1–H10 | 60 min | concurrency, async, distributed-systems and framework bugs that need a test to prove |

They're written to match the publicly reported shape of these rounds (Google's code comprehension pilot, Meta's AI-enabled coding round). They aren't leaked company questions; they're the kind of codebase and bug classes those rounds use. Imports are omitted for brevity (assume `java.util.*`, `java.util.concurrent.*`, `java.time.*`).

#### How it works
**For each mock**
1. Start a timer. Read the brief and every file before touching anything. Narrate your map out loud.
2. Run the `Demo` class in your head (or paste it into an IDE: every mock compiles as given). The demo prints expected vs actual.
3. **Stage 1**: find the planted bugs. State a hypothesis for each before fixing. Then open the answer.
4. **Stage 2**: implement the feature in the existing style. Then compare with the model solution.
5. **Stage 3**: answer the optimisation or extension question out loud in 3–5 minutes.
6. Mark the mock as learned, or "Revise later" if you missed more than one bug.

**Practising with an AI assistant**: paste the files into an assistant and practise the prompts from the "Using the AI assistant well" lesson. Write your hypothesis first, ask for a test that proves it, and verify the test fails on the original code.

#### Real-world example
Doing 2 easy mocks a day in week 1, then 1 medium per day, then hard ones in the last week mirrors how people build reading speed: pattern recognition for common bug classes first, then multi-file reasoning, then concurrency.

#### Interview questions
?? How many mocks should you do before the real round?
Aim for all 10 easy (fast pattern recognition), at least 8 medium and at least 6 hard under time pressure, plus 2 done with an AI assistant while narrating. Redo any mock where you missed bugs a week later.

#### Tricky questions
?? You found more bugs than the answer lists. Is that wrong?
Not necessarily. Real code has unplanted issues too. If your extra finding is a real defect (with a scenario that breaks), mention it; that's a plus in the interview. Just prioritise by impact.

#### Interview simulation
At the start of every mock, say out loud: "Let me read all the files first and summarise the flow, then run the demo." Practising the habit is half the value of the mock bank.

### E1. Library fine calculator

#### Brief
A library app charges fines for late returns. **Rules**: ₹10 (1,000 paise) per late day, counted from the due date. A 2-day grace period means books returned up to 2 days late are free; after that, every late day is charged. The fine is capped at ₹500. Books not yet returned are charged up to today. The report shows the total fine per member. **Symptom**: the report crashes, and members report wrong fines. Time box: 30 minutes.

#### Files
```java
// Loan.java
public record Loan(String memberId, String isbn, LocalDate dueOn, LocalDate returnedOn) {}   // returnedOn null = not returned
```
```java
// FinePolicy.java
public class FinePolicy {
    static final long PER_DAY_PAISE = 1_000;
    static final long MAX_FINE_PAISE = 50_000;
    static final int GRACE_DAYS = 2;
    private final Clock clock;

    public FinePolicy(Clock clock) { this.clock = clock; }

    public long fine(Loan loan) {
        long lateDays = java.time.temporal.ChronoUnit.DAYS.between(loan.dueOn(), loan.returnedOn());
        if (lateDays < GRACE_DAYS) return 0;
        return Math.max(lateDays * PER_DAY_PAISE, MAX_FINE_PAISE);
    }
}
```
```java
// FineReport.java
public class FineReport {
    private final FinePolicy policy;
    public FineReport(FinePolicy policy) { this.policy = policy; }

    public Map<String, Long> totalsByMember(List<Loan> loans) {
        Map<String, Long> totals = new HashMap<>();
        for (Loan l : loans) {
            long f = policy.fine(l);
            if (f > 0) totals.put(l.memberId(), totals.get(l.memberId()) + f);
        }
        return totals;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Clock clock = Clock.fixed(Instant.parse("2026-10-20T10:00:00Z"), ZoneOffset.UTC);
        FinePolicy p = new FinePolicy(clock);
        LocalDate due = LocalDate.of(2026, 10, 1);
        System.out.println("2 days late -> expected 0, got " + p.fine(new Loan("m1", "b1", due, due.plusDays(2))));
        System.out.println("5 days late -> expected 5000, got " + p.fine(new Loan("m1", "b1", due, due.plusDays(5))));
        System.out.println("90 days late -> expected 50000, got " + p.fine(new Loan("m1", "b1", due, due.plusDays(90))));
        System.out.println("not returned (19 days late) -> expected 19000, got " + p.fine(new Loan("m2", "b2", due, null)));
        System.out.println(new FineReport(p).totalsByMember(List.of(new Loan("m3", "b3", due, due.plusDays(4)))));
    }
}
```

#### Stage 1: find and fix the bugs
There are 4 planted bugs.

?? Show the bugs
1. **Cap uses `Math.max` instead of `Math.min`**: every late return is charged at least ₹500. Fix: `Math.min(lateDays * PER_DAY_PAISE, MAX_FINE_PAISE)`.
2. **Grace boundary is wrong**: `lateDays < GRACE_DAYS` charges a return exactly 2 days late. The spec says up to 2 days late is free: use `lateDays <= GRACE_DAYS`.
3. **Unreturned books crash**: `returnedOn` is null, and `ChronoUnit.between` throws an NPE. Use `LocalDate end = loan.returnedOn() != null ? loan.returnedOn() : LocalDate.now(clock);`. The clock is injected but never used, which is a hint.
4. **First fine per member crashes**: `totals.get(member)` returns null for the first entry, and unboxing throws an NPE. Use `totals.merge(l.memberId(), f, Long::sum)`.

Bonus discussion: dates in UTC vs the library's local zone (`LocalDate.now(clock)` uses the clock's zone; make sure it's the library's zone).

#### Stage 2: add a feature
**Task**: students pay 50% of the fine (rounded down to whole rupees), and senior citizens pay nothing. Add a member type without breaking the existing callers.

?? Show a strong solution
Introduce `enum MemberType { REGULAR, STUDENT, SENIOR }` and a lookup `Function<String, MemberType> memberTypes` injected into `FinePolicy` (or a new `fine(Loan, MemberType)` overload). Apply the discount **after** the cap: `long base = …; return switch (type) { case REGULAR -> base; case STUDENT -> (base / 2) / 100 * 100; case SENIOR -> 0; };`. Better still for growth: a `Map<MemberType, DiscountRule>` (strategy) so new types are data, not code. Add a demo line for each type. Ask the interviewer whether the cap applies before or after the discount: that's the clarifying question they're waiting for.

#### Stage 3: optimise
**Question**: the report now runs nightly over 20 million loan rows in Postgres. The current code loads them all into a `List`. What would you change?

?? Show the points to hit
Don't load 20M rows into memory. Either push the aggregation to SQL (`SELECT member_id, SUM(LEAST(GREATEST(late_days - 2, ...)…)) GROUP BY member_id` with the rules expressed in SQL, or a materialised fine column updated on return), or stream rows with a cursor (JDBC fetch size, `Stream<Loan>` from Spring Data) and aggregate incrementally. Only overdue loans matter, so filter `WHERE due_on < current_date AND (returned_on IS NULL OR returned_on > due_on + 2)` with an index on `due_on`. Mention keeping the rules in one place (if duplicated in SQL and Java, test both).

#### Interview simulation
**Ask before coding**: "Is a book returned on the due date late? Does the grace period mean the first 2 days are always free, or only if returned within 2 days? Does the cap apply per loan or per member? Which time zone defines 'today'?" Then: map the 3 files in one sentence each, run the demo, and fix in order of impact (crashes first, then wrong amounts).

### E2. Shopping cart totals

#### Brief
A cart service computes order totals. **Rules**: adding an existing SKU increases its quantity; a percentage coupon applies to the subtotal; delivery is free when the subtotal **before** discount is at least ₹499, otherwise ₹40; out-of-stock items can be removed in one call. **Symptom**: QA reports wrong totals and a crash in "remove out-of-stock items". Time box: 30 minutes.

#### Files
```java
// CartItem.java
public class CartItem {
    final String sku; final long unitPricePaise; int qty;
    CartItem(String sku, long unitPricePaise, int qty) { this.sku = sku; this.unitPricePaise = unitPricePaise; this.qty = qty; }
    long lineTotal() { return unitPricePaise * qty; }
}
```
```java
// Cart.java
public class Cart {
    private final List<CartItem> items = new ArrayList<>();

    public void add(String sku, long pricePaise, int qty) {
        for (CartItem i : items) {
            if (i.sku.equals(sku)) { i.qty = qty; return; }
        }
        items.add(new CartItem(sku, pricePaise, qty));
    }

    public void removeOutOfStock(Set<String> outOfStock) {
        for (CartItem i : items) {
            if (outOfStock.contains(i.sku)) items.remove(i);
        }
    }

    public List<CartItem> getItems() { return items; }
}
```
```java
// PriceCalculator.java
public class PriceCalculator {
    static final long FREE_DELIVERY_MIN_PAISE = 49_900;
    static final long DELIVERY_FEE_PAISE = 4_000;

    public long total(Cart cart, int couponPercent) {
        long subtotal = 0;
        for (CartItem i : cart.getItems()) subtotal += i.lineTotal();
        long discount = subtotal * (couponPercent / 100);
        long afterDiscount = subtotal - discount;
        long delivery = afterDiscount >= FREE_DELIVERY_MIN_PAISE ? 0 : DELIVERY_FEE_PAISE;
        return afterDiscount + delivery;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Cart c = new Cart();
        c.add("PEN", 2_000, 2);
        c.add("PEN", 2_000, 3);                       // now 5 pens
        c.add("BAG", 50_000, 1);
        System.out.println("pens: expected 5, got " + c.getItems().get(0).qty);
        // subtotal 60_000; 10% off = 54_000; subtotal >= 49_900 so free delivery
        System.out.println("total: expected 54000, got " + new PriceCalculator().total(c, 10));
        c.removeOutOfStock(Set.of("PEN", "BAG"));
        System.out.println("after removal: expected 0 items, got " + c.getItems().size());
    }
}
```

#### Stage 1: find and fix the bugs
There are 4 planted bugs.

?? Show the bugs
1. **`add` overwrites instead of adding**: `i.qty = qty` should be `i.qty += qty`. Also validate `qty > 0`.
2. **Coupon never applies**: `couponPercent / 100` is integer division, so it's 0 for 1–99%. Use `subtotal * couponPercent / 100` (and validate 0–100; decide the rounding explicitly).
3. **Delivery uses the post-discount amount**: the spec says before discount. Use `subtotal >= FREE_DELIVERY_MIN_PAISE`.
4. **Removing while iterating**: `items.remove(i)` inside a for-each throws `ConcurrentModificationException` (or silently skips elements, depending on position). Use `items.removeIf(i -> outOfStock.contains(i.sku))`.

Also worth raising: `getItems()` exposes the internal mutable list, so callers can change the cart without validation. Return `List.copyOf(items)` or an unmodifiable view.

#### Stage 2: add a feature
**Task**: add "buy 2 get 1 free" for selected SKUs (every 3rd unit of an eligible SKU is free) on top of the coupon. The coupon applies after the free units are removed.

?? Show a strong solution
Add a `Set<String> b2g1Skus` (or a `Promotion` interface returning a discount per cart, so more promotions can be added later). The free units per line are `qty / 3`, so the line discount is `(qty / 3) * unitPrice`. Compute `subtotal → minus promo discount → minus coupon on the remainder → delivery (based on the original subtotal, per the spec; confirm)`. Order of application is the key clarifying question. Add demo cases: qty 2 (no free), qty 3 (1 free), qty 7 (2 free).

#### Stage 3: optimise
**Question**: carts are now stored in Redis and read on every page view (50K reads per second). Each read recomputes totals. What would you do?

?? Show the points to hit
Recomputing a small cart is cheap in CPU; the cost is the Redis round trips and serialisation. Store the cart as a Redis hash per user (`HSET cart:{user} sku qty`) and cache the computed summary with a version that changes on every cart mutation (or recompute on write and store totals with the cart). Prices must be re-validated against the catalogue at checkout (cached prices can be stale). Keep money as `long` paise, never `double`.

#### Interview simulation
**Ask**: "Is free delivery based on the subtotal before or after the coupon? Can quantity be zero or negative? How should the discount round: down, or to the nearest paisa?" Then show the bug with the demo, fix one bug at a time, rerun.

### E3. Student grade report

#### Brief
A school tool computes each student's average score, letter grade, and the top N students. **Rules**: average to 2 decimal places; A ≥ 90, B ≥ 75, C ≥ 60, else F; ranking by average descending, ties broken by name ascending; students with no scores are listed with average 0 and grade F. **Symptom**: averages are whole numbers, the ranking looks random for close scores, and asking for the top 5 of 3 students crashes. Time box: 30 minutes.

#### Files
```java
// Student.java
public record Student(String name, List<Integer> scores) {}
```
```java
// GradeCalculator.java
public class GradeCalculator {
    public double average(Student s) {
        int sum = 0;
        for (int x : s.scores()) sum += x;
        return sum / s.scores().size();
    }

    public char grade(double avg) {
        if (avg > 90) return 'A';
        if (avg > 75) return 'B';
        if (avg > 60) return 'C';
        return 'F';
    }
}
```
```java
// Ranking.java
public class Ranking {
    private final GradeCalculator calc = new GradeCalculator();

    public List<String> topN(List<Student> students, int n) {
        List<Student> sorted = new ArrayList<>(students);
        sorted.sort((a, b) -> (int) (calc.average(b) - calc.average(a)));
        return sorted.subList(0, n).stream().map(Student::name).toList();
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        GradeCalculator g = new GradeCalculator();
        Student asha = new Student("Asha", List.of(90, 91));
        Student ravi = new Student("Ravi", List.of(90, 90));
        Student meena = new Student("Meena", List.of(75));
        System.out.println("Asha avg: expected 90.5, got " + g.average(asha));
        System.out.println("Ravi grade: expected A, got " + g.grade(g.average(ravi)));
        System.out.println("Meena grade: expected B, got " + g.grade(g.average(meena)));
        System.out.println("top 2: expected [Asha, Ravi], got " + new Ranking().topN(List.of(ravi, meena, asha), 2));
        System.out.println("top 5 of 3: " + new Ranking().topN(List.of(ravi, meena, asha), 5));
        System.out.println("no scores: " + g.average(new Student("New", List.of())));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Integer division in `average`**: `sum / size` truncates (90.5 becomes 90). Use `(double) sum / size`, then round to 2 decimals for display (`Math.round(avg * 100) / 100.0`, or BigDecimal with HALF_UP if the school mandates a rounding rule).
2. **Empty scores**: division by zero (`ArithmeticException` with ints; `NaN` with doubles). Return 0 when there are no scores, per the spec.
3. **Grade boundaries use `>` instead of `>=`**: exactly 90 gives B. Use `>=` for each boundary.
4. **Comparator truncates differences**: `(int)(b - a)` makes 90.5 vs 90.0 compare as 0 (a tie), so the order depends on the input. Use `Comparator.comparingDouble(calc::average).reversed().thenComparing(Student::name)`. It also recomputes averages O(n log n) times; precompute them.
5. **`subList(0, n)` out of bounds** when n > size. Use `Math.min(n, sorted.size())`, or `stream().limit(n)`.

#### Stage 2: add a feature
**Task**: support weighted components (assignments 40%, exams 60%) instead of a flat list of scores, while keeping old students (flat lists) working.

?? Show a strong solution
Model the scores as `Map<Component, List<Integer>>` with weights in a config (`Map<Component, Double>` summing to 1.0, validated at startup). The weighted average = Σ weight × (component average); skip empty components and renormalise the weights over the components present (or treat missing as 0: ask!). Keep `average(Student)` for the legacy flat format by treating it as a single component with weight 1.0, so existing callers don't change. Add tests where the weights don't sum to 1 (reject) and a student is missing a component.

#### Stage 3: optimise
**Question**: the ranking is now computed across 2 million students for a state-level merit list, and it must update when new scores arrive.

?? Show the points to hit
Precompute each student's average when scores change (store it), and keep the ranking in an ordered structure: a DB index on `(average DESC, name)` for queries such as "top 100" and "rank of student X" (`COUNT(*) WHERE average > x`), or a Redis sorted set (`ZADD`/`ZREVRANK`) for live ranks. Encode the tie-break into the sort key. Recomputing a full sort on every update is O(n log n) per change, which is wasteful.

#### Interview simulation
**Ask**: "How are ties broken? What should a student with no scores show? Is the average rounded for display only, or also for grading (89.995 → A?)" That last question is a classic. Fix the arithmetic first, then the comparator, then the bounds.

### E4. Sensor moving average monitor

#### Brief
An IoT service keeps the last N temperature readings per sensor and raises an alert when the moving average exceeds a threshold. **Rules**: the window holds the most recent N readings; the average is over the readings currently in the window (fewer than N at the start); an alert fires when the average is **strictly above** the threshold, and only once until it drops back below. **Symptom**: averages are wrong at startup and drift over time; alerts fire repeatedly. Time box: 35 minutes.

#### Files
```java
// MovingAverage.java
public class MovingAverage {
    private final int size;
    private final Deque<Double> window = new ArrayDeque<>();
    private double sum;

    public MovingAverage(int size) { this.size = size; }

    public double add(double value) {
        window.addLast(value);
        sum += value;
        if (window.size() > size) {
            window.removeLast();
        }
        return sum / size;
    }
}
```
```java
// SensorMonitor.java
public class SensorMonitor {
    private final Map<String, MovingAverage> averages = new HashMap<>();
    private final Map<String, Boolean> alerting = new HashMap<>();
    private final double threshold; private final int windowSize;
    private final List<String> alerts = new ArrayList<>();

    public SensorMonitor(double threshold, int windowSize) { this.threshold = threshold; this.windowSize = windowSize; }

    public void onReading(String sensorId, double celsius) {
        MovingAverage ma = averages.computeIfAbsent(sensorId, k -> new MovingAverage(windowSize));
        double avg = ma.add(celsius);
        if (avg >= threshold) {
            alerts.add(sensorId + " high: " + avg);
            alerting.put(sensorId, true);
        } else {
            alerting.put(sensorId, false);
        }
    }

    public List<String> alerts() { return alerts; }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        MovingAverage ma = new MovingAverage(3);
        System.out.println("after 1 reading of 30: expected 30.0, got " + ma.add(30));
        ma.add(30); ma.add(30);
        System.out.println("after 30,30,30,60: expected 40.0, got " + ma.add(60));
        SensorMonitor m = new SensorMonitor(50, 2);
        m.onReading("s1", 60); m.onReading("s1", 60); m.onReading("s1", 60);
        System.out.println("alerts while continuously high: expected 1, got " + m.alerts().size());
        SensorMonitor m2 = new SensorMonitor(50, 1);
        m2.onReading("s2", 50);
        System.out.println("exactly at threshold: expected 0 alerts, got " + m2.alerts().size());
    }
}
```

#### Stage 1: find and fix the bugs
There are 4 planted bugs.

?? Show the bugs
1. **Removes the newest reading**: `removeLast()` drops the value just added. A sliding window evicts the oldest: `removeFirst()`.
2. **Sum isn't updated on eviction**: the evicted value stays in `sum`, so the average drifts upward forever. Use `sum -= window.removeFirst();`.
3. **Divides by the capacity, not the current count**: at startup, 1 reading of 30 averages to 10. Use `sum / window.size()`.
4. **Alert logic**: `>=` should be `>` (strictly above), and it alerts on every reading while high. Only alert on the transition: `if (avg > threshold && !alerting.getOrDefault(id, false)) { alert; alerting.put(id, true); } else if (avg <= threshold) alerting.put(id, false);`.

Also mention floating-point accumulation drift over millions of readings (periodically recompute the sum from the window, or use Kahan summation), and that `alerts()` exposes a mutable list.

#### Stage 2: add a feature
**Task**: ignore obviously broken readings (below −40 °C or above 125 °C, the sensor's rated range) and raise a "sensor fault" alert if 3 consecutive readings are invalid.

?? Show a strong solution
Validate in `onReading` before adding to the average (so bad values don't poison the window). Keep a per-sensor consecutive-invalid counter: reset it on a valid reading; when it hits 3, emit a single fault alert (same edge-triggered approach as above). Put the range in config. Test cases: one spike (ignored, no fault), three spikes (one fault), recovery.

#### Stage 3: optimise
**Question**: 200,000 sensors each send a reading every second, from many threads.

?? Show the points to hit
Thread safety: `HashMap` plus per-sensor mutable state isn't safe. Use `ConcurrentHashMap` and synchronise per sensor (or partition sensors to single-threaded workers by `hash(sensorId) % N`, so each sensor is processed by one thread: no locks, ordered processing). 200K msg/s suggests a stream processor (Kafka keyed by sensorId, consumers per partition) with windowed aggregation (Kafka Streams/Flink). Alerts should go to a queue, not an in-memory list. Memory: N doubles per sensor × 200K is fine for small N.

#### Interview simulation
**Ask**: "Should the average include fewer than N readings at startup, or wait until the window is full? Is the threshold inclusive? Should alerts repeat while high?" Then fix the window (bugs 1–3 together, since they're one concept), and the alert edge-triggering.

### E5. Inventory restock alerts

#### Brief
A warehouse service tracks stock per SKU per warehouse. **Rules**: `ship` reduces stock and fails if not enough; `restock` adds stock (quantity must be positive); an alert is raised once when stock drops **below** the reorder level and re-armed after restocking above it; the warehouse code is case-sensitive, like "BLR-1". **Symptom**: crashes for new SKUs, duplicate alerts, and stock can go negative. Time box: 30 minutes.

#### Files
```java
// StockKey.java
public record StockKey(String warehouse, String sku) {}
```
```java
// Inventory.java
public class Inventory {
    private final Map<StockKey, Integer> stock = new HashMap<>();
    private final Map<String, Integer> reorderLevel = new HashMap<>();
    private final List<String> alerts = new ArrayList<>();

    public void setReorderLevel(String sku, int level) { reorderLevel.put(sku, level); }

    public void restock(String warehouse, String sku, int qty) {
        StockKey k = new StockKey(warehouse, sku);
        stock.put(k, stock.getOrDefault(k, 0) + qty);
    }

    public boolean ship(String warehouse, String sku, int qty) {
        StockKey k = new StockKey(warehouse, sku);
        int current = stock.get(k);
        stock.put(k, current - qty);
        if (current - qty <= reorderLevel.get(sku)) alerts.add("Reorder " + sku + " at " + warehouse);
        return true;
    }

    public int stockOf(String warehouse, String sku) { return stock.getOrDefault(new StockKey(warehouse, sku), 0); }
    public List<String> alerts() { return alerts; }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Inventory inv = new Inventory();
        inv.setReorderLevel("SOAP", 10);
        inv.restock("BLR-1", "SOAP", 15);
        inv.ship("BLR-1", "SOAP", 5);              // 10 left: not below 10
        System.out.println("alerts at exactly reorder level: expected 0, got " + inv.alerts().size());
        inv.ship("BLR-1", "SOAP", 2);              // 8 left
        inv.ship("BLR-1", "SOAP", 2);              // 6 left
        System.out.println("alerts after two shipments below level: expected 1, got " + inv.alerts().size());
        System.out.println("ship 50 of 6: expected false, got " + inv.ship("BLR-1", "SOAP", 50) + ", stock " + inv.stockOf("BLR-1", "SOAP"));
        try { inv.ship("BLR-1", "SHAMPOO", 1); } catch (Exception e) { System.out.println("unknown SKU crashed: " + e); }
        inv.restock("BLR-1", "SOAP", -100);
        System.out.println("negative restock accepted? stock now " + inv.stockOf("BLR-1", "SOAP"));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **NPE for unknown SKU or warehouse**: `stock.get(k)` returns null and unboxing throws. Use `getOrDefault(k, 0)` and return false.
2. **No stock check**: `ship` always succeeds and stock goes negative. Check `current >= qty` before deducting, else return false (or throw).
3. **Boundary**: the rule says *below* the reorder level, so use `<`, not `<=`.
4. **Duplicate alerts**: every shipment below the level alerts again. Track an "alerted" set per key: alert only on the transition from ≥ level to < level, and clear the flag on restock when stock goes back above the level.
5. **Negative restock accepted**: validate `qty > 0` (throw `IllegalArgumentException`).

Also: `reorderLevel.get(sku)` NPEs if no level is configured (default it, or skip alerting), and `alerts()` exposes the mutable list.

#### Stage 2: add a feature
**Task**: support **transfers** between warehouses: `transfer(from, to, sku, qty)` must be all-or-nothing.

?? Show a strong solution
Validate the source has enough stock, then deduct and add in one method (single-threaded here, so it's atomic). In a concurrent version, lock both keys in a consistent order, or use one synchronized method. Reuse the alert logic for the source (it may drop below the level) and the re-arm logic for the destination. Reject `from.equals(to)` and non-positive quantities. In a DB, one transaction with conditional updates (`UPDATE … SET qty = qty - ? WHERE … AND qty >= ?`, checking the affected row count) and lock ordering by key.

#### Stage 3: optimise
**Question**: 300 concurrent order threads call `ship` for popular SKUs during a sale.

?? Show the points to hit
`HashMap` isn't thread-safe, and get-check-put is a race (overselling). Use `ConcurrentHashMap.compute(key, (k, v) -> …)` to do the check and deduction atomically per key (returning a result via a holder), or move stock to the DB with conditional updates, or Redis with a Lua script for hot SKUs. Alerts should be emitted outside the compute lambda (no slow work while holding the bin lock).

#### Interview simulation
**Ask**: "Should a failed shipment throw or return false? Is 'below the reorder level' strict? Should alerts repeat?" Lead with the crash (bug 1), then correctness (2, 5), then alert semantics (3, 4).

### E6. URL query string parser

#### Brief
An API gateway parses query strings into a map. **Rules**: `a=1&b=2` gives `{a:[1], b:[2]}`; repeated keys collect all values in order (`tag=x&tag=y`); values are URL-decoded (`%20` and `+` become spaces); a value may itself contain `=` (base64 tokens); a key without `=` maps to an empty string; empty input gives an empty map. **Symptom**: crashes on some inputs; tokens get truncated. Time box: 30 minutes.

#### Files
```java
// QueryParser.java
public class QueryParser {
    public Map<String, List<String>> parse(String query) {
        Map<String, List<String>> out = new LinkedHashMap<>();
        for (String pair : query.split("&")) {
            String[] kv = pair.split("=");
            String key = kv[0];
            String value = kv[1];
            out.put(key, new ArrayList<>(List.of(value)));
        }
        return out;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        QueryParser p = new QueryParser();
        System.out.println(p.parse("a=1&b=hello%20world"));          // expected {a=[1], b=[hello world]}
        System.out.println(p.parse("tag=x&tag=y"));                  // expected {tag=[x, y]}
        System.out.println(p.parse("token=YWJj=="));                 // expected {token=[YWJj==]}
        System.out.println(p.parse("q=red+shoes"));                  // expected {q=[red shoes]}
        try { System.out.println(p.parse("debug")); } catch (Exception e) { System.out.println("debug crashed: " + e); }   // expected {debug=[]}
        try { System.out.println(p.parse("")); } catch (Exception e) { System.out.println("empty crashed: " + e); }       // expected {}
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **No URL decoding**: use `URLDecoder.decode(value, StandardCharsets.UTF_8)` for both key and value (it also turns `+` into a space).
2. **Values containing `=` are truncated**: `split("=")` splits on every `=`, and trailing empty strings are dropped. Use `pair.split("=", 2)`.
3. **Key without `=` crashes**: `kv[1]` throws `ArrayIndexOutOfBoundsException`. Use `kv.length > 1 ? kv[1] : ""`.
4. **Repeated keys overwrite**: `put` replaces the earlier list. Use `out.computeIfAbsent(key, k -> new ArrayList<>()).add(value)`.
5. **Empty input**: `"".split("&")` returns `[""]`, producing a key `""`. Skip empty pairs (also handles `a=1&&b=2` and a trailing `&`).

Also: null input (return an empty map), and malformed percent-encoding (`%ZZ` throws `IllegalArgumentException`: decide whether to reject the request with 400 or keep the raw value).

#### Stage 2: add a feature
**Task**: add `getInt(map, key, defaultValue)` and `getBoolean(…)` helpers for typed access, with clear errors for invalid values.

?? Show a strong solution
`Optional.ofNullable(map.get(key)).filter(l -> !l.isEmpty()).map(l -> l.get(0))`, then parse with a try/catch that throws a domain exception (`BadRequestException("Parameter 'page' must be an integer")`) mapped to HTTP 400, not a raw `NumberFormatException` (500). For booleans, accept only `true`/`false` (case-insensitive) and maybe `1`/`0`; `Boolean.parseBoolean` silently returns false for "yes", which is a bug source.

#### Stage 3: optimise
**Question**: should you write this parser at all?

?? Show the points to hit
Usually no: use the framework's parser (Spring's `@RequestParam`, `UriComponentsBuilder`, Servlet `getParameterMap`), which handles encoding, repeated keys and edge cases, and is security-reviewed. Custom parsers are a common source of bugs and parameter-pollution vulnerabilities (`role=user&role=admin`: which wins?). If you must, cap the input size and the number of parameters (DoS protection).

#### Interview simulation
**Ask**: "How should repeated keys behave? Should a key without a value be an empty string or absent? What happens on malformed encoding: reject, or keep raw?" Write a table of input → expected output before coding. Interviewers love that for parsers.

### E7. Game leaderboard

#### Brief
A quiz app keeps total points per player and shows the top N. **Rules**: `addScore` accumulates points; ranking is by points descending, ties alphabetical by name; `rankOf(player)` is 1-based (top player is rank 1); asking for more players than exist returns everyone. **Symptom**: the leaderboard shows the lowest scores first, ranks are off by one, and some players with equal points "aren't equal". Time box: 30 minutes.

#### Files
```java
// Leaderboard.java
public class Leaderboard {
    private final Map<String, Integer> points = new HashMap<>();

    public void addScore(String player, int pts) {
        points.put(player, pts);
    }

    public List<String> top(int n) {
        List<Map.Entry<String, Integer>> entries = new ArrayList<>(points.entrySet());
        entries.sort(Map.Entry.comparingByValue());
        List<String> out = new ArrayList<>();
        for (int i = 0; i < n; i++) out.add(entries.get(i).getKey());
        return out;
    }

    public int rankOf(String player) {
        List<String> all = top(points.size());
        return all.indexOf(player);
    }

    public boolean tied(String a, String b) {
        return points.get(a) == points.get(b);
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        Leaderboard lb = new Leaderboard();
        lb.addScore("zara", 500); lb.addScore("zara", 500);   // zara total 1000
        lb.addScore("amit", 1000);
        lb.addScore("bina", 200);
        System.out.println("top 2: expected [amit, zara], got " + lb.top(2));
        System.out.println("rank of amit: expected 1, got " + lb.rankOf("amit"));
        System.out.println("amit tied with zara: expected true, got " + lb.tied("amit", "zara"));
        try { System.out.println("top 10: " + lb.top(10)); } catch (Exception e) { System.out.println("top 10 crashed: " + e); }
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **`addScore` replaces instead of accumulating**: use `points.merge(player, pts, Integer::sum)`.
2. **Sort is ascending**: use `Map.Entry.<String,Integer>comparingByValue().reversed().thenComparing(Map.Entry.comparingByKey())` for descending points with alphabetical ties.
3. **`top(n)` crashes when n > size**: loop to `Math.min(n, entries.size())`.
4. **`rankOf` is 0-based and returns -1 for unknown players**: return `index + 1`, and handle the unknown player explicitly (throw, or return 0 / Optional). It also sorts everything per call: O(n log n).
5. **`tied` uses `==` on `Integer`**: it compares references, which only works for cached values −128..127 (1000 == 1000 is false). Use `Objects.equals(…)` or compare `int`s.

Also ask: should equal points share a rank (1, 1, 3, "competition ranking") or not? That's a product decision worth clarifying.

#### Stage 2: add a feature
**Task**: support weekly leaderboards that reset every Monday 00:00 IST, while keeping all-time totals.

?? Show a strong solution
Keep two maps (or a map keyed by period): `allTime` and `weekly.get(weekKey)`, where `weekKey` is computed from an injected `Clock` in Asia/Kolkata (`LocalDate.now(clock).with(TemporalAdjusters.previousOrSame(MONDAY))`). `addScore` updates both. `top(n, Period)` reads the right one. Old weeks can be archived or dropped. No scheduled "reset" job is needed when keys are derived from time; that's a nice point to make.

#### Stage 3: optimise
**Question**: 5 million players, 20K score updates per second, and the app shows the top 100 plus each player's own rank.

?? Show the points to hit
Sorting on every request is too slow. Use a Redis sorted set: `ZINCRBY lb:week:{key} pts player`, `ZREVRANGE … 0 99 WITHSCORES`, `ZREVRANK` for a player's rank (O(log n)). Encode the tie-break in the score (e.g. points × 10^6 + a value derived from the name or time) or resolve ties in the app for the displayed page. Shard by region if a single key gets too hot.

#### Interview simulation
**Ask**: "Do equal scores share a rank? Is the rank 1-based? What should `rankOf` return for an unknown player?" Then go through the bugs in the order of the demo output.

### E8. Password policy validator

#### Brief
A signup service validates passwords. **Rules** (all must hold): at least 12 characters; at least one uppercase letter, one lowercase letter, one digit and one special character from `!@#$%^&*()-_+=`; must not contain the username (case-insensitive); must not be in the common-password list. The validator must report **all** failed rules, not just the first. **Symptom**: weak passwords are accepted. Time box: 30 minutes.

#### Files
```java
// PasswordPolicy.java
public class PasswordPolicy {
    private static final String SPECIALS = "!@#$%^&*()-_+=";
    private final Set<String> common;

    public PasswordPolicy(Set<String> commonPasswords) { this.common = commonPasswords; }

    public List<String> validate(String username, String pw) {
        List<String> errors = new ArrayList<>();
        if (pw.length() < 12) { errors.add("too short"); return errors; }
        boolean upper = false, lower = false, digit = false, special = false;
        for (char c : pw.toCharArray()) {
            if (Character.isLetter(c)) upper = true;
            if (Character.isLowerCase(c)) lower = true;
            if (Character.isDigit(c)) digit = true;
            if (SPECIALS.indexOf(c) > 0) special = true;
        }
        if (!(upper || lower)) errors.add("needs upper and lower case");
        if (!digit) errors.add("needs a digit");
        if (!special) errors.add("needs a special character");
        if (pw.contains(username)) errors.add("contains username");
        if (common.contains(pw)) errors.add("too common");
        return errors;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        PasswordPolicy p = new PasswordPolicy(Set.of("password123!a", "qwertyuiop1!"));
        System.out.println("all lowercase: " + p.validate("akash", "lowercase123!xyz"));       // expected [needs upper and lower case]
        System.out.println("starts with '!': " + p.validate("akash", "!Strongpass123"));       // expected []
        System.out.println("username upper: " + p.validate("akash", "MyAKASHpass#2026"));      // expected [contains username]
        System.out.println("short + no digit: " + p.validate("akash", "Short!"));              // expected [too short, needs a digit]
        System.out.println("common (case variant): " + p.validate("akash", "Password123!A"));  // expected [too common]
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Uppercase check uses `isLetter`**: any letter counts as uppercase. Use `Character.isUpperCase(c)`.
2. **Case check uses `||`**: the condition passes if either is present. It should require both: `if (!upper || !lower)` (better: separate messages for each).
3. **Special character at index 0 is missed**: `indexOf(c) > 0` ignores `'!'` (index 0). Use `>= 0`.
4. **Early return on length**: the spec says report all failures. Remove `return errors;` after "too short".
5. **Username and common-list checks are case-sensitive**: compare lowercased (`pw.toLowerCase(Locale.ROOT).contains(username.toLowerCase(Locale.ROOT))`, and normalise the common list to lowercase at construction).

Discussion: modern guidance (NIST SP 800-63B) actually prefers length plus breached-password checks over composition rules. Worth mentioning as product feedback, while still implementing the spec.

#### Stage 2: add a feature
**Task**: reject passwords found in known breaches using the "Have I Been Pwned" k-anonymity API (send only the first 5 hex characters of the SHA-1 hash).

?? Show a strong solution
Add a `BreachChecker` interface (testable with a fake). The implementation computes the uppercase SHA-1 hex, calls `GET https://api.pwnedpasswords.com/range/{first5}` with a short timeout, and scans the response lines for the remaining 35 characters. On timeout or error, decide the policy (usually fail open with logging, so signups don't break; ask). Cache recent prefixes. Never log the password or the full hash.

#### Stage 3: optimise
**Question**: the common-password list grows to 10 million entries. Memory and startup time are a concern.

?? Show the points to hit
A `HashSet<String>` of 10M strings costs on the order of 1GB. Options: a **Bloom filter** (about 12MB at 1% false positives: a false positive merely rejects a fine password, which is acceptable), a sorted file with binary search on disk, or delegating to the breach API. Load it lazily or at build time into a compact format.

#### Interview simulation
**Ask**: "Should all failures be reported? Is the username check case-insensitive? Which characters count as special?" Then build a table of test passwords → expected errors (like the demo) before fixing. Validators are about edge cases.

### E9. Bank statement generator

#### Brief
A banking backend builds a monthly statement: the opening balance, then transactions sorted by date (oldest first), each with a running balance, then the closing balance. Debits reduce the balance. Dates come as `dd/MM/yyyy` strings from a legacy system. **Symptom**: balances are off by tiny amounts, the order is wrong in October, and debits increase the balance. Time box: 35 minutes.

#### Files
```java
// Txn.java
public record Txn(String date, String type, double amount, String description) {}   // type: "CREDIT" or "DEBIT", date dd/MM/yyyy
```
```java
// StatementService.java
public class StatementService {
    public List<String> build(double openingBalance, List<Txn> txns) {
        List<Txn> sorted = new ArrayList<>(txns);
        sorted.sort(Comparator.comparing(Txn::date));
        List<String> lines = new ArrayList<>();
        double balance = 0;
        for (Txn t : sorted) {
            if (t.type() == "DEBIT") balance += t.amount(); else balance += t.amount();
            lines.add(t.date() + " " + t.description() + " " + t.amount() + " bal=" + balance);
        }
        lines.add("Closing balance: " + balance);
        return lines;
    }
}
```
```java
// Demo.java
public class Demo {
    public static void main(String[] args) {
        List<Txn> txns = List.of(
            new Txn("10/10/2026", "CREDIT", 0.10, "cashback"),
            new Txn("02/10/2026", "CREDIT", 0.20, "interest"),
            new Txn("15/09/2026", "DEBIT", 100.00, "groceries"),
            new Txn("05/10/2026", new String("DEBIT"), 50.00, "fuel"));
        new StatementService().build(1000.00, txns).forEach(System.out::println);
        // expected order: 15/09 groceries, 02/10 interest, 05/10 fuel, 10/10 cashback
        // expected closing balance: 850.30 exactly
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **`double` for money**: 0.10 + 0.20 isn't 0.30 in binary floating point. Use `BigDecimal` (scale 2) or `long` paise throughout, including the record.
2. **Sorting date strings lexicographically**: `"15/09/2026"` sorts after `"10/10/2026"`. Parse with `DateTimeFormatter.ofPattern("dd/MM/yyyy")` into `LocalDate` and sort by that (ties: by a sequence or posting time, to make the order deterministic).
3. **Opening balance ignored**: `balance` starts at 0. Start at `openingBalance`.
4. **Debit adds**: both branches add. Subtract for DEBIT.
5. **String comparison with `==`**: `t.type() == "DEBIT"` fails for strings not from the literal pool (as in the demo's `new String`). Use `"DEBIT".equals(t.type())`, or better an enum `TxnType` parsed at the boundary, rejecting unknown values.

Also: formatting money for display (`String.format("%.2f")` on BigDecimal or a currency formatter with ₹ and Indian grouping), and validation of negative amounts.

#### Stage 2: add a feature
**Task**: flag transactions that make the balance negative (overdraft) and add an overdraft fee of ₹500 the first time it happens in the month.

?? Show a strong solution
While iterating, after applying each transaction check `balance.signum() < 0`; on the first occurrence in the month, append a synthetic fee line (a DEBIT of 500.00 with a description "Overdraft fee") and apply it. Model fees as transactions so the ledger stays consistent. Ask: should the fee be charged on the statement only, or posted to the account (a separate service)? Statements should be read-only views; fees belong in the ledger. That's a good design point to raise.

#### Stage 3: optimise
**Question**: generate monthly statements for 30 million accounts on the 1st of every month.

?? Show the points to hit
A batch job (Spring Batch or Spark) partitioned by account ranges, reading each account's transactions in date order with an index on `(account_id, posted_at)`. Stream rows rather than loading everything; the opening balance comes from the previous statement's closing balance (or a balance snapshot table), so you never sum all history. Render PDFs asynchronously, store them in S3, notify users. Make the job idempotent and restartable per partition.

#### Interview simulation
**Ask**: "What's the source of the opening balance? How are same-day transactions ordered? Is the amount always positive, with the type giving the sign?" Lead with the money type (it changes the method signatures), then sorting, then the arithmetic bugs.

### E10. Meeting room booking

#### Brief
An office app books meeting rooms. **Rules**: a booking is `[start, end)`: start inclusive, end exclusive, so a 10:00–11:00 meeting and an 11:00–12:00 meeting don't conflict; start must be before end; two bookings in the same room conflict if their intervals overlap at all; `freeRooms(start, end)` returns the rooms with no conflict in that interval. **Symptom**: double bookings happen, back-to-back meetings are rejected, and `freeRooms` sometimes crashes. Time box: 30 minutes.

#### Files
```java
// Booking.java
public record Booking(String room, LocalDateTime start, LocalDateTime end, String owner) {}
```
```java
// RoomScheduler.java
public class RoomScheduler {
    private final List<String> rooms;
    private final List<Booking> bookings = new ArrayList<>();

    public RoomScheduler(List<String> rooms) { this.rooms = rooms; }

    private boolean overlaps(Booking a, LocalDateTime s, LocalDateTime e) {
        return !s.isBefore(a.start()) && !e.isAfter(a.end());
    }

    public boolean book(String room, LocalDateTime s, LocalDateTime e, String owner) {
        for (Booking b : bookings) {
            if (b.room().equals(room) && (overlaps(b, s, e) || s.equals(b.end()))) return false;
        }
        bookings.add(new Booking(room, s, e, owner));
        return true;
    }

    public List<String> freeRooms(LocalDateTime s, LocalDateTime e) {
        List<String> free = rooms;
        for (Booking b : bookings) {
            if (overlaps(b, s, e)) free.remove(b.room());
        }
        return free;
    }
}
```
```java
// Demo.java
public class Demo {
    static LocalDateTime t(int h, int m) { return LocalDateTime.of(2026, 10, 28, h, m); }
    public static void main(String[] args) {
        RoomScheduler rs = new RoomScheduler(new ArrayList<>(List.of("Everest", "Nilgiri")));
        System.out.println("10-11: expected true, got " + rs.book("Everest", t(10, 0), t(11, 0), "a"));
        System.out.println("10:30-11:30 (overlaps): expected false, got " + rs.book("Everest", t(10, 30), t(11, 30), "b"));
        System.out.println("09:00-12:00 (contains): expected false, got " + rs.book("Everest", t(9, 0), t(12, 0), "c"));
        System.out.println("11-12 (back to back): expected true, got " + rs.book("Everest", t(11, 0), t(12, 0), "d"));
        System.out.println("12-11 (invalid): expected false, got " + rs.book("Nilgiri", t(12, 0), t(11, 0), "e"));
        System.out.println("free 10:15-10:45: expected [Nilgiri], got " + rs.freeRooms(t(10, 15), t(10, 45)));
        System.out.println("free 13-14: expected [Everest, Nilgiri], got " + rs.freeRooms(t(13, 0), t(14, 0)));
    }
}
```

#### Stage 1: find and fix the bugs
There are 5 planted bugs.

?? Show the bugs
1. **Overlap only detects containment**: the code checks "new interval inside the existing one". The correct half-open overlap test is `s.isBefore(b.end()) && b.start().isBefore(e)`. That catches partial overlaps and the 9–12 case containing the existing booking.
2. **Back-to-back rejected**: `|| s.equals(b.end())` treats touching intervals as conflicts. Remove it (half-open intervals don't overlap when they touch).
3. **No validation**: start ≥ end should be rejected (return false or throw).
4. **`freeRooms` mutates the room list**: `free = rooms` aliases the field, so each call permanently removes rooms. Copy it: `new ArrayList<>(rooms)`.
5. **Removing from a fixed list / duplicates**: if `rooms` were built with `List.of` it throws `UnsupportedOperationException`; and the demo shows rooms vanishing for later queries. Compute the busy set first, then filter: `rooms.stream().filter(r -> !busy.contains(r)).toList()`.

#### Stage 2: add a feature
**Task**: recurring bookings: "every weekday 10:00–10:30 for 4 weeks", all-or-nothing (if any occurrence conflicts, book none and report the conflicts).

?? Show a strong solution
Generate the occurrences first (skip weekends; consider holidays as a follow-up), check each against the existing bookings, collect the conflicts, and only if there are none add them all (with a shared `seriesId` so the series can be cancelled together). Return a result object listing the conflicts. Discuss time zones (`ZonedDateTime` in Asia/Kolkata) and DST for global offices.

#### Stage 3: optimise
**Question**: a campus has 2,000 rooms and 500K bookings per month; `book` scans every booking.

?? Show the points to hit
Index the bookings per room: a `Map<String, TreeMap<LocalDateTime, Booking>>` keyed by start. Overlap check = look at `floorEntry(s)` (the booking starting at or before s: does it end after s?) and `ceilingEntry(s)` (the next booking: does it start before e?), which is O(log n). In Postgres, an exclusion constraint makes the DB reject overlaps atomically under concurrency: `EXCLUDE USING gist (room WITH =, tsrange(start, "end") WITH &&)`.

#### Interview simulation
**Ask**: "Are the intervals inclusive or exclusive at the end? Can a meeting span midnight? What's the time zone?" Draw the 4 overlap cases (partial left, partial right, inside, containing) and test each; that diagram is the senior signal.
