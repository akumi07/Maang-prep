## JVM internals | P2 | must

### JVM architecture and class loading

#### Core idea
The **JVM** runs Java bytecode. It has three major parts: the **class loader subsystem** (finds and loads `.class` files), the **runtime data areas** (heap, stacks, metaspace and so on), and the **execution engine** (interpreter, JIT compilers, garbage collector).

#### How it works
```
 .java ──javac──▶ .class (bytecode)
                     │
          ┌──────────▼──────────┐
          │ Class Loader         │  Loading → Linking (verify, prepare, resolve) → Initialization
          └──────────┬──────────┘
          ┌──────────▼──────────────────────────────────────┐
          │ Runtime Data Areas                                │
          │  Heap (objects) | Metaspace (class metadata)      │  shared by all threads
          │  JVM Stack | PC Register | Native stack           │  per thread
          └──────────┬──────────────────────────────────────┘
          ┌──────────▼──────────┐
          │ Execution Engine    │  Interpreter + JIT (C1, C2) + GC
          └─────────────────────┘
```
**Class loading phases**
1. **Loading**: read the bytes and create a `Class` object.
2. **Linking**:
   - *Verify*: the bytecode is safe (type checks, no stack overflows in the verifier's model).
   - *Prepare*: allocate static fields and set them to default values.
   - *Resolve*: symbolic references become direct references (can be lazy).
3. **Initialization**: run static initialisers and `<clinit>` (thread-safe, exactly once), on first active use.

**Class loader hierarchy and parent delegation**
- **Bootstrap** (native): core JDK classes (`java.lang.*`).
- **Platform** (formerly Extension): other JDK modules.
- **Application/System**: your classpath.
- **Parent delegation**: a loader first asks its parent, and only loads the class itself if the parent can't. This stops anyone defining their own `java.lang.String`, and avoids duplicate core classes.
- A class's identity at runtime = **its fully qualified name + its defining loader**. The same class loaded by two loaders gives two distinct types, which causes `ClassCastException: X cannot be cast to X`.
- Custom loaders (Tomcat per-webapp, Spring Boot's `LaunchedURLClassLoader` for nested jars, OSGi, hot reload in DevTools) sometimes deliberately invert delegation (child-first).

#### Real-world example
Spring Boot's fat jar contains jars inside a jar, which the standard class loader can't read. Boot's launcher (`JarLauncher`) installs a custom class loader that understands nested jars. Spring DevTools' fast restart uses two class loaders: a "base" one for unchanging dependencies and a "restart" one for your code, which it throws away and recreates on each change.

#### Interview questions
?? What is the parent delegation model and why does it exist?
Before loading a class, a loader delegates to its parent; only if no ancestor can load it does it load the class itself. This gives security (core classes can't be spoofed), consistency (a single definition of core types) and avoids duplicate loading.

?? `ClassNotFoundException` vs `NoClassDefFoundError`?
`ClassNotFoundException` is a checked exception thrown when code explicitly loads a class by name (`Class.forName`, `loadClass`) and it isn't found. `NoClassDefFoundError` is an Error thrown when a class that **was present at compile time** can't be found at runtime, or **failed its static initialisation earlier** (the first failure is `ExceptionInInitializerError`; later accesses see `NoClassDefFoundError`). It's typically a classpath or dependency conflict.

?? When is a class initialised?
On first active use: `new`, a static method call, a non-constant static field access, reflection (`Class.forName` with initialize=true), initialising a subclass, or being the main class. Not when declaring a variable of that type or creating an array of it.

#### Tricky questions
?? Two copies of the same library version conflict on the classpath. What symptoms do you see?
`NoSuchMethodError` / `NoSuchFieldError` (compiled against version 2, loaded version 1), `ClassCastException` between same-named classes from different loaders, or `LinkageError`. Diagnose with `mvn dependency:tree` and `-verbose:class`, then fix with dependency management or exclusions.

?? Can a static initializer failure make a class permanently unusable?
Yes. If `<clinit>` throws, the class is marked erroneous: the first use throws `ExceptionInInitializerError`, and every later use throws `NoClassDefFoundError` for the lifetime of that class loader.

#### Interview simulation
**Interviewer:** "After deploying, the service fails with `NoSuchMethodError` in a Jackson class. How do you debug it?"

**Clarify:** "Did we change dependencies in this release? Does it happen locally, or only in the deployed artifact?"

**Answer:** It's a classic version conflict: code compiled against one version but a different version is loaded at runtime. Steps: run `mvn dependency:tree -Dincludes=com.fasterxml.jackson.core` to find competing versions; check which jar the class came from (`-verbose:class`, or `X.class.getProtectionDomain().getCodeSource()`); pin the version through Spring Boot's dependency management or the Jackson BOM; and add an enforcer rule (`dependencyConvergence`) to the build so it can't recur.

### JVM memory areas: heap, stack, metaspace

#### Core idea
JVM memory is split into areas with different lifetimes and owners:
- **Heap** (shared): all objects and arrays. Managed by GC.
- **Stack** (per thread): frames for method calls, holding local variables and the operand stack.
- **Metaspace** (shared, native memory): class metadata.
- **PC register** and **native method stack** (per thread).
- Plus off-heap: direct buffers, thread stacks, code cache, GC structures.

#### How it works
**Heap generations** (most collectors; ZGC and Shenandoah differ in layout):
```
Young Gen: [ Eden | Survivor S0 | Survivor S1 ]   → minor GC, copying
Old Gen:   [ long-lived objects ]                  → major/mixed GC
```
- New objects go in **Eden** (fast bump-the-pointer allocation inside thread-local allocation buffers, **TLABs**).
- **Minor GC**: live Eden objects are copied to a survivor space, and their age increments each time. After about 15 survivals (`MaxTenuringThreshold`) they're **promoted** to Old Gen.
- This works because of the **weak generational hypothesis**: most objects die young.
- Large objects may go straight to Old (G1: "humongous" regions for objects ≥ half a region).

**Stack**
- One frame per method call: local variables (primitives and references), the operand stack, and a reference to the constant pool.
- Default size is about 512KB–1MB (`-Xss`). Deep recursion causes `StackOverflowError`.
- **Escape analysis**: if the JIT proves an object never escapes a method, it can scalar-replace it (no heap allocation at all).

**Metaspace** (Java 8+, replaced PermGen)
- Class metadata in native memory, which grows automatically by default. Cap it with `-XX:MaxMetaspaceSize`.
- A leak here means class loaders that are never collected (redeploys in app servers, dynamic proxy or bytecode generation in a loop) → `OutOfMemoryError: Metaspace`.

**Key flags**: `-Xms`/`-Xmx` (heap min/max: set them equal in containers), `-Xss`, `-XX:MaxMetaspaceSize`, `-XX:MaxDirectMemorySize`, and **`-XX:MaxRAMPercentage=75`** (container-aware heap sizing, preferred over a fixed `-Xmx` in Kubernetes).

#### Real-world example
A Spring Boot service in a 2GB Kubernetes pod with `-Xmx2g` gets **OOMKilled** by the kernel even though the heap is fine: total memory = heap + metaspace (~150MB) + thread stacks (200 threads × 1MB) + code cache + direct buffers (Netty, Kafka). The rule of thumb is a heap of about 70–75% of the container limit (`-XX:MaxRAMPercentage=75`). Diagnose with Native Memory Tracking (`-XX:NativeMemoryTracking=summary`, then `jcmd <pid> VM.native_memory summary`).

#### Interview questions
?? Where are local variables, objects and static variables stored?
Local primitives and references live on the thread's **stack** frame. Objects (including arrays and the objects locals refer to) live on the **heap**. Static variables live with the class's `Class` object, which is on the heap since Java 8 (class *metadata* is in metaspace). String pool: heap.

?? Why did Java 8 replace PermGen with Metaspace?
PermGen was a fixed-size part of the heap, and frequently caused `OutOfMemoryError: PermGen space` in apps with many classes or redeploys. Metaspace lives in native memory and grows dynamically, so tuning is simpler, and class metadata is freed when its class loader is collected.

?? What is a TLAB?
A Thread-Local Allocation Buffer: a chunk of Eden reserved for one thread, so most allocations are a pointer bump with no synchronisation. That's why allocation in Java is very cheap, about 10 instructions.

#### Tricky questions
?? Container memory limit is 1GB and `-Xmx` is 1GB. What happens?
The process will exceed 1GB because of non-heap memory (metaspace, thread stacks, code cache, direct buffers, GC overhead), and the container gets OOMKilled (exit code 137) with no Java `OutOfMemoryError` in the logs. Set the heap to about 70–75% of the limit.

?? Can objects be allocated on the stack in Java?
Not explicitly. But through escape analysis the JIT can eliminate allocations for non-escaping objects via scalar replacement, so effectively yes for some short-lived objects.

#### Interview simulation
**Interviewer:** "Our pods keep getting restarted with exit code 137. The heap looks fine in metrics. Why?"

**Clarify:** "What are the container memory limit and the JVM flags? How many threads? Do we use Netty or direct buffers?"

**Answer:** Exit 137 means SIGKILL from the kernel OOM killer, so the *process* exceeded the cgroup limit, not the heap. Walk through the non-heap components and how you'd measure them (NMT, `jcmd VM.native_memory`, thread count). Fix: `-XX:MaxRAMPercentage=70`, cap metaspace and direct memory, reduce thread count or stack size, or raise the limit. Mention that `-Xms` = `-Xmx` avoids resize pauses and makes memory use predictable.

### Garbage collection algorithms

#### Core idea
**Garbage collection** automatically frees objects that are no longer **reachable** from GC roots (thread stacks, static fields, JNI references, active monitors). Collectors trade off **throughput** (total work done), **latency** (pause times) and **footprint** (memory overhead).

#### How it works
**Basic phases**
- **Mark**: trace from the GC roots and mark everything reachable.
- **Sweep**: free the unmarked memory.
- **Compact / copy**: move live objects together to defragment (needed for fast bump allocation).
- **Stop-the-world (STW)**: application threads are paused at **safepoints** during some phases.

**Collectors**
| Collector | Flag | Design | Best for |
|---|---|---|---|
| Serial | `-XX:+UseSerialGC` | single-threaded, STW | tiny heaps, CLI tools, 1-CPU containers |
| Parallel | `-XX:+UseParallelGC` | multi-threaded STW, maximises throughput | batch jobs where pauses don't matter |
| **G1** (default since Java 9) | `-XX:+UseG1GC` | heap split into equal **regions** (1–32MB); collects the regions with the most garbage first; pause-time target `-XX:MaxGCPauseMillis=200` | general-purpose services, heaps of 4–32GB |
| **ZGC** | `-XX:+UseZGC` (generational in 21+: `-XX:+ZGenerational`, default in 23) | concurrent mark *and* relocation via colored pointers and load barriers; pauses **< 1ms** regardless of heap size | latency-sensitive services, very large heaps |
| Shenandoah | `-XX:+UseShenandoahGC` | concurrent compaction with Brooks pointers/barriers | similar to ZGC (Red Hat builds) |
| CMS | removed in Java 14 | concurrent mark-sweep, no compaction → fragmentation | legacy |

**G1 cycle**: young GCs (STW, evacuate Eden and survivor regions) → when the heap occupancy passes the IHOP threshold, *concurrent marking* → *mixed GCs* that also evacuate old regions with the most garbage. A **Full GC** (a slow fallback) happens if evacuation fails because there's no free space ("to-space exhausted").

**Reading GC logs**: `-Xlog:gc*:file=gc.log:time,uptime,level,tags`. Watch pause times, frequency, heap after GC (it should return to a stable baseline), and promotion rates.

#### Real-world example
A payments API with a p99 SLO of 50ms had spikes of 300ms that correlated exactly with G1 mixed collections on a 16GB heap. The options considered: tuning `MaxGCPauseMillis` and IHOP, reducing allocation rate (object pooling for a hot JSON path, fewer temporary collections), or moving to ZGC on Java 21. The ZGC switch brought pauses under 1ms at the cost of about 5–10% throughput and slightly more CPU. That's a trade-off worth saying out loud in interviews.

#### Interview questions
?? How does the JVM decide an object is garbage?
**Reachability**, not reference counting. Starting from the GC roots (stack locals, static fields, JNI handles, live threads), the GC traces references. Anything not reached is garbage, which is how cycles get collected (unlike pure reference counting).

?? Explain G1 GC briefly.
G1 divides the heap into equal regions, each playing a role (Eden, survivor, old, humongous). Young collections evacuate live objects from young regions in short STW pauses. Concurrent marking finds the liveness of old regions, and mixed collections then evacuate the old regions with the **most garbage first** (hence "Garbage-First"), choosing how many regions fit within the pause-time goal. Compaction happens incrementally through evacuation.

?? Throughput vs latency collectors: how do you choose?
Batch or ETL jobs care about total time, so use Parallel GC. Typical web services balance both, so use G1. Strict tail-latency SLOs or very large heaps call for ZGC or Shenandoah, which need slightly more CPU and memory headroom. Always measure with GC logs under realistic load.

#### Tricky questions
?? Does `System.gc()` force a garbage collection?
It's only a *hint*. HotSpot usually performs a Full GC (expensive STW) unless `-XX:+DisableExplicitGC` is set. Libraries calling it (old RMI did, hourly) can cause mysterious pauses. Don't call it in application code.

?? Strong, soft, weak and phantom references?
Strong: never collected while reachable. **Soft**: collected only under memory pressure, so it suits memory-sensitive caches (somewhat unpredictable). **Weak**: collected at the next GC once only weakly reachable (`WeakHashMap` keys, ThreadLocalMap keys, canonicalising maps). **Phantom**: enqueued after the object is finalised, used for cleanup actions (`Cleaner`) instead of the deprecated `finalize()`.

?? Why can a memory leak exist in a garbage-collected language?
The GC frees only *unreachable* objects. If your code keeps references you no longer need (a growing static map, listeners never removed, ThreadLocals in pools, caches without eviction), those objects stay reachable forever. The GC can't know you don't need them.

#### Interview simulation
**Interviewer:** "p99 latency spikes every few minutes. How do you check whether GC is the cause?"

**Clarify:** "Which JVM version and GC? What heap size and container limit? Do the spikes correlate with traffic?"

**Answer:** Enable or collect the GC logs (or JFR) and line up pause timestamps with the latency spikes (Grafana: `jvm_gc_pause_seconds` from Micrometer). If they correlate, check pause type (young, mixed or full), heap occupancy after GC (a rising baseline means a leak), and allocation rate. Remedies in order: reduce allocation (profile with JFR or async-profiler), right-size the heap, tune G1 (pause goal, IHOP, region size), or move to ZGC for sub-millisecond pauses. If there's no correlation, look at other causes: downstream calls, lock contention, CPU throttling from container CPU limits (very common in Kubernetes).

### Memory leaks and OutOfMemoryError

#### Core idea
An **OutOfMemoryError (OOM)** means the JVM couldn't allocate memory in some area. The *message* tells you which area, and each has different causes. A **memory leak** in Java means objects that are no longer needed but still reachable.

#### How it works
| OOM message | Meaning | Typical causes |
|---|---|---|
| `Java heap space` | heap full after GC | leak (unbounded cache or collection), or genuinely too-large data (loading a whole table) |
| `GC overhead limit exceeded` | >98% of time in GC recovering <2% of heap | heap nearly full, often a leak |
| `Metaspace` | class metadata full | class loader leaks, runaway proxy/class generation |
| `Direct buffer memory` | off-heap NIO buffers exhausted | Netty or Kafka buffers not released, `MaxDirectMemorySize` too small |
| `unable to create native thread` | the OS won't give more threads | thread leak (new thread per task), ulimit, container memory |
| `Requested array size exceeds VM limit` | an array larger than the max | bug in size computation |

**Classic leak sources**
1. Static collections that only grow (`static Map<String, Session>`).
2. Caches without eviction or size limits (use Caffeine with `maximumSize` and `expireAfterWrite`).
3. Listeners/callbacks registered and never removed.
4. ThreadLocals in thread pools not removed.
5. Non-static inner classes or lambdas capturing large outer objects.
6. Unclosed resources (streams, connections), which hold native memory too.
7. Mutable `HashMap` keys (entries become unreachable but still referenced).
8. Collections of futures or tasks accumulating in unbounded executor queues.

**Diagnosis workflow**
1. Always run with `-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/dumps`.
2. Watch heap-after-GC over time. A sawtooth with a **rising floor** means a leak.
3. Take a heap dump (`jcmd <pid> GC.heap_dump file.hprof`) and open it in **Eclipse MAT**: the "Leak Suspects" report, the **dominator tree** (largest retained sizes), and "path to GC roots" (who's holding the memory).
4. Compare two histograms taken minutes apart (`jmap -histo:live`) to see which classes grow.

#### Real-world example
A notification service leaked memory because a `static Map<String, SseEmitter>` kept emitters for clients that had disconnected. The `onCompletion`/`onTimeout` callbacks that should have removed them were never registered. MAT's dominator tree showed the map retaining 3GB. The fix: register cleanup callbacks, and use a cache with expiry as a safety net.

#### Interview questions
?? How do you find a memory leak in a Java service?
Confirm it with GC metrics (a rising old-gen floor after GCs). Capture a heap dump (on OOM automatically, or with jcmd). Analyse it in MAT: dominator tree, then retained size, then the path to GC roots to find the reference chain keeping objects alive. Map that to code (often a static collection, cache or listener), fix it, and verify with a soak test.

?? What's the difference between shallow and retained heap?
Shallow: the memory of the object itself. Retained: everything that would be freed if this object were collected (the object plus everything reachable *only* through it). The retained size identifies leak roots.

#### Tricky questions
?? The heap is only 40% used but the app crashes with `OutOfMemoryError: unable to create native thread`. Why?
That's not a heap problem. The OS refused to create a thread: the process hit the thread limit (`ulimit -u`, the cgroup `pids.max`) or the native memory available for stacks. Typical cause: code creating `new Thread()` per request, or an unbounded `newCachedThreadPool`. Check the thread count in a dump or in metrics.

?? Can a heap dump be dangerous in production?
Yes. It pauses the JVM for the whole dump (seconds to minutes for large heaps), needs disk space equal to the heap, and **contains sensitive data** (passwords, tokens, personal data in memory). Take dumps from one pod removed from the load balancer, and handle the files as confidential.

#### Interview simulation
**Interviewer:** "Your service's memory slowly grows and it gets OOM-killed every ~3 days. Walk me through what you'd do."

**Clarify:** "Is it Java OOM in the logs or a container kill (exit 137)? Does heap usage after GC grow, or only total RSS? Did anything change recently?"

**Answer:** Split into two branches. **Heap leak** (rising post-GC heap): heap dumps 24h apart, MAT comparison, find the growing dominator, fix it. **Native leak** (RSS grows, heap flat): NMT to find which native area grows (threads, direct buffers, metaspace, or glibc arena fragmentation; mention `MALLOC_ARENA_MAX=2` for that last case). Short-term mitigation: rolling restarts plus alerts. Long-term: the fix plus a soak test in CI. Two structured branches with tools is what scores highly.

### JIT compilation

#### Core idea
The JVM starts by **interpreting** bytecode, then profiles which methods are hot and **compiles them to native machine code** at runtime (Just-In-Time). Because it has runtime profile data, the JIT can make optimisations that ahead-of-time compilers can't.

#### How it works
- **Tiered compilation** (the default): level 0 is the interpreter, levels 1–3 are **C1** (a fast compiler with light optimisation and profiling), and level 4 is **C2** (an aggressive optimising compiler using the profile data).
- **Key optimisations**:
  - **Inlining**: copy small or hot method bodies into the caller. It's the mother of all optimisations, because it enables everything else.
  - **Escape analysis**: remove allocations and locks for objects that don't escape.
  - **Loop unrolling, range-check elimination, dead code elimination, constant folding**.
  - **Speculative optimisations**: e.g. if only one implementation of an interface has been seen at a call site (monomorphic), devirtualise and inline it. If a new type shows up later, **deoptimise** back to the interpreter and recompile.
  - **Lock elision and coarsening**.
- **Code cache**: where compiled code lives (`-XX:ReservedCodeCacheSize`). If it's full, compilation stops and performance degrades badly (there's a warning in the logs).
- **Warm-up**: the first few thousand requests are slower until hot paths are compiled. Mitigations: warm-up traffic before receiving production load, CDS/AppCDS for faster startup, **GraalVM native image** (AOT: fast startup and low memory, but lower peak performance and reflection limits), and CRaC (checkpoint/restore).

#### Real-world example
After each deployment, p99 latency was high for about 2 minutes. That's JIT warm-up plus cold caches and connection pools. The fix: a readiness probe that passes only after a warm-up routine sends synthetic requests through the hot endpoints, plus a slow-start weight in the load balancer. Serverless Java functions (Lambda) suffer the most, which is why Lambda SnapStart and GraalVM native images exist.

#### Interview questions
?? Why can Java sometimes be as fast as C++?
The JIT optimises with **real runtime profiles**: it inlines across virtual calls that are monomorphic in practice, eliminates bounds checks, and allocates with TLABs (allocation is very cheap) plus escape analysis. A C++ compiler must be conservative about what it can't prove statically. The costs are warm-up time and memory for the compiler and profile data.

?? What is deoptimisation?
The JIT compiles code under speculative assumptions (e.g. "this call site only sees `ArrayList`"). If an assumption is violated (a `LinkedList` arrives), the compiled code is invalidated and execution falls back to the interpreter, which may later recompile with the new profile.

#### Tricky questions
?? Why are microbenchmarks with a simple loop and `System.nanoTime()` often wrong?
JIT effects: no warm-up (you measure interpreted code), dead-code elimination (the result is unused, so the work is removed), constant folding, and on-stack replacement artefacts. Use **JMH**, which handles warm-up, forks and blackholes.

#### Interview simulation
If asked "Why is the first request after deployment slow?", give layered causes: class loading and lazy Spring bean initialisation, JIT warm-up (interpreted code), cold caches (local and Redis), connection pools establishing TCP/TLS connections, and DNS. Fixes: eager init of critical beans, warm-up requests before readiness, pre-filled pools (`minimumIdle`), and CDS for startup.

### Profiling and troubleshooting tools

#### Core idea
When production misbehaves, you need evidence. The JDK ships with powerful tools: `jcmd`, `jstack`, `jmap`, `jstat`, **JFR (Java Flight Recorder)** with JDK Mission Control, plus third-party tools like **async-profiler**, VisualVM and Eclipse MAT.

#### How it works
| Problem | Tool | What to look at |
|---|---|---|
| Hanging / slow requests | `jstack <pid>` / `jcmd <pid> Thread.print` (3 dumps, 5s apart) | BLOCKED threads, deadlocks, threads stuck in I/O |
| High CPU | `top -H -p <pid>` → thread id → hex → find in jstack; **async-profiler** flame graph | hot methods, infinite loops, GC threads |
| Memory growth | `jstat -gcutil <pid> 1s`, heap dump + **MAT** | old gen after GC, dominator tree |
| GC pauses | GC logs (`-Xlog:gc*`), JFR GC events | pause time, frequency, cause |
| General profiling in prod | **JFR**: `jcmd <pid> JFR.start duration=60s filename=rec.jfr` | CPU samples, allocation, locks, I/O, GC; overhead about 1% |
| Lock contention | JFR "Java Monitor Blocked" events, async-profiler `-e lock` | which locks threads wait on |
| Native memory | `-XX:NativeMemoryTracking=summary` + `jcmd VM.native_memory` | threads, metaspace, code cache, direct buffers |
| Spring Boot | Actuator: `/actuator/metrics`, `/threaddump`, `/heapdump`, `/health` | quick checks; secure these endpoints! |

**Flame graphs**: the x-axis is the proportion of samples (not time order), the y-axis is stack depth. Wide plateaus at the top are where CPU is spent. Async-profiler avoids the safepoint bias of older profilers.

**Observability in production**: Micrometer → Prometheus → Grafana for JVM metrics (heap, GC pauses, threads, pool usage), distributed tracing for latency breakdowns, and continuous profiling (Pyroscope, Datadog) for always-on flame graphs.

#### Real-world example
CPU on a search pod was pinned at 100% after a release. `top -H` showed one thread at 99%; converting its ID to hex and finding it in `jstack` revealed a regex in an input sanitiser with **catastrophic backtracking** on a long query string. Async-profiler's flame graph confirmed `java.util.regex.Pattern$Loop.match` dominating. The fix: a possessive quantifier and an input length limit.

#### Interview questions
?? CPU is at 100% on one pod. How do you find the cause?
`top -H -p <pid>` to find the hottest thread IDs. Convert to hex (`printf '%x'`), take a `jstack`, and search for `nid=0x…` to see the stack. Repeat a few times to confirm. If the hot threads are GC threads, it's memory pressure, so check GC logs. For a fuller picture, run async-profiler for 30s and read the flame graph.

?? What is JFR and why is it good for production?
Java Flight Recorder is built into the JVM. It records low-overhead (about 1%) events: CPU samples, allocations, GC, locks, file and socket I/O, exceptions and thread states. You can start it on a running JVM with `jcmd` and analyse it in JDK Mission Control, which makes it safe to use in production, unlike attaching heavy profilers.

#### Tricky questions
?? Why might a heap dump show no leak while the container still runs out of memory?
The growth is off-heap: direct buffers, thread stacks, metaspace, code cache, or native allocations by libraries (or glibc malloc fragmentation). A heap dump only covers the heap. Use NMT and `pmap` for native memory.

#### Interview simulation
**Interviewer:** "Tell me about a production issue you debugged."

Use your resume's "resolved downstream integration issues through log analysis and root-cause investigation." Structure: **symptom** (errors and latency on the journey API) → **hypotheses** (our code, network, downstream) → **evidence** (correlated logs via trace ID, timestamps showing the downstream's TLS handshake timing out, thread dumps showing threads blocked on socket connect) → **root cause** (e.g. a downstream certificate rotation, or a connection pool without a connect timeout) → **fix** (timeouts, retries with idempotency, alerting) → **prevention** (dashboards, a runbook). Interviewers grade the method more than the bug.
