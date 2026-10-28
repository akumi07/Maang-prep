## Containers & orchestration | P4

### Docker: images, layers and multi-stage builds

#### Core idea
**Docker** packages an application with its runtime and dependencies into an **image**: an immutable, layered filesystem plus metadata. A **container** is a running instance of an image, isolated by Linux **namespaces** (process, network and mount views) and limited by **cgroups** (CPU and memory). Containers share the host kernel, so they're much lighter than VMs.

#### How it works
- **Layers**: each Dockerfile instruction (`FROM`, `COPY`, `RUN`) creates a layer, cached and reused across builds and images. Order instructions from least to most frequently changing so the cache hits.
- **Multi-stage builds**: build in a heavy image (JDK + Maven), copy only the artifact into a slim runtime image (JRE or distroless). Smaller images, fewer vulnerabilities.

```dockerfile
# ---- build stage ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline            # cached unless pom changes
COPY src ./src
RUN mvn -q package -DskipTests && java -Djarmode=layertools -jar target/app.jar extract

# ---- runtime stage ----
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=build /app/dependencies/ ./      # Spring Boot layered jar: deps change rarely
COPY --from=build /app/spring-boot-loader/ ./
COPY --from=build /app/snapshot-dependencies/ ./
COPY --from=build /app/application/ ./       # your code changes often → last layer
USER app
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
```
- **Best practices**: a minimal base image, a non-root user, `.dockerignore`, pinned versions, no secrets in images (they persist in layers!), one process per container, the exec form of `ENTRYPOINT` (so signals reach the JVM), health checks handled by the orchestrator, and image scanning (Trivy, ECR scanning).
- **Container-aware JVM**: Java 10+ reads cgroup limits. Use `-XX:MaxRAMPercentage` rather than a fixed `-Xmx`.

#### Real-world example
NeuronixAI's "Dockerized services on AWS ECS/Fargate": images built in CI, pushed to **ECR**, deployed as ECS task definitions. A typical improvement story: a 700MB image (JDK base, fat jar copied in one layer) reduced to ~200MB with a multi-stage JRE-alpine build and Spring Boot layered jars, making pushes and pulls faster and deploys quicker, with fewer CVEs.

#### Interview questions
?? Container vs virtual machine?
A VM virtualises hardware and runs a full guest OS (heavy: GBs, boots in minutes, strong isolation). A container virtualises the OS: processes isolated with namespaces and cgroups that share the host kernel (light: MBs, starts in seconds). Containers are less isolated (a shared kernel), so security hardening matters.

?? Why use multi-stage builds?
To keep build tools out of the runtime image. The result is smaller images (faster pulls, less storage), a smaller attack surface, and a clean separation of build and runtime concerns, all in one Dockerfile.

#### Tricky questions
?? You put a secret in a `RUN` step and deleted it in the next step. Is it gone?
No. Each layer is stored separately, so the secret is still in the earlier layer and recoverable with `docker history` or by extracting layers. Use build secrets (`RUN --mount=type=secret`) or inject secrets at runtime.

?? Why does `ENTRYPOINT java -jar app.jar` (shell form) cause slow shutdowns?
The shell form runs `/bin/sh -c`, so the shell is PID 1 and doesn't forward SIGTERM to Java. The app never shuts down gracefully and gets SIGKILLed after the grace period. Use the exec form, or `exec` inside a shell script.

#### Interview simulation
If asked "How do you containerise a Spring Boot app?", go through: a multi-stage build, a layered jar for cache efficiency, a JRE or distroless base, non-root, `MaxRAMPercentage`, the exec-form entrypoint for graceful shutdown, health endpoints for the orchestrator, image scanning in CI. Then mention your ECS deployment.

### Kubernetes core: pods, deployments, services and ingress

#### Core idea
**Kubernetes (K8s)** orchestrates containers across a cluster: it schedules them onto nodes, keeps the desired number running, connects them via service discovery, and rolls out updates. You declare the **desired state** in YAML; **controllers** continuously reconcile the actual state towards it.

#### How it works
**Architecture**: the **control plane** (API server, etcd, scheduler, controller manager) plus **worker nodes** (kubelet, container runtime, kube-proxy).

**Core objects**
| Object | Purpose |
|---|---|
| **Pod** | smallest unit: one or more containers sharing network and storage (sidecars) |
| **Deployment** | manages ReplicaSets for stateless apps: replicas, rolling updates, rollbacks |
| **StatefulSet** | stable identities and storage for stateful apps (Kafka, DBs): `pod-0`, `pod-1` |
| **DaemonSet** | one pod per node (log agents, monitoring) |
| **Job / CronJob** | run-to-completion and scheduled tasks |
| **Service** | a stable virtual IP and DNS name load-balancing to matching pods (ClusterIP, NodePort, LoadBalancer) |
| **Ingress / Gateway API** | L7 HTTP routing from outside (host and path rules, TLS) via an ingress controller (Nginx, ALB controller) |
| **Namespace** | logical isolation and quotas |

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: orders }
spec:
  replicas: 3
  selector: { matchLabels: { app: orders } }
  strategy: { rollingUpdate: { maxSurge: 1, maxUnavailable: 0 } }
  template:
    metadata: { labels: { app: orders } }
    spec:
      containers:
      - name: orders
        image: 1234.dkr.ecr.ap-south-1.amazonaws.com/orders:1.4.2
        ports: [{ containerPort: 8080 }]
        resources:
          requests: { cpu: "500m", memory: "1Gi" }
          limits:   { memory: "1Gi" }
        readinessProbe: { httpGet: { path: /actuator/health/readiness, port: 8080 }, periodSeconds: 5 }
        livenessProbe:  { httpGet: { path: /actuator/health/liveness,  port: 8080 }, initialDelaySeconds: 30 }
---
apiVersion: v1
kind: Service
metadata: { name: orders }
spec: { selector: { app: orders }, ports: [{ port: 80, targetPort: 8080 }] }
```
- **Requests** are used for scheduling (guaranteed capacity); **limits** are the caps. Exceeding the memory limit gets you OOMKilled; exceeding the CPU limit gets you throttled.
- **Scheduling**: the scheduler places pods by requests, affinity and anti-affinity (spread replicas across zones), taints and tolerations.

#### Real-world example
A typical EKS setup for a Spring Boot microservice: a Deployment with 3+ replicas spread across AZs (topology spread constraints), a Service for in-cluster discovery (`http://orders`), an Ingress via the AWS Load Balancer Controller creating an ALB, an HPA on CPU or RPS, ConfigMaps and Secrets for config, and a PodDisruptionBudget so node upgrades never take down more than one replica.

#### Interview questions
?? What happens when you `kubectl apply` a Deployment?
The API server validates it and stores it in etcd. The Deployment controller creates or updates a ReplicaSet. The ReplicaSet controller creates Pod objects. The scheduler assigns each pod to a node. The kubelet on that node pulls the image and starts the containers. Readiness probes then gate when the pods join Service endpoints. Controllers keep reconciling (recreating crashed pods).

?? Requests vs limits: why set memory limit = request?
Setting them equal gives predictable memory (Guaranteed QoS for memory) and avoids pods being OOMKilled by node pressure due to overcommit. For CPU, many teams set requests but no limits, avoiding CFS throttling latency spikes while still scheduling fairly.

#### Tricky questions
?? Your pod restarts every few minutes with exit code 137. What's going on?
137 means SIGKILL, typically **OOMKilled** (check `kubectl describe pod`: "Last State: OOMKilled"), from exceeding the memory limit (heap plus native memory). Or a failing liveness probe kills it (the events show probe failures). Fix the JVM sizing (`MaxRAMPercentage`), raise the limit, or fix the probe (initial delay too short during JVM startup).

#### Interview simulation
If asked "How is your service deployed?", walk through the image → Deployment (replicas, probes, resources) → Service → Ingress or ALB → HPA → config and secrets → rolling update strategy. If your actual experience is ECS (NeuronixAI), say so and map the concepts: task definition ≈ pod spec, service ≈ Deployment plus Service, ALB target group ≈ Ingress backend.

### Kubernetes config, secrets and health probes

#### Core idea
Kubernetes separates **configuration** (ConfigMaps), **sensitive data** (Secrets) and **health signalling** (liveness, readiness and startup probes) from the container image, so the same image runs everywhere and the platform knows when to restart or route traffic to a pod.

#### How it works
**ConfigMaps and Secrets**
- Injected as environment variables or mounted as files (mounted files update without a restart; env vars don't).
- Secrets are only **base64-encoded**, not encrypted by default. Enable etcd encryption at rest, restrict RBAC, and prefer external secret managers (**External Secrets Operator** syncing from AWS Secrets Manager or Vault; the CSI Secrets Store driver).
- Spring Boot reads mounted files via `spring.config.import=optional:configtree:/etc/config/`.

**Probes**
| Probe | Question | On failure |
|---|---|---|
| **startupProbe** | has the app finished starting? | keep waiting (other probes paused) until the threshold, then restart |
| **livenessProbe** | is the process healthy or stuck? | **restart** the container |
| **readinessProbe** | can it serve traffic right now? | **remove from Service endpoints** (no restart) |

- Spring Boot Actuator exposes `/actuator/health/liveness` and `/readiness` (availability state).
- **Don't check dependencies in liveness**: if the DB is down, restarting every pod won't help and causes restart storms. Readiness can reflect "I can't serve" (careful: if all pods go unready at once, everything goes down; often it's better to stay ready and serve errors or degraded responses).
- A startup probe for slow-starting JVMs prevents liveness from killing pods during startup.

**Graceful shutdown**: on pod termination → removal from endpoints (asynchronous) → `preStop` hook (e.g. sleep 5–10s so load balancers stop sending traffic) → SIGTERM → Spring `server.shutdown=graceful` drains in-flight requests → SIGKILL after `terminationGracePeriodSeconds`.

#### Real-world example
A team added a DB check to the liveness probe. During a 2-minute RDS failover, every pod failed liveness and restarted repeatedly, so when the DB came back, all pods were cold-starting at once (JIT warm-up, empty caches) and the outage lasted 15 minutes instead of 2. Moving the dependency check out of liveness fixed it.

#### Interview questions
?? Liveness vs readiness probe?
Liveness answers "should this container be restarted?" (a deadlock or a stuck process). Readiness answers "should this pod receive traffic now?" (warming up, temporarily overloaded, shutting down). A failed readiness check removes the pod from load balancing without restarting it.

?? How do you avoid dropped requests during rolling deployments?
Readiness probes so new pods get traffic only when ready; `maxUnavailable: 0` with surge; a preStop sleep so old pods leave the endpoints before shutting down; graceful shutdown that drains in-flight requests; a long enough termination grace period; and connection draining or deregistration delay on the load balancer.

#### Tricky questions
?? Is it safe to store database passwords in Kubernetes Secrets?
Only with care: they're base64, not encrypted, unless etcd encryption is enabled; anyone with read access to Secrets in the namespace (or able to exec into pods) can see them. Use RBAC least privilege, encryption at rest, and preferably an external secret manager with rotation.

#### Interview simulation
If the interviewer asks about zero-downtime deploys, give the full chain: readiness probe → rolling update with maxUnavailable 0 → preStop sleep → SIGTERM → graceful drain → grace period, plus backward-compatible DB migrations (expand/contract). That completeness distinguishes production experience.

### Autoscaling and deployment strategies

#### Core idea
- **Autoscaling** adjusts capacity to load: more pods (horizontal), bigger pods (vertical), more nodes (cluster).
- **Deployment strategies** control how new versions replace old ones while limiting risk: rolling, blue-green, canary.

#### How it works
**Autoscaling**
| Autoscaler | Scales | Signal |
|---|---|---|
| **HPA** (Horizontal Pod Autoscaler) | pod replicas | CPU/memory utilisation vs requests, or custom metrics (RPS, latency, queue depth via Prometheus adapter) |
| **KEDA** | pod replicas (including to zero) | event sources: Kafka lag, SQS depth, cron |
| **VPA** | pod requests and limits | historical usage (usually in recommendation mode) |
| **Cluster Autoscaler / Karpenter** | nodes | pending pods that can't be scheduled |

- HPA formula: `desired = ceil(current × currentMetric / target)`. Stabilisation windows prevent flapping.
- Scaling lag: metrics delay + pod scheduling + image pull + JVM startup and warm-up = 1–3+ minutes. For predictable spikes (sales, match start), **pre-scale** on a schedule.
- Scale on the metric that represents load: CPU for compute-bound services, **consumer lag** for Kafka workers, RPS or concurrency for I/O-bound APIs.

**Deployment strategies**
| Strategy | How | Pros | Cons |
|---|---|---|---|
| **Rolling** | replace pods gradually | simple, the K8s default | both versions run during the rollout; rollback is another rollout |
| **Blue-green** | stand up the full new environment, switch traffic at once | instant switch and rollback | double capacity during the switch; DB changes must be compatible |
| **Canary** | send 1% → 10% → 50% → 100% to the new version while watching metrics | limits the blast radius, catches issues with real traffic | needs traffic splitting (a service mesh, Argo Rollouts, ALB weights) and good metrics |
| **Feature flags** | deploy dark, enable per user or segment | decouples deploy from release, instant kill switch | flag debt, testing combinations |

**Automated canary analysis**: compare the canary's error rate and latency with the baseline (Kayenta, Argo Rollouts analysis), and roll back automatically on regression.

#### Real-world example
Hotstar pre-scales for IPL matches based on predicted concurrency because reactive autoscaling can't keep up with millions of users joining within minutes of the toss. Many teams run canaries through Argo Rollouts: 5% of traffic for 10 minutes with automatic analysis of the 5xx rate and p99 latency, then progressive promotion.

#### Interview questions
?? HPA on CPU isn't scaling the service, but latency is terrible. Why?
The service is I/O-bound (waiting on the DB or downstream calls), so CPU stays low while requests queue up. Scale on a better signal (concurrent requests, latency, thread-pool saturation), or fix the bottleneck downstream; adding pods may even make DB contention worse.

?? Canary vs blue-green?
Blue-green switches all traffic at once between two full environments, giving a simple, instant rollback but no gradual exposure. Canary exposes the new version to a small fraction of traffic first and expands it gradually based on metrics, so the blast radius is limited, but it needs traffic splitting and solid observability.

#### Tricky questions
?? Why can a canary pass but the full rollout still fail?
Issues that only appear at scale or over time: a memory leak (too short a canary window), load-dependent contention, a cache or DB effect from 100% traffic, rare code paths not exercised by 1% of traffic, or problems with interactions between old and new versions. Use longer bake times and diverse metrics.

#### Interview simulation
If asked "How do you release safely?", answer: CI with tests → build once, promote the same artifact → canary with automated analysis on SLO metrics → progressive rollout → automatic rollback; feature flags for risky behaviour; backward-compatible migrations; dashboards and alerts during rollout. And "pre-scale for known events."

## AWS essentials | P4

### AWS compute: EC2, ECS/Fargate, EKS and Lambda

#### Core idea
AWS offers a spectrum of compute, from full control to fully managed:
- **EC2**: virtual machines; you manage the OS.
- **ECS** (Elastic Container Service): AWS's container orchestrator, on EC2 or on **Fargate** (serverless containers, no nodes to manage).
- **EKS**: managed Kubernetes.
- **Lambda**: functions run on events, billed per invocation and duration, scaling to zero.

#### How it works
| | EC2 | ECS on Fargate | EKS | Lambda |
|---|---|---|---|---|
| You manage | OS, patching, scaling | task definitions only | K8s objects (+ nodes unless Fargate) | code only |
| Startup | minutes | ~30–60s per task | pod start (nodes pre-provisioned) | ms to seconds (cold starts) |
| Max duration | unlimited | unlimited | unlimited | 15 min |
| Pricing | per instance-hour (spot/reserved discounts) | per vCPU/GB-second of tasks | control plane + nodes | per request + GB-second |
| Best for | custom or legacy, GPUs, full control | containerised services without K8s complexity | teams standardised on K8s, portability | event-driven glue, spiky low-volume APIs, cron |

- **ECS concepts**: task definition (image, CPU and memory, env, IAM task role), service (desired count, ALB integration, deployment config), cluster.
- **Lambda pitfalls**: cold starts (worse for JVM: use SnapStart or GraalVM native, or provisioned concurrency), connection storms to RDS (use RDS Proxy), 15-minute limit, concurrency limits per account.
- **Spot instances** cut costs by ~70% for interruption-tolerant workloads (batch, stateless workers with graceful shutdown).

#### Real-world example
NeuronixAI: **ECS on Fargate** behind an ALB, images in ECR, logs in CloudWatch, secrets from Secrets Manager via the task execution role, RDS Postgres for data. A sensible choice for a small team: no cluster management. Be ready to explain why you didn't pick EKS (operational overhead) or Lambda (long-running LLM calls, a streaming SSE connection, JVM cold starts).

#### Interview questions
?? When would you choose Lambda over containers?
Event-driven, short-lived, spiky or low-volume workloads (S3 upload triggers, scheduled jobs, webhooks, light APIs) where scale-to-zero saves money and there's no server management. Containers suit steady traffic, long-running connections (WebSockets, SSE), heavy frameworks with slow cold starts, and consistent latency needs.

?? ECS vs EKS?
ECS is simpler and AWS-native (fewer concepts, deep IAM and ALB integration, no control-plane fee). EKS is Kubernetes: a huge ecosystem (Helm, operators, service meshes, Argo), portable across clouds, more complex to operate. Pick ECS for simplicity on AWS, EKS when you need the K8s ecosystem or multi-cloud portability.

#### Tricky questions
?? Your Lambda functions exhausted the RDS connection limit during a spike. Why, and what's the fix?
Each concurrent Lambda execution environment opens its own DB connection(s); 1,000 concurrent invocations means 1,000 connections, beyond Postgres's limits. Fix: RDS Proxy (connection pooling), reserved concurrency caps, or reusing connections across invocations.

#### Interview simulation
When asked about your deployment architecture, describe it concretely (the compute choice, why, the networking, the load balancer, scaling, secrets, logs) and one thing you'd change at larger scale ("move to EKS once we have 20+ services and need a mesh" or "add autoscaling on request count"). Concrete beats generic.

### AWS storage and databases: S3, RDS/Aurora, DynamoDB, ElastiCache

#### Core idea
AWS managed data services let you pick a store per access pattern without operating it yourself: **S3** (objects), **RDS/Aurora** (relational), **DynamoDB** (key-value/document at massive scale), **ElastiCache/MemoryDB** (Redis/Valkey, Memcached), plus OpenSearch, Keyspaces (Cassandra) and Neptune (graph).

#### How it works
**S3**: eleven 9s of durability, strong read-after-write consistency, storage classes (Standard, IA, Glacier) with lifecycle rules, versioning, pre-signed URLs, event notifications, server-side encryption (SSE-S3/SSE-KMS), Block Public Access.

**RDS / Aurora**
- RDS: managed Postgres/MySQL with automated backups, point-in-time recovery, **Multi-AZ** (a synchronous standby with automatic failover in ~1–2 min), read replicas (async).
- **Aurora**: AWS's cloud-native engine. Storage is decoupled and replicated 6 ways across 3 AZs; up to 15 low-lag read replicas sharing the storage; faster failover (~30s); Aurora Serverless v2 for elastic capacity; Global Database for cross-region replicas.

**DynamoDB**
- Fully managed key-value/document store with single-digit-millisecond latency at any scale.
- **Partition key** (+ optional sort key); access by key or query within a partition; **GSIs/LSIs** for other access patterns (single-table design).
- Capacity: on-demand or provisioned (with auto scaling). Hot partitions are throttled, so design high-cardinality keys.
- Features: TTL, Streams (CDC → Lambda), transactions (up to 100 items), global tables (multi-region active-active, last-writer-wins), conditional writes for optimistic locking.

**ElastiCache / MemoryDB**: managed Redis/Valkey or Memcached; cluster mode for sharding; Multi-AZ replicas. MemoryDB adds a durable transaction log (it can be a primary database).

#### Real-world example
An e-commerce stack on AWS: Aurora Postgres for orders and payments (ACID, multi-AZ), DynamoDB for carts and sessions (high scale, key access, TTL), ElastiCache Redis for caching and rate limits, S3 plus CloudFront for product images, OpenSearch for search, with DynamoDB Streams and Debezium on Aurora feeding Kafka/MSK for events.

#### Interview questions
?? RDS Multi-AZ vs read replicas?
Multi-AZ is for **availability**: a synchronous standby (not readable in the classic setup) that takes over automatically on failure. Read replicas are for **read scaling**: asynchronous copies serving reads, with lag, which can be promoted manually (or used in another region for DR). Often you use both.

?? How do you design a DynamoDB table?
Start from the access patterns. Choose the partition key for even distribution and to group the items queried together, the sort key for ordering or range queries within a partition, and GSIs for additional patterns. Often a single table holds multiple entity types with composite keys (`PK=USER#42`, `SK=ORDER#2026-10-01#123`). Avoid scans and hot keys.

#### Tricky questions
?? DynamoDB is throttling even though total provisioned capacity isn't used. Why?
A **hot partition**: traffic concentrated on a few partition key values exceeds per-partition limits (~3,000 RCU / 1,000 WCU per partition), even if the table's total capacity is underused. Fix the key design (more cardinality, write sharding with suffixes), use caching (DAX), or redistribute the access.

#### Interview simulation
In AWS-flavoured design questions, map each component to a managed service with one line of justification. For example: "Orders in Aurora Postgres (transactions, relational queries, Multi-AZ); sessions and carts in DynamoDB with TTL (key access at scale); images in S3 behind CloudFront." Then mention backups, encryption and cross-region DR if relevant.

### AWS messaging and integration: SQS, SNS, EventBridge, API Gateway

#### Core idea
AWS provides managed building blocks for asynchronous and event-driven architectures:
- **SQS**: message queues (standard or FIFO).
- **SNS**: pub/sub fan-out to many subscribers (SQS, Lambda, HTTP, email, SMS).
- **EventBridge**: an event bus with content-based routing rules, SaaS integrations and a scheduler.
- **Kinesis / MSK**: streaming (Kinesis Data Streams; MSK = managed Kafka).
- **API Gateway**: a managed front door for REST, HTTP and WebSocket APIs (auth, throttling, Lambda integration).
- **Step Functions**: managed workflow orchestration (sagas, retries, waits).

#### How it works
- **SQS standard**: at-least-once, best-effort ordering, nearly unlimited throughput. **SQS FIFO**: ordered per message group id, exactly-once processing within a 5-minute dedup window, lower throughput (high-throughput mode is available).
- Visibility timeout, DLQ via redrive policy, long polling (`WaitTimeSeconds=20`) to reduce empty receives, delay queues, a 256KB message limit (put large payloads in S3 and send a pointer).
- **SNS → SQS fan-out**: one event published to an SNS topic, delivered to several SQS queues (one per consumer service), each processing independently with its own retries. Message filtering policies route subsets.
- **EventBridge**: events with rich JSON patterns route to targets; archive and replay; schema registry; cross-account buses.
- **Step Functions**: a state machine in JSON (ASL) with retries, catch, parallel branches and waits; good for orchestrated sagas and long-running processes.

#### Real-world example
An order platform on AWS: the order service publishes `OrderPlaced` to SNS (or EventBridge) → SQS queues for inventory, notifications and analytics, each with a DLQ and CloudWatch alarms on the oldest-message age. A Step Functions workflow orchestrates the payment-and-fulfilment saga with retries and compensations.

#### Interview questions
?? How do you fan out one event to multiple consumers on AWS?
SNS topic → several SQS queue subscriptions (one per consumer), or EventBridge rules → multiple targets. Each consumer gets its own durable queue with independent retries and DLQ, so a slow or failing consumer doesn't affect the others.

?? SQS standard vs FIFO?
Standard: maximum throughput, at-least-once delivery, possible duplicates and out-of-order delivery. FIFO: strict ordering per message group and deduplication, with lower throughput limits. Use FIFO when order matters per entity (e.g. per account), and standard plus idempotent consumers otherwise.

#### Tricky questions
?? Messages in SQS are being processed twice. Why?
The visibility timeout is shorter than the processing time, so the message reappears while the first consumer is still working; or the consumer crashed after processing but before deleting; or standard SQS delivered a duplicate. Fix: a longer or extended visibility timeout, delete after success, and idempotent processing.

#### Interview simulation
In AWS designs, specify the messaging pattern precisely: "SNS topic `order-events` fanning out to an SQS queue per consumer, each with a DLQ after 5 receives and an alarm on queue age; consumers are idempotent by eventId." It's equivalent to the Kafka answer in the AWS-managed world.

### Networking and security: VPC and IAM

#### Core idea
- A **VPC** (Virtual Private Cloud) is your isolated network in AWS: subnets, routing, gateways and firewalls.
- **IAM** (Identity and Access Management) controls **who can do what** to which AWS resources, through policies attached to users, roles and resources.

#### How it works
**VPC layout (typical 3-tier, multi-AZ)**
```
VPC 10.0.0.0/16
 ├─ Public subnets (per AZ): ALB, NAT Gateway        → route 0.0.0.0/0 → Internet Gateway
 ├─ Private app subnets (per AZ): ECS tasks / EKS nodes → route 0.0.0.0/0 → NAT Gateway (outbound only)
 └─ Private data subnets (per AZ): RDS, ElastiCache    → no internet route
```
- **Security groups**: stateful, instance-level allow rules. Reference other security groups (`DB SG allows 5432 from App SG`) instead of IPs.
- **NACLs**: stateless subnet-level rules (coarse, rarely tuned).
- **VPC endpoints**: private access to S3, DynamoDB and other AWS APIs without the NAT (saves NAT data costs and improves security).
- **Peering / Transit Gateway / PrivateLink** connect VPCs and services privately.

**IAM**
- **Principals**: users (humans: prefer SSO), **roles** (assumed by services, with temporary credentials), groups.
- **Policies**: JSON statements of Effect, Action, Resource and Condition. Evaluation: explicit Deny > Allow > implicit deny.
- **Least privilege**: grant specific actions on specific resources (`s3:GetObject` on `arn:aws:s3:::docs-bucket/tenant-123/*`).
- **Roles for workloads**: EC2 instance profiles, ECS task roles, EKS IRSA / Pod Identity, Lambda execution roles. **No long-lived access keys in apps.**
- Resource policies (S3 bucket policies, KMS key policies), SCPs (organisation guardrails), permission boundaries.

#### Real-world example
NeuronixAI-style setup: the ALB in public subnets; Fargate tasks in private subnets; RDS in data subnets reachable only from the task security group; outbound calls to OpenAI via the NAT gateway; S3 through a gateway endpoint. The task role has `s3:GetObject` and `s3:PutObject` on the documents bucket prefix, `secretsmanager:GetSecretValue` on specific secrets, and nothing else. Being able to draw this is a strong signal.

#### Interview questions
?? How do you give an application running on ECS access to S3 securely?
Create an IAM role with a least-privilege policy (specific bucket and prefix, specific actions) and set it as the ECS **task role**. The SDK automatically gets temporary credentials from the task metadata endpoint. No access keys in code or environment variables. Optionally restrict via a bucket policy and a VPC endpoint condition.

?? Security group vs NACL?
Security groups are stateful (return traffic automatically allowed), attached to network interfaces, allow-only rules, can reference other SGs. NACLs are stateless (you need both inbound and outbound rules), apply to subnets, support deny rules, and are evaluated in order. Most access control is done with SGs.

#### Tricky questions
?? Your private-subnet service suddenly costs a lot in data transfer. Likely cause?
Traffic to S3 or other AWS services going through the **NAT gateway** (charged per GB processed). Add gateway VPC endpoints for S3 and DynamoDB and interface endpoints for other heavy services. Also check cross-AZ traffic charges.

#### Interview simulation
If asked "How is your service secured on AWS?", cover the network (private subnets, SG references, no public DB), identity (task roles, least privilege, no static keys), data (encryption at rest via KMS, TLS in transit), secrets (Secrets Manager with rotation), and audit (CloudTrail, GuardDuty). Layered and concrete.

## Observability & operations | P4

### The three pillars: logs, metrics and traces

#### Core idea
**Observability** is the ability to understand a system's internal state from its outputs. The three pillars:
- **Metrics**: numeric time series (request rate, error rate, latency percentiles, CPU). Cheap, aggregatable, used for dashboards and **alerts**.
- **Logs**: timestamped event records with details. Used for the **why**.
- **Traces**: the path of one request across services as a tree of **spans** with timings. Used for the **where**.

#### How it works
- **Instrumentation**: **OpenTelemetry** (OTel) is the vendor-neutral standard for traces, metrics and logs. Java auto-instrumentation via an agent; Spring Boot 3 uses Micrometer Observation (metrics plus tracing) with OTel or Brave bridges.
- **Golden signals** (Google SRE): latency, traffic, errors, saturation. **RED** for services: Rate, Errors, Duration. **USE** for resources: Utilisation, Saturation, Errors.
- **Percentiles, not averages**: p50, p95, p99, p99.9. Averages hide tail latency, and at scale many users hit the tail.
- **Structured logs** (JSON) with a trace id, span id, request id, user or tenant id (no PII), level, logger and message, so you can correlate logs with traces.
- **Context propagation**: the W3C `traceparent` header carries the trace context across HTTP, gRPC and messaging (in Kafka headers).
- **Sampling**: traces are expensive at full volume. Head sampling (decide at the start, e.g. 10%) vs **tail sampling** (keep all errors and slow traces, sample the rest) via the OTel Collector.
- **Exemplars**: link a metric data point (a latency spike) to an example trace.

#### Real-world example
Debugging the 1mg search latency: a Grafana dashboard shows the p99 of `/search` rising (metric) → a sample of slow traces (Tempo/Jaeger/X-Ray) shows 80% of the time in the `offers-service` span → offers-service logs filtered by trace id show timeouts to its DB → the root cause is a missing index after a deploy. Metrics found it, traces located it, logs explained it.

#### Interview questions
?? Metrics vs logs vs traces: when do you use each?
Metrics to detect and alert (something's wrong, and how much); traces to localise (which service or span is slow or failing for a request); logs for detailed context (the exact error, inputs, state). They're linked by trace ids and exemplars.

?? Why monitor p99 rather than average latency?
Averages hide outliers: a 50ms average can coexist with a 2s p99. Users hitting the slow tail have a bad experience, and with fan-out (a page making 20 backend calls), most page loads include at least one tail-latency call. SLOs are usually defined on percentiles.

#### Tricky questions
?? How do you trace a request that goes through Kafka?
Propagate the trace context in Kafka record headers (the OTel instrumentation for Kafka does this). The consumer starts a span linked to (or as a child of) the producer span, so the trace continues across the asynchronous boundary.

#### Interview simulation
If asked "How do you monitor your services?", describe: Micrometer metrics to Prometheus (or CloudWatch) with RED dashboards per endpoint; structured JSON logs with trace ids shipped to Loki/ELK/CloudWatch Logs; OpenTelemetry tracing with tail sampling; SLO-based alerts. Then one debugging story showing all three working together.

### Monitoring, alerting and SLOs

#### Core idea
Good alerting pages humans only for **user-impacting problems that need action**, and gives them enough context to act. **SLOs** (Service Level Objectives) define "good enough" reliability; **error budgets** make reliability a measurable trade-off against shipping speed.

#### How it works
- **SLI**: a measured ratio, e.g. "the fraction of `/checkout` requests that succeed in < 500ms".
- **SLO**: the target over a window: 99.9% over 30 days. Error budget = 0.1% ≈ 43 minutes of full outage-equivalent per month.
- **Burn-rate alerts** (from the Google SRE Workbook): alert when the budget is being consumed too fast. For example, page if the 1h burn rate is > 14.4× (2% of the monthly budget gone in an hour) **and** the 5-minute rate confirms it; open a ticket for slower burns (6× over 6h). That catches real incidents fast with few false positives, unlike static thresholds.
- **Alert hygiene**: every page must be actionable, linked to a **runbook**, routed by severity (page vs ticket), deduplicated and grouped (Alertmanager), with ownership. Alert on symptoms (user-facing errors and latency), not on causes (CPU 80%), except for capacity warnings.
- **Dashboards**: service overview (RED), dependencies, saturation (pools, queues, consumer lag), recent deploys annotated.
- **Synthetic monitoring**: probes hitting critical flows from outside (login, search, checkout).

#### Real-world example
A team got paged 30 times a week for "CPU > 80%" with no user impact, so engineers started ignoring pages (alert fatigue). Moving to SLO burn-rate alerts on checkout success and latency cut pages to about 2 a week, all real, and the time to detect real incidents dropped.

#### Interview questions
?? What's an error budget and how is it used?
1 − SLO: the allowed unreliability in a window. If the budget is healthy, teams can ship faster and take more risk; if it's exhausted, they prioritise reliability work and freeze risky releases. It turns reliability into a shared, objective decision tool between product and engineering.

?? What makes a good alert?
It indicates real or imminent user impact, is actionable, has a clear owner and runbook, fires early enough to act but rarely falsely (burn rates, `for:` durations), includes context (dashboard links, recent deploys), and is routed by severity.

#### Tricky questions
?? Why not set the SLO to 100%?
It's unachievable (dependencies, networks and deploys all fail sometimes), infinitely expensive, and blocks all change. Users can't distinguish 99.99% from 100% when their own networks are less reliable. Pick SLOs matching user expectations and business needs.

#### Interview simulation
If asked about on-call or production ownership (your resume says "owned features from design to production support"), describe the SLOs for your service, what pages you, an incident you handled (detection → mitigation → root cause → postmortem actions), and one alert you improved. Concrete operational stories score highly for SDE-2.

### Debugging production incidents

#### Core idea
Incident handling is a skill interviewers probe with "tell me about a production issue" and "the service is slow, what do you do?". The goal is a **calm, systematic process**: **mitigate first, then find the root cause, then prevent recurrence.**

#### How it works
**Incident response flow**
1. **Detect**: an alert, a user report, a dashboard anomaly.
2. **Assess impact**: which users, endpoints, regions? How bad? Declare severity, open an incident channel, assign roles (incident commander, communications).
3. **Mitigate** (stop the bleeding): **roll back** the recent deploy, toggle off the feature flag, scale up, fail over, shed load, block abusive traffic. Restoring service comes before understanding it.
4. **Diagnose**: what changed? (Deploys, config, traffic, dependencies, data.) Use metrics → traces → logs; thread and heap dumps; DB slow queries and locks.
5. **Resolve and verify**: confirm the metrics return to normal.
6. **Postmortem** (blameless): timeline, root cause (5 whys), what went well and badly, action items with owners (fixes, alerts, runbooks, tests).

**Latency spike checklist**
- Recent deploy or config change? (Correlate the timestamps.)
- Traffic increase or a different traffic mix?
- Downstream latency (traces)? DB slow queries, locks, connection pool saturation (`hikaricp.connections.pending`)?
- JVM: GC pauses, thread pool exhaustion, CPU throttling in containers?
- Infrastructure: node issues, noisy neighbours, network (DNS, NAT, cross-AZ)?
- Cache hit-ratio drop (eviction, a restart, a key-format change)?

#### Real-world example
A real-style story from your 1mg work: "After a release, search p99 went from 300ms to 2s. We rolled back first (mitigation in 10 minutes). Traces showed a new query in the offers path doing a sequential scan; the release had added a filter on a column without an index. We added the index concurrently, redeployed, and added a CI check comparing EXPLAIN plans for new queries, plus a latency SLO alert per endpoint."

#### Interview questions
?? Users report the app is slow. Walk me through your debugging.
Check the dashboards for scope (which endpoints, since when, all users or some); correlate with deploys or changes, and roll back if one matches. Check the golden signals per service, trace slow requests to find the slow span, then dig into that component (DB queries and locks, GC, pools, downstream calls). Mitigate as soon as you've isolated the cause, and follow up with a postmortem.

?? What is a blameless postmortem?
A review focused on how the system and processes allowed the incident, not on who made a mistake, so people share information honestly. It produces a timeline, root causes, contributing factors, and concrete action items that make recurrence less likely or less harmful.

#### Tricky questions
?? You don't know the root cause yet, but a rollback would fix the symptoms. Do you roll back?
Yes, if the evidence points at the change and rollback is safe (backward-compatible data). Mitigation first: user impact matters more than diagnosis speed. Capture evidence first if it's cheap (a heap or thread dump, logs), then roll back and investigate in staging or from the captured data.

#### Interview simulation
Prepare **two incident stories** in STAR format with numbers (impact, time to mitigate, root cause, prevention). When answering, explicitly separate the **mitigation** from the **root cause** from the **prevention**. Interviewers listen for that structure and for ownership ("I added the alert that would have caught it earlier").

### CI/CD pipelines

#### Core idea
**Continuous Integration** merges and verifies code changes frequently (build, test, scan). **Continuous Delivery/Deployment** automates releasing verified changes to environments, up to production, safely and repeatably. The goal: small, frequent, low-risk releases.

#### How it works
**A typical pipeline (GitHub Actions / GitLab CI / Jenkins)**
```
PR opened → build + unit tests + static analysis (Checkstyle/SpotBugs/Sonar) + dependency & secret scanning
         → integration tests (Testcontainers) → code review → merge to main
main     → build image once (tag = git SHA) → image scan (Trivy) → push to registry (ECR)
         → deploy to staging (Helm/Argo CD/ECS deploy) → smoke/e2e tests → (approval?) 
         → production canary → automated analysis → progressive rollout → done (or auto-rollback)
```
- **Build once, deploy many**: the same immutable artifact is promoted across environments; only config differs.
- **GitOps** (Argo CD, Flux): the desired state of the clusters lives in git; a controller syncs it. That gives an audit trail and easy rollbacks (git revert).
- **Database migrations** run as a pipeline step or a job, backward compatible (expand/contract).
- **Trunk-based development** plus feature flags enable frequent merges without long-lived branches.
- **DORA metrics**: deployment frequency, lead time for changes, change failure rate, time to restore. These measure delivery performance.

#### Real-world example
For NeuronixAI: GitHub Actions builds and tests (with Testcontainers Postgres plus pgvector), builds the Docker image tagged with the commit SHA, pushes to ECR, and updates the ECS service (rolling deployment with health checks and circuit-breaker rollback on ECS). Flyway migrations run at startup or as a one-off task before the deploy. Describing this concretely shows end-to-end ownership.

#### Interview questions
?? What's the difference between continuous delivery and continuous deployment?
Continuous delivery: every change is automatically built, tested and **ready** to release; production deploys may need a manual approval. Continuous deployment: every change that passes the pipeline goes to production automatically, with no manual gate.

?? How do you make deployments safe?
Small changes, automated tests at the right levels, immutable artifacts, staged environments, canary or progressive rollouts with automated metric analysis, feature flags, backward-compatible migrations, fast automated rollback, and good observability during and after the deploy.

#### Tricky questions
?? Why tag images with the git SHA instead of `latest`?
`latest` is mutable: you can't know exactly what's running, rollbacks are ambiguous, and nodes may cache different "latest" images. An immutable SHA tag gives traceability (image → commit) and reproducible deploys and rollbacks.

#### Interview simulation
If asked "Walk me through how your code gets to production", describe your actual pipeline step by step, the gates (tests, scans, review), the deploy strategy, how you'd roll back, and one improvement you'd make (e.g. adding a canary analysis or contract tests). Specific and honest wins.
