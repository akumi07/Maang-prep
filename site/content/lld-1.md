## Design principles | P2 | must

### SOLID principles

#### Core idea
SOLID is five principles for object-oriented design that keep code **easy to change**. In LLD interviews you're judged on whether your classes would survive the interviewer's follow-up ("now add a new payment method", "now support EV parking"). SOLID is how you make that answer "add one class" instead of "edit five".

#### How it works
**S: Single Responsibility Principle**: a class should have one reason to change (one actor it serves).
```java
// ❌ Invoice calculates totals, renders PDF, and emails it — three reasons to change
// ✅ InvoiceCalculator, InvoicePdfRenderer, InvoiceMailer
```
**O: Open/Closed Principle**: open for extension, closed for modification. Add behaviour with new code, not by editing tested code.
```java
interface DiscountRule { long apply(Cart c); }
class FestiveDiscount implements DiscountRule { ... }
class FirstOrderDiscount implements DiscountRule { ... }
class PricingEngine {
    private final List<DiscountRule> rules;           // new rule = new class, engine unchanged
    long total(Cart c) { long t = c.subtotal(); for (var r : rules) t -= r.apply(c); return Math.max(t, 0); }
}
// ❌ the alternative: if (type == FESTIVE) … else if (type == FIRST_ORDER) … grows forever
```
**L: Liskov Substitution Principle**: subtypes must be usable anywhere the base type is expected, without surprises: no stronger preconditions, no weaker postconditions, no new exceptions.
```java
// Classic violation: Square extends Rectangle — setWidth() also changes height, breaking callers
// that assume width and height are independent. Real-world: a ReadOnlyList that throws on add()
// while claiming to be a List (java.util's unmodifiable lists are a known LSP compromise).
```
**I: Interface Segregation Principle**: clients shouldn't depend on methods they don't use. Prefer small, role-specific interfaces.
```java
// ❌ interface Machine { print(); scan(); fax(); }  — a basic printer must stub fax()
// ✅ interface Printer { print(); }  interface Scanner { scan(); }  class MultiFunction implements Printer, Scanner
```
**D: Dependency Inversion Principle**: high-level modules depend on **abstractions**, not concrete low-level modules. Both depend on the interface; the concrete class is injected.
```java
class OrderService {                          // high-level policy
    private final PaymentGateway gateway;     // abstraction, owned by the domain
    OrderService(PaymentGateway g) { this.gateway = g; }
}
class RazorpayGateway implements PaymentGateway { ... }   // low-level detail
```
DIP is what makes unit testing (inject fakes) and swapping vendors possible. Spring's DI is the mechanism; DIP is the design idea.

#### Real-world example
At Tata 1mg, payment providers change (Razorpay, Paytm, PayU) and new discount types appear every sale. A codebase with a `PaymentGateway` interface (DIP + OCP) and a list of `DiscountRule`s (OCP) absorbs those changes as new classes. One with `switch (provider)` statements spread across services needs risky edits in many places for every new provider.

#### Interview questions
?? Explain SOLID with one example each.
Give the five with crisp examples, as above: SRP (an Invoice split into calculator, renderer and mailer), OCP (discount rules as strategies), LSP (Square/Rectangle, or a subclass that throws on a parent method), ISP (split printer/scanner interfaces), DIP (a service depending on a `PaymentGateway` interface, with the implementation injected).

?? Isn't SRP just "a class should do one thing"?
Not exactly. Robert Martin's framing is "one reason to change", or one **actor/stakeholder** the class answers to. A class can have several methods; what matters is that changes requested by different parts of the business (finance's tax rules vs marketing's email template) don't land in the same class.

?? How do you know when to apply OCP?
Not everywhere upfront (that's over-engineering). Apply it at points of **expected variation**: payment methods, notification channels, pricing rules, vehicle types. A good heuristic: the second time you add an `else if` for a new type, extract a strategy or polymorphism.

#### Tricky questions
?? Can following SOLID make code worse?
Yes, when it's applied dogmatically: dozens of single-method interfaces with one implementation each, deep indirection, and "enterprise FizzBuzz". Interfaces should exist for real variation, testing seams, or module boundaries. YAGNI balances SOLID.

?? Does a subclass that overrides a method to throw `UnsupportedOperationException` violate LSP?
Yes. Callers relying on the base contract break at runtime. It signals that the hierarchy is wrong: split the interface (ISP) or use composition.

#### Interview simulation
**Interviewer:** "Your parking lot design has `if (vehicle instanceof Car)` in the spot allocator. What's wrong?"

**Answer:** "It violates OCP: adding a Truck or EV means editing the allocator. I'd move the decision into polymorphism or a strategy: each `Vehicle` declares its `SpotSize` (or a `SpotCompatibility` rule), and the allocator asks 'which spot types can fit this vehicle?' through an interface. New vehicles become new classes." Then refactor on the board. Interviewers deliberately poke at `instanceof`/`switch`, so anticipate it.

### DRY, KISS, YAGNI, coupling and cohesion

#### Core idea
Beyond SOLID, a few principles guide everyday design decisions:
- **DRY** (Don't Repeat Yourself): every piece of *knowledge* has one authoritative place.
- **KISS** (Keep It Simple): the simplest design that meets the requirements wins.
- **YAGNI** (You Aren't Gonna Need It): don't build for hypothetical futures.
- **High cohesion, low coupling**: related things stay together; modules depend on each other minimally and through stable interfaces.
- **Composition over inheritance**: build behaviour by combining objects instead of deep class hierarchies.
- **Law of Demeter**: talk to your immediate friends only (avoid `order.getCustomer().getAddress().getCity()` chains).

#### How it works
- **DRY is about knowledge, not text**: two similar-looking code blocks that change for different reasons aren't duplication. Merging them creates coupling (the "wrong abstraction"). Duplicated *business rules* (the tax rate in three services) are the real danger.
- **Coupling types** from worst to best: content (reaching into another module's internals) → shared global state → control (passing flags that change behaviour) → stamp (passing big objects when you need one field) → data (passing just what's needed) → message (events).
- **Cohesion**: a `UserService` that also formats PDFs and sends SMS has low cohesion. Split by responsibility.
- **Composition example**: instead of `class LoggingRetryingHttpClient extends RetryingHttpClient extends HttpClient`, wrap decorators: `new Logging(new Retrying(new BaseClient()))`.
- **Tell, don't ask**: `account.withdraw(amt)` (the object protects its invariant) instead of `if (account.getBalance() >= amt) account.setBalance(...)`.

#### Real-world example
Microservice boundaries are coupling and cohesion at a larger scale. If every change to "orders" also requires changing "inventory" and "payments" together, the boundaries are wrong (high coupling). Well-drawn services own their data and communicate through APIs or events (low coupling), with the related logic in one place (high cohesion).

#### Interview questions
?? What's the difference between coupling and cohesion?
Cohesion measures how closely related the responsibilities *inside* a module are (you want high). Coupling measures how dependent modules are on *each other* (you want low). High cohesion and low coupling let you change one module without rippling changes elsewhere.

?? When does DRY go wrong?
When code that's coincidentally similar but driven by different requirements is merged into a shared abstraction with flags and parameters. Each new requirement adds conditions, and the abstraction becomes harder to change than the duplication was. "Duplication is far cheaper than the wrong abstraction" (Sandi Metz).

#### Tricky questions
?? KISS and YAGNI vs designing for extensibility in an LLD interview: which wins?
Both, deliberately. Build the simple version that meets the stated requirements, but put **seams** (interfaces, strategies) at the variation points the interviewer is likely to extend (payment, pricing, notification, allocation strategy). Say it out loud: "I'll keep this simple, but make spot allocation a strategy because I expect it to change."

#### Interview simulation
If the interviewer asks "Why did you create this interface?", answer with the expected variation or testability reason. If you can't name one, remove it. Showing that you consciously trade simplicity against flexibility is the senior signal.

### UML class and sequence diagrams

#### Core idea
In LLD interviews you'll sketch **class diagrams** (structure: classes, fields, methods, relationships) and sometimes **sequence diagrams** (behaviour: who calls whom, in what order). You don't need perfect UML syntax, just clear, conventional notation.

#### How it works
**Relationships (weakest to strongest)**
| Relationship | Meaning | Notation | Example |
|---|---|---|---|
| Dependency | uses temporarily (a parameter or local) | dashed arrow `- - >` | `OrderService` uses `Clock` in a method |
| Association | has a reference | solid line `——>` | `Ticket` → `ParkingSpot` |
| Aggregation | has-a, parts can exist independently | hollow diamond `◇——` | `Team ◇—— Player` |
| Composition | owns, parts die with the whole | filled diamond `◆——` | `Order ◆—— OrderItem` |
| Inheritance | is-a | hollow triangle `——▷` | `Car ——▷ Vehicle` |
| Realisation | implements an interface | dashed hollow triangle `- - ▷` | `UpiPayment - - ▷ PaymentMethod` |

Multiplicity: `1`, `0..1`, `*`, `1..*` at the line ends. Visibility: `+` public, `-` private, `#` protected.

**Text-friendly class diagram (fine on a whiteboard or in CoderPad)**
```
ParkingLot 1 ◆── * Floor 1 ◆── * ParkingSpot
ParkingSpot <|-- CompactSpot, LargeSpot, EVSpot
Vehicle <|-- Car, Bike, Truck
Ticket ──> ParkingSpot, Vehicle
PricingStrategy <|.. HourlyPricing, FlatPricing
EntryGate ──> SpotAllocationStrategy
```

**Sequence diagram (text)**
```
Driver -> EntryGate: enter(vehicle)
EntryGate -> SpotAllocator: allocate(vehicle.type)
SpotAllocator -> Floor: findFreeSpot(type)
Floor --> SpotAllocator: spot
EntryGate -> TicketRepo: save(new Ticket(vehicle, spot, now))
EntryGate --> Driver: ticket
```

#### Real-world example
Design reviews at product companies often start with a sequence diagram of the critical flow (checkout, payment callback) because it exposes the tricky parts: what happens if step 4 fails after step 3 succeeded? That's where idempotency, retries and compensations get designed.

#### Interview questions
?? Aggregation vs composition?
Both are whole-part. In composition the part's lifecycle is bound to the whole (delete an Order and its OrderItems go too; items aren't shared). In aggregation, parts exist independently and can be shared (a Department has Employees, who remain if the department is dissolved).

?? Association vs dependency?
An association is a structural, long-lived relationship (a field reference). A dependency is a transient usage (a method parameter, local variable or static call). A dependency is weaker.

#### Tricky questions
?? Should you draw every getter and setter in an interview class diagram?
No. Show the key fields, the important behaviour methods, and the relationships. The diagram communicates design decisions, not a code dump.

#### Interview simulation
In any LLD round: after clarifying requirements, spend 5–8 minutes on the entity list and a quick class diagram with relationships and multiplicities, and confirm it with the interviewer **before** coding. "Here are the main entities and how they relate. Does this match what you have in mind?" catches misunderstandings while they're cheap to fix.

## Design patterns | P2 | must

### Creational patterns: Singleton, Factory, Abstract Factory, Builder, Prototype

#### Core idea
Creational patterns control **how objects are created**, so that client code doesn't depend on concrete classes or messy construction logic.

#### How it works
**Singleton**: exactly one instance, globally accessible.
```java
public enum IdGenerator { INSTANCE; private final AtomicLong seq = new AtomicLong(); public long next() { return seq.incrementAndGet(); } }
// or holder idiom (lazy, thread-safe)
public final class Config { private Config() {} private static class H { static final Config I = new Config(); } public static Config get() { return H.I; } }
```
Use it sparingly: it's global state, hard to test and hides dependencies. In Spring apps, prefer singleton-scoped beans injected via DI.

**Factory Method / Simple Factory**: centralise "which concrete class?" decisions.
```java
public final class PaymentProcessorFactory {
    private final Map<PaymentMode, PaymentProcessor> processors;
    public PaymentProcessorFactory(List<PaymentProcessor> all) {
        processors = all.stream().collect(Collectors.toMap(PaymentProcessor::mode, p -> p));
    }
    public PaymentProcessor get(PaymentMode mode) {
        return Optional.ofNullable(processors.get(mode)).orElseThrow(() -> new IllegalArgumentException("Unsupported " + mode));
    }
}
```
(The map-based registry avoids a growing `switch`, which is OCP-friendly.)

**Abstract Factory**: create *families* of related objects that must match.
```java
interface UiFactory { Button button(); Checkbox checkbox(); }
class DarkUiFactory implements UiFactory { ... }   // dark button + dark checkbox always consistent
```
Example: a cloud-provider factory creating a matching `Storage`, `Queue` and `SecretsClient` for AWS vs GCP.

**Builder**: construct complex objects step by step with readable, validated construction (avoids telescoping constructors with 10 parameters).
```java
public final class SearchQuery {
    private final String text; private final int page, size; private final Set<String> filters;
    private SearchQuery(Builder b) { text = b.text; page = b.page; size = b.size; filters = Set.copyOf(b.filters); }
    public static Builder builder(String text) { return new Builder(text); }
    public static final class Builder {
        private final String text; private int page = 0, size = 20; private final Set<String> filters = new HashSet<>();
        private Builder(String text) { this.text = Objects.requireNonNull(text); }
        public Builder page(int p) { this.page = p; return this; }
        public Builder size(int s) { if (s < 1 || s > 100) throw new IllegalArgumentException(); this.size = s; return this; }
        public Builder filter(String f) { filters.add(f); return this; }
        public SearchQuery build() { return new SearchQuery(this); }
    }
}
```
**Prototype**: create new objects by copying an existing configured instance (`clone`, or copy constructors). Useful when construction is expensive or objects are configured at runtime (game entities, document templates).

#### Real-world example
JDK and Spring are full of these: `Calendar.getInstance()` and `List.of()` (factories), `StringBuilder`, `HttpClient.newBuilder()`, `WebClient.builder()`, Lombok `@Builder` (builder), `Runtime.getRuntime()` (singleton), Spring's `BeanFactory` (factory), and prototype-scoped beans.

#### Interview questions
?? How do you make a thread-safe singleton, and what are the pitfalls?
An enum singleton (serialisation- and reflection-safe) or the holder idiom (lazy via class-init guarantees). Volatile double-checked locking also works. Pitfalls: reflection calling the private constructor, serialisation creating a second instance (`readResolve` fixes it), multiple class loaders, and testability (global state). In DI frameworks you rarely need a hand-written singleton.

?? Factory vs Builder?
A factory decides **which** class to instantiate, usually in one step. A builder handles **how** to assemble one complex object, step by step, with optional parameters and validation.

#### Tricky questions
?? Why is Singleton considered an anti-pattern by many?
It introduces hidden global state, tight coupling (callers reach for `getInstance()` instead of receiving dependencies), difficulty mocking in tests, and hidden lifecycle and concurrency issues. Dependency injection with a single-instance scope gives the benefit without those costs.

#### Interview simulation
If asked "Which patterns did you use in your LLD?", name them with the *reason*: "Factory to pick the payment processor by mode, so new modes are new classes; Builder for the immutable SearchQuery because it has many optional fields; and I avoided Singleton by injecting a shared instance." Patterns justified by forces score; pattern-name-dropping doesn't.

### Structural patterns: Adapter, Decorator, Proxy, Facade, Composite

#### Core idea
Structural patterns describe how to **compose classes and objects** into larger structures while keeping them flexible.

#### How it works
**Adapter**: make an incompatible interface fit the one your code expects.
```java
interface PaymentGateway { PaymentResult charge(String orderId, long amountPaise); }
class StripeAdapter implements PaymentGateway {            // wraps the vendor SDK
    private final StripeClient stripe;
    public PaymentResult charge(String orderId, long paise) {
        var pi = stripe.paymentIntents().create(Map.of("amount", paise, "currency", "inr", "metadata", Map.of("orderId", orderId)));
        return PaymentResult.from(pi.getStatus(), pi.getId());
    }
}
```
**Decorator**: add behaviour to an object **dynamically** by wrapping it with the same interface. You can stack decorators.
```java
interface DataSource { byte[] read(String key); }
class CachingDataSource implements DataSource { private final DataSource inner; ... /* check cache, else inner.read */ }
class MetricsDataSource implements DataSource { private final DataSource inner; ... /* time inner.read */ }
DataSource ds = new MetricsDataSource(new CachingDataSource(new S3DataSource()));
```
Java's `BufferedInputStream(new GZIPInputStream(new FileInputStream(f)))` is the canonical example.

**Proxy**: a stand-in that **controls access** to a real object: lazy loading (Hibernate entity proxies), remote access (RPC stubs), security checks, caching, Spring AOP (`@Transactional`). Structurally it looks like a decorator; the intent differs (control vs add features).

**Facade**: one simple interface over a complex subsystem.
```java
class CheckoutFacade {
    // hides inventory, pricing, payment, notification orchestration behind one call
    public OrderConfirmation checkout(Cart cart, PaymentMode mode) { ... }
}
```
**Composite**: treat individual objects and groups uniformly (tree structures).
```java
interface PriceComponent { long price(); }
record Item(long price) implements PriceComponent {}
record Bundle(List<PriceComponent> parts, int discountPct) implements PriceComponent {
    public long price() { return parts.stream().mapToLong(PriceComponent::price).sum() * (100 - discountPct) / 100; }
}
```
Examples: file systems (a file or folder), UI component trees, org charts, nested product bundles.

**Others worth knowing**: **Bridge** (separate abstraction from implementation so both vary: `Notification` × `Channel`), **Flyweight** (share intrinsic state to save memory: Java's Integer cache, glyphs in text editors).

#### Real-world example
Your NeuronixAI "Spring AI orchestration layer that routes requests across chat, RAG, document, research and coding capabilities" is a **Facade** (one entry point) over **Strategy** implementations, possibly with **Adapters** around different LLM providers (OpenAI, Anthropic, local models) behind one `ChatModel` interface. That's exactly how Spring AI itself is designed.

#### Interview questions
?? Decorator vs Proxy vs Adapter?
All three wrap an object. **Adapter** changes the interface (makes A look like B). **Decorator** keeps the same interface and adds responsibilities, often stacked. **Proxy** keeps the same interface and controls access (lazy, remote, security, caching), usually managing the real object's lifecycle.

?? When would you use a Facade?
When clients need a simple way to do a common task that involves many subsystems: checkout orchestration, an SDK hiding HTTP details, or a legacy module hidden behind a clean API (an anti-corruption layer). It reduces coupling between clients and subsystem internals.

#### Tricky questions
?? Is inheritance a valid alternative to Decorator?
Only for a fixed set of combinations. For N optional features, inheritance needs up to 2^N subclasses (`CachingMetricsRetryingClient`…). Decorators combine at runtime with N classes.

#### Interview simulation
If the interviewer says "Now add caching and metrics to the repository without changing it", reach for Decorators: wrap the repository interface. Explain the order (metrics outside the cache means you measure cache hits too). That's a common follow-up in LLD rounds.

### Behavioral patterns: Strategy, Observer, State, Command, Chain of Responsibility, Template Method, Iterator

#### Core idea
Behavioral patterns are about **how objects interact and distribute responsibility**. They're the patterns you'll use most in LLD rounds, because interviewers love follow-ups that change *behaviour*.

#### How it works
**Strategy**: a family of interchangeable algorithms behind one interface, chosen at runtime.
```java
interface SpotAllocationStrategy { Optional<ParkingSpot> allocate(List<Floor> floors, VehicleType t); }
class NearestToEntryStrategy implements SpotAllocationStrategy { ... }
class FillLowestFloorFirst implements SpotAllocationStrategy { ... }
```
Use it for pricing, allocation, matching, ranking, retry policies and payment methods.

**Observer**: when a subject changes, its subscribers are notified (publish/subscribe inside a process).
```java
interface OrderListener { void onStatusChanged(Order o, Status from, Status to); }
class Order { private final List<OrderListener> listeners = new CopyOnWriteArrayList<>(); ... notify on transitions }
// Listeners: CustomerNotifier, AnalyticsTracker, InventoryReleaser
```
Spring's `ApplicationEventPublisher` + `@EventListener` is the framework version; Kafka is the distributed version.

**State**: an object changes behaviour when its internal state changes. Each state is a class, which replaces big `switch (state)` blocks.
```java
interface VendingState { void insertCoin(VendingMachine m, int c); void select(VendingMachine m, String code); void dispense(VendingMachine m); }
class IdleState implements VendingState { ... }   class HasMoneyState ... class DispensingState ...
// Machine delegates: state.insertCoin(this, c); states call m.setState(...)
```
**Command**: encapsulate a request as an object, so you can queue, log, undo or retry it.
```java
interface Command { void execute(); void undo(); }
class MoveCommand implements Command { ... }   // text editor undo stack, job queues, macro recording
```
**Chain of Responsibility**: pass a request along a chain of handlers until one handles it (or each processes part of it).
```java
abstract class Handler { private Handler next; Handler linkWith(Handler n) { this.next = n; return n; }
    void handle(Request r) { if (next != null) next.handle(r); } }
// AuthHandler -> RateLimitHandler -> ValidationHandler -> BusinessHandler
```
Examples: servlet filters and the Spring Security filter chain, logging levels, ATM cash dispensing (₹2000 → ₹500 → ₹100 handlers), approval workflows.

**Template Method**: a base class defines the algorithm's skeleton; subclasses fill in steps.
```java
abstract class ReportExporter {
    public final void export() { var data = fetch(); var rows = transform(data); write(rows); }   // fixed skeleton
    protected abstract List<Row> transform(Data d);
    protected abstract void write(List<Row> rows);
}
```
Spring's `JdbcTemplate` and `RestTemplate` are template-method or callback hybrids.

**Iterator**: traverse a collection without exposing its structure (`Iterator`, `Spliterator`).

**Also know**: **Mediator** (objects communicate through a central mediator, like an air-traffic controller or chat room), **Memento** (snapshot state for undo), **Visitor** (add operations to a class hierarchy without changing it; sealed types plus pattern matching are the modern Java alternative).

#### Real-world example
An order lifecycle (`CREATED → PAID → PACKED → SHIPPED → DELIVERED`, or `CANCELLED`/`REFUNDED`) is a **State machine**: illegal transitions (cancel after delivery) are rejected in one place. Each transition publishes an event (**Observer**/Kafka) that notifications and analytics consume. Pricing uses **Strategy**, and the API passes through a **Chain** of filters. One feature can naturally use four patterns.

#### Interview questions
?? Strategy vs State?
Both delegate behaviour to interchangeable objects. In **Strategy**, the client picks the algorithm, and strategies don't know about each other. In **State**, the object switches its own state as events happen, and states often trigger transitions to other states. Strategy is about *how to do X*; State is about *what doing X means right now*.

?? Observer: what are the pitfalls?
Memory leaks if listeners aren't unregistered, unexpected ordering, a slow listener blocking the publisher (synchronous notification), exceptions in one listener breaking the others, and hard-to-trace flows. Mitigations: async dispatch with error isolation, weak references or explicit unsubscribe, and for cross-service events, a durable broker with retries.

?? Where have you seen Chain of Responsibility in real frameworks?
Servlet filters, the Spring Security `FilterChain`, Netty `ChannelPipeline` handlers, OkHttp interceptors, and logging appenders.

#### Tricky questions
?? Isn't the State pattern overkill for a 3-state enum?
Often, yes. An enum with a transition map (`Map<State, Set<State>>`) plus validation is simpler. Use State classes when each state has substantial, different behaviour for several operations. Say this trade-off aloud; it shows judgement.

#### Interview simulation
If an interviewer asks you to design a vending machine, traffic light, order lifecycle or document workflow, name the **State** pattern early, draw the state diagram (states and events), and show how illegal events are handled per state. Then add Observer for notifications. State diagrams are fast to draw and impress.

### When not to use patterns: anti-patterns and over-engineering

#### Core idea
Patterns are tools for **specific forces** (expected variation, decoupling, complexity hiding). Applied without those forces, they add indirection and slow everyone down. Interviewers check that you know **when not** to use them, and that you can recognise common **anti-patterns**.

#### How it works
**Over-engineering signals**
- Interfaces with exactly one implementation and no testing need ("IUserService / UserServiceImpl" everywhere).
- Factories that build one class; abstract factories for one family.
- Deep inheritance hierarchies (more than 2–3 levels).
- Configuration-driven "frameworks" for problems that occur once.

**Common anti-patterns**
| Anti-pattern | Symptom | Fix |
|---|---|---|
| **God object** | one `Manager` class with 3,000 lines doing everything | split by responsibility |
| **Anemic domain model** | entities with only getters and setters; all logic in services | put behaviour that protects invariants in the domain objects (`order.cancel()`) |
| **Primitive obsession** | `String` for email, `double` for money, `int` for status | value objects (`Email`, `Money`), enums |
| **Shotgun surgery** | one change requires edits in many classes | consolidate the responsibility |
| **Feature envy** | a method uses another class's data more than its own | move it to that class |
| **Magic numbers/strings** | `if (status == 3)` | named constants or enums |
| **Boolean flag parameters** | `send(msg, true, false)` | separate methods or a parameter object |
| **Singleton abuse** | global mutable state everywhere | dependency injection |
| **Distributed monolith** | microservices that must deploy together and share a DB | revisit the boundaries |

**Rule of three**: duplicate once, and abstract when the third occurrence shows the real pattern.

#### Real-world example
`double` for money is a classic production bug: `0.1 + 0.2 = 0.30000000000000004`, giving rounding errors in invoices. Payment systems use `long` minor units (paise) or `BigDecimal` with explicit rounding, wrapped in a `Money` value object.

#### Interview questions
?? What is an anemic domain model and why is it criticised?
Domain objects hold only data while all the business rules live in service classes, so invariants can be bypassed by anyone setting fields, and the logic scatters across services. A richer model puts rules with the data (`order.addItem()` validates stock and limits). It's not always wrong (simple CRUD), but for complex domains it leads to duplication and bugs.

?? How do you avoid over-engineering in an LLD interview?
Implement the stated requirements cleanly. Add abstraction only at the points the interviewer hints will change, or where it makes testing possible. Name the extension points verbally instead of building them all ("If we later need X, this strategy interface is where it would plug in").

#### Tricky questions
?? Your interviewer says "this is too simple, where are the patterns?" How do you respond?
Explain the deliberate choice, then show where a pattern *would* go when the requirement appears ("Right now there's one pricing rule, so it's a method. If we add surge or subscription pricing, I'd extract a PricingStrategy here"), and offer to refactor live. That shows judgement rather than pattern-matching.

#### Interview simulation
At the end of an LLD round, interviewers often ask "What would you improve?" Have a list ready: thread safety of shared state, persistence instead of in-memory maps, extracting strategies at variation points, validation and error handling, and tests. Pointing out your own design's limits honestly is a strong positive signal.

## Machine coding approach | P3 | must

### How to run a 60–90 minute LLD or machine-coding round

#### Core idea
LLD and machine-coding rounds (very common at Indian product companies: Flipkart, Swiggy, Uber, PhonePe, Atlassian, Razorpay, Amazon's OOD round) test whether you can turn a vague problem into **working, extensible, readable code** under time pressure while communicating clearly. The process matters as much as the code.

#### How it works
**Time plan (90 minutes; scale down for 60)**
| Time | Step | What you do |
|---|---|---|
| 0–8 min | **Clarify requirements** | ask questions, list functional requirements, agree on scope (in and out) |
| 8–15 | **Entities and relationships** | nouns become classes, verbs become methods; draw a quick class diagram; identify patterns |
| 15–20 | **APIs / interfaces** | public methods of the main service(s); input and output; error cases |
| 20–70 | **Code** | interfaces and models first, then core logic, then a driver/demo in `main` |
| 70–80 | **Edge cases and concurrency** | thread safety, validation, exceptions |
| 80–90 | **Demo and extensions** | run it, walk through a scenario, discuss how to extend |

**Clarifying-question checklist (adapt per problem)**
- Who are the actors? (user, admin, system)
- What are the core use cases? Which are *must-have* for this round?
- Scale and concurrency: is it single process or concurrent users?
- In-memory, or must it persist? (Usually in-memory with repository interfaces.)
- Are there special rules: pricing, limits, priorities, failure handling?
- Input and output format: a CLI, method calls, or the given test harness?

**Code-quality checklist evaluators use**
- Clear package structure: `model`, `service`, `repository`, `strategy`, `exception`.
- Interfaces at variation points; no `instanceof` chains.
- Immutable value objects where possible; enums for fixed sets.
- Meaningful names; small methods; no god class.
- Validation plus custom exceptions (`SpotNotAvailableException`).
- Thread safety where shared state exists (ConcurrentHashMap, locks on the right granularity).
- A **working demo**: many companies reject non-running code regardless of design.
- Bonus: a few unit tests.

**Skeleton to start fast**
```java
// model/   — entities & value objects (records/enums)
// repository/ — interfaces + InMemory implementations (ConcurrentHashMap)
// service/ — business logic, depends on repository interfaces + strategies
// strategy/ — pluggable algorithms
// exception/ — domain exceptions
// Main.java — driver with a scenario that exercises happy path + edge cases
```

#### Real-world example
Machine-coding rounds at Flipkart or Swiggy typically give a written problem (e.g. "design a cab booking system with the following commands"), sometimes with sample input and output, and evaluate on: runs and passes the scenarios, extensibility (they add a requirement in the last 15 minutes), code readability, and handling of edge cases. Practising 10–15 problems end to end under a timer is the most effective preparation.

#### Interview questions
?? What do interviewers look for in a machine-coding round?
Working code first; then modularity and extensibility (can a new requirement be added by adding classes?); readability (naming, structure); correctness on edge cases; concurrency awareness; and communication (clarifying, explaining trade-offs). Over-engineered code that doesn't run scores lower than simple, clean, working code.

?? Should you use a database in an LLD round?
Usually not. Use in-memory storage behind **repository interfaces**, so a DB could be plugged in later. Mention that persistence would replace the InMemory implementations.

#### Tricky questions
?? You're 60 minutes in and realise your design has a flaw. What do you do?
Say so explicitly and decide quickly: if the fix is local, refactor; if not, finish a working version and explain how you'd restructure. Hiding it is worse than acknowledging it. Interviewers value self-correction.

#### Interview simulation
**Opening script (practise saying this):** "Before I start, let me make sure I understand the scope. The core use cases are A, B and C. Should I also handle D? I'll assume in-memory storage and a single process, but I'll make the shared state thread-safe since multiple users can act at once. I'll keep persistence behind repository interfaces. I'll start with the entities, show you a quick class diagram, then code the core flow and a demo. Does that sound good?" Then go. Every LLD problem lesson in this track follows this flow.
