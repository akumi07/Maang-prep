## Computer networks | P2 | must

### OSI and TCP/IP models

#### Core idea
Network communication is split into **layers**, each with a single responsibility, using the services of the layer below. The **OSI model** has 7 layers (a teaching reference); the **TCP/IP model** has 4–5 layers and is what the internet actually runs on.

#### How it works
| OSI layer | TCP/IP | Responsibility | Examples | Unit |
|---|---|---|---|---|
| 7 Application | Application | app protocols | HTTP, DNS, gRPC, SMTP, TLS-ish | message |
| 6 Presentation | Application | encoding, encryption | TLS, JSON, compression | |
| 5 Session | Application | session management | (TLS sessions, RPC sessions) | |
| 4 Transport | Transport | process-to-process delivery, ports, reliability | TCP, UDP, QUIC | segment / datagram |
| 3 Network | Internet | addressing and routing across networks | IP, ICMP | packet |
| 2 Data link | Link | node-to-node on the same network | Ethernet, Wi-Fi, ARP, MAC | frame |
| 1 Physical | Link | bits on the wire | cables, radio | bits |

**Encapsulation**: each layer wraps the data with its header on the way down (HTTP data → TCP segment → IP packet → Ethernet frame) and strips it on the way up.

**Where the devices live**: switch = L2 (MAC addresses), router = L3 (IP), **L4 load balancer** = TCP/UDP (IP + port, e.g. AWS NLB), **L7 load balancer** = HTTP-aware (paths, headers, cookies, e.g. AWS ALB, Nginx, Envoy).

#### Real-world example
When a service is unreachable, debug layer by layer: L3 (is the IP reachable? `ping`/`traceroute`, security groups, routes), L4 (is the port open? `nc -vz host 443`, `telnet`), TLS (`openssl s_client -connect host:443` to inspect the certificate chain), L7 (`curl -v` for the HTTP status and headers). That ladder is how the "downstream integration issue" on your resume would be investigated.

#### Interview questions
?? Why do we use layered models?
Separation of concerns: each layer can evolve independently (Wi-Fi to fibre with no change to HTTP; HTTP/1.1 to HTTP/2 without touching IP), interoperability between vendors, and easier troubleshooting by isolating the failing layer.

?? At which layer do load balancers work?
Both L4 and L7 exist. L4 balancers route by IP and port, without inspecting content: fast, and protocol-agnostic. L7 balancers parse HTTP: they route by path or host, terminate TLS, add headers, retry, and do sticky sessions and rate limiting. Many systems use both.

#### Tricky questions
?? Is TLS at layer 4, 6 or 7?
It doesn't map cleanly. It runs on top of TCP (above L4), provides encryption (an L6 concept), and is usually considered part of the application layer in the TCP/IP model. Say that the OSI model is a reference and real protocols straddle layers.

#### Interview simulation
For "explain the OSI model", don't recite 7 names robotically. Give the 4-layer TCP/IP view with one protocol and one device per layer, then connect it to debugging or load balancers. That shows practical understanding.

### TCP vs UDP: handshake, flow and congestion control

#### Core idea
- **TCP**: connection-oriented, **reliable, ordered** byte stream, with flow and congestion control. Used for HTTP/1–2, databases, gRPC, SSH.
- **UDP**: connectionless **datagrams**, no delivery or ordering guarantees, minimal overhead. Used for DNS, video calls, gaming, metrics (StatsD), and QUIC (HTTP/3) builds its own reliability on top of UDP.

#### How it works
**3-way handshake**
```
Client → SYN (seq=x) → Server
Client ← SYN-ACK (seq=y, ack=x+1) ← Server
Client → ACK (ack=y+1) → Server        → connection ESTABLISHED (1 RTT before data)
```
**4-way close**: FIN → ACK, FIN → ACK. The side that closes first enters **TIME_WAIT** (2 × MSL, often 60s) so delayed packets don't corrupt a new connection using the same 4-tuple. Lots of short-lived outgoing connections can exhaust ephemeral ports (TIME_WAIT buildup), so use **keep-alive and connection pooling**.

**Reliability**: sequence numbers, acknowledgements, retransmission on timeout or **3 duplicate ACKs** (fast retransmit), checksums.

**Flow control** (protect the *receiver*): the receiver advertises a **receive window** (`rwnd`); the sender won't have more unacknowledged bytes in flight than this.

**Congestion control** (protect the *network*): the sender keeps a **congestion window** (`cwnd`).
- **Slow start**: cwnd starts small (about 10 segments) and doubles every RTT until loss or a threshold.
- **Congestion avoidance (AIMD)**: additive increase, multiplicative decrease on loss.
- Algorithms: Reno, **CUBIC** (the Linux default), **BBR** (Google; models bandwidth and RTT instead of reacting to loss).
- Effective send rate ≈ min(cwnd, rwnd) / RTT.

**Head-of-line blocking**: TCP delivers bytes in order. One lost packet stalls everything behind it, even data for unrelated HTTP/2 streams on the same connection.

**Nagle's algorithm** batches small writes, which interacts badly with delayed ACKs (40ms stalls); latency-sensitive apps set `TCP_NODELAY`.

| | TCP | UDP |
|---|---|---|
| Connection | handshake | none |
| Reliability | retransmits, ordered | none (best effort) |
| Header | 20–60 bytes | 8 bytes |
| Flow/congestion control | yes | no (app must handle it) |
| Use | web, APIs, DBs, file transfer | DNS, VoIP, video, gaming, QUIC |

#### Real-world example
Video calls (Zoom, Meet) use UDP-based RTP: a late packet is useless (better to skip a frame than freeze waiting for a retransmission). Databases use TCP because every byte matters. **Connection pooling** in your services (HikariCP, HTTP keep-alive, gRPC channels) exists largely to avoid paying the TCP and TLS handshake and slow-start costs on every request.

#### Interview questions
?? Why is TCP's handshake three-way and not two-way?
Both sides need to agree on initial sequence numbers and confirm that the other side received theirs. Two messages would let the server confirm the client's ISN but not prove the client received the server's ISN. It also protects against old duplicate SYNs creating bogus connections.

?? Flow control vs congestion control?
Flow control prevents overwhelming the **receiver** (based on the receiver's advertised buffer space, rwnd). Congestion control prevents overwhelming the **network** (the sender infers congestion from loss or delay and adjusts cwnd). The sender respects the minimum of the two.

?? When would you choose UDP over TCP?
When timeliness beats reliability (real-time audio and video, games), for tiny request/response exchanges where a handshake would dominate (DNS), for multicast or broadcast, or when you want to implement custom reliability or congestion control in user space (QUIC).

#### Tricky questions
?? A service makes thousands of short HTTP calls per second to another service and starts failing with "cannot assign requested address". Why?
**Ephemeral port exhaustion**: each new outgoing connection uses a local port, and closed connections sit in TIME_WAIT for about 60s. At a high connection churn rate you run out of the about 28k default ports. Fix: HTTP keep-alive and connection pooling (reuse connections), widen the port range, or `tcp_tw_reuse` for outgoing connections.

?? Why does a large file download start slowly and then speed up?
TCP slow start: cwnd begins small and grows exponentially per RTT until it hits the bandwidth or a loss. On long-RTT links it takes several round trips to reach full speed, which is why CDNs and connection reuse matter.

#### Interview simulation
**Interviewer:** "Explain what happens when TCP packets are lost."

Explain detection (timeout or 3 duplicate ACKs), retransmission, the congestion response (cwnd cut, back to slow start on timeout), and the effect on applications (latency spikes, head-of-line blocking for multiplexed streams), and how HTTP/3/QUIC improves that by using independent streams over UDP. Linking low-level behaviour to protocol evolution is a strong answer.

### HTTP/1.1 vs HTTP/2 vs HTTP/3

#### Core idea
HTTP has evolved to reduce latency:
- **HTTP/1.1** (1997): text protocol, persistent connections, but one request at a time per connection.
- **HTTP/2** (2015): binary framing, **multiplexing** many streams on one TCP connection, header compression.
- **HTTP/3** (2022): HTTP over **QUIC** (UDP), removing TCP head-of-line blocking, with faster connection setup and connection migration.

#### How it works
**HTTP/1.1**
- Keep-alive reuses TCP connections, but each connection handles requests **sequentially** (pipelining exists but is broken in practice, so it's disabled).
- Browsers open about 6 connections per host to parallelise; developers used hacks: domain sharding, sprites, bundling.
- Text headers are repeated on every request (cookies can be KBs).

**HTTP/2**
- **Binary frames** on **streams**; many concurrent requests and responses interleaved over **one connection**.
- **HPACK** header compression (static and dynamic tables).
- Stream prioritisation; server push (now deprecated and removed by Chrome).
- Still on TCP, so a single lost packet stalls **all** streams (**transport-level head-of-line blocking**).

**HTTP/3 (QUIC)**
- QUIC runs over UDP and implements reliability, congestion control and **TLS 1.3 built in**.
- **Independent streams**: loss on one stream doesn't block others.
- **Faster handshakes**: 1-RTT for new connections (transport and TLS combined), **0-RTT** resumption (with replay caveats for non-idempotent requests).
- **Connection migration**: connections are identified by a connection ID, not the IP:port 4-tuple, so switching from Wi-Fi to 4G keeps the connection alive.
- Some networks block or throttle UDP, so clients fall back to HTTP/2.

| | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| Transport | TCP | TCP | QUIC/UDP |
| Format | text | binary | binary |
| Concurrency | 1 per connection (~6 connections) | multiplexed | multiplexed, independent |
| HOL blocking | application level | TCP level | none (per stream) |
| Header compression | none | HPACK | QPACK |
| TLS | optional | effectively required by browsers | mandatory (built in) |

#### Real-world example
Google, YouTube, Facebook and Cloudflare serve most traffic over HTTP/3. Mobile users on lossy networks see the biggest gains (fewer stalls, survival across network changes). Internally, **gRPC** runs on HTTP/2, which is why it gets multiplexing, and also why L4 load balancing doesn't distribute gRPC load well (one long-lived connection carries everything).

#### Interview questions
?? What problems does HTTP/2 solve over HTTP/1.1?
Request-level head-of-line blocking and connection overhead: multiplexing lets many requests share one connection concurrently; header compression shrinks repeated headers; binary framing is more efficient to parse. Bundling and domain-sharding hacks are no longer needed.

?? Why was HTTP/3 built on UDP instead of improving TCP?
TCP is implemented in OS kernels and middleboxes (firewalls, NATs) that ossified its behaviour, so changing it takes years to deploy. Building QUIC in user space over UDP allows fast iteration, integrated TLS, independent streams (fixing HOL blocking) and connection migration.

#### Tricky questions
?? Can HTTP/2 be slower than HTTP/1.1?
On very lossy networks, yes: one TCP connection carrying all streams means a lost packet stalls everything, while HTTP/1.1's 6 separate connections are affected independently. That's exactly the motivation for HTTP/3.

?? Is 0-RTT in TLS 1.3 / QUIC safe for all requests?
No. 0-RTT data can be **replayed** by an attacker. It should only carry idempotent requests (GET). Servers typically reject or restrict 0-RTT for non-idempotent methods.

#### Interview simulation
If asked "How would you make a web page load faster from a protocol perspective?": enable HTTP/2 or 3 at the CDN, TLS 1.3, keep-alive, compression (Brotli), caching headers, preconnect and DNS-prefetch, fewer round trips (inline critical CSS), and a CDN close to users. Then mention measuring with real-user metrics (TTFB, LCP).

### HTTPS and the TLS handshake

#### Core idea
**HTTPS** is HTTP over **TLS**, which gives three guarantees: **confidentiality** (encryption), **integrity** (tamper detection) and **authentication** (you're talking to the real server, verified with **certificates**). TLS uses **asymmetric crypto** to authenticate and agree on keys, then fast **symmetric crypto** for the data.

#### How it works
**TLS 1.3 handshake (1 RTT)**
```
Client → ClientHello: supported ciphers, key share (ECDHE public value), SNI (hostname), ALPN (h2/http1.1)
Server → ServerHello: chosen cipher, its key share
         {EncryptedExtensions, Certificate, CertificateVerify (signature), Finished}   ← already encrypted
Client:  verify cert chain → trusted root CA, hostname matches SAN, not expired/revoked;
         verify signature proves server owns the private key
Client → {Finished} + application data
Both derive the same session keys from ECDHE shared secret (HKDF)
```
- **Key exchange**: ephemeral (EC)Diffie-Hellman gives **forward secrecy**: stealing the server's private key later doesn't decrypt past traffic.
- **Certificates**: the server's public key plus identity, signed by a **CA**. The chain goes leaf → intermediate → root (the root is in the OS or browser trust store).
- **Symmetric encryption**: AES-GCM or ChaCha20-Poly1305 (AEAD: encryption plus integrity).
- TLS 1.2 needed **2 RTTs** and allowed weaker ciphers (static RSA key exchange, no forward secrecy). TLS 1.3 removed them and added 0-RTT resumption.
- **SNI** tells the server which hostname you want (one IP, many certificates). **ALPN** negotiates HTTP/2 vs 1.1.
- **mTLS** (mutual TLS): the client also presents a certificate. Used for service-to-service auth (service meshes) and B2B APIs.
- **Certificate pinning** (mobile apps): trust only specific keys, which stops MITM through rogue CAs, but rotation becomes risky.

#### Real-world example
A classic production incident: a downstream partner's **certificate expired** (or they rotated to a CA chain your Java truststore didn't include), and every call failed with `PKIX path building failed` / `SSLHandshakeException`. Debug with `openssl s_client -connect partner.com:443 -servername partner.com -showcerts`, check the expiry and the chain, and update the truststore if needed. Prevention: certificate expiry monitoring and automated renewal (Let's Encrypt or ACM). That's a plausible version of the downstream integration debugging on your resume.

#### Interview questions
?? Walk through what happens in a TLS handshake.
The client says hello with supported versions, ciphers and a key share. The server picks the parameters, sends its key share and certificate, and proves it owns the private key by signing the handshake. The client validates the certificate chain against trusted CAs and the hostname. Both compute the shared secret via ECDHE and derive symmetric keys, and from then on data is encrypted with AES-GCM. TLS 1.3 does this in 1 RTT.

?? Why use both asymmetric and symmetric encryption?
Asymmetric crypto solves key distribution and authentication (you can verify a server with its public key and agree on a secret over an insecure channel), but it's slow. Symmetric crypto is orders of magnitude faster for bulk data. TLS uses asymmetric crypto only for the handshake.

?? What is forward secrecy?
Session keys are derived from ephemeral Diffie-Hellman values that are discarded after the session. Even if the server's long-term private key is stolen later, recorded past sessions can't be decrypted. TLS 1.3 mandates it.

#### Tricky questions
?? How does a browser know a certificate hasn't been revoked?
CRLs (downloaded lists, rarely used by browsers now), OCSP (asking the CA; it has privacy and latency issues), **OCSP stapling** (the server attaches a fresh signed OCSP response), and browser-pushed revocation sets (CRLite). Short-lived certificates (90 days or less) reduce reliance on revocation.

?? Where should TLS terminate in a microservices architecture?
Commonly at the edge load balancer or API gateway (offloading crypto and centralising certificates), with **re-encryption** or mTLS internally for zero-trust (a service mesh like Istio or Linkerd makes it automatic). Terminating at the edge and sending plaintext inside the VPC is common but weaker. Compliance regimes (PCI) often require encryption in transit everywhere.

#### Interview simulation
If asked "How does HTTPS keep my password safe on public Wi-Fi?": an attacker on the Wi-Fi can see the packets but can't read them (encryption) or modify them (integrity), and can't impersonate the site without a certificate signed by a trusted CA for that hostname (authentication). Mention HSTS to prevent downgrade to HTTP, and that the risk shifts to things like a phishing domain with its own valid certificate.

### DNS resolution

#### Core idea
**DNS** translates names (`api.acme.com`) into IP addresses. It's a hierarchical, distributed, heavily **cached** database. DNS is in the path of almost every request, so its latency, caching (TTL) and failures matter a lot.

#### How it works
**Resolution path**
```
App → OS stub resolver (checks /etc/hosts, local cache)
    → Recursive resolver (ISP, 8.8.8.8, 1.1.1.1, VPC resolver) — cache?
        → Root server (".")          → "ask .com TLD servers"
        → .com TLD server            → "ask acme.com's authoritative NS"
        → Authoritative NS (Route53) → "api.acme.com A 203.0.113.10, TTL 60"
    ← answer cached at each level for TTL seconds
```
**Record types**: `A` (IPv4), `AAAA` (IPv6), `CNAME` (alias to another name; not allowed at the zone apex), `ALIAS`/`ANAME` (provider-specific apex alias, e.g. Route 53 alias to an ALB), `MX` (mail), `TXT` (verification, SPF, DKIM), `NS` (delegation), `SRV` (service and port), `CAA` (which CAs may issue certificates).

**TTL trade-off**: a low TTL (30–60s) allows fast failover and traffic shifting but means more queries; a high TTL means fewer queries but slow changes. Lower TTLs *before* planned migrations.

**DNS-based load balancing and routing**: multiple A records (round-robin), **GeoDNS / latency-based routing** (send users to the nearest region), weighted routing (canaries), failover routing with health checks. Clients and resolvers caching beyond the TTL limit how fast this reacts.

**Transport**: UDP port 53 (TCP for large responses or zone transfers); DoH/DoT for privacy. **DNSSEC** signs records against spoofing.

**In Kubernetes**: CoreDNS resolves `orders.default.svc.cluster.local`. The `ndots:5` setting makes lookups of external names try several search-domain suffixes first, multiplying the DNS queries per request, a known latency source. Use FQDNs with a trailing dot, or tune ndots.

#### Real-world example
The **2021 Facebook outage**: a BGP configuration change withdrew the routes to Facebook's DNS servers, so the authoritative DNS became unreachable, and facebook.com, Instagram and WhatsApp were down globally for about 6 hours, even internal tools were affected. Another: **Java's DNS caching**. The JVM may cache successful lookups for a long time (forever with a security manager in older versions; `networkaddress.cache.ttl`), so services keep calling an old IP after a failover. Set the TTL to around 30–60s for cloud environments.

#### Interview questions
?? What happens when you resolve a domain name for the first time?
The local cache misses, so the query goes to the recursive resolver. If it doesn't have the answer cached, it asks a root server (referral to the TLD), then the TLD server (referral to the authoritative name servers), then the authoritative server, which returns the record with a TTL. The resolver caches it and returns it to the client, which also caches it.

?? Why can't you put a CNAME at the root domain (acme.com)?
The DNS spec says a CNAME can't coexist with other records at the same name, and the apex must have SOA and NS records. Providers offer ALIAS or ANAME (Route 53 alias records), which resolve the target server-side and return A records.

#### Tricky questions
?? You changed a DNS record with TTL 3600 to point to a new server, but some users still hit the old one hours later. Why?
Resolvers and clients cache for up to the TTL (and some misbehaving clients or JVMs cache longer). Changes propagate only as caches expire. Lower the TTL well in advance of a planned change, and keep the old server serving (or redirecting) during the transition.

#### Interview simulation
If asked "How would you do a zero-downtime region failover?": DNS failover routing with health checks plus a low TTL, or better, anycast or global load balancers (Cloudflare, AWS Global Accelerator) that don't depend on client DNS caching. Data replication across regions is the harder part. That shows you know DNS's limits.

### What happens when you type a URL

#### Core idea
This is the classic end-to-end question. It tests whether you can connect DNS, TCP, TLS, HTTP, load balancers, servers, databases and browser rendering into one coherent story. The skill is **structure and depth control**: give the full path, then go deep wherever the interviewer steers.

#### How it works
**Typing `https://www.1mg.com/search?q=dolo` and pressing Enter:**
1. **URL parsing**: the browser parses the scheme, host, path and query; checks the HSTS list (force HTTPS); checks whether it's a search term.
2. **Caches first**: the browser HTTP cache or service worker may serve the response directly.
3. **DNS resolution**: browser cache → OS cache → recursive resolver → root → TLD → authoritative → IP (often a **CDN** edge IP via GeoDNS/anycast).
4. **TCP connection**: 3-way handshake to port 443 (or a reused keep-alive connection; or QUIC over UDP for HTTP/3).
5. **TLS handshake**: ClientHello with SNI and ALPN, certificate verification, ECDHE keys (1 RTT in TLS 1.3).
6. **HTTP request**: `GET /search?q=dolo` with headers (Host, cookies, Accept-Encoding, User-Agent), framed in HTTP/2.
7. **Edge / CDN**: static assets served from the edge cache; dynamic requests forwarded to the origin. WAF and DDoS protection, rate limiting.
8. **Load balancer** (L7): terminates or re-encrypts TLS, routes by host and path to a healthy backend, adds `X-Forwarded-For` and trace headers.
9. **API gateway / service**: authentication (JWT), rate limit, routing to the search service. The service checks **Redis** (cache hit?) and on a miss queries **Elasticsearch/Postgres**, calls pricing and stock services in parallel, builds the JSON response.
10. **Response** travels back with status, headers (`Cache-Control`, `Set-Cookie`, `Content-Encoding: br`) and body.
11. **Browser rendering**: parse HTML → DOM; CSS → CSSOM; render tree → layout → paint → composite. JS blocks parsing unless `defer`/`async`. More requests for CSS, JS and images (often parallel over HTTP/2, many from the CDN).
12. **After load**: connections are kept alive for reuse; analytics beacons are sent.

#### Real-world example
Use a real system you know: for the 1mg search, the CDN serves the JS bundle, the API request goes through the ALB to the search service, the Redis soft-TTL cache serves popular queries, and misses hit Postgres/Elasticsearch, with CompletableFuture fan-out for enrichment. Walking through *your* architecture makes the answer memorable and lets you steer toward topics you know deeply.

#### Interview questions
?? What happens when you type google.com and press Enter? (Answer in 2 minutes.)
Browser checks its cache and HSTS → DNS resolution (caches → recursive resolver → root/TLD/authoritative, giving the nearest edge IP) → TCP handshake (or QUIC) → TLS 1.3 handshake with certificate validation → HTTP/2 GET → Google's edge or load balancer routes it to a frontend server, which fans out to backend services → the response with HTML → the browser parses, fetches subresources, builds the DOM and CSSOM, lays out, paints → keep-alive for further requests. Offer to go deeper on any step.

#### Tricky questions
?? Where could latency hide in this flow, and how would you measure it?
DNS (slow resolver, no caching), TCP and TLS handshakes (no connection reuse, far from the user, so use a CDN), server time (TTFB: backend processing, DB, downstream calls), payload size (no compression, oversized images), render-blocking JS and CSS. Measure with the browser DevTools waterfall, `curl -w` timing (`time_namelookup`, `time_connect`, `time_appconnect`, `time_starttransfer`), real-user monitoring and distributed tracing on the backend.

#### Interview simulation
**Interviewer:** "What happens when you type a URL in the browser?"

**Clarify:** "Should I focus on networking, on the backend, or on browser rendering? I'll give the full path briefly and then go deep where you'd like." Then deliver the 12 steps in about 2–3 minutes with no rambling, and offer depth: "I can go deeper into the TLS handshake, or into how the backend serves this request with caching." Letting the interviewer choose shows confidence and control.

### WebSockets, SSE and long polling

#### Core idea
HTTP is request-response: the server can't speak first. For **real-time updates** (chat, notifications, live tracking, price tickers), there are three main techniques:
- **Long polling**: the client asks, and the server holds the request open until there's data (or a timeout), then the client asks again.
- **Server-Sent Events (SSE)**: one long-lived HTTP response where the server streams events (one-way, server → client).
- **WebSockets**: a full-duplex, persistent connection after an HTTP upgrade (two-way).

#### How it works
| | Long polling | SSE | WebSocket |
|---|---|---|---|
| Direction | server → client (simulated) | server → client | bidirectional |
| Protocol | plain HTTP | HTTP (`text/event-stream`) | `ws://`/`wss://` after `Upgrade: websocket` (101 Switching Protocols) |
| Overhead | a new request per message | low | very low per message (2–14 byte frames) |
| Reconnect | manual | **built in** (`EventSource` auto-reconnects with `Last-Event-ID`) | manual |
| Binary data | yes | text only | yes |
| Proxies/LB | easy | easy (HTTP), watch buffering and timeouts | need upgrade support and long idle timeouts |
| Use case | fallback, simple notifications | live feeds, notifications, LLM token streaming | chat, collaborative editing, games |

**Scaling stateful connections**
- Each connection lives on one server, so you need a way to deliver a message to the server holding the user's connection: **pub/sub fan-out** (Redis Pub/Sub, Kafka) or a connection registry (userId → server).
- **Sticky sessions** are needed for some fallbacks (Socket.io polling).
- Connection limits: file descriptors, memory per connection; event-loop servers (Netty, Node) handle 100k+ connections per node.
- Heartbeats (ping/pong) detect dead connections; reconnect with backoff and jitter after a deploy (otherwise a thundering herd of reconnects).
- Load balancer idle timeouts (AWS ALB defaults to 60s) close quiet connections, so send heartbeats more often than that.

#### Real-world example
Your OnTheMove resume: **Socket.io real-time updates (latency −80%)** replaced client polling. Expect follow-ups: How did you scale beyond one Node instance? (The Socket.io **Redis adapter** broadcasts events across instances.) What happens on deploy? (Clients reconnect, so stagger them with jitter.) Also: ChatGPT-style **LLM token streaming uses SSE**, which fits your AI work (Spring `SseEmitter` or WebFlux `Flux<ServerSentEvent>`).

#### Interview questions
?? When would you choose SSE over WebSockets?
When updates flow only from server to client (notifications, live scores, dashboards, LLM streaming). SSE is plain HTTP (works with existing infrastructure, auth headers and HTTP/2 multiplexing), has automatic reconnection and resume via `Last-Event-ID`, and is simpler to operate. Choose WebSockets when the client also sends frequent messages (chat, collaborative editing, games).

?? How do you scale WebSocket servers horizontally?
Make the servers stateless apart from their connections: keep a mapping of user to connection-server (in Redis), or broadcast through pub/sub (Redis, Kafka, NATS) so each server forwards messages to its local connections. Use L7 load balancers that support upgrades and long timeouts, heartbeats, graceful draining on deploy, and jittered reconnect logic on clients.

#### Tricky questions
?? Your SSE stream works locally but behind Nginx events arrive in bursts. Why?
Proxy **response buffering**: Nginx buffers the upstream response before sending it. Disable it for SSE (`proxy_buffering off;` or the `X-Accel-Buffering: no` header), and turn off gzip buffering and compression for the stream.

#### Interview simulation
If asked "Design live order tracking for a delivery app": clarify the update frequency (every 2–5s), the number of concurrent viewers, and whether it's mobile. Propose: the driver app sends GPS over HTTP or MQTT to an ingestion service → Kafka → the tracking service updates Redis (latest location) → customers subscribe via WebSocket/SSE to a gateway that fans out per order id through Redis Pub/Sub. Push notifications for app-backgrounded states, plus a polling fallback. Discuss battery, reconnects and why not to poll every second.

### Load balancing, proxies and NAT

#### Core idea
- A **load balancer** distributes traffic across multiple servers for scale and availability.
- A **forward proxy** acts for **clients** (corporate egress proxy, hiding client identity). A **reverse proxy** acts for **servers** (Nginx or Envoy in front of your apps: TLS termination, caching, routing).
- **NAT** (Network Address Translation) lets many private IPs share one public IP.

#### How it works
**L4 vs L7 load balancing**
| | L4 (transport) | L7 (application) |
|---|---|---|
| Sees | IP, port, TCP/UDP | HTTP method, path, host, headers, cookies |
| Can do | forward connections, very fast, TLS passthrough | path/host routing, TLS termination, retries, header rewrite, auth, rate limiting, canary by header |
| Examples | AWS NLB, LVS, Maglev | AWS ALB, Nginx, HAProxy, Envoy, API gateways |

**Algorithms**: round robin, weighted round robin, **least connections / least outstanding requests** (good for varied request costs), IP hash (session affinity), **consistent hashing** (cache locality), random with two choices ("power of two choices": pick 2 random servers and send to the less loaded, which is nearly optimal and cheap), and latency-aware (EWMA).

**Health checks**: active (LB probes `/health` periodically) vs passive (outlier detection: eject a backend after N errors). Separate **liveness** (restart me) from **readiness** (send me traffic).

**Sticky sessions**: route a client to the same backend (cookie or IP hash). Needed for stateful servers, but they hurt even distribution and failover, so prefer stateless servers with session state in Redis or a JWT.

**Global load balancing**: GeoDNS, anycast (the same IP announced from many locations; BGP routes users to the nearest: Cloudflare, Google), AWS Global Accelerator.

**NAT**: a private subnet's outbound traffic goes through a NAT gateway, which rewrites the source IP and port. The NAT keeps a translation table, so it has connection limits and idle timeouts (AWS NAT gateway: 350s idle timeout, which breaks long-idle pooled connections → set keep-alive or max-lifetime below it). Inbound connections to private hosts aren't possible without explicit port forwarding or a load balancer.

#### Real-world example
A typical AWS setup like your NeuronixAI deployment: Route 53 → **ALB** (L7, TLS via ACM certificates, path routing `/api/*` → ECS service target group, health checks on `/actuator/health/readiness`) → ECS Fargate tasks in private subnets → outbound calls to OpenAI through a **NAT gateway**. Knowing that the NAT idle timeout can silently kill pooled HTTP connections is the kind of detail senior interviewers love.

#### Interview questions
?? L4 vs L7 load balancer: when would you use each?
L4 for raw performance, non-HTTP protocols (databases, MQTT, gaming over UDP), TLS passthrough, or very high connection counts. L7 for HTTP microservices: content-based routing, TLS termination, observability, retries, canary releases, auth at the edge. Large systems often put L4 in front of a fleet of L7 proxies.

?? Which load-balancing algorithm would you choose and why?
Round robin for identical servers with uniform requests. Least outstanding requests (or P2C) for varied request costs or heterogeneous servers. Consistent hashing when routing affects cache locality (cache servers, sharded state). Avoid sticky sessions unless necessary.

?? Reverse proxy vs load balancer vs API gateway?
A reverse proxy sits in front of servers (TLS, caching, compression, routing). A load balancer is a reverse proxy whose main job is spreading load with health checks. An API gateway is an L7 reverse proxy with API-specific features: authentication, rate limiting, request transformation, API keys and quotas, aggregation. The lines blur (Envoy can be all three).

#### Tricky questions
?? Why might one backend get much more traffic than others even with round robin?
Long-lived connections (HTTP/2, gRPC, WebSockets) are balanced per connection, not per request, so whichever backend got the long-lived connections takes their load. Also, new instances added after the connections were established get nothing, and client-side DNS caching pins clients to old IPs. Fix with L7 per-request balancing, connection max-age, or client-side load balancing.

?? How does the backend know the real client IP behind a load balancer?
L7: the `X-Forwarded-For` header (trust only the entries added by your own proxies; clients can spoof the left-most values). L4: the **PROXY protocol** header, or preserving the source IP. In Spring, `server.forward-headers-strategy=native` or framework handles it.

#### Interview simulation
If asked "Users report intermittent 502 errors behind the ALB": clarify the frequency, whether it correlates with deploys, and which endpoints. Causes: backend keep-alive timeout **shorter** than the ALB idle timeout (the backend closes an idle connection just as the ALB sends a request on it, giving a 502; fix: backend keep-alive > ALB idle timeout), deploys without graceful draining (connections killed mid-request; fix: deregistration delay plus graceful shutdown and preStop), crashing or OOM-killed tasks, and health checks too lenient. That keep-alive mismatch detail is gold.

### CORS

#### Core idea
**CORS (Cross-Origin Resource Sharing)** is a browser mechanism that relaxes the **Same-Origin Policy**. By default, JavaScript on `https://app.acme.com` can't read responses from `https://api.acme.com` (a different origin: scheme + host + port). The server opts in by sending `Access-Control-Allow-*` headers. **CORS is enforced by browsers, not servers**: it protects users, not your API.

#### How it works
- **Simple requests** (GET/HEAD/POST with simple headers and content types like `application/x-www-form-urlencoded`): the browser sends the request with an `Origin` header and only lets JS read the response if it includes `Access-Control-Allow-Origin` matching the origin (or `*`).
- **Preflighted requests** (PUT/DELETE/PATCH, `Content-Type: application/json`, custom headers like `Authorization`): the browser first sends an **OPTIONS** request:
```
OPTIONS /v1/orders
Origin: https://app.acme.com
Access-Control-Request-Method: POST
Access-Control-Request-Headers: authorization, content-type

← 204
Access-Control-Allow-Origin: https://app.acme.com
Access-Control-Allow-Methods: GET, POST, PUT, DELETE
Access-Control-Allow-Headers: authorization, content-type
Access-Control-Max-Age: 600          (cache preflight 10 min)
```
- **Credentials** (cookies): require `Access-Control-Allow-Credentials: true` and a **specific origin**, never `*`.
- In Spring: `@CrossOrigin`, or a global `CorsConfigurationSource` bean (with Spring Security, enable `http.cors()` so preflights aren't blocked by authentication).

#### Real-world example
A frontend team reports "the API is broken" because the browser shows a CORS error, while `curl` works fine. The cause: the Spring Security filter chain rejected the OPTIONS preflight with 401 because it had no `Authorization` header (browsers never send credentials on preflights). The fix: enable CORS in the security config so preflights are answered before authentication. Common in every SPA + Spring project.

#### Interview questions
?? What is CORS and why does it exist?
The browser's Same-Origin Policy stops scripts on one site from reading data from another site using the user's cookies (otherwise evil.com could read your bank's API responses). CORS is the controlled exception: the API declares which origins, methods and headers are allowed, and the browser enforces it.

?? Why does my API work in Postman or curl but not from the browser?
CORS is only enforced by browsers. Non-browser clients ignore it. The browser blocks the response (or the preflight fails) because the server didn't return the right `Access-Control-Allow-*` headers.

#### Tricky questions
?? Does CORS protect your API from unauthorised access?
No. Any non-browser client (curl, server-side scripts) can call your API regardless of CORS. CORS only controls which web origins' JavaScript can read responses in users' browsers. API security comes from authentication and authorisation.

?? Can you use `Access-Control-Allow-Origin: *` with cookies?
No. Browsers reject credentialed requests with a wildcard origin. You must echo the specific allowed origin (validated against an allowlist; never blindly reflect any `Origin`, which is a security hole) and set `Allow-Credentials: true`.

#### Interview simulation
If asked to debug a CORS error: open the browser console and network tab, check whether it's the preflight (OPTIONS) or the actual request that fails, compare the response headers with the request's `Origin`, method and headers, check that the security config permits OPTIONS without auth, and check whether credentials and a wildcard are mixed. A systematic check beats random header changes.
