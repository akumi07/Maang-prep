## Operating systems | P2 | must

### Process vs thread and context switching

#### Core idea
- A **process** is a running program with its **own address space** (memory), file descriptors and resources. Processes are isolated from each other.
- A **thread** is a unit of execution **inside** a process. Threads share the process's memory and resources but each has its own **stack, registers and program counter**.
- A **context switch** is the OS saving the state of one thread or process and loading another's, so many can share the CPU cores.

#### How it works
| | Process | Thread |
|---|---|---|
| Memory | separate virtual address space | shared heap, code and globals; own stack |
| Creation cost | high (`fork` + copy-on-write page tables) | low |
| Communication | IPC (pipes, sockets, shared memory) | shared memory directly (needs synchronisation) |
| Crash impact | isolated | one thread's crash (e.g. a segfault) can kill the whole process |
| Context switch cost | higher (switch page tables, flush TLB unless PCID) | lower (same address space) |

**What a context switch involves**: save registers, PC and stack pointer into the PCB/TCB; the scheduler picks the next task; restore its registers; and for a process switch, change the page-table base register (CR3 on x86), so TLB entries become invalid and caches go cold. Direct cost is about 1–5 µs; the indirect cost from **cache and TLB pollution** is often larger.

**Triggers**: a timer interrupt (time slice expired), blocking I/O, a system call that waits, a higher-priority task becoming ready, or yielding.

**Kernel vs user threads**: Java platform threads are kernel threads (1:1). Green threads, goroutines and Java virtual threads are scheduled in user space (M:N), so they're cheaper to create and switch.

#### Real-world example
**Chrome** runs each tab or site in a separate **process**: one tab crashing or being compromised doesn't take down others (isolation plus security sandboxing), at the cost of memory. **Nginx** uses a few worker processes, each with an event loop. **PostgreSQL** forks a process per connection, which is why connection counts must stay low and why PgBouncer exists. **Java app servers** use threads (cheap shared memory, but a bug in one thread can corrupt shared state).

#### Interview questions
?? Process vs thread: when would you choose multiple processes over threads?
Processes when you need **isolation** (fault containment, security sandboxing, different privilege levels) or to sidestep a global interpreter lock (Python multiprocessing). Threads when tasks share lots of data and need cheap communication and creation. Many systems combine them: a few processes, each multi-threaded.

?? What happens during a context switch and why is it expensive?
The CPU state is saved and restored, and the kernel scheduler runs. A process switch also changes the address space. The hidden cost is cold CPU caches and TLB misses after the switch, plus pipeline flushes. Excessive switching (thousands of threads fighting for few cores) wastes CPU, which shows up as high `system` CPU and `cs` in `vmstat`.

?? What does a thread have of its own vs share?
Own: stack, registers, PC, thread-local storage, signal mask. Shared: heap, code, global/static data, open files, current working directory.

#### Tricky questions
?? What does `fork()` do and what is copy-on-write?
`fork` creates a child process that's a copy of the parent. Instead of copying all memory, the parent and child share the pages marked read-only; a page is copied only when either one writes to it (**copy-on-write**). Redis uses this for `BGSAVE` snapshots: it forks, the child writes the snapshot while the parent keeps serving, and memory grows only by the pages modified during the snapshot.

?? Why can creating 10,000 Java platform threads crash a server?
Each reserves stack memory (about 1MB virtual), kernel structures and scheduler overhead. You hit OS limits (`ulimit -u`, `pids.max` in containers) or memory limits, giving `OutOfMemoryError: unable to create native thread`, and switching overhead dominates. That's why we use pools, async I/O or virtual threads.

#### Interview simulation
**Interviewer:** "Explain process vs thread."

Answer with the table's top three rows (memory, cost, communication), then one real example (Chrome tabs as processes for isolation, or Postgres process-per-connection explaining connection pooling), then the trade-off. Interviewers stop asking once they hear real-world grounding.

### CPU scheduling

#### Core idea
The **scheduler** decides which ready thread runs on each CPU core and for how long. The goals conflict: **throughput**, **low latency/response time**, **fairness**, and **no starvation**.

#### How it works
**Classic algorithms**
| Algorithm | Idea | Pros | Cons |
|---|---|---|---|
| FCFS | first come, first served | simple | convoy effect (short jobs wait behind long ones) |
| SJF / SRTF | shortest (remaining) job first | optimal average waiting time | needs job lengths; starves long jobs |
| Priority | highest priority first | importance-aware | starvation, fixed with **aging** |
| Round Robin | each gets a time quantum in turn | fair, responsive | quantum too small means switch overhead; too large approaches FCFS |
| Multilevel feedback queue | several queues; tasks move down if they use their full quantum | favours interactive and I/O-bound tasks | complex tuning |

**Linux CFS (Completely Fair Scheduler)**, the default from 2.6.23 to 6.5: each task accumulates `vruntime` (CPU time weighted by nice value). The task with the **smallest vruntime** runs next, using a red-black tree for O(log n) selection. I/O-bound tasks that sleep a lot have low vruntime and get the CPU quickly, which makes them feel responsive. Linux 6.6+ replaced CFS with **EEVDF** (Earliest Eligible Virtual Deadline First), which keeps fairness and improves latency.

**Metrics**: turnaround time (completion − arrival), waiting time, response time (first run − arrival), throughput.

**Preemptive vs non-preemptive**: preemptive schedulers can interrupt a running task (timer interrupts); all modern general-purpose OSes are preemptive.

#### Real-world example
**Containers and CPU limits**: Kubernetes CPU limits use CFS **bandwidth control** (quota per 100ms period). A Java service with `limit: 1 CPU` but 20 busy threads (GC threads, JIT, request threads) can burn its quota in 20–30ms and then be **throttled** for the rest of the period, giving mysterious latency spikes of up to 70–80ms with low average CPU. Check `container_cpu_cfs_throttled_periods_total`. Many teams remove CPU limits (keeping requests) for latency-sensitive services.

#### Interview questions
?? Explain round robin and how the quantum affects performance.
Each ready process runs for at most one quantum, then goes to the back of the queue. A small quantum gives better responsiveness but more context-switch overhead; a large one gives less overhead but worse response time, approaching FCFS. Typical values are 1–100ms.

?? What is starvation and how is it prevented?
A low-priority task never runs because higher-priority tasks keep arriving. **Aging** gradually raises the priority of tasks that have waited long; fair schedulers like CFS avoid it by design.

#### Tricky questions
?? Why does SJF give the minimal average waiting time but is rarely used directly?
Running shorter jobs first reduces the total time that others spend waiting (an exchange argument proves it's optimal). But the OS doesn't know job lengths in advance; it can only estimate them from history (exponential averaging), and long jobs can starve.

#### Interview simulation
If asked about scheduling, give the classic algorithms briefly, then bridge to practice: "In production this shows up as CPU throttling in containers. I've seen p99 spikes caused by CFS quotas when a JVM had more busy threads than its CPU limit allowed." That shows you connect theory to real systems.

### Synchronization primitives: mutex, semaphore, monitor

#### Core idea
When threads share data, **race conditions** happen: the result depends on timing. The code that accesses shared data is a **critical section**, and synchronisation primitives ensure only safe interleavings happen.

#### How it works
- **Race condition example**: `counter++` is load → add → store; two threads interleave and one increment is lost.
- **Requirements for a critical-section solution**: mutual exclusion, progress (no unnecessary blocking), bounded waiting (no starvation).
- **Mutex (lock)**: binary, with **ownership**. Only the thread that locked it can unlock it. Used for mutual exclusion.
- **Semaphore**: an integer counter with atomic `wait/P` (decrement, block if < 0) and `signal/V` (increment, wake a waiter). **Counting** semaphores limit concurrent access to N resources; binary semaphores are used for signalling. There's no ownership.
- **Monitor**: a language construct combining a mutex with **condition variables** (wait/signal) around an object's methods. Java's `synchronized` + `wait/notify` is a monitor.
- **Spinlock**: busy-waits in a loop instead of sleeping. Good only for very short critical sections on multi-core machines (no context switch); terrible if the holder is descheduled.
- **Read-write lock**: many readers or one writer.
- **Hardware support**: atomic instructions (test-and-set, compare-and-swap, fetch-and-add) and memory barriers. All the above are built on them.
- **Futex** (Linux): a fast userspace mutex. Uncontended locking is a single atomic op in user space; it enters the kernel only to sleep or wake when contended.

**Classic problems**: producer-consumer (bounded buffer: 2 counting semaphores + 1 mutex), readers-writers (writer starvation), dining philosophers (deadlock).

```text
// Producer-consumer with semaphores
empty = N, full = 0, mutex = 1
producer: wait(empty); wait(mutex); put(item); signal(mutex); signal(full)
consumer: wait(full);  wait(mutex); take();    signal(mutex); signal(empty)
// Swapping wait(empty) and wait(mutex) in the producer can deadlock: holding mutex while waiting for space.
```

#### Real-world example
A **database connection pool** is conceptually a counting semaphore (N permits = N connections). **Rate limiting concurrent calls** to a partner API uses a semaphore. The Linux kernel uses spinlocks for very short sections in interrupt contexts where sleeping is impossible.

#### Interview questions
?? Mutex vs semaphore?
A mutex provides mutual exclusion with ownership (the locker must unlock) and is usually binary. A semaphore is a counter for signalling or limiting access to N resources, with no ownership (any thread can signal). A binary semaphore can emulate a mutex but lacks ownership semantics (and priority-inheritance support).

?? Spinlock vs mutex: when is spinning better?
Spinning avoids context-switch cost, so it's better when the expected wait is shorter than two context switches **and** the lock holder is running on another core. On a single core, or for long waits, spinning wastes CPU. Adaptive mutexes spin briefly, then sleep (Java's synchronized and futex-based locks do this).

#### Tricky questions
?? What is priority inversion?
A high-priority task waits for a lock held by a low-priority task, which is preempted by a medium-priority task, so the high-priority task effectively waits for the medium one. The famous case is the **Mars Pathfinder** resets (1997). The fix is **priority inheritance**: the lock holder temporarily inherits the waiter's priority.

?? Is `volatile` a synchronisation primitive?
It gives visibility and ordering, not mutual exclusion. It's enough for a single-writer flag; not enough for compound updates.

#### Interview simulation
**Interviewer:** "Solve producer-consumer."

**Clarify:** "Is the buffer bounded? How many producers and consumers? Which language: pseudocode, or Java?" Give the semaphore version (above) and explain each semaphore's role, point out the deadlock if you swap the order, then mention the Java `BlockingQueue` equivalent. Covering both theory and practice is ideal.

### Deadlocks: conditions, prevention, avoidance, detection

#### Core idea
A **deadlock** is a set of processes each waiting for a resource held by another in the set, so none can proceed. It requires all four **Coffman conditions**: mutual exclusion, hold-and-wait, no preemption, circular wait.

#### How it works
Four strategies:
1. **Prevention**: structurally break a condition.
   - Hold-and-wait: request all resources at once (poor utilisation).
   - No preemption: if a request fails, release what you hold (tryLock + backoff).
   - **Circular wait: impose a global ordering on resources and always acquire in that order** (the most practical).
2. **Avoidance**: grant requests only if the system stays in a **safe state**. **Banker's algorithm**: each process declares its maximum need; before allocating, simulate whether there's an order in which every process can finish. It's rarely used in general OSes (max needs are unknown, and it costs O(m·n²)), but it's classic interview material.
3. **Detection and recovery**: allow deadlocks, detect cycles in a **wait-for graph**, then recover by aborting a victim or preempting resources. **Databases do this** (Postgres checks after `deadlock_timeout`, 1s by default, and aborts one transaction).
4. **Ignore** (the ostrich algorithm): most OSes for application-level locks. Restart if needed.

**Banker's example**: total resources 10; P1 holds 5 (max 7), P2 holds 2 (max 4), P3 holds 2 (max 9); available 1. P2 needs 2 more, but only 1 is available. P1 needs 2, P3 needs 7: nobody can finish, so this is an **unsafe** state, and a request leading here would be denied.

**Resource allocation graph**: with single-instance resources, a cycle means deadlock. With multi-instance resources, a cycle is necessary but not sufficient.

#### Real-world example
Database deadlocks in transfers (A→B and B→A updating rows in opposite order). Postgres logs `ERROR: deadlock detected … Process 123 waits for ShareLock on transaction 456; blocked by process 789`. The application fix is consistent lock ordering (`ORDER BY id … FOR UPDATE`) plus retrying the aborted transaction.

#### Interview questions
?? What are the four necessary conditions for deadlock?
Mutual exclusion (resources can't be shared), hold and wait (holding some while waiting for others), no preemption (resources can't be forcibly taken), circular wait (a cycle of waiting processes). Break any one and deadlock can't happen.

?? Deadlock prevention vs avoidance?
Prevention designs the system so a condition can never hold (e.g. lock ordering): static and simple. Avoidance decides dynamically, per request, whether granting it could lead to deadlock (Banker's): it needs advance knowledge of max needs and costs runtime checks.

#### Tricky questions
?? Can a deadlock occur with just one process?
With non-reentrant locks, yes: a process trying to re-acquire a lock it already holds waits for itself. Or a single-threaded process waiting on a pipe it's supposed to write to.

?? Deadlock vs starvation vs livelock?
Deadlock: everyone blocked forever in a cycle. Starvation: some process waits indefinitely while others progress. Livelock: processes are active (not blocked) but keep reacting to each other without progress.

#### Interview simulation
If asked "How do databases handle deadlocks?", explain wait-for graph detection, victim selection (usually the cheapest transaction to roll back), error codes (Postgres 40P01, MySQL 1213), and the application's role: retry with backoff, acquire locks in a consistent order, keep transactions short. Theory plus practice.

### Memory management: paging, virtual memory, TLB

#### Core idea
**Virtual memory** gives each process the illusion of a large, private, contiguous address space. The OS and hardware (the **MMU**) translate virtual addresses into physical addresses using **page tables**, with fixed-size **pages** (typically 4KB) mapped to physical **frames**. Pages not in RAM can live on disk.

#### How it works
- **Address translation**: virtual address = (page number, offset). The page table maps the page number to a frame number; physical address = frame × page size + offset.
- **Multi-level page tables** (4 levels on x86-64, 5 with LA57) avoid allocating huge tables for sparse address spaces.
- **TLB (Translation Lookaside Buffer)**: a small, fast cache of recent translations inside the CPU. A TLB hit means translation in about 1 cycle; a miss means a **page walk** (several memory accesses). A context switch to another process invalidates the entries (unless tagged with PCID/ASID).
- **Huge pages** (2MB/1GB) cover more memory per TLB entry, so there are fewer misses. Databases and JVMs with large heaps benefit (`-XX:+UseLargePages`). But **Transparent Huge Pages** can cause latency spikes for Redis or MongoDB, which recommend disabling THP.
- **Page fault**: accessing a page that isn't present. *Minor*: the page is in memory but not mapped (e.g. first touch, copy-on-write). *Major*: it must be read from disk (swap or a memory-mapped file), which is slow (ms).
- **Demand paging**: pages are loaded only when touched. **Swap**: evicting pages to disk under memory pressure. **Thrashing**: the working set exceeds RAM, so the system spends its time paging and throughput collapses.
- **Segmentation**: variable-size logical segments (code, data, stack); historically used by x86, now mostly flat.
- **Fragmentation**: internal (wasted space inside allocated pages/blocks) vs external (free memory split into unusable holes; paging eliminates this for physical memory).
- Benefits: isolation and protection (read/write/execute bits per page), sharing (shared libraries mapped into many processes), memory-mapped files (`mmap`), and copy-on-write.

#### Real-world example
**Kafka** relies on the OS **page cache**: it writes to files and lets the OS cache them, and consumers reading recent data are served from RAM. That's why Kafka brokers want lots of free memory beyond the JVM heap. **Elasticsearch** recommends giving no more than 50% of RAM to the heap, leaving the rest for the page cache (Lucene files are memory-mapped). Production DB servers disable swap or set `vm.swappiness` low, because swapping a database is catastrophic for latency.

#### Interview questions
?? What is virtual memory and why do we need it?
An abstraction where each process sees its own address space, translated to physical memory by the MMU via page tables. It gives isolation and protection between processes, lets programs use more memory than RAM (paging to disk), simplifies loading and linking (every process sees the same layout), and enables sharing, copy-on-write and memory-mapped files.

?? What is a TLB, and what happens on a TLB miss?
A cache of virtual-to-physical page translations in the CPU. On a miss, the hardware (on x86) walks the multi-level page table in memory to find the mapping and caches it. If the page isn't present, a page fault traps to the OS.

?? What is thrashing and how do you fix it?
When the total working sets of running processes exceed physical memory, pages are constantly evicted and faulted back in, and the CPU sits idle waiting for disk. Fix: reduce the degree of multiprogramming (fewer processes or containers per node), add RAM, fix memory-hungry processes, or use working-set-based admission control.

#### Tricky questions
?? Two processes print the same pointer address for a variable. Do they share memory?
No. Virtual addresses are per process: the same virtual address maps to different physical frames in each (unless explicitly shared memory or a COW page before modification).

?? Why does a Java process's RSS sometimes stay high after the heap shrinks?
The JVM may not return freed heap memory to the OS (it depends on the GC and flags like `-XX:+UseStringDeduplication`/`ShrinkHeapInSteps`; G1 uncommits periodically with `G1PeriodicGCInterval`). And glibc malloc arenas may keep native memory. RSS reflects pages touched, not current live objects.

#### Interview simulation
If asked "What happens when a program accesses memory?": CPU issues virtual address → TLB lookup → (miss: page table walk) → present? → physical address → L1/L2/L3 cache → RAM. If not present: page fault → OS finds the page (disk or zero-fill) → maps it → restarts the instruction. A step-by-step chain like this is what interviewers look for.

### Page replacement algorithms

#### Core idea
When memory is full and a new page must be loaded, the OS must **evict** a page. Page replacement algorithms choose which one, trying to minimise future page faults. The same ideas power **cache eviction** in Redis, CDNs and in-process caches.

#### How it works
| Algorithm | Evicts | Notes |
|---|---|---|
| **Optimal (Belady's)** | the page used **farthest in the future** | not implementable (needs the future); the benchmark |
| **FIFO** | the oldest loaded page | simple; suffers **Belady's anomaly** (more frames can mean *more* faults) |
| **LRU** | the least recently used page | good approximation of optimal; exact LRU is expensive in hardware |
| **Clock (second chance)** | circular scan using a reference bit: if the bit is 1, clear it and move on; if 0, evict | practical LRU approximation used by real OSes |
| **LFU** | the least frequently used page | adapts poorly when popularity changes, unless counts decay |
| **ARC / 2Q / LRU-K** | balance recency and frequency | resist scans (a one-off sequential read doesn't flush hot data) |

**Worked example** (3 frames, reference string 7 0 1 2 0 3 0 4 2 3 0 3 2):
- FIFO: 10 faults. LRU: 9 faults. Optimal: 7 faults. *(Practise computing these by hand; interviewers ask.)*

Linux uses **active/inactive LRU lists** (a two-list clock variant) and, since 6.1, **MGLRU** (multi-generational LRU).

**Cache-world equivalents**: Redis `maxmemory-policy` (`allkeys-lru`, `allkeys-lfu`, `volatile-ttl`… using *approximated* LRU by sampling keys); Caffeine uses **W-TinyLFU** (a frequency sketch with an admission window), with near-optimal hit rates.

#### Real-world example
A nightly batch job doing a full table scan evicted the "hot" pages from a database's buffer pool, so the morning traffic had cold-cache latency. Scan-resistant policies (Postgres uses a ring buffer for large sequential scans; MySQL's LRU midpoint insertion) exist precisely for this. The same issue hits application caches when a crawler hits millions of unique URLs and a plain LRU cache evicts the popular items. That's why Caffeine's TinyLFU admission helps.

#### Interview questions
?? Why is LRU a good policy, and why isn't it implemented exactly in OSes?
Programs exhibit **temporal locality**: recently used pages are likely to be used again, so LRU approximates optimal well. Exact LRU needs updating an ordering on *every* memory access, which is too expensive in hardware, so OSes use approximations like Clock with reference bits set by the MMU.

?? What is Belady's anomaly?
For FIFO, increasing the number of frames can *increase* page faults for some reference strings (e.g. 1 2 3 4 1 2 5 1 2 3 4 5: 9 faults with 3 frames, 10 with 4). Stack algorithms like LRU and Optimal don't suffer from it.

#### Tricky questions
?? When is LFU better than LRU?
When popularity is stable over time and there are periodic scans of rarely used items: LFU keeps truly popular items. Plain LFU is slow to adapt when popularity shifts (old counts dominate), which is why practical LFU variants use decaying counters (Redis LFU decays its counters over time).

#### Interview simulation
If asked "Design a cache eviction policy for product pages": discuss the access pattern (a Zipf-like distribution, so a few very hot items), the risk of scans (bots), and choose W-TinyLFU (Caffeine) or Redis `allkeys-lfu`. Add TTLs for freshness, and measure hit ratio as the deciding metric. Linking OS theory to the cache you used in production (Redis soft-TTL at 1mg) is the strongest answer.

### IPC, system calls and user vs kernel mode

#### Core idea
- **User mode vs kernel mode**: the CPU runs applications in a restricted **user mode**; only the kernel (in **kernel mode**) can touch hardware, page tables and other processes' memory.
- **System calls** are the controlled gateway: an app asks the kernel to do privileged work (`read`, `write`, `open`, `fork`, `mmap`, `socket`).
- **IPC (Inter-Process Communication)** lets isolated processes exchange data.

#### How it works
**System call path**: the library wrapper (glibc `read()`) puts the syscall number and arguments in registers → the `syscall` instruction traps into kernel mode → the kernel validates the arguments and does the work → it returns to user mode with the result. Cost: about 100ns–1µs, plus side effects (cache and TLB disturbance; more with Meltdown/Spectre mitigations). That's why batching I/O (buffered streams, `writev`, larger reads) matters.

**IPC mechanisms**
| Mechanism | Description | Use |
|---|---|---|
| Pipes (anonymous) | a one-way byte stream between related processes | shell `ls | grep` |
| Named pipes (FIFO) | a pipe with a filesystem name | unrelated local processes |
| Message queues | kernel-managed message lists | discrete messages |
| **Shared memory** | the same physical pages mapped into several processes | **fastest** (no copying); needs synchronisation |
| Semaphores | synchronisation across processes | with shared memory |
| **Sockets** | Unix domain (local) or TCP/UDP (network) | the most general; how microservices talk |
| Signals | asynchronous notifications (`SIGTERM`, `SIGKILL`, `SIGHUP`) | process control |
| Memory-mapped files | `mmap` a file into several processes | shared data, DB files |

**Signals in practice**: Kubernetes sends **SIGTERM** on pod shutdown, waits `terminationGracePeriodSeconds` (30s by default), then sends **SIGKILL** (which can't be caught). Spring Boot's graceful shutdown (`server.shutdown=graceful`) handles SIGTERM: it stops accepting requests and finishes in-flight ones.

**Zero-copy**: `sendfile()` transfers file data straight from the page cache to a socket inside the kernel, with no copying into user space. **Kafka** uses it to serve consumers efficiently; Nginx uses it for static files.

#### Real-world example
Docker containers talk to the Docker daemon over a **Unix domain socket** (`/var/run/docker.sock`); mounting it into a container effectively grants root on the host (a classic security pitfall). Postgres clients on the same host can connect via a Unix socket, which is faster than TCP localhost.

#### Interview questions
?? What is a system call and why is it relatively expensive?
A request from a user program to the kernel for privileged operations. It requires a mode switch (a trap), saving and restoring state, argument validation, and sometimes TLB or cache effects. It's not as expensive as a context switch, but noticeable in tight loops, which is why buffering and batching are used.

?? Which IPC is fastest, and why?
Shared memory: once mapped, processes read and write the same physical memory with no kernel involvement or copying. The cost is that you must handle synchronisation yourself (semaphores, futexes, lock-free structures).

#### Tricky questions
?? Why might a Java app not shut down gracefully in Kubernetes?
The JVM may not be PID 1 handling signals properly (a shell entrypoint `sh -c "java …"` doesn't forward SIGTERM: use the exec form `ENTRYPOINT ["java", …]`, or `exec java`); graceful shutdown isn't enabled; or shutdown takes longer than the grace period, so SIGKILL arrives. Also add a `preStop` sleep so the endpoint is removed from the load balancer before shutdown begins.

#### Interview simulation
If asked "What happens when a pod is terminated?": the API server marks the pod Terminating → the endpoints controller removes it from Services (asynchronously) → the preStop hook runs → SIGTERM goes to PID 1 → the app stops accepting connections and drains in-flight requests → after the grace period, SIGKILL. Then mention the race between endpoint removal and SIGTERM, and the preStop sleep fix. This links OS signals to real deployments.

### I/O models: blocking, non-blocking, epoll and event loops

#### Core idea
How a program waits for I/O decides how many concurrent connections it can handle:
- **Blocking I/O**: the thread sleeps until data arrives. Simple, but one thread per connection.
- **Non-blocking I/O + readiness notification** (`select`/`poll`/**`epoll`**/`kqueue`): one thread watches thousands of sockets and handles whichever are ready, in an **event loop**.
- **Asynchronous I/O** (`io_uring`, Windows IOCP): submit operations and get completion events.

#### How it works
**The C10K problem** (handling 10,000+ concurrent connections): thread-per-connection costs memory and switching; event-driven designs solved it.

- `select`/`poll`: you pass the whole set of file descriptors on every call, and the kernel scans them all, so it's **O(n)** per call (select is also limited to 1024 fds).
- **`epoll`** (Linux): register fds once (`epoll_ctl`); `epoll_wait` returns **only the ready ones**, so it's O(ready). Supports level-triggered and edge-triggered modes.
- **Event loop**: `while (true) { events = epoll_wait(); for e in events: handle(e) }`. Handlers must **never block**; a slow handler stalls every connection on that loop.
- **Reactor pattern**: one or more event-loop threads dispatch readiness events to handlers (Netty: a boss group accepts connections, worker groups handle I/O; Node.js: a single loop plus libuv's thread pool for blocking work like file I/O and DNS).
- **Java**: classic `java.io` is blocking; **NIO** (`Selector`, `SocketChannel`) is non-blocking and uses epoll on Linux. Netty builds on NIO; Spring WebFlux and the Reactor Netty server use it. **Virtual threads** give a blocking programming style with an event-loop-like footprint (the JVM parks the virtual thread and uses epoll underneath).

| Model | Threads | Programming | Examples |
|---|---|---|---|
| Thread-per-request, blocking | many | simple | Tomcat (classic), Spring MVC |
| Event loop, non-blocking | few | callbacks/reactive | Node.js, Nginx, Netty, Redis |
| Virtual threads | millions (cheap) | simple blocking style | Java 21+ Loom |

#### Real-world example
**Redis** handles 100k+ ops per second on a **single thread** (an event loop over epoll): every command is in-memory and fast, so no thread ever waits. That's also why one slow command (`KEYS *`, a huge `LRANGE`, a Lua script) **blocks everyone**: the event loop rule in action. **Nginx** serves tens of thousands of connections per worker with an event loop. Your OnTheMove **Socket.io** real-time updates ran on Node's event loop.

#### Interview questions
?? Why can Node.js handle many connections with one thread?
Its event loop uses non-blocking I/O via epoll/kqueue (through libuv). The thread never waits on network I/O; it registers interest and processes completions as they arrive. It's great for I/O-bound work, but CPU-heavy work blocks the loop for everyone (offload it to worker threads).

?? What's the difference between select/poll and epoll?
select/poll require passing and scanning the entire fd set on every call: O(n) work even if only one fd is ready, and select is capped at 1024 fds. epoll keeps the interest list in the kernel and returns only ready fds, which scales to hundreds of thousands of connections.

#### Tricky questions
?? You run a blocking JDBC call inside a WebFlux handler. What happens?
It blocks a Netty event-loop thread (there are only about `cores` of them). All connections served by that loop stall, and throughput collapses under load. Use R2DBC (reactive drivers), or offload with `Mono.fromCallable(...).subscribeOn(Schedulers.boundedElastic())`, or use Spring MVC with virtual threads instead.

?? Edge-triggered vs level-triggered epoll?
Level-triggered: `epoll_wait` keeps reporting the fd while data remains. Edge-triggered: it's reported only when the state changes (new data arrives), so you must read until `EAGAIN`, or you'll never be notified about the leftover data. ET is more efficient but easier to get wrong.

#### Interview simulation
If asked "Spring MVC or WebFlux for a new service?": explain the thread-per-request vs event-loop models. WebFlux pays off with very high concurrency, streaming and backpressure, but needs end-to-end non-blocking drivers and is harder to debug. On Java 21, MVC with virtual threads covers most high-concurrency I/O cases with simpler code. Choose based on the team's skills, the libraries' support (blocking JDBC, for instance), and measured requirements.
