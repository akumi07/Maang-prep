## Language & OOP | P1 | must

### The four pillars of OOP

#### Core idea
Object-oriented programming organises code around **objects** that bundle state (fields) and behaviour (methods). Interviewers rarely want the textbook definitions. They want to see that you know *why* each pillar exists and what goes wrong without it.

| Pillar | What it means | Why it matters in real code |
|---|---|---|
| **Encapsulation** | Hide internal state; expose behaviour through methods | Lets you change internals (e.g. swap a `List` for a `Set`) without breaking callers; protects invariants |
| **Abstraction** | Expose *what* something does, hide *how* | Callers depend on `PaymentGateway.charge()`, not on Razorpay's HTTP details |
| **Inheritance** | A class reuses and specialises another (`is-a`) | Code reuse and a common type, but creates tight coupling |
| **Polymorphism** | One interface, many implementations; the call is resolved at runtime | Add a new `NotificationChannel` without touching the code that sends notifications |

#### How it works
- **Encapsulation** is enforced with access modifiers: `private` (class only), package-private (no keyword, same package), `protected` (package + subclasses), `public`. A well-encapsulated class has private fields, validates inputs in its constructor/methods, and never returns its internal mutable collections directly (return `List.copyOf(items)` or `Collections.unmodifiableList(items)`).
- **Abstraction** is expressed with interfaces and abstract classes. The rule of thumb: depend on the most abstract type that gives you what you need (`List`, not `ArrayList`; `Map`, not `HashMap`).
- **Inheritance** uses `extends`. The subclass inherits non-private members. Constructors are *not* inherited; the subclass constructor must call `super(...)` (implicitly or explicitly) first.
- **Polymorphism** comes in two forms:
  - *Compile-time (static)*: **method overloading**: same name, different parameter lists. The compiler picks the method from the *declared* types of the arguments.
  - *Runtime (dynamic)*: **method overriding**: the subclass provides its own implementation of an inherited method. The JVM picks the method from the *actual* object type through **dynamic dispatch** (a virtual method table, or vtable, lookup).

```java
interface Notifier { void send(String userId, String msg); }

class EmailNotifier implements Notifier {
    public void send(String userId, String msg) { /* SMTP */ }
}
class SmsNotifier implements Notifier {
    public void send(String userId, String msg) { /* SMS gateway */ }
}

// Caller depends only on the abstraction. Adding PushNotifier needs no change here.
class OrderService {
    private final List<Notifier> notifiers;
    OrderService(List<Notifier> notifiers) { this.notifiers = notifiers; }
    void onOrderPlaced(String userId) {
        notifiers.forEach(n -> n.send(userId, "Order placed")); // runtime polymorphism
    }
}
```

#### Real-world example
In a Spring Boot service, every `@Service` that depends on an interface (say `InventoryClient`) is using abstraction and polymorphism: in production Spring injects `HttpInventoryClient`; in tests you inject a fake. At Tata 1mg-style search, a `SearchRanker` interface with `PopularityRanker` and `PersonalisedRanker` implementations lets you A/B test ranking strategies without touching the controller.

#### Interview questions
?? What is the difference between overloading and overriding?
Overloading is the same method name with a different parameter list in the same class (or subclass). It's resolved at **compile time** from the declared argument types. The return type alone can't differ.
Overriding is a subclass redefining an inherited instance method with the **same signature**. It's resolved at **runtime** from the actual object type.
Overriding rules: the return type may be covariant (a subtype); access can't be more restrictive; it can't throw broader *checked* exceptions; `static`, `private` and `final` methods can't be overridden.

?? Why is composition often preferred over inheritance?
Inheritance couples the subclass to the parent's implementation (the "fragile base class" problem): a change in the parent can silently break children. It's also fixed at compile time, and Java allows only one superclass. Composition (holding a reference to another object and delegating to it) lets you swap behaviour at runtime, test with mocks, and combine several behaviours.
Classic example: `class Stack extends Vector` in the JDK exposes `insertElementAt`, breaking stack semantics. A `Stack` that *has* a `Deque` wouldn't.
Use inheritance only for a true *is-a* relationship where the subclass honours every promise of the parent (Liskov).

?? Can you achieve encapsulation without getters and setters?
Yes, and often you should. Encapsulation means the object protects its invariants. A class with private fields plus a public setter for every field is barely encapsulated, because anyone can put it in an invalid state. Prefer behaviour methods: `account.withdraw(amount)` validates the balance; `account.setBalance(x)` doesn't.

#### Tricky questions
?? Is Java 100% object-oriented?
No. It has primitive types (`int`, `boolean`…) that aren't objects, and `static` members that belong to the class rather than an object. Wrapper classes and autoboxing bridge the gap.

?? Can you override a static method? What happens with this code?
```java
class A { static void hi() { System.out.println("A"); } }
class B extends A { static void hi() { System.out.println("B"); } }
A obj = new B();
obj.hi();
```
It prints `A`. Static methods are **hidden**, not overridden: the call is bound at compile time using the *declared* type `A`. Calling static methods through an instance is legal but misleading; IDEs warn about it.

?? Are fields polymorphic?
No. Fields are resolved by declared type. If `A` and `B` both declare `int x`, then `A ref = new B(); ref.x` reads `A`'s field. Only instance methods are dynamically dispatched.

?? What happens if a constructor calls an overridable method?
The subclass override runs **before the subclass's fields are initialised**, so it can see `null`s or zeros. This is a classic bug, so never call overridable methods from a constructor.

#### Interview simulation
**Interviewer:** "Explain polymorphism with an example from your work."

**Clarify first (one quick question):** "Do you want runtime polymorphism specifically, or both compile-time and runtime?" Most interviewers mean runtime.

**Structure your answer:**
1. One-line definition: "One interface, many implementations, with the method chosen at runtime by the actual object type."
2. Concrete example from your project: "In our notification flow, `OrderService` holds a `List<Notifier>`. Email, SMS and push are separate implementations, and adding WhatsApp meant adding one class with no change to `OrderService`."
3. Mechanism: "The JVM uses dynamic dispatch through the vtable; overloads, in contrast, are chosen at compile time."
4. Trade-off: "It's the basis of the open/closed principle and of mocking in tests."

Expect follow-ups on overriding rules, static hiding, or composition vs inheritance.

### Abstract class vs interface

#### Core idea
Both define a type that other classes implement or extend, but they model different things:
- An **interface** is a *capability contract* ("can be compared", "can send notifications"). A class can implement many.
- An **abstract class** is a *partial implementation* with shared state for a family of closely related classes. A class can extend only one.

#### How it works
| | Interface | Abstract class |
|---|---|---|
| Multiple inheritance | A class can implement many | Only one superclass |
| State | Only `public static final` constants | Instance fields of any visibility |
| Constructors | None | Yes (called via `super`) |
| Methods | abstract, `default` (Java 8), `static` (Java 8), `private` (Java 9) | Any: abstract or concrete, any access level |
| Access of members | Implicitly `public` | Any |
| Use when | Defining a role many unrelated classes can play | Sharing code and state among closely related classes |

**Default methods** were added in Java 8 so the JDK could add `forEach`, `stream()` etc. to `Collection` without breaking every existing implementation. If a class inherits the same default method from two interfaces, it **must override** it and may call one explicitly: `A.super.hello()`.

```java
abstract class BaseRepository<T, ID> {
    protected final DataSource ds;               // shared state
    protected BaseRepository(DataSource ds) { this.ds = ds; }
    public Optional<T> findById(ID id) {          // shared template
        return query("SELECT * FROM " + table() + " WHERE id = ?", id);
    }
    protected abstract String table();            // subclasses fill in
    protected abstract Optional<T> query(String sql, ID id);
}

interface Auditable {                             // capability
    Instant createdAt();
    default boolean isOlderThan(Duration d) {
        return createdAt().isBefore(Instant.now().minus(d));
    }
}
```

#### Real-world example
Spring's `JpaRepository` is an interface (a capability you get by extending), while `AbstractController`-style base classes in older Spring MVC were abstract classes sharing state such as message converters. In your code: a `PaymentGateway` interface (Stripe, Razorpay implementations) vs an `AbstractKafkaConsumer` that holds the retry/backoff logic and leaves `handle(record)` abstract.

#### Interview questions
?? When would you choose an abstract class over an interface after Java 8?
When implementations need **shared mutable state** or **constructors**, when you want **non-public** helper methods visible to subclasses (`protected`), or when you want to enforce a template method with `final` steps. Otherwise prefer interfaces: they keep implementations free to extend something else and are easier to mock.

?? What is the diamond problem and how does Java handle it?
If class C inherits the same method from two parents, which one runs? Java avoids it for classes by allowing only single inheritance. For interfaces with conflicting `default` methods, compilation fails unless C overrides the method; inside it you can pick with `InterfaceA.super.method()`. Rules: class methods win over interface defaults; a more specific interface wins over a less specific one.

?? What is a functional interface?
An interface with exactly one abstract method (it may have any number of default/static methods), e.g. `Runnable`, `Comparator`, `Function`. It can be the target of a lambda. `@FunctionalInterface` makes the compiler enforce the rule.

#### Tricky questions
?? Can an abstract class have a constructor if you can't instantiate it?
Yes. It runs when a subclass is instantiated (via `super(...)`) and initialises the abstract class's fields.

?? Can an interface have private methods? Static methods?
Private methods since Java 9 (to share code between default methods). Static methods since Java 8. Static interface methods are **not inherited** by implementing classes; you call them as `MyInterface.util()`.

?? Can an abstract class have zero abstract methods?
Yes. It just can't be instantiated. It's useful as a base that should never stand alone (e.g. `HttpServlet`).

#### Interview simulation
**Interviewer:** "Interface or abstract class: which would you use for a payment processing module?"

**Clarify first:** "Do the payment providers share logic, like retry, idempotency checks or logging, or are they completely independent integrations?"

**Model answer:** "I'd define a `PaymentGateway` interface as the contract that callers depend on. If Stripe and Razorpay share real logic, like idempotency-key handling and retry with backoff, I'd add an `AbstractPaymentGateway` that implements the interface, holds that shared code, and leaves `doCharge()` abstract. Callers still depend only on the interface, so tests can mock it and a new provider can skip the base class if it doesn't fit." This shows you can combine both deliberately.

### equals, hashCode, Comparable and Comparator

#### Core idea
These four methods decide how your objects behave in collections. Get them wrong and `HashMap` loses entries, `HashSet` keeps duplicates, and `TreeSet` drops elements.

#### How it works
**The equals/hashCode contract** (from `Object`'s Javadoc):
1. If `a.equals(b)` then `a.hashCode() == b.hashCode()`. *(Mandatory.)*
2. Equal hash codes do **not** imply equality (collisions are allowed).
3. `equals` must be reflexive, symmetric, transitive, consistent, and `x.equals(null)` must be `false`.

Why: `HashMap` first uses `hashCode()` to find the bucket, then `equals()` to find the key inside it. If two equal objects have different hashes, they land in different buckets, and the map treats them as different keys.

```java
public final class Sku {
    private final String code;
    private final String warehouse;

    @Override public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Sku other)) return false;
        return code.equals(other.code) && warehouse.equals(other.warehouse);
    }
    @Override public int hashCode() { return Objects.hash(code, warehouse); }
}
// Or simply: public record Sku(String code, String warehouse) {}  — generates both.
```

**Comparable vs Comparator**
- `Comparable<T>`: the class's *natural ordering*, via `compareTo` in the class itself (`String`, `Integer`, `LocalDate`). One per class.
- `Comparator<T>`: an *external* ordering you pass in. You can have many.

```java
List<Order> orders = ...;
orders.sort(Comparator.comparing(Order::getPriority).reversed()
                      .thenComparing(Order::getCreatedAt));
```

**Consistency with equals:** `TreeMap`/`TreeSet` use `compareTo`/`compare` *instead of* `equals`. If `compare(a,b)==0` but `!a.equals(b)`, a `TreeSet` treats them as duplicates and silently drops one. `BigDecimal` is the famous example: `new BigDecimal("2.0").equals(new BigDecimal("2.00"))` is false, but `compareTo` returns 0.

#### Real-world example
A cache keyed by a request object (`SearchQuery(text, filters, page)`) only gets hits if `SearchQuery` implements `equals`/`hashCode` over all three fields. Forget `page` and users get page 1 results for page 2; forget `hashCode` entirely and every lookup misses, so your hit ratio silently drops to zero.

#### Interview questions
?? What happens if you override equals but not hashCode?
Two equal objects get different identity-based hash codes, so `HashMap`/`HashSet` put them in different buckets. `set.add(a); set.contains(copyOfA)` returns false, and duplicates appear in sets. The code compiles and mostly "works", which is why it's dangerous.

?? Why do we compare with `instanceof` vs `getClass()` in equals?
`getClass() != o.getClass()` is strict: a subclass instance is never equal to a parent instance, which keeps symmetry safe when subclasses add fields. `instanceof` allows subclass instances to be equal, which is fine (and needed for proxies like Hibernate's) **if** the class is `final` or subclasses don't add state to equality. Hibernate entities typically use `instanceof` because entities are proxied by subclasses.

?? How do you write a null-safe comparator for a field that can be null?
`Comparator.comparing(User::getLastLogin, Comparator.nullsLast(Comparator.naturalOrder()))`.

#### Tricky questions
?? Why is `return a.score - b.score;` a bad compareTo?
Integer overflow. If `a.score` is large positive and `b.score` large negative, the subtraction overflows and flips sign, breaking the ordering. Use `Integer.compare(a.score, b.score)`.

?? An entity uses a database-generated `id` in equals/hashCode. What can go wrong?
Before persistence `id` is null. If you put the entity in a `HashSet` and then save it, the `id` changes, so its hash changes and the set can't find it any more. Common fixes: use a natural/business key, or use an `id`-based `equals` with a constant `hashCode` (e.g. `getClass().hashCode()`).

?? Can two unequal objects have the same hashCode? Can equal objects have different ones?
Unequal with the same hash: yes, that's a collision and it's legal. Equal with different hashes: no, that violates the contract.

#### Interview simulation
**Interviewer:** "You've put a `User` object into a HashSet, and later `contains()` returns false for the same user. Why?"

**Clarify first:** "Is `User` mutable? Were any fields changed after insertion? And does `User` override equals and hashCode?"

**Answer flow:** List the three likely causes in order of probability:
1. `hashCode` isn't overridden, or is inconsistent with `equals`.
2. A field used in `hashCode` was mutated after insertion, so the object now hashes to a different bucket.
3. `equals` has a bug (wrong parameter type such as `equals(User u)`, which overloads instead of overriding).

Then give the fix: make key fields immutable, use a `record`, and add `@Override` so the compiler catches the overload mistake.

### String, immutability and the string pool

#### Core idea
`String` is **immutable**: once created, its characters never change. Every "modification" (`concat`, `replace`, `toUpperCase`) returns a new object. The JVM exploits this with the **string pool**, a cache of string literals so identical literals share one object.

#### How it works
- Since Java 9, a `String` stores a `byte[]` plus a `coder` flag (**Compact Strings**): Latin-1 text uses 1 byte per char, otherwise UTF-16 with 2. This roughly halves memory for ASCII-heavy apps.
- **Literals** (`"java"`) are interned into the pool, which lives in the heap since Java 7 (it was in PermGen before). `new String("java")` always creates a new heap object; `.intern()` returns the pooled instance.
- **Why immutable?**
  1. *Security*: class names, file paths, URLs and DB credentials are strings, so they can't be changed after validation.
  2. *Thread safety*: strings can be shared freely with no synchronisation.
  3. *Hash caching*: `hashCode` is computed once and cached, which makes strings ideal `HashMap` keys.
  4. *Pooling*: safe only because nobody can mutate a shared literal.
- **Concatenation:** `a + b` in a single expression compiles (Java 9+) to an `invokedynamic` call to `StringConcatFactory`, which is efficient. But in a **loop**, `s += x` creates a new String every iteration, which is O(n²) character copying. Use `StringBuilder` (not synchronised, so faster) or `StringBuffer` (synchronised, legacy).

```java
String s1 = "java";
String s2 = "ja" + "va";          // compile-time constant → same pooled object
String part = "ja";
String s3 = part + "va";          // computed at runtime → new object
System.out.println(s1 == s2);     // true
System.out.println(s1 == s3);     // false
System.out.println(s1 == s3.intern()); // true
```

#### Real-world example
Building a large CSV export or a log line in a loop with `+=` is a common performance bug: for 100k rows it can take seconds and create gigabytes of garbage. `StringBuilder` with an initial capacity fixes it. Passwords are kept in `char[]` (e.g. in `PasswordCallback`, `KeyStore` APIs) rather than `String` because an array can be zeroed after use, whereas a String stays in memory until GC (and may be pooled).

#### Interview questions
?? How many objects does `String s = new String("hello");` create?
Up to two. The literal `"hello"` goes in the pool (if it isn't already there; this happens when the class loads), and `new` creates a separate heap object. So 1 or 2 depending on whether the literal was already pooled.

?? String vs StringBuilder vs StringBuffer?
`String`: immutable, thread-safe. `StringBuilder`: mutable, not thread-safe, fastest. `StringBuffer`: mutable, synchronised methods, rarely needed today. Use `StringBuilder` for building strings inside a method.

?? Why is String a popular HashMap key?
It's immutable (the hash can't change while it's in the map), it caches its hash, and `equals`/`hashCode` are correctly implemented.

#### Tricky questions
?? Why should passwords be stored in char[] rather than String?
A `char[]` can be overwritten with zeros right after use. A `String` is immutable, may be interned, and lingers in the heap until GC, so it can show up in heap dumps. Also, logging a `char[]` prints an address rather than the secret.

?? Can `substring` cause a memory leak?
In Java 6 it could: `substring` shared the parent's `char[]`, so a tiny substring kept a huge string alive. Since Java 7u6, `substring` copies the characters, so it's no longer a leak.

?? What does `"a" + 1 + 2` vs `1 + 2 + "a"` produce?
`"a12"` and `"3a"`. Evaluation is left to right; once a String is involved, `+` means concatenation.

#### Interview simulation
**Interviewer:** "Why is String immutable in Java?"

**Clarify:** none needed. This is a conceptual question, so answer it directly and in a structured way.

**Structure:** "Four reasons: security, thread safety, hash caching, and enabling the string pool." Then give one sentence on each, and finish with a practical consequence: "The flip side is that repeated concatenation in loops creates garbage, so we use `StringBuilder` there. And for secrets, `char[]` is preferred because it can be wiped."

### Exceptions and error handling

#### Core idea
Java separates problems into **checked exceptions** (recoverable conditions the compiler forces you to handle), **unchecked exceptions** (programming bugs, subclasses of `RuntimeException`), and **errors** (serious JVM problems you shouldn't catch).

```
Throwable
├── Error                      (OutOfMemoryError, StackOverflowError) — don't catch
└── Exception
    ├── IOException, SQLException…   (checked: must catch or declare)
    └── RuntimeException             (unchecked)
        ├── NullPointerException
        ├── IllegalArgumentException / IllegalStateException
        └── ConcurrentModificationException …
```

#### How it works
- `try / catch / finally`: `finally` runs whether or not an exception was thrown, even after `return`. The exceptions are `System.exit()`, a JVM crash, or a thread that is killed.
- **try-with-resources** (Java 7): any `AutoCloseable` declared in the header is closed automatically, in reverse order. If both the body and `close()` throw, the body's exception is primary and the close exception is attached as **suppressed** (`e.getSuppressed()`).
- **Multi-catch**: `catch (IOException | SQLException e)`.
- **Exception chaining**: `throw new ServiceException("fetch failed", e)` preserves the root cause. Always pass the cause.
- **Custom exceptions**: extend `RuntimeException` for most business errors in modern code (Spring rolls back transactions only on unchecked exceptions by default).
- **Cost**: building the stack trace is the expensive part. For high-frequency control-flow exceptions, you can override `fillInStackTrace` or use the 4-arg constructor with `writableStackTrace=false`, but using exceptions for control flow is itself a smell.

```java
try (Connection c = ds.getConnection();
     PreparedStatement ps = c.prepareStatement(SQL)) {
    ps.setLong(1, id);
    try (ResultSet rs = ps.executeQuery()) { ... }
} catch (SQLException e) {
    throw new DataAccessException("Failed to load order " + id, e); // chain it
}
```

#### Real-world example
In a Spring Boot API, a `@RestControllerAdvice` maps exceptions to HTTP responses: `OrderNotFoundException → 404`, `MethodArgumentNotValidException → 400`, `OptimisticLockException → 409`, anything else → `500` with a correlation ID and **no stack trace leaked to clients**. That's the "structured exception handling" on your resume, so be ready to show it.

#### Interview questions
?? Checked vs unchecked: which should you use?
Checked exceptions suit conditions the *caller* can reasonably recover from (a file is missing, so ask for another path). Unchecked suit programming errors and most business failures in service code. Most modern frameworks (Spring, Hibernate) wrap checked exceptions in unchecked ones because forced catch blocks across layers produce boilerplate and swallowed exceptions. In Spring, unchecked exceptions also trigger transaction rollback by default.

?? What's the difference between `throw` and `throws`?
`throw` actually throws an exception instance. `throws` in a method signature declares which checked exceptions the method may propagate.

?? What happens to an exception thrown inside a thread in an ExecutorService?
With `execute()`, it goes to the thread's `UncaughtExceptionHandler` (printed by default) and the worker thread dies and is replaced. With `submit()`, it's captured inside the `Future` and only surfaces when you call `future.get()` (wrapped in `ExecutionException`). If you never call `get()`, the exception is silently lost, which is a common production bug.

#### Tricky questions
?? What does this return?
```java
int f() { try { throw new RuntimeException(); } finally { return 1; } }
```
It returns `1`, and the exception is **swallowed**. A `return` in `finally` discards any in-flight exception. Never return from `finally`.

?? Can you catch `StackOverflowError`? Should you?
Technically yes (it's a `Throwable`), but the stack is nearly exhausted and the program state may be inconsistent. Catch it only at the top level to log it, never to "recover".

?? If `close()` throws inside try-with-resources and the body also threw, which exception do you see?
The body's exception. The `close()` exception is attached as a suppressed exception.

#### Interview simulation
**Interviewer:** "How do you handle exceptions in your REST APIs?"

**Clarify:** "Are you asking about API design, meaning error response format and status codes, or about internal exception handling strategy?" Then cover both briefly.

**Answer:**
1. Domain exceptions are unchecked (`OrderNotFound`, `InsufficientStock`) and carry an error code.
2. A global `@RestControllerAdvice` maps them to HTTP status codes and a consistent body (`code`, `message`, `traceId`, `details[]`). RFC 7807 `ProblemDetail` is built into Spring 6.
3. Validation errors return 400 with a field list.
4. Unknown errors are logged once with full context and the trace ID, and return a generic 500.
5. Cause chains are never lost and exceptions are never swallowed.

Close with a real story: "At Tata 1mg we had a downstream timeout being mapped to 500. We changed it to 503 with retry-after, which made client retries sane."

### Generics and type erasure

#### Core idea
Generics give **compile-time type safety** for containers and algorithms (`List<String>` can't hold an `Integer`) without casts. Under the hood Java implements them with **type erasure**: generic type information is removed after compilation, so at runtime `List<String>` and `List<Integer>` are both just `List`.

#### How it works
- **Erasure**: type parameters are replaced by their bound (`Object` if unbounded) and the compiler inserts casts. This kept bytecode compatible with pre-Java 5 code.
- **Consequences of erasure**:
  - You can't do `new T()`, `new T[10]`, or `obj instanceof List<String>`.
  - You can't overload `m(List<String>)` and `m(List<Integer>)`: they erase to the same signature.
  - Static fields can't use the class's type parameter.
  - The compiler generates **bridge methods** to keep polymorphism working with erased types.
- **Bounded types**: `<T extends Comparable<T>>` lets you call `compareTo` on `T`.
- **Wildcards and PECS ("Producer Extends, Consumer Super")**:
  - `List<? extends Number>` is a **producer**: you can *read* `Number`s, but can't add (except `null`).
  - `List<? super Integer>` is a **consumer**: you can *add* `Integer`s, but reads give you `Object`.
  - Example: `Collections.copy(List<? super T> dest, List<? extends T> src)`.
- **Invariance**: `List<Integer>` is **not** a subtype of `List<Number>` (otherwise you could add a `Double` to a list of Integers). Arrays are covariant (`Integer[]` is a `Number[]`), which is why arrays throw `ArrayStoreException` at runtime.

```java
static double sum(Collection<? extends Number> nums) {   // producer → extends
    double s = 0; for (Number n : nums) s += n.doubleValue(); return s;
}
static void fill(List<? super Integer> out, int n) {     // consumer → super
    for (int i = 0; i < n; i++) out.add(i);
}
// Getting the runtime type back: pass a Class token
<T> T fromJson(String json, Class<T> type) { ... }
```

#### Real-world example
Jackson's `objectMapper.readValue(json, new TypeReference<List<OrderDto>>(){})` works around erasure. The anonymous subclass preserves the generic type in its class metadata (`getGenericSuperclass()`), which Jackson reads at runtime. Spring's `ParameterizedTypeReference` in `RestTemplate.exchange` uses the same trick.

#### Interview questions
?? What is type erasure and why did Java choose it?
The compiler checks generic types and then removes them, replacing them with bounds and inserting casts. It was chosen for **backward compatibility**, so generic code could interoperate with the huge body of pre-generics libraries and run on existing JVMs.

?? Explain PECS with an example.
If a parameter *produces* values you read, use `? extends T`. If it *consumes* values you write, use `? super T`. `addAll(Collection<? extends E>)` reads from the argument; `Comparator<? super T>` consumes `T`s, so a `Comparator<Object>` can sort `String`s.

?? Why can't you create a generic array?
Arrays need their component type at runtime to enforce `ArrayStoreException`, but erasure removed it. `new T[n]` would be unsafe, so it's forbidden. Use `List<T>`, or `(T[]) new Object[n]` inside a class you control (like `ArrayList` does internally).

#### Tricky questions
?? Does this compile? `List<Object> objs = new ArrayList<String>();`
No. Generics are invariant. `List<? extends Object>` (or `List<?>`) would accept it.

?? What's the difference between `List<?>`, `List<Object>` and raw `List`?
`List<?>`: a list of some unknown type. You can read `Object`s, can't add (except null), and it's type-safe. `List<Object>`: a list that can hold anything; you can add any object, but a `List<String>` can't be assigned to it. Raw `List`: opts out of generics checks entirely, so you get unchecked warnings and heap pollution. Avoid it.

?? How can `List<String>` end up containing an Integer?
Through raw types or unchecked casts (heap pollution). The failure appears later as a `ClassCastException` at the read site, far from the bug.

#### Interview simulation
**Interviewer:** "Write a generic method that returns the max element of a list."

**Clarify:** "Should it work on any type with a natural order, or should it accept a comparator? And what should an empty list return: an exception, or Optional?"

**Answer:**
```java
static <T extends Comparable<? super T>> Optional<T> max(List<? extends T> list) {
    T best = null;
    for (T x : list) if (best == null || x.compareTo(best) > 0) best = x;
    return Optional.ofNullable(best);
}
```
Explain the bound: `Comparable<? super T>` lets it work for types whose `compareTo` is defined on a supertype (e.g. `java.sql.Timestamp`, which extends `Date` and is `Comparable<Date>`). That detail is what shows real depth.

### static, final and nested classes

#### Core idea
- `static`: belongs to the **class**, not to instances.
- `final`: can't be changed. A final variable can't be reassigned, a final method can't be overridden, and a final class can't be extended.
- **Nested classes**: classes inside classes. They come in four kinds with different access and memory implications.

#### How it works
**static**
- Static fields live once per class (in the heap, associated with the `Class` object since Java 8).
- Static methods can't use `this` or instance members directly.
- **Static blocks** run once when the class is *initialised* (first active use), in textual order.
- Class init is thread-safe, guaranteed by the JVM, which is why the *holder-class singleton* idiom works.

**final**
- `final` on a reference means the reference can't change, **not** the object: `final List<String> l` can still be `add`ed to.
- Final fields set in the constructor get a JMM guarantee: other threads see their initialised values once the constructor finishes (as long as `this` didn't escape). This is the foundation of safe immutable objects.
- Effectively final: a local variable never reassigned. Lambdas and anonymous classes can capture only (effectively) final locals.

**Nested classes**
| Kind | Declared | Has outer instance? | Typical use |
|---|---|---|---|
| Static nested | `static class Node` | No | Helpers tightly tied to the outer class (`HashMap.Node`, `Builder`) |
| Inner (non-static) | `class Itr` | Yes (hidden `Outer.this`) | Iterators needing outer state |
| Local | inside a method | Yes, if in an instance method | Rare |
| Anonymous | `new Runnable() {...}` | Yes, if in an instance context | Pre-lambda callbacks |

#### Real-world example
The **Builder pattern** uses a static nested class: `Order.builder().id(..).items(..).build()`. Making it static matters: an inner class would hold a hidden reference to an outer instance it doesn't need. Inner classes and anonymous listeners holding `Outer.this` are a classic **memory leak** (e.g. Android Activities leaked by anonymous Handlers, or a cache listener keeping a whole service object graph alive).

#### Interview questions
?? Why should a nested class be static by default?
A non-static inner class keeps an implicit reference to its enclosing instance. That costs memory, prevents the outer object from being garbage-collected while the inner one lives, and makes serialisation awkward. Make it static unless it truly needs outer instance state (Effective Java, Item 24).

?? Does `final` make an object immutable?
No. It only stops the variable from being reassigned. Immutability needs: a final class (or private constructor), all fields `private final`, no setters, defensive copies of mutable inputs/outputs, and no `this` escaping during construction.

?? When are static blocks executed?
When the class is initialised: on first creation of an instance, first access to a non-constant static field, first static method call, `Class.forName`, or a subclass's initialisation. Not when it's merely referenced in a variable type.

#### Tricky questions
?? Does accessing a `static final int` constant trigger class initialisation?
No, if it's a compile-time constant (`static final int MAX = 10;`): the compiler inlines the value into the caller. A `static final` initialised by a method call (e.g. `= compute()`) *does* trigger initialisation. Inlining is also why changing a constant in a library jar requires recompiling its callers.

?? Can a static method be called on a null reference?
Yes. `((MyClass) null).staticMethod()` works without an NPE because it's bound at compile time to the class.

?? Why can't lambdas modify captured local variables?
Locals live on the creating thread's stack and the lambda may run later or on another thread. Java copies the value, and requiring it to be effectively final avoids the illusion of shared mutable state. Workarounds like `AtomicInteger` or a one-element array exist but are usually a smell.

#### Interview simulation
**Interviewer:** "Design an immutable `Money` class."

**Clarify:** "Single currency or multi-currency? Do we need arithmetic? And what rounding mode for things like splitting?"

**Answer:** `public final class Money` with `private final BigDecimal amount; private final Currency currency;`. The constructor validates and normalises scale (`setScale(2, HALF_EVEN)`). Operations return new instances (`plus`, `minus`, `multiply`), and `plus` rejects mismatched currencies. `equals`/`hashCode` use `compareTo` semantics on the normalised scale. No setters. Or simply a `record` with a compact constructor for validation. Then mention the benefits: thread-safe, safe as a map key, no defensive copying needed.

### Java is pass-by-value

#### Core idea
Java **always** passes arguments by value. For primitives the value is the number itself. For objects the value is the **reference** (a pointer-like handle), copied into the parameter. So a method can mutate the object the reference points to, but can't make the caller's variable point to a different object.

#### How it works
```java
void reassign(StringBuilder sb) { sb = new StringBuilder("new"); }   // caller unaffected
void mutate(StringBuilder sb)   { sb.append(" changed"); }           // caller sees it

StringBuilder s = new StringBuilder("orig");
reassign(s);  // s → "orig"
mutate(s);    // s → "orig changed"

void swap(Integer a, Integer b) { Integer t = a; a = b; b = t; }     // does nothing for the caller
```
The caller's `s` and the method's `sb` are two separate variables holding copies of the same reference. Assigning to `sb` changes only the method's copy.

#### Real-world example
A service method that receives a `List<Item>` from the controller and calls `items.removeIf(...)` mutates the caller's list, which can surprise the caller (e.g. if the controller logs or reuses it, or if the list is `List.of(...)`, which throws `UnsupportedOperationException`). Defensive practice: don't mutate inputs; return a new collection.

#### Interview questions
?? Is Java pass-by-reference for objects?
No. It passes the reference *by value*. Proof: you can't write a `swap(a, b)` method that swaps the caller's two objects. In true pass-by-reference (C++ `&`), you could.

?? Why doesn't modifying a String parameter affect the caller?
Two reasons: Strings are immutable, so you can't mutate them; and reassigning the parameter only changes the local copy of the reference.

#### Tricky questions
?? What does this print?
```java
static void change(int[] arr) { arr[0] = 99; arr = new int[]{7}; arr[0] = 42; }
int[] a = {1}; change(a); System.out.println(a[0]);
```
`99`. The first write goes through the shared reference; after reassignment the method works on a new array the caller never sees.

#### Interview simulation
**Interviewer:** "Is Java pass-by-value or pass-by-reference?"

Answer in one sentence ("Always pass-by-value; for objects, the value passed is a copy of the reference"), then prove it with the swap example and point out the practical implication of mutating inputs. Under 60 seconds.

## Collections internals | P1 | must

### ArrayList vs LinkedList

#### Core idea
Both implement `List`, but `ArrayList` is backed by a **resizable array** and `LinkedList` by a **doubly linked list**. In practice `ArrayList` wins almost every real workload because of CPU cache locality.

#### How it works
| Operation | ArrayList | LinkedList |
|---|---|---|
| `get(i)` | O(1) | O(n) (walks from the nearer end) |
| `add(e)` at end | Amortised O(1) | O(1) |
| `add(i, e)` / `remove(i)` in middle | O(n) (shifts with `System.arraycopy`) | O(n) to find, O(1) to link |
| Memory per element | ~4–8 bytes (a reference) | ~24–40 bytes (node object + prev/next refs) |
| Iteration | Very fast (contiguous memory, prefetch) | Slow (pointer chasing, cache misses) |

**ArrayList growth:** the default capacity is 10, allocated lazily on the first add (a no-arg `new ArrayList<>()` starts with an empty shared array). When full it grows to `oldCapacity + (oldCapacity >> 1)`, about **1.5×**, copying via `Arrays.copyOf`. If you know the size, pass it: `new ArrayList<>(expected)` avoids repeated copying.

**LinkedList** also implements `Deque`, but `ArrayDeque` is faster for queue and stack use.

#### Real-world example
Loading 1M rows from a DB into a `LinkedList` and then iterating it can be 3–5× slower than with `ArrayList`, purely because of cache misses and GC pressure from a million node objects. Most production Java code, including JDK internals, uses `ArrayList` and `ArrayDeque`; `LinkedList` is rarely the right answer.

#### Interview questions
?? When would you actually pick LinkedList?
Very rarely. The theoretical case is frequent insert/remove at a position you *already hold* via a `ListIterator`, on a large list. Even then, benchmarks often favour `ArrayList` because `arraycopy` is extremely fast. For queues and stacks use `ArrayDeque`.

?? What is the time complexity of `ArrayList.add()`?
Amortised O(1). Most adds just write to the array; occasionally a resize copies all n elements. Because capacity grows geometrically (1.5×), the total copying over n adds is O(n), so the average per add is O(1).

?? How does `remove(Object)` differ from `remove(int)` on `List<Integer>`?
`list.remove(1)` removes the element at **index 1**. `list.remove(Integer.valueOf(1))` removes the first element **equal to 1**. Overload resolution prefers the exact primitive match.

#### Tricky questions
?? Is `ArrayList` thread-safe? What are the alternatives?
No. Concurrent adds can lose elements or throw `ArrayIndexOutOfBoundsException` during a resize. Alternatives: `Collections.synchronizedList` (one lock; you must also lock manually while iterating), `CopyOnWriteArrayList` (great when reads vastly outnumber writes, such as listener lists), or redesign to use a concurrent queue.

?? Does `ArrayList.clear()` shrink the backing array?
No. It nulls out the elements (so they can be garbage-collected) but keeps the capacity. Call `trimToSize()` or create a new list if memory matters.

#### Interview simulation
**Interviewer:** "ArrayList or LinkedList for an LRU cache?"

**Clarify:** "What's the expected size, and which operations dominate: get, put or eviction?"

**Answer:** "Neither on its own. An LRU needs O(1) lookup *and* O(1) move-to-front. That's a HashMap plus a doubly linked list of nodes I control, or simply `LinkedHashMap` with `accessOrder=true`. `java.util.LinkedList` doesn't help, because removing an arbitrary node from it costs O(n): you can't get at its internal nodes." This turns a trivia question into a design answer.

### HashMap internals

#### Core idea
`HashMap` stores key-value pairs in an **array of buckets**. A key's `hashCode()` picks the bucket, and `equals()` finds the key within the bucket. Average `get`/`put` is O(1); worst case is O(log n) since Java 8 (it was O(n) before).

#### How it works
1. **Hashing**: `hash = h ^ (h >>> 16)` where `h = key.hashCode()`. This "spreads" the high bits into the low bits, because the index uses only the low bits.
2. **Index**: `index = hash & (n - 1)`, where `n` (table size) is always a **power of two**, so this is a fast modulo.
3. **Bucket structure**: a linked list of `Node(hash, key, value, next)`. New nodes are added at the **tail** (Java 8+; Java 7 added at the head, which could create infinite loops during a concurrent resize).
4. **Treeification**: when one bucket reaches **8** nodes *and* the table has at least **64** buckets, that bucket becomes a **red-black tree** (`TreeNode`), giving O(log n) lookups. If the table is smaller than 64, it resizes instead. It reverts to a list when the bucket shrinks to **6**.
5. **Resize**: when `size > capacity × loadFactor` (default 16 × 0.75 = 12), capacity doubles. Because n is a power of two, each node either stays at index `i` or moves to `i + oldCap`, decided by a single bit (`hash & oldCap`). No rehashing is needed.
6. **Null**: one `null` key is allowed (stored in bucket 0) and null values are allowed.

```
table[0] → null
table[1] → Node(k1) → Node(k9) → null          (collision chain)
table[2] → TreeNode (red-black tree, ≥ 8 nodes)
...
```

**`put(k, v)` step by step:** compute the hash → find the index → if the bucket is empty, insert. Otherwise walk the bucket: if a node has the same hash and `equals` the key, replace its value (and return the old one). Else append; if the chain length reaches 8, treeify. Then `++size`, and resize if over the threshold.

#### Real-world example
A hash-flooding DoS attack sends many keys that collide (e.g. specially crafted HTTP parameter names) to make `HashMap` degrade to O(n) per operation, freezing servers. Java 8's treeification limits the damage to O(log n). It's why `String` keys, which are `Comparable`, perform well even under collisions: tree bins order by `compareTo` when hashes tie.

#### Interview questions
?? Why is the capacity always a power of two?
So that `hash & (n-1)` can replace the slower `%`, and so that a resize can split each bucket with one bit check. The cost is that only the low bits pick the bucket, which is why `HashMap` mixes in the high bits with `h ^ (h >>> 16)`.

?? Why is the load factor 0.75?
It's a time/space trade-off. Lower means fewer collisions but more memory; higher means more collisions. Under Poisson-distributed hashing, 0.75 keeps the expected chain length very short. The treeify threshold of 8 was chosen because a bucket reaching 8 at that load factor has a probability of about 0.00000006 with a good hash function.

?? What happens when two keys have the same hashCode?
They land in the same bucket. `equals` decides whether they're the same key (replace) or different (chain). Performance degrades only if many keys collide.

?? How do you size a HashMap for 1,000 entries without resizing?
Capacity must be greater than 1000 / 0.75 ≈ 1334, so `new HashMap<>(1334)` (rounded up internally to 2048). Java 19+ provides `HashMap.newHashMap(1000)`, which does the math for you.

#### Tricky questions
?? Can a mutable key break a HashMap?
Yes. If a field used in `hashCode` changes after insertion, the entry sits in the old bucket while lookups go to a new one, so `get` returns null and the entry leaks. Use immutable keys.

?? Why did Java 7's HashMap sometimes hang at 100% CPU in production?
Concurrent `put`s during a resize, combined with head insertion, could reverse links and create a **cycle** in a bucket's list, so a later `get` looped forever. HashMap was never thread-safe; Java 8's tail insertion removes the cycle but still loses data under concurrency. Use `ConcurrentHashMap`.

?? Why does treeification need 64 buckets minimum?
With a small table, long chains more likely mean "the table is too small" than "keys collide badly", so resizing is the cheaper fix.

?? HashMap vs Hashtable?
`Hashtable` is legacy: every method is synchronised, it allows no null keys or values, and it grows to `2n+1` using `%`. Use `HashMap` (single thread) or `ConcurrentHashMap` (concurrent).

#### Interview simulation
**Interviewer:** "Explain how HashMap works internally."

**Clarify:** "Should I cover Java 8+ behaviour, including treeification?" (Yes.) This topic rewards a structured walkthrough.

**Answer flow (3–4 minutes):**
1. Structure: an array of buckets of nodes, power-of-two size.
2. `put` path: hash spreading → index → collision handling → equals → replace or append.
3. Treeification: thresholds 8, 64 and 6, giving an O(log n) worst case.
4. Resize: load factor 0.75, doubling, the one-bit split.
5. Contract: why equals/hashCode must be consistent; immutable keys.
6. Concurrency: not thread-safe; the Java 7 infinite loop; use CHM.

Draw the bucket array while talking. Then expect the follow-up "how does ConcurrentHashMap differ?" (next topic).

### LinkedHashMap and TreeMap

#### Core idea
- **`LinkedHashMap`**: a `HashMap` plus a doubly linked list through all entries, giving **predictable iteration order** (insertion order, or access order).
- **`TreeMap`**: a **red-black tree** keyed by sort order. Operations are O(log n), and you get navigation methods like `floorKey` and `ceilingKey`.

#### How it works
**LinkedHashMap**
- Each entry has `before`/`after` pointers, maintaining either insertion order (default) or **access order** (`new LinkedHashMap<>(16, 0.75f, true)`), where every `get`/`put` moves the entry to the tail.
- `removeEldestEntry(Map.Entry eldest)` is a hook called after every `put`. Return `true` to evict the head, which gives you an LRU cache in about 5 lines.

```java
class LruCache<K, V> extends LinkedHashMap<K, V> {
    private final int capacity;
    LruCache(int capacity) { super(16, 0.75f, true); this.capacity = capacity; }
    @Override protected boolean removeEldestEntry(Map.Entry<K, V> e) { return size() > capacity; }
}
```

**TreeMap**
- A red-black tree is a self-balancing BST: height ≤ 2·log₂(n+1), so `get`/`put`/`remove` are O(log n).
- It uses `compareTo` (natural order) or a supplied `Comparator`, **not** `equals`/`hashCode`.
- Navigation methods: `firstKey`, `lastKey`, `floorKey(k)` (≤ k), `ceilingKey(k)` (≥ k), `lowerKey`, `higherKey`, `headMap`, `tailMap`, `subMap`, and `descendingMap`.
- `null` keys aren't allowed with natural ordering (it throws NPE).

#### Real-world example
- **TreeMap**: rate tables and time-based lookups. "Which price tier applies to quantity 37?" is `tiers.floorEntry(37)`. "Which config version was active at time T?" is `versions.floorEntry(T)`. **Consistent hashing** rings are often a `TreeMap<Long, Node>`, where `ceilingEntry(hash)` finds the next node clockwise.
- **LinkedHashMap**: small in-process LRU caches, and preserving JSON field order (Jackson deserialises objects into `LinkedHashMap`).

#### Interview questions
?? HashMap vs LinkedHashMap vs TreeMap?
HashMap: no order, O(1). LinkedHashMap: insertion or access order, O(1), slightly more memory. TreeMap: sorted order, O(log n), range and floor/ceiling queries. Choose by the ordering you need.

?? How would you implement an LRU cache in Java?
Quickly: `LinkedHashMap` with access order and `removeEldestEntry`. From scratch (the usual interview ask): a `HashMap<K, Node>` plus a hand-written doubly linked list with sentinel head and tail. `get` moves the node to the front; `put` inserts at the front and evicts from the tail when over capacity. Everything is O(1). For concurrency, wrap with a lock or use Caffeine in production.

#### Tricky questions
?? Is the LinkedHashMap LRU thread-safe for reads?
No. With access order, even `get()` **mutates** the internal linked list. Concurrent "reads" can corrupt it. You need a lock around both `get` and `put`.

?? A TreeMap with a comparator that compares only by `name` ignores a `put` of a different object with the same name. Why?
TreeMap treats `compare == 0` as "same key" and replaces the value. Your comparator must be consistent with equals, or tie-break on a unique field.

#### Interview simulation
**Interviewer:** "Design an in-memory cache that evicts least-recently-used entries."

**Clarify first:** "What's the capacity: by count or by memory? Is it single-threaded or concurrent? Do we need TTL expiry too? And what are the read/write ratios?"

**Answer flow:** Start with the `LinkedHashMap` version to show you know the library, then implement the HashMap + doubly linked list version (the interviewer will usually ask for it). Discuss concurrency: a single `ReentrantLock` is simple; for high throughput, use segmented locks, or Caffeine's approach of recording reads in a buffer and applying the LRU reordering asynchronously. Mention adding TTL with a timestamp on each node, checked lazily on `get`.

### HashSet, PriorityQueue and ArrayDeque

#### Core idea
Three collections you'll use constantly in interviews and production:
- **`HashSet`**: unique elements, O(1) contains. It's backed by a `HashMap` (elements are keys; the value is a dummy `PRESENT` object).
- **`PriorityQueue`**: a **binary min-heap**. `peek` is O(1), `offer`/`poll` are O(log n).
- **`ArrayDeque`**: a circular resizable array. O(1) add/remove at both ends, and the best choice for both stacks and queues.

#### How it works
**PriorityQueue**
- Stored as an array where `children(i) = 2i+1, 2i+2` and `parent(i) = (i-1)/2`.
- `offer`: append at the end, then **sift up**. `poll`: move the last element to the root, then **sift down**.
- Building from a collection uses heapify in O(n).
- It's a min-heap by default. For a max-heap use `new PriorityQueue<>(Comparator.reverseOrder())`.
- **Iteration order is not sorted**; only `poll()` returns elements in order.
- `remove(Object)` is O(n). It's not thread-safe; use `PriorityBlockingQueue` for that.

**ArrayDeque**
- `head` and `tail` indices wrap around the array, and capacity doubles when full.
- It doesn't allow `null` elements (null is used as the "empty" sentinel).
- It's faster than `Stack` (synchronised, extends `Vector`) and `LinkedList` (node allocation).

```java
Deque<Integer> stack = new ArrayDeque<>(); stack.push(1); stack.pop();
Deque<Integer> queue = new ArrayDeque<>(); queue.offer(1); queue.poll();
PriorityQueue<int[]> pq = new PriorityQueue<>((a, b) -> Integer.compare(a[1], b[1]));
```

#### Real-world example
Job schedulers keep the next-due job at the top of a `PriorityQueue` ordered by run time. Java's `ScheduledThreadPoolExecutor` uses exactly this, via a `DelayedWorkQueue` heap. "Top-K trending searches" keeps a min-heap of size K over a stream of counts.

#### Interview questions
?? How would you find the top K most frequent items in a stream?
Count with a `HashMap`, then keep a **min-heap of size K** ordered by count: push each entry, and pop when size exceeds K. That's O(n log K) time and O(K) heap space. For a truly unbounded stream with limited memory, use Count-Min Sketch plus a heap (an approximate method used in real trending systems).

?? Why prefer ArrayDeque over Stack?
`Stack` extends `Vector`, so every method is synchronised (slow) and it exposes index-based operations that break stack semantics. `ArrayDeque` is unsynchronised and cache-friendly. The Javadoc of `Stack` itself recommends `Deque`.

#### Tricky questions
?? You change a field of an object already in a PriorityQueue. What happens?
The heap invariant is broken. The queue doesn't notice, so `poll()` may return the wrong element. Remove the element, update it, and re-add it (O(n) for the remove), or use a TreeSet or indexed heap if updates are frequent.

?? Why does printing a PriorityQueue not show sorted order?
`toString` and the iterator walk the internal array, which is heap-ordered, not sorted. Only successive `poll()` calls give sorted order.

#### Interview simulation
**Interviewer:** "Which data structure would you use to schedule delayed jobs?"

**Clarify:** "Roughly how many jobs, and is this a single node or distributed? Do jobs need to survive a restart?"

**Answer:** "On a single node, a min-heap keyed by due time (`DelayQueue` or `ScheduledThreadPoolExecutor`): the worker sleeps until the head is due. That's O(log n) insert and O(1) peek. For millions of timers, a **hierarchical timing wheel** (used by Kafka and Netty) gives O(1) insert. For distributed and durable jobs, a Redis sorted set with the score as the timestamp, polled with `ZRANGEBYSCORE`, or a DB table indexed on `due_at` with `SELECT … FOR UPDATE SKIP LOCKED`."

### Fail-fast vs fail-safe iterators

#### Core idea
- **Fail-fast** iterators (`ArrayList`, `HashMap`…) throw `ConcurrentModificationException` (CME) if the collection is structurally modified during iteration by anything other than the iterator itself.
- **Fail-safe** (more precisely, *weakly consistent*) iterators (`ConcurrentHashMap`, `CopyOnWriteArrayList`) never throw CME. They iterate over a snapshot, or tolerate concurrent changes.

#### How it works
- Fail-fast collections keep a `modCount` that's incremented on every structural change (add/remove, but not `set`). The iterator records `expectedModCount` at creation and checks it on each `next()`; on a mismatch, it throws CME.
- It's **best-effort**: it's for detecting bugs, not a concurrency guarantee. It can even happen in a single thread:

```java
for (String s : list) if (s.isEmpty()) list.remove(s);   // CME (usually)

// Correct options:
list.removeIf(String::isEmpty);                          // best
Iterator<String> it = list.iterator();
while (it.hasNext()) if (it.next().isEmpty()) it.remove();  // iterator's own remove
```
- `CopyOnWriteArrayList`: each write copies the whole array, and iterators see the array as of their creation. Writes are expensive; reads are lock-free.
- `ConcurrentHashMap` iterators are **weakly consistent**: they reflect some state at or after creation, may or may not show concurrent updates, never throw CME, and never return an element twice.

#### Real-world example
A common production bug: a scheduled job iterates a `HashMap` of sessions to evict expired ones and calls `map.remove(key)` inside the loop, which throws CME. Another: an event-listener list modified by a listener during dispatch. `CopyOnWriteArrayList` is the standard fix for listener lists (rare writes, frequent iteration).

#### Interview questions
?? Can ConcurrentModificationException happen in a single-threaded program?
Yes. It's about modifying a collection while iterating it, not about threads. The for-each loop with `list.remove()` is the classic case.

?? Why is the for-each removal of the second-to-last element sometimes silent?
After the removal, the size shrinks so that `hasNext()` (which checks `cursor != size`) returns false, and the loop exits *before* `next()` checks `modCount`. The bug silently skips the last element instead of throwing, which is why CME is described as "best-effort".

#### Tricky questions
?? Does `list.set(i, x)` during iteration cause CME?
No. `set` isn't a structural modification (the size doesn't change), so `modCount` isn't incremented.

?? Is CopyOnWriteArrayList a good general-purpose concurrent list?
No. Every write copies the full array (O(n) time and garbage). It's only good when reads vastly outnumber writes and the list is small to medium (listeners, config snapshots).

#### Interview simulation
**Interviewer:** "How do you safely remove items from a map while iterating?"

**Answer quickly with options:** `map.entrySet().removeIf(e -> e.getValue().isExpired())`, or an explicit `Iterator` with `it.remove()`. If other threads modify it concurrently, switch to `ConcurrentHashMap`, whose iterators are weakly consistent, and use `map.remove(key, expectedValue)` for conditional removal. Mention why CME exists (the `modCount` check).

### ConcurrentHashMap internals

#### Core idea
`ConcurrentHashMap` (CHM) is a thread-safe hash map with **lock-free reads** and **fine-grained locking for writes**, so many threads can read and write at once with high throughput.

#### How it works
**Java 7 (historic):** 16 **segments**, each a mini hash table with its own `ReentrantLock`. Up to 16 concurrent writers.

**Java 8+ (current):**
- A single `Node[]` table, like HashMap. Node `val` and `next` are `volatile`.
- **Reads (`get`)** take no lock. They read the volatile table slot and walk the chain; volatile reads guarantee visibility of completed writes.
- **Insert into an empty bin**: a **CAS** (compare-and-set) puts the first node, with no lock at all.
- **Insert into a non-empty bin**: `synchronized` on the **first node of that bin**. Locks are per bucket, so contention is tiny.
- **Treeify**: the same thresholds as HashMap (8, 64), using `TreeBin` objects with their own read-write locking.
- **Resize**: **cooperative**. Threads that try to write during a resize *help* transfer buckets in chunks. Moved bins are marked with a `ForwardingNode` (hash `MOVED = -1`) so readers follow it to the new table.
- **Size**: tracked with `baseCount` plus an array of `CounterCell`s (the same idea as `LongAdder`) to avoid contention on one counter. `size()` is therefore an estimate under concurrent updates; `mappingCount()` returns a long.
- **No nulls**: neither null keys nor null values. In a concurrent map, `get(k) == null` must unambiguously mean "absent", because you can't follow it with a `containsKey` check atomically.

**Atomic compound operations (use these!):**
```java
counts.merge(word, 1, Integer::sum);                       // atomic increment
cache.computeIfAbsent(key, k -> expensiveLoad(k));         // atomic load-once
map.putIfAbsent(k, v); map.replace(k, oldV, newV); map.remove(k, v);
// Hot counters: ConcurrentHashMap<String, LongAdder>
hits.computeIfAbsent(page, k -> new LongAdder()).increment();
```

#### Real-world example
In the Tata 1mg search service, an in-process per-key request deduplication ("single-flight") map is a `ConcurrentHashMap<String, CompletableFuture<Result>>`: `computeIfAbsent` ensures only the first request for a hot query hits the DB, and the rest wait on the same future. This prevents a cache stampede when a popular key expires.

#### Interview questions
?? How is ConcurrentHashMap different from `Collections.synchronizedMap` or Hashtable?
Those use **one lock for the whole map**, so every operation (even reads) serialises. CHM has lock-free reads, per-bucket locking for writes, cooperative resizing, and atomic compound operations (`compute`, `merge`). Its iterators are weakly consistent (no CME); synchronized maps need manual locking during iteration.

?? Is `if (!map.containsKey(k)) map.put(k, v);` safe on a ConcurrentHashMap?
No. Each call is thread-safe, but the *sequence* isn't atomic (check-then-act): two threads can both see "absent" and both put. Use `putIfAbsent` or `computeIfAbsent`.

?? Why doesn't ConcurrentHashMap allow null?
Ambiguity. In a concurrent setting, `get(k)` returning null couldn't distinguish "absent" from "mapped to null", and you can't safely follow up with `containsKey` because another thread may change the map in between. Doug Lea disallowed nulls to avoid that.

#### Tricky questions
?? Can `computeIfAbsent` deadlock or misbehave?
The mapping function runs **while holding the bin's lock**. Keep it short and **never modify the same map inside it**. Recursive `computeIfAbsent` on the same map can throw `IllegalStateException("Recursive update")` (Java 9+) or livelock (Java 8). A slow function (a remote call) blocks other writers to that bin.

?? Is `map.get(k) + 1` then `put` a lost-update risk? How do you fix it at scale?
Yes, a read-modify-write race. Use `merge(k, 1, Integer::sum)`. For very hot keys, `LongAdder` values spread contention across cells.

?? Is `size()` accurate?
It's exact when the map is quiescent, and an approximation during concurrent modification. Don't use it for control flow like "if size < limit, then put".

#### Interview simulation
**Interviewer:** "How does ConcurrentHashMap achieve thread safety in Java 8?"

**Answer flow:**
1. "Lock-free reads via volatile fields."
2. "A CAS for inserting into an empty bucket."
3. "`synchronized` on the bucket's head node for collisions, so locking is per bucket."
4. "Cooperative resizing with ForwardingNodes."
5. "Counter cells for size."
6. "No nulls, and why."

Then pivot to usage: "In practice the real bugs are compound operations, so I use `merge`/`computeIfAbsent`. At Tata 1mg I used `computeIfAbsent` with CompletableFutures to collapse duplicate concurrent cache misses." Follow-up ideas the interviewer might push: Java 7 segments, `LongAdder` vs `AtomicLong`, and why `computeIfAbsent` must stay fast.
