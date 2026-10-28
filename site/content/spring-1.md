## Spring core | P2 | must

### IoC container and dependency injection

#### Core idea
**Inversion of Control (IoC)** means your classes don't create their dependencies; a container creates them and hands them in. **Dependency Injection (DI)** is how Spring does IoC: the `ApplicationContext` creates **beans**, wires their dependencies, and manages their lifecycle.

#### How it works
- **Bean definitions** come from component scanning (`@Component`, `@Service`, `@Repository`, `@Controller`), `@Bean` methods in `@Configuration` classes, and auto-configuration.
- At startup Spring builds a graph of bean definitions, runs `BeanFactoryPostProcessor`s (which modify definitions, e.g. resolving `${}` placeholders), instantiates singletons eagerly, injects dependencies, then runs `BeanPostProcessor`s (which can wrap beans in proxies, e.g. for `@Transactional`).
- **Injection types**:
  - **Constructor injection** (recommended): dependencies are `final`, the object is never half-built, it's easy to test with `new`, and circular dependencies fail fast. Since Spring 4.3, a single constructor needs no `@Autowired`.
  - **Setter injection**: for optional dependencies.
  - **Field injection** (`@Autowired` on a field): concise but hides dependencies, can't be `final`, and needs reflection or Spring to test. Avoid it in production code.
- **Resolving ambiguity**: when several beans match a type, use `@Primary`, `@Qualifier("name")`, or inject `List<PaymentGateway>` / `Map<String, PaymentGateway>` to get all of them.
- `@Repository` also enables exception translation (SQL exceptions become Spring's `DataAccessException`).

```java
@Service
public class CheckoutService {
    private final PaymentGateway gateway;        // final + constructor = immutable, testable
    private final InventoryClient inventory;
    public CheckoutService(@Qualifier("razorpay") PaymentGateway gateway, InventoryClient inventory) {
        this.gateway = gateway; this.inventory = inventory;
    }
}

@Configuration
class HttpConfig {
    @Bean RestClient inventoryRestClient(RestClient.Builder b) {
        return b.baseUrl("http://inventory").build();
    }
}
```

#### Real-world example
Strategy selection with DI: inject `Map<String, NotificationSender>`, where the keys are bean names like `"sms"`, `"email"`, `"push"`. The controller looks up `senders.get(channel)`. Adding WhatsApp means adding one `@Component("whatsapp")` class with no changes elsewhere, which is open/closed in practice.

#### Interview questions
?? Why is constructor injection recommended over field injection?
Dependencies are explicit and `final`; the object is fully initialised and immutable after construction; unit tests can use plain `new` without Spring or reflection; circular dependencies are detected at startup instead of hidden; and too many constructor parameters is a visible smell that the class does too much.

?? What is the difference between BeanFactory and ApplicationContext?
`BeanFactory` is the basic container (lazy bean creation, DI). `ApplicationContext` extends it with eager singleton initialisation, event publishing, i18n message sources, environment and profiles, automatic `BeanPostProcessor` registration, and AOP integration. Applications always use ApplicationContext.

?? How does Spring resolve which bean to inject when there are two implementations?
By type first. If there are several candidates: a `@Qualifier` match, then a `@Primary` bean, then a match between the parameter name and a bean name. Otherwise it throws `NoUniqueBeanDefinitionException`. You can also inject all of them as a `List` or `Map`.

#### Tricky questions
?? How does Spring handle circular dependencies?
With **setter or field** injection on singletons, Spring could resolve them through an early reference ("three-level cache": it exposes a reference to the not-yet-initialised bean). With **constructor** injection, it can't, and fails with `BeanCurrentlyInCreationException`. Since **Spring Boot 2.6, circular references are prohibited by default** (`spring.main.allow-circular-references=false`). The right fix is to redesign: extract the shared logic into a third bean, or use events.

?? You `new` a `@Service` class yourself. Does `@Autowired` or `@Transactional` work inside it?
No. Only beans created by the container get injection and proxies. A manually `new`ed object is a plain object, so its dependencies are null and its annotations are ignored.

#### Interview simulation
**Interviewer:** "What happens when a Spring Boot application starts?"

**Structure:** (1) `SpringApplication.run` creates the environment (property sources, profiles) and the `ApplicationContext`. (2) Component scanning and auto-configuration register bean definitions, with `@Conditional` deciding which auto-configs apply. (3) BeanFactoryPostProcessors run (property placeholders, `@Configuration` class processing). (4) Singletons are instantiated: constructor → injection → `Aware` callbacks → BeanPostProcessors before init → `@PostConstruct` → `afterPropertiesSet` → post-processors after init (proxies created here). (5) The embedded server (Tomcat) starts. (6) `ApplicationRunner`/`CommandLineRunner` run, and `ApplicationReadyEvent` is published. Give it in about 90 seconds, then offer to go deeper on any step.

### Bean lifecycle and scopes

#### Core idea
Spring controls each bean's **lifecycle** (creation, initialisation, use, destruction) and its **scope** (how many instances exist and how long they live).

#### How it works
**Lifecycle in order**
1. Instantiate (constructor).
2. Populate properties (setter/field injection).
3. `BeanNameAware`, `BeanFactoryAware`, `ApplicationContextAware` callbacks.
4. `BeanPostProcessor.postProcessBeforeInitialization`.
5. `@PostConstruct` → `InitializingBean.afterPropertiesSet()` → custom `initMethod`.
6. `BeanPostProcessor.postProcessAfterInitialization` (**AOP proxies are created here**).
7. The bean is ready.
8. On shutdown: `@PreDestroy` → `DisposableBean.destroy()` → `destroyMethod`.

**Scopes**
| Scope | Instances | Notes |
|---|---|---|
| `singleton` (default) | one per ApplicationContext | must be thread-safe (stateless services) |
| `prototype` | a new one every time it's requested | Spring doesn't call destroy callbacks |
| `request` | one per HTTP request | web only |
| `session` | one per HTTP session | web only |
| `application` | one per ServletContext | web only |
| `websocket` | one per WebSocket session | |

**Scope mismatch problem**: injecting a prototype or request-scoped bean into a singleton injects **one instance at startup**, forever. Fixes: `ObjectProvider<T>` (`provider.getObject()` each time), `@Lookup` methods, or a scoped proxy (`@Scope(value="request", proxyMode=ScopedProxyMode.TARGET_CLASS)`).

#### Real-world example
A singleton `@Service` holding a mutable field like `private List<Item> currentCart` is a **production bug**: every concurrent request shares it, so users see each other's carts. Singletons must be stateless, with per-request data in method parameters or local variables. `@PostConstruct` is commonly used to warm a cache or validate configuration at startup; `@PreDestroy` flushes buffers or closes clients.

#### Interview questions
?? Are Spring singleton beans thread-safe?
Not automatically. Spring creates one instance shared by all request threads, but doesn't synchronise anything. They're safe if they're **stateless** (only final references to other thread-safe beans). Mutable instance state must be removed, made thread-safe (concurrent collections, atomics), or moved to request scope.

?? Singleton bean vs the Singleton design pattern?
The GoF Singleton guarantees one instance per **classloader**, enforced by the class itself (private constructor). A Spring singleton is one instance per **ApplicationContext**, managed by the container. You can still `new` the class, and two contexts give two instances.

?? When does @PostConstruct run, and can you use injected dependencies in it?
After dependency injection completes, before the bean is put into service, so yes, dependencies are available. But the bean isn't yet proxied at that point, so calling its own `@Transactional` methods from `@PostConstruct` won't start a transaction. Use `ApplicationReadyEvent` for work that needs the full context and proxies.

#### Tricky questions
?? You inject a prototype bean into a singleton and call it 10 times. How many prototype instances are created?
One. Injection happens once, when the singleton is created. To get a new instance per use, inject `ObjectProvider<MyProto>` and call `getObject()`.

?? Does Spring call @PreDestroy on prototype beans?
No. Spring hands prototypes over and forgets them; the client must clean them up.

#### Interview simulation
**Interviewer:** "A bug report says users occasionally see another user's data. The service is Spring Boot. Where do you look first?"

**Clarify:** "Is it in API responses or in logs? Does it appear only under load? Is there any caching layer?"

**Answer:** Top suspects: (1) **mutable state in a singleton bean** (an instance field assigned per request); (2) a **ThreadLocal not cleared** in a pooled thread (security or user context); (3) a **cache key missing the user ID**; (4) a response cached by a CDN or proxy without `Cache-Control: private`. Explain how you'd confirm each (code search for non-final fields in `@Service` classes, a load test with two users, cache key review). It shows systematic thinking about a scary class of bug.

### Proxies and AOP

#### Core idea
**Aspect-Oriented Programming (AOP)** adds cross-cutting behaviour (transactions, security, caching, logging, retries) around methods without changing their code. Spring implements AOP with **runtime proxies**: the bean you inject is a wrapper that runs the extra logic and then calls the real object.

#### How it works
- **Proxy types**:
  - **JDK dynamic proxy**: implements the bean's *interfaces*. It works only through interfaces.
  - **CGLIB proxy**: generates a *subclass* of the bean class at runtime. It can't proxy `final` classes or methods. **Spring Boot defaults to CGLIB** (`proxyTargetClass=true`).
- **Terminology**: an *aspect* (a module of cross-cutting logic, `@Aspect`), *advice* (what to run: `@Before`, `@After`, `@AfterReturning`, `@AfterThrowing`, `@Around`), a *pointcut* (where: an expression matching methods), a *join point* (a method execution in Spring AOP).
- **Annotations implemented through proxies**: `@Transactional`, `@Cacheable`, `@Async`, `@Retryable`, `@PreAuthorize`, `@Validated` (method validation).

```java
@Aspect @Component
public class TimingAspect {
    @Around("@annotation(com.acme.Timed)")
    public Object time(ProceedingJoinPoint pjp) throws Throwable {
        long t = System.nanoTime();
        try { return pjp.proceed(); }
        finally { log.info("{} took {} ms", pjp.getSignature(), (System.nanoTime() - t) / 1_000_000); }
    }
}
```

**The big limitation: self-invocation.** A call from one method of a bean to another method of **the same bean** (`this.otherMethod()`) goes directly to the target object and **bypasses the proxy**, so the advice (transaction, cache, async) doesn't apply. The same is true for `private` methods (CGLIB can't override them) and `final` methods.

#### Real-world example
At Tata 1mg-style services, `@Cacheable("medicineSearch")` on a search method gives Redis caching via a proxy. A teammate calls `search()` from another method in the same class to "reuse" it and the cache silently stops working. Hit ratio drops and DB load rises with no error anywhere. Knowing the proxy model lets you diagnose this in minutes.

#### Interview questions
?? JDK dynamic proxy vs CGLIB?
JDK proxies implement interfaces, so callers must use the interface type. CGLIB subclasses the concrete class, so it works without interfaces but can't intercept `final` methods or classes, and needs a non-private constructor (Objenesis avoids actually calling it). Spring Boot uses CGLIB by default to avoid "proxy is not an instance of MyServiceImpl" injection errors.

?? Why doesn't @Transactional work on a private method?
Spring's proxy can only intercept calls that go through it to overridable public (or, with CGLIB in Spring 6, protected and package-visible) methods. Private methods can't be overridden by the CGLIB subclass, and calls to them are always internal, so the annotation is ignored silently.

?? Which advice type would you use for timing or retries, and why?
`@Around`, because it's the only advice that controls whether and when `proceed()` runs and can measure both before and after, catch exceptions, and retry.

#### Tricky questions
?? How can you make self-invocation go through the proxy?
Options: move the method to another bean (cleanest); inject the bean into itself lazily (`@Lazy @Autowired private MyService self;` and call `self.method()`); use `AopContext.currentProxy()` with `exposeProxy=true` (couples code to AOP); or use AspectJ compile-time or load-time weaving, which modifies the bytecode itself so self-calls are woven too.

?? Does `@Async` on a method returning `void` propagate exceptions to the caller?
No. The caller has already returned. Exceptions go to the `AsyncUncaughtExceptionHandler`. Return `CompletableFuture` if the caller needs results or errors. And `@Async` has the same self-invocation limitation.

#### Interview simulation
**Interviewer:** "Explain how @Transactional works under the hood."

**Answer flow:** (1) At startup a BeanPostProcessor detects `@Transactional` and wraps the bean in a proxy. (2) A call enters the proxy's `TransactionInterceptor`. (3) The interceptor asks the `PlatformTransactionManager` to begin or join a transaction according to the propagation setting; the connection is bound to the thread through `TransactionSynchronizationManager` (a ThreadLocal). (4) The target method runs; repositories pick up the same connection from the ThreadLocal. (5) On normal return it commits; on a RuntimeException or Error it rolls back (checked exceptions commit unless `rollbackFor` says otherwise). (6) Pitfalls: self-invocation, private methods, async threads not sharing the transaction, swallowed exceptions preventing rollback. This answer covers AOP, ThreadLocal and the transaction topic together.

### Spring Boot auto-configuration

#### Core idea
**Auto-configuration** makes Spring Boot "just work": based on what's on the classpath and in your properties, Boot registers sensible beans for you (a `DataSource` when there's a JDBC driver, Jackson's `ObjectMapper`, Tomcat, and so on). **Starters** are curated dependency bundles that pull in the libraries plus their auto-configuration.

#### How it works
- `@SpringBootApplication` = `@SpringBootConfiguration` + `@ComponentScan` + `@EnableAutoConfiguration`.
- `@EnableAutoConfiguration` loads the classes listed in `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` (Boot 2.7+; earlier versions used `spring.factories`).
- Each auto-config class is guarded by **conditions**:
  - `@ConditionalOnClass(DataSource.class)`: only if a class is on the classpath.
  - `@ConditionalOnMissingBean`: **only if you haven't defined your own**. This is how you override defaults.
  - `@ConditionalOnProperty("feature.x.enabled")`, `@ConditionalOnWebApplication`, `@ConditionalOnBean`.
- Your beans are processed **before** auto-configuration, so defining your own `ObjectMapper` makes Boot's back off.
- **Debugging**: run with `--debug` (or `debug=true`) to print the **Conditions Evaluation Report** showing which auto-configs matched and why. Or use `/actuator/conditions`.
- Exclude with `@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)` or `spring.autoconfigure.exclude`.

#### Real-world example
You add `spring-boot-starter-data-redis`, set `spring.data.redis.host`, and get a `RedisConnectionFactory`, `RedisTemplate` and `StringRedisTemplate` with no config code. When you need custom serialisation (JSON instead of JDK serialisation), you define your own `RedisTemplate<String, Object>` bean, and Boot's default backs off because of `@ConditionalOnMissingBean`. Companies also write **internal starters** (`acme-logging-starter`) so every service gets the same tracing, logging and security setup automatically.

#### Interview questions
?? How does Spring Boot auto-configuration work?
Boot reads the list of auto-configuration classes from the `AutoConfiguration.imports` file in each jar. Each is a `@Configuration` with `@Conditional...` annotations evaluated against the classpath, existing beans and properties. Matching ones register beans. `@ConditionalOnMissingBean` lets user-defined beans take precedence.

?? How would you create a custom starter?
Two modules: `acme-foo-autoconfigure` (a `@AutoConfiguration` class with conditions, `@ConfigurationProperties` for settings, and the imports file) and `acme-foo-spring-boot-starter` (a dependency-only pom bringing in the autoconfigure module and the libraries). Name it `acme-foo-spring-boot-starter`; only official starters use the `spring-boot-starter-*` prefix.

#### Tricky questions
?? You defined a `DataSource` bean but Boot still configures Hikari properties from application.yml. Why?
`spring.datasource.*` properties bind only to the auto-configured DataSource. If you define your own, you must bind properties yourself (`@ConfigurationProperties("spring.datasource.hikari")` on your `@Bean`). Otherwise those settings are silently ignored.

#### Interview simulation
If asked "What does @SpringBootApplication do?", name the three annotations, explain the conditional mechanism and `@ConditionalOnMissingBean` for overrides, mention the debug report, and end with an example of overriding a default (a custom ObjectMapper or RedisTemplate). Short and concrete.

### Profiles and externalized configuration

#### Core idea
The same artifact (jar or image) should run in dev, staging and prod with **different configuration supplied from outside**. That's a **12-factor** principle. Spring Boot reads configuration from many **property sources** with a defined precedence, and **profiles** activate environment-specific beans and properties.

#### How it works
**Precedence (highest wins, simplified):**
1. Command-line arguments (`--server.port=9090`).
2. `SPRING_APPLICATION_JSON`.
3. OS environment variables (`SPRING_DATASOURCE_URL` → `spring.datasource.url` via relaxed binding).
4. Profile-specific files outside the jar, then inside the jar (`application-prod.yml`).
5. `application.yml` outside the jar, then inside.
6. `@PropertySource` and defaults.

- **Profiles**: `spring.profiles.active=prod`; beans annotated `@Profile("prod")`; profile-specific files. Profile groups combine several profiles.
- **Type-safe config** (preferred over scattered `@Value`):
```java
@ConfigurationProperties(prefix = "payment")
@Validated
public record PaymentProps(@NotBlank String baseUrl, @NotNull Duration timeout, int maxRetries) {}
// application.yml:  payment: { base-url: https://api.pay, timeout: 2s, max-retries: 3 }
```
- **Secrets** never go in git: use environment variables injected by Kubernetes Secrets, AWS Secrets Manager or Parameter Store (Spring Cloud AWS), or Vault. Use `spring.config.import=optional:configtree:/etc/secrets/` for mounted secret files.
- **Dynamic refresh**: Spring Cloud Config with `@RefreshScope`, or feature flag systems for runtime toggles.

#### Real-world example
One Docker image is promoted from staging to prod. The Kubernetes Deployment sets `SPRING_PROFILES_ACTIVE=prod` and injects `SPRING_DATASOURCE_PASSWORD` from a Secret; `application-prod.yml` sets pool sizes and log levels. If someone hardcodes a staging URL in `application.yml`, an env var still overrides it, which is why knowing the precedence matters during incidents.

#### Interview questions
?? @Value vs @ConfigurationProperties?
`@Value("${x}")` injects single values, with SpEL support, and is scattered and stringly typed. `@ConfigurationProperties` binds a whole prefix into a typed object with relaxed binding, validation (`@Validated`), IDE metadata and easy testing. Prefer it for anything more than one or two values.

?? How do you manage secrets in a Spring Boot app?
Never commit them. Inject them at runtime through environment variables or mounted files from a secret manager (Kubernetes Secrets, ideally synced from AWS Secrets Manager or Vault through External Secrets), with least-privilege IAM access, rotation, and no logging of config values (Actuator `/env` masks keys like "password" and "secret" by default; keep it secured anyway).

#### Tricky questions
?? An env var `SPRING_DATASOURCE_URL` is set, but application.yml also has `spring.datasource.url`. Which wins?
The environment variable, because OS env vars have higher precedence than `application.yml`. This often confuses people debugging "why is it connecting to the wrong DB?"

#### Interview simulation
If asked "How do you promote the same build across environments?", answer: build once, versioned image; config via env vars and profile files; secrets from a secret manager; feature flags for risky changes; and validation at startup with `@Validated` properties so misconfiguration fails fast instead of at 2am.

## Data access & transactions | P2 | must

### @Transactional: propagation, isolation and rollback

#### Core idea
`@Transactional` declares a **transaction boundary**: everything inside commits together or rolls back together. Its attributes control how transactions **nest** (propagation), how they **see concurrent changes** (isolation), and **which exceptions roll back**.

#### How it works
**Propagation**
| Value | Behaviour | Use case |
|---|---|---|
| `REQUIRED` (default) | join the existing transaction, or start one | almost everything |
| `REQUIRES_NEW` | suspend the outer one and start an independent transaction | audit log or outbox that must commit even if the outer one rolls back |
| `NESTED` | savepoint inside the outer transaction (JDBC only) | partial rollback of a step |
| `SUPPORTS` | join if one exists, else run non-transactionally | read helpers |
| `MANDATORY` | must already be in a transaction, else throw | enforcing that callers start one |
| `NOT_SUPPORTED` | suspend any transaction and run without one | long reads, calls that shouldn't hold a connection |
| `NEVER` | throw if a transaction exists | |

**Isolation** (maps to the DB's levels; see the CS → DBMS lesson for the anomalies):
`READ_UNCOMMITTED` < `READ_COMMITTED` (Postgres default) < `REPEATABLE_READ` (MySQL InnoDB default) < `SERIALIZABLE`.

**Rollback rules**
- By default it rolls back on **unchecked** exceptions (`RuntimeException`, `Error`) and **commits on checked exceptions**!
- Change this with `@Transactional(rollbackFor = Exception.class)` or `noRollbackFor`.
- If you catch an exception inside the method and don't rethrow, Spring sees a normal return and commits.

**Other attributes**: `readOnly = true` (a hint: Hibernate skips dirty checking and flush, and the driver may route to a replica); `timeout`.

**Where to put it**: on **service** methods (the business transaction), not controllers or repositories. Keep transactions short, with no remote HTTP calls inside.

```java
@Transactional
public void placeOrder(OrderReq r) {
    Order o = orders.save(new Order(r));
    inventory.reserve(r.items());            // same DB → same transaction
    outbox.save(new OrderPlacedEvent(o));    // committed atomically with the order (outbox pattern)
}

@Transactional(propagation = Propagation.REQUIRES_NEW)
public void recordAttempt(Attempt a) { attempts.save(a); }   // survives outer rollback
```

#### Real-world example
Payment flows: a failed charge must still be recorded for reconciliation. If `recordAttempt` used `REQUIRED`, the outer rollback would erase the evidence; `REQUIRES_NEW` (in a separate bean!) keeps it. And a remote call to a payment gateway **inside** a DB transaction holds a DB connection for the whole HTTP round trip; under load the Hikari pool runs dry and the whole service stalls. Do the remote call outside the transaction, or use an outbox or saga.

#### Interview questions
?? What is the default rollback behaviour of @Transactional?
It rolls back on `RuntimeException` and `Error`; it **commits** on checked exceptions. This comes from EJB conventions (checked = expected business outcome). Use `rollbackFor = Exception.class` if your checked exceptions mean failure.

?? REQUIRED vs REQUIRES_NEW vs NESTED?
REQUIRED joins the caller's transaction, so one failure rolls back everything. REQUIRES_NEW runs an independent transaction on a **separate connection** (the outer one is suspended), committing or rolling back on its own. NESTED uses a savepoint in the same connection: the inner part can roll back to the savepoint while the outer continues, but if the outer rolls back, the nested work is lost too.

?? Why should you avoid remote calls inside a transaction?
The transaction holds a DB connection and possibly row locks for the whole remote call. Slow downstreams exhaust the pool and increase lock contention. And the remote side effect can't be rolled back if the DB transaction later fails. Use the outbox pattern, or do the call before or after the transaction with compensation.

#### Tricky questions
?? An inner REQUIRED method throws a RuntimeException, the outer method catches it and returns normally. What happens?
The transaction was marked **rollback-only** when the exception passed through the inner proxy. When the outer method tries to commit, Spring throws `UnexpectedRollbackException: Transaction silently rolled back because it has been marked as rollback-only`. Catching doesn't undo the mark. Use REQUIRES_NEW for the inner call, or don't catch.

?? Does `readOnly = true` prevent writes?
Not reliably. It's a hint. Hibernate sets the flush mode to manual (so entity changes aren't flushed), and some drivers or DBs set the connection read-only (Postgres rejects writes in a read-only transaction). But it's not a security mechanism.

?? Does REQUIRES_NEW need a second connection? Can it deadlock?
Yes, it takes a second pooled connection while the first is still held. With a small pool and many concurrent requests each holding one connection and waiting for a second, the pool deadlocks (everyone waits for a connection nobody releases). Size the pool accordingly, or avoid REQUIRES_NEW on hot paths.

#### Interview simulation
**Interviewer:** "Orders are being created without the inventory being reduced. Both happen in placeOrder() which is @Transactional. How?"

**Clarify:** "Are inventory and orders in the same database? Is the inventory call a remote service or a local repository? Is placeOrder called from within the same class?"

**Answer:** Candidates: (1) Self-invocation, so there's no transaction at all and each repository call auto-commits. (2) Inventory is a **remote service**: the DB transaction can't cover it, the remote call failed or timed out, the exception was caught, and the order committed. (3) A checked exception was thrown, which commits by default. (4) The exception was swallowed in a try/catch. Fixes: verify with logs (`logging.level.org.springframework.transaction=DEBUG` shows transaction boundaries); for cross-service consistency use a saga with an outbox; add `rollbackFor`. Ending with "for cross-service I'd use a saga" signals seniority.

### Self-invocation and other @Transactional pitfalls

#### Core idea
Most `@Transactional` bugs come from forgetting that it's a **proxy-based** feature. If the call doesn't go through the proxy, or the transaction's thread or connection isn't the one doing the work, the annotation silently does nothing.

#### How it works
**The pitfall list (memorise it):**
1. **Self-invocation**: `this.save()` from another method of the same bean bypasses the proxy.
2. **Private/final/static methods**: they can't be proxied, so the annotation is ignored.
3. **Checked exceptions** commit by default.
4. **Swallowed exceptions**: catching without rethrowing means commit.
5. **New threads/async**: `@Async`, `CompletableFuture.supplyAsync` and parallel streams run on other threads with no transaction, because the transaction is bound to a ThreadLocal.
6. **Wrong transaction manager** in multi-datasource apps: specify `@Transactional("ordersTxManager")`.
7. **Calling from `@PostConstruct`**: the proxy isn't ready.
8. **Lazy loading outside the transaction**: `LazyInitializationException` after the method returns.
9. **Long transactions** holding connections during remote calls or heavy computation.
10. **Database auto-commit or engine issues**: MySQL MyISAM tables don't support transactions at all.

```java
@Service
public class ReportService {
    public void generateAll() {
        for (var id : ids) generateOne(id);          // ❌ self-invocation: no transaction per report
    }
    @Transactional(propagation = REQUIRES_NEW)
    public void generateOne(Long id) { ... }
}
// ✅ Fix: move generateOne to ReportWorker bean and inject it, or use TransactionTemplate:
txTemplate.executeWithoutResult(status -> generate(id));
```
`TransactionTemplate` (programmatic transactions) gives explicit control, with no proxy magic. It's great for loops where each item needs its own transaction.

#### Real-world example
A nightly job processed 50k records inside one `@Transactional` method: 40 minutes holding one connection, huge undo logs, and a single bad record rolled back everything. The fix: per-batch transactions (chunks of 500) via `TransactionTemplate`, failed records logged to an error table, and the job made idempotent so it could resume. This is the same pattern Spring Batch uses (chunk-oriented processing).

#### Interview questions
?? List reasons @Transactional might not work.
Self-invocation; non-public, final or private methods; checked exceptions (commit); swallowed exceptions; work done on another thread; the bean not managed by Spring (`new`); the wrong transaction manager; called during `@PostConstruct`; a non-transactional storage engine.

?? How do you run each item of a loop in its own transaction?
Put the per-item method in a separate bean with `@Transactional(propagation = REQUIRES_NEW)`, or use `TransactionTemplate` inside the loop. Also consider batching (chunks) to reduce overhead.

#### Tricky questions
?? You call a @Transactional method from a CompletableFuture. Is it transactional?
Yes. If the method is on another bean called through its proxy, it starts its **own** transaction on the async thread. It does **not** join the caller's transaction (different thread, different ThreadLocal). So the caller's rollback doesn't undo it.

#### Interview simulation
In code-comprehension or review rounds you may be shown a service with `@Transactional` on a private method or a self-call. Say it out loud: "This annotation has no effect because the call doesn't go through the Spring proxy," then propose the fix. Interviewers specifically plant this bug (see the Code Comprehension track).

### JPA and Hibernate: entity states, fetching and N+1

#### Core idea
**JPA** is the specification and **Hibernate** the implementation that maps Java objects to tables. The `EntityManager` (the persistence context) tracks entities and automatically writes changes to the DB at flush. Its biggest performance trap is the **N+1 query problem**.

#### How it works
**Entity states**
```
new (transient) ──persist()──▶ MANAGED ──commit/flush──▶ SQL
                                  │  ▲
                     detach/clear/close │  merge()
                                  ▼  │
                               DETACHED        MANAGED ──remove()──▶ REMOVED
```
- **Managed** entities are tracked: changing a field is enough, and **dirty checking** issues the UPDATE at flush with no `save()` needed.
- The persistence context is a **first-level cache**: `find` for the same id in the same transaction hits memory.
- **Flush** happens before commit, before queries that might be affected (AUTO mode), or explicitly.

**Fetching**
- `@ManyToOne` / `@OneToOne` default to **EAGER**; `@OneToMany` / `@ManyToMany` default to **LAZY**. Best practice: make **everything LAZY** and fetch explicitly.
- Lazy associations are proxies, loaded on first access. Accessing them outside an open session throws `LazyInitializationException`.

**N+1 problem**
```java
List<Order> orders = orderRepo.findAll();             // 1 query
for (Order o : orders) o.getItems().size();           // N queries, one per order
```
Fixes:
- **Fetch join**: `@Query("select o from Order o join fetch o.items where o.status = :s")`.
- **`@EntityGraph(attributePaths = "items")`** on a repository method.
- **Batch fetching**: `hibernate.default_batch_fetch_size=50` loads lazy collections with `IN (…)` in batches. A low-effort global improvement.
- **DTO projections**: select only the columns you need (`select new com.acme.OrderSummary(o.id, o.total) …`, or interface/record projections).
- Caution: fetch-joining collections together with pagination makes Hibernate paginate **in memory** (warning HHH000104). Paginate the IDs first, then fetch the entities by IDs.

**Open Session in View (OSIV)**: Spring Boot enables `spring.jpa.open-in-view=true` by default, which keeps the session open through view rendering so lazy loading "works" in controllers. But it holds a DB connection for the entire request and hides N+1 queries. **Disable it** in APIs and fetch what you need in the service layer.

**Detecting N+1**: enable SQL logging (`spring.jpa.show-sql`, or better, `logging.level.org.hibernate.SQL=debug`), Hibernate statistics, or tools like datasource-proxy or Hypersistence Optimizer. Assert the query count in tests.

#### Real-world example
An admin dashboard listing 100 orders with customer names fired **201 queries** (orders, then each customer, then each order's items). p95 was 2.3s. The fix was one query with `join fetch o.customer` plus batch fetching for items: **3 queries, 80ms**. A DB-tuning story like your "query time −50%" is likely to come up in follow-ups, so know this pattern cold.

#### Interview questions
?? What is the N+1 problem and how do you fix it?
Loading a list with 1 query and then lazily loading an association for each element with N more queries. Fixes: fetch join / EntityGraph for the association you need, batch fetching, DTO projections, and disabling OSIV so it surfaces early. Detect it via SQL logs or query-count assertions in tests.

?? What does `save()` do on an entity that's already managed?
Nothing extra is needed. Dirty checking flushes changes at commit. `repo.save()` on an existing entity calls `merge`, which is unnecessary for managed entities and can cause an extra SELECT for detached ones. Knowing this shows you understand the persistence context.

?? `persist` vs `merge`?
`persist` makes a *new* entity managed (an INSERT at flush) and returns void; the same instance becomes managed. `merge` copies the state of a detached (or new) entity **onto a managed instance**, loading it if needed, and **returns that managed instance**; the argument stays detached. A common bug is continuing to modify the argument after `merge`.

#### Tricky questions
?? Why does `findAll(PageRequest.of(0, 20))` with a `join fetch` of a collection load the whole table?
Pagination with a collection fetch join can't be done in SQL (row duplication from the join), so Hibernate fetches **all** rows and paginates in memory (warning HHH000104, or an exception with `hibernate.query.fail_on_pagination_over_collection_fetch`). Fix: query the page of IDs first, then fetch the entities with their collections `where id in :ids`.

?? Why is `@ManyToOne` EAGER by default a problem?
Every query loading that entity also loads the associated entity, and with JPQL queries this often happens as **separate queries per row** (an N+1 of its own). Set `fetch = LAZY` explicitly on all `@ManyToOne`/`@OneToOne`.

?? What's the danger of Lombok `@Data` or `@EqualsAndHashCode` on entities?
They generate equals/hashCode/toString over all fields, including lazy collections, which triggers lazy loading, causes `LazyInitializationException`, and can recurse infinitely with bidirectional relations (StackOverflowError in `toString`). They also break `HashSet` semantics when the id changes after persist. Write entity equals/hashCode by hand (id-based with a constant hashCode).

#### Interview simulation
**Interviewer:** "This endpoint is slow. It returns 50 orders with their items and customer names." (Typical LLD/backend round.)

**Clarify:** "Do we have the SQL logs? How many queries does one request issue? Is OSIV on? And what does the response DTO need: all the fields, or a summary?"

**Answer:** Hypothesise N+1 first, and confirm it by counting queries. Fix in layers: fetch join for the to-one association (customer), batch fetch or a second IN query for the to-many (items) to avoid a cartesian explosion, DTO projection if we only need a few columns, and an index on `order_items(order_id)`. Then verify with `EXPLAIN ANALYZE`, disable OSIV, and add a test that asserts the query count. Report before/after numbers.

### Optimistic vs pessimistic locking

#### Core idea
Two ways to prevent **lost updates** when concurrent transactions modify the same row:
- **Optimistic locking**: assume conflicts are rare. Don't lock; detect a conflict at write time with a version number, and retry or fail.
- **Pessimistic locking**: assume conflicts are likely. Lock the row when reading (`SELECT … FOR UPDATE`) so others wait.

#### How it works
**Optimistic (JPA `@Version`)**
```java
@Entity class Product { @Id Long id; int stock; @Version long version; }
// Hibernate issues: UPDATE product SET stock=?, version=version+1 WHERE id=? AND version=?
// 0 rows updated → OptimisticLockException (Spring: ObjectOptimisticLockingFailureException)
```
- No locks are held, so it scales for read-heavy workloads with low contention.
- On conflict: retry the whole read-modify-write (e.g. `@Retryable`), or return **409 Conflict** to the client. In REST, expose the version as an **ETag** and require `If-Match` on updates.

**Pessimistic**
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)                 // SELECT ... FOR UPDATE
@Query("select w from Wallet w where w.id = :id")
Optional<Wallet> findForUpdate(Long id);
```
- Others block until commit, so it's correct under high contention, but holds locks (deadlock risk, lower throughput).
- Variants: `FOR UPDATE NOWAIT` (fail immediately), `FOR UPDATE SKIP LOCKED` (skip locked rows, perfect for **job queues** where workers each grab different rows).
- Set a lock timeout (`jakarta.persistence.lock.timeout`).

**Third option, often best: an atomic conditional update**
```sql
UPDATE product SET stock = stock - :qty WHERE id = :id AND stock >= :qty;   -- check rows affected == 1
```
No read-modify-write at all, so no lost update, in a single round trip.

| | Optimistic | Pessimistic | Atomic UPDATE |
|---|---|---|---|
| Contention | low | high | any |
| Locks held | none | until commit | very brief, row-level |
| Failure mode | retries / 409 | waiting, deadlocks | 0 rows → business error |

#### Real-world example
**Flash sale stock**: 10k users buy the last 100 units. Optimistic locking leads to retry storms (most attempts conflict). Pessimistic locking serialises everyone on one hot row (high latency). The atomic conditional `UPDATE … WHERE stock >= qty` (or a Redis `DECR` with a Lua check, reconciled to the DB) handles it best. For **editing a profile or document**, optimistic locking with an ETag is ideal: conflicts are rare and you want no locks.

#### Interview questions
?? When would you choose optimistic over pessimistic locking?
Optimistic when conflicts are rare and transactions short (most CRUD, user edits): no lock overhead, scales well, and conflicts are handled by retry or 409. Pessimistic when conflicts are frequent and retries would be wasteful or unsafe (ticket seat allocation, financial balance updates under contention), or when the critical section must not be redone.

?? How do you implement a job queue in Postgres where multiple workers pull jobs without double-processing?
```sql
UPDATE jobs SET status='RUNNING', locked_by=:worker, locked_at=now()
WHERE id IN (SELECT id FROM jobs WHERE status='PENDING' ORDER BY created_at
             FOR UPDATE SKIP LOCKED LIMIT 10)
RETURNING *;
```
`SKIP LOCKED` lets each worker take different rows without blocking. Add a visibility timeout (reclaim jobs stuck in RUNNING for too long) for crash safety.

#### Tricky questions
?? Optimistic locking with @Version, but two users still overwrite each other via the REST API. Why?
The API loads the entity fresh (getting the *current* version) for each PUT, so the version check always passes. The client's version must round-trip: return it (or an ETag) on GET, and require it on PUT (`If-Match`). Otherwise the lost update happens across HTTP requests, not inside one transaction.

?? Does REPEATABLE_READ isolation alone prevent lost updates?
Database-dependent. In Postgres, a REPEATABLE READ transaction that updates a row changed by a concurrent committed transaction gets a serialization error (good). In MySQL InnoDB, a plain `SELECT` is a snapshot read but `UPDATE` uses the latest committed row, so a read-modify-write in application code **can still lose updates** unless you use `SELECT … FOR UPDATE` or atomic SQL.

#### Interview simulation
**Interviewer:** "Two concurrent requests try to withdraw from the same wallet. How do you prevent overdraft?"

**Clarify:** "What's the expected contention per wallet? Single DB or sharded? Can the client retry? Are there idempotency requirements?"

**Answer:** Simplest correct approach: atomic `UPDATE wallet SET balance = balance - :amt WHERE id = :id AND balance >= :amt`, checking rows affected, inside a transaction that also inserts the ledger entry. For transfers between two wallets, `SELECT … FOR UPDATE` both rows in id order (deadlock avoidance). Add an idempotency key so client retries don't double-withdraw. Mention optimistic locking as a fine alternative at low contention, with retries. That covers correctness, concurrency and idempotency.

### Connection pooling with HikariCP

#### Core idea
Opening a DB connection costs a TCP handshake, TLS and authentication (milliseconds). A **connection pool** keeps open connections ready and lends them to requests. HikariCP is Spring Boot's default pool, and it's fast and minimal.

#### How it works
Key settings (`spring.datasource.hikari.*`):
| Setting | Meaning | Guidance |
|---|---|---|
| `maximum-pool-size` | max connections (default 10) | often small: around `cores × 2 + spindles` per DB server, *divided across all app instances* |
| `minimum-idle` | idle connections kept | Hikari recommends = max (a fixed-size pool) |
| `connection-timeout` | wait for a connection before failing (default 30s) | lower it (e.g. 2–5s) to fail fast under overload |
| `max-lifetime` | retire connections after this long (default 30min) | set below the DB, proxy or firewall idle timeouts |
| `idle-timeout` | close idle connections above minimum-idle | |
| `leak-detection-threshold` | warn if a connection is held longer than this | e.g. 20s in non-prod, to catch leaks |

**Why a bigger pool isn't better:** a DB can only work on about `cores` queries truly in parallel. 300 connections on an 8-core Postgres means context switching, lock contention and memory per connection (Postgres forks a process per connection, around 5–10MB each). Throughput often **increases** when the pool shrinks.

**Total connections = pool size × number of app instances.** 20 pods × 20 = 400 connections, which can exceed Postgres `max_connections` (default 100). Use **PgBouncer** (transaction pooling) or RDS Proxy in front of the DB when you have many instances.

**Metrics to watch** (Micrometer): `hikaricp.connections.active`, `.pending` (threads waiting: a red flag), `.usage` and `.acquire` (time to get a connection).

#### Real-world example
Under a traffic spike, the API started returning 500s after exactly 30 seconds: `SQLTransientConnectionException: Connection is not available, request timed out after 30000ms`. The root cause wasn't the pool size. A new endpoint called a slow partner API **inside** a `@Transactional` method, holding connections for 5–10 seconds each. Fix: move the remote call out of the transaction, lower `connection-timeout` to 3s so failures surface fast, and alert on `pending > 0`.

#### Interview questions
?? How do you size a database connection pool?
Start from DB capacity, not from app threads: roughly `2 × DB cores` of active queries for the whole cluster, divided by the number of app instances. Measure the acquire time and pending threads under load and adjust. Keep transactions short so a small pool goes far. If there are many instances, add PgBouncer or RDS Proxy.

?? What happens when the pool is exhausted?
Threads block in `getConnection()` up to `connection-timeout`, then get an exception. Request latency spikes, Tomcat threads pile up waiting, and the service can cascade into total unavailability. Root causes are usually long transactions, connection leaks (not closed, e.g. raw JDBC without try-with-resources), slow queries, or traffic beyond capacity.

#### Tricky questions
?? Why set max-lifetime shorter than the database's or firewall's idle timeout?
Network devices (AWS NAT gateways, load balancers, firewalls) silently drop idle TCP connections after some time (e.g. 350s on NAT gateways). The pool doesn't know, and the next query on that connection hangs or fails. Retiring connections earlier avoids handing out dead ones.

#### Interview simulation
If asked "We scaled from 5 to 50 pods and the database fell over. Why?", say: each pod's pool multiplied the connection count (50 × 20 = 1000 connections), exceeding `max_connections` and DB memory, plus contention. Fixes: smaller per-pod pools, PgBouncer in transaction mode, read replicas for reads, and checking whether the scaling was even needed (CPU vs DB bound). Showing that you multiply pool size by instance count is the key insight.

### Database migrations with Flyway and Liquibase

#### Core idea
Schema changes must be **versioned, repeatable and automated**, like code. Migration tools apply ordered scripts (`V1__init.sql`, `V2__add_status.sql`) and record which ones ran in a history table, so every environment converges to the same schema.

#### How it works
- **Flyway**: plain SQL (or Java) migrations named `V<version>__<desc>.sql`, applied in order. It records checksums in `flyway_schema_history`. **Never edit an applied migration**: the checksum mismatch fails startup. Repeatable migrations (`R__views.sql`) rerun when changed.
- **Liquibase**: changelogs in XML, YAML or SQL with changesets. It supports rollbacks and DB-agnostic changes, but is more verbose.
- Spring Boot runs them automatically at startup when the library is on the classpath. In production, many teams run migrations as a **separate step** (a Kubernetes Job or init container) before deploying the app, so several pods don't race (Flyway also takes a DB lock).

**Zero-downtime changes: expand/contract pattern**
During a rolling deploy, old and new app versions run *at the same time*, so every migration must be compatible with both.
1. **Expand**: add the new column (nullable, or with a default); deploy code that writes both old and new.
2. **Migrate**: backfill in batches (not one huge UPDATE that locks the table).
3. **Switch**: deploy code that reads the new column.
4. **Contract**: later release: drop the old column.

Dangerous operations: renaming a column (old code breaks), adding a `NOT NULL` column without a default to a big table, creating an index without `CONCURRENTLY` (Postgres locks writes), and changing column types (table rewrite).

#### Real-world example
Your NeuronixAI project uses Flyway-managed PostgreSQL. A good story: adding the `embedding vector(1536)` column and an HNSW index. The index build on a large table was done with `CREATE INDEX CONCURRENTLY` in its own migration (Flyway needs it outside a transaction: put it in its own script and configure the migration as non-transactional), so writes kept flowing.

#### Interview questions
?? How do you rename a column without downtime?
Never rename in place. Add the new column, dual-write from the app, backfill old rows in batches, switch reads to the new column, stop writing the old one, then drop it in a later release. Each step is compatible with both the old and new app versions during rolling deploys.

?? Why shouldn't you edit an already-applied Flyway migration?
Environments that already ran it won't rerun it, so schemas silently diverge, and Flyway's checksum validation will fail on startup. Add a new migration instead.

#### Tricky questions
?? Why might `ALTER TABLE orders ADD COLUMN status text NOT NULL DEFAULT 'NEW'` be fast in Postgres 11+ but slow in older versions?
Postgres 11+ stores a constant default in the catalog without rewriting the table (an instant operation). Older versions rewrote every row while holding an exclusive lock. Volatile defaults (like `now()`) still force a rewrite. Knowing your DB version matters for migration safety.

#### Interview simulation
If asked "How do you deploy a schema change safely?", describe expand/contract, running migrations before the app rollout, batching backfills, `CONCURRENTLY` for indexes, testing migrations against a production-sized copy, and having a forward-fix plan (rollbacks of schema changes are rarely clean).
