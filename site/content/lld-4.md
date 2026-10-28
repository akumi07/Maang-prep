## LLD problems III | P3 | must

### Food delivery (Swiggy / Zomato)

#### Clarifying questions to ask
- *Actors?* → Customer, restaurant, delivery partner, admin.
- *Core flow?* → Browse restaurants and menus → cart (single restaurant) → place order → restaurant accepts and prepares → assign a delivery partner → pick up → deliver.
- *Payment?* → Online or COD; online payment before the order is sent to the restaurant.
- *Partner assignment rule?* → The nearest available partner to the restaurant; consider prep time.
- *Cancellations and refunds?* → Allowed before the restaurant accepts (full refund); a policy after that.
- *Order tracking?* → Status updates to the customer.

#### Requirements (agreed scope)
1. Search restaurants (by location, cuisine); view the menu with availability.
2. A cart with items from **one** restaurant; price with taxes, delivery fee and coupons.
3. Place an order → payment → the restaurant accepts or rejects.
4. Assign a delivery partner; track status through the state machine.
5. Notify the customer on every status change.

#### Entities and class diagram
```
Customer(id, addresses)  Restaurant(id, location, isOpen, menu: List<MenuItem>)  MenuItem(id, name, pricePaise, available)
Cart(customerId, restaurantId, items: Map<itemId, qty>)
Order(id, customerId, restaurantId, items, amounts{subtotal, tax, deliveryFee, discount, total}, status, partnerId?)
OrderStatus: PLACED → PAID → ACCEPTED → PREPARING → READY_FOR_PICKUP → PICKED_UP → DELIVERED ; CANCELLED/REJECTED
DeliveryPartner(id, location, status{AVAILABLE, BUSY, OFFLINE})
PricingService(+ CouponStrategy) ; AssignmentStrategy ; OrderService ; NotificationService(Observer)
```

#### Key design decisions
- **Order state machine** with an explicit transition table, so illegal transitions (deliver before pickup) fail.
- **Observer**: status changes publish events to notification, analytics and partner-assignment listeners.
- **Strategy** for partner assignment (nearest, or batching orders from the same restaurant) and for coupons.
- **Price snapshot**: order items copy name and price at order time.
- Assign the partner when the order is **accepted** (not placed), timed against the prep time so the rider arrives as the food gets ready.

#### Core code
```java
enum OrderStatus { PLACED, PAID, ACCEPTED, PREPARING, READY_FOR_PICKUP, PICKED_UP, DELIVERED, CANCELLED, REJECTED;
    private static final Map<OrderStatus, Set<OrderStatus>> NEXT = Map.of(
        PLACED, Set.of(PAID, CANCELLED), PAID, Set.of(ACCEPTED, REJECTED, CANCELLED),
        ACCEPTED, Set.of(PREPARING, CANCELLED), PREPARING, Set.of(READY_FOR_PICKUP),
        READY_FOR_PICKUP, Set.of(PICKED_UP), PICKED_UP, Set.of(DELIVERED),
        DELIVERED, Set.of(), CANCELLED, Set.of(), REJECTED, Set.of());
    boolean canMoveTo(OrderStatus n) { return NEXT.get(this).contains(n); }
}
record OrderLine(String itemId, String name, long unitPricePaise, int qty) { long total() { return unitPricePaise * qty; } }
record MenuItem(String id, String name, long pricePaise, boolean available) {}
interface MenuRepository { boolean isOpen(String restaurantId); MenuItem item(String restaurantId, String itemId); }
interface PartnerLocator { List<DeliveryPartner> nearestAvailable(String restaurantId, int limit); }
final class DeliveryPartner {
    private final String id; private final AtomicReference<String> currentOrder = new AtomicReference<>(null);
    DeliveryPartner(String id) { this.id = id; }
    String id() { return id; }
    boolean tryAssign(String orderId) { return currentOrder.compareAndSet(null, orderId); }   // atomic claim
    void complete() { currentOrder.set(null); }
}

final class Order {
    final String id, customerId, restaurantId; final List<OrderLine> lines; final long totalPaise;
    private OrderStatus status = OrderStatus.PLACED; String partnerId;
    Order(String id, String c, String r, List<OrderLine> lines, long total) { this.id = id; customerId = c; restaurantId = r; this.lines = List.copyOf(lines); totalPaise = total; }
    synchronized OrderStatus transition(OrderStatus to) {
        if (!status.canMoveTo(to)) throw new IllegalStateException(status + " -> " + to + " not allowed");
        OrderStatus from = status; status = to; return from;
    }
    synchronized OrderStatus status() { return status; }
}

interface OrderEventListener { void onStatusChange(Order o, OrderStatus from, OrderStatus to); }

interface CouponStrategy { long discount(long subtotal, String customerId); }
class FlatOffAboveMin implements CouponStrategy {
    private final long minPaise, offPaise; FlatOffAboveMin(long min, long off) { minPaise = min; offPaise = off; }
    public long discount(long subtotal, String c) { return subtotal >= minPaise ? offPaise : 0; }
}

class OrderService {
    private final Map<String, Order> orders = new ConcurrentHashMap<>();
    private final List<OrderEventListener> listeners = new CopyOnWriteArrayList<>();
    private final MenuRepository menus;
    OrderService(MenuRepository menus) { this.menus = menus; }
    void addListener(OrderEventListener l) { listeners.add(l); }

    public Order place(String customerId, String restaurantId, Map<String, Integer> cart, CouponStrategy coupon) {
        if (!menus.isOpen(restaurantId)) throw new IllegalStateException("Restaurant closed");
        List<OrderLine> lines = cart.entrySet().stream().map(e -> {
            MenuItem item = menus.item(restaurantId, e.getKey());
            if (!item.available()) throw new IllegalStateException(item.name() + " unavailable");
            return new OrderLine(item.id(), item.name(), item.pricePaise(), e.getValue());       // price snapshot
        }).toList();
        long subtotal = lines.stream().mapToLong(OrderLine::total).sum();
        long tax = subtotal * 5 / 100, delivery = subtotal >= 19900 ? 0 : 3000;
        long total = Math.max(0, subtotal + tax + delivery - (coupon == null ? 0 : coupon.discount(subtotal, customerId)));
        Order o = new Order(UUID.randomUUID().toString(), customerId, restaurantId, lines, total);
        orders.put(o.id, o); return o;
    }
    public void move(String orderId, OrderStatus to) {
        Order o = orders.get(orderId); OrderStatus from = o.transition(to);
        listeners.forEach(l -> { try { l.onStatusChange(o, from, to); } catch (RuntimeException e) { /* isolate listener failures */ } });
    }
}

/** assigns nearest available partner when restaurant accepts */
class PartnerAssigner implements OrderEventListener {
    private final PartnerLocator locator; private final OrderService orders;
    PartnerAssigner(PartnerLocator l, OrderService o) { locator = l; orders = o; }
    public void onStatusChange(Order o, OrderStatus from, OrderStatus to) {
        if (to != OrderStatus.ACCEPTED) return;
        for (DeliveryPartner p : locator.nearestAvailable(o.restaurantId, 5)) {
            if (p.tryAssign(o.id)) { o.partnerId = p.id(); return; }       // CAS on partner status
        }
        // none free: enqueue for retry (scheduled re-attempt / widen radius)
    }
}
```

#### Concurrency and edge cases
- Order transitions are synchronised per order: a restaurant "accept" racing a customer "cancel" means one wins, and the other gets a clear error.
- Partner double-assignment is prevented by a CAS on the partner status (the same as the cab design).
- Payment callback duplicates: an idempotent `PLACED → PAID` (the second attempt fails the transition check, which we treat as a no-op for the same payment id).
- An item becomes unavailable after the order is placed: the restaurant can mark items unavailable, leading to a partial refund or a rejection.

#### Extensions the interviewer may add
?? "Batch two orders from the same restaurant to one rider."
An `AssignmentStrategy` that checks whether an assigned rider en route to the same restaurant has capacity, and whether both drops are close (a detour cost under a threshold) and the prep times align. That's an optimisation layer on top of the same interfaces.

?? "Show an ETA to the customer."
ETA = max(prep time remaining, rider-to-restaurant travel) + restaurant-to-customer travel, using a routing service plus historical data. Update it on each status or location event and push it to the customer over WebSocket/SSE.

?? "How do the restaurant, rider and customer apps get updates?"
Status events published to a broker (Kafka); a notification service pushes through FCM/APNs; live screens subscribe over WebSocket. The LLD Observer becomes distributed pub/sub in HLD.

#### Interview simulation
Clarify the actors and the flow, then draw the **order state machine** first (it anchors everything). Code: price calculation with a snapshot, the transition table, the observer fan-out, and partner assignment on ACCEPTED. Demo the order lifecycle with a coupon and a cancellation attempt after pickup (rejected). Mention where your design would split into microservices (order, restaurant, delivery, payment, notification) to bridge to HLD.

### Inventory and order management

#### Clarifying questions to ask
- *Single warehouse or many?* → Multiple warehouses; fulfil from the nearest one with stock.
- *Reserve stock at add-to-cart, or at order placement?* → At placement (checkout), with a reservation expiry if payment doesn't complete.
- *Partial fulfilment?* → An order may be split across warehouses (extension).
- *Restocking and low-stock alerts?* → Yes, alert below a threshold.
- *Flash sales?* → A high-contention case to discuss.

#### Requirements (agreed scope)
1. Track stock per (SKU, warehouse): on-hand, reserved, available = on-hand − reserved.
2. Reserve stock for an order (all lines or none) with a TTL; confirm on payment; release on failure or expiry.
3. Ship: deduct on-hand on dispatch.
4. Restock; low-stock alerts.
5. No overselling under concurrency.

#### Entities and class diagram
```
Sku(id, name)  Warehouse(id, location)
StockLevel(skuId, warehouseId, onHand, reserved, version)  → available = onHand - reserved
Reservation(id, orderId, lines: [(sku, warehouse, qty)], expiresAt, status{ACTIVE, CONFIRMED, RELEASED, EXPIRED})
InventoryService: reserve(orderId, lines) ; confirm(resId) ; release(resId) ; ship(orderId) ; restock(sku, wh, qty)
WarehouseSelectionStrategy: NearestWithFullStock, SplitAcrossWarehouses
StockAlertListener (Observer)
```

#### Key design decisions
- Separate **reserved** from **on-hand**: reserving doesn't remove items physically; it removes them from **available**.
- **All-or-nothing multi-line reservation**: lock the stock rows in a **consistent order** (sorted by SKU) to avoid deadlocks; check all lines, then apply.
- **Reservation TTL**: abandoned checkouts must give stock back (an expiry sweeper, lazily enforced).
- In SQL: `UPDATE stock SET reserved = reserved + :q WHERE sku = :s AND wh = :w AND on_hand - reserved >= :q` per line in one transaction, rolling back if any line updates 0 rows.

#### Core code
```java
final class StockLevel {
    final String sku, wh; int onHand, reserved; final ReentrantLock lock = new ReentrantLock();
    StockLevel(String sku, String wh, int onHand) { this.sku = sku; this.wh = wh; this.onHand = onHand; }
    int available() { return onHand - reserved; }
    String key() { return sku + "@" + wh; }
}
record Line(String sku, String wh, int qty) {}
class InsufficientStockException extends RuntimeException { InsufficientStockException(String sku) { super("Insufficient stock: " + sku); } }
enum ResStatus { ACTIVE, CONFIRMED, RELEASED, EXPIRED }
final class Reservation { final String id, orderId; final List<Line> lines; final Instant expiresAt; volatile ResStatus status = ResStatus.ACTIVE;
    Reservation(String id, String orderId, List<Line> lines, Instant exp) { this.id = id; this.orderId = orderId; this.lines = lines; expiresAt = exp; } }

class InventoryService {
    private final Map<String, StockLevel> stock = new ConcurrentHashMap<>();
    private final Map<String, Reservation> reservations = new ConcurrentHashMap<>();
    private final Clock clock; private final Duration ttl = Duration.ofMinutes(15); private final Consumer<StockLevel> lowStockAlert;
    InventoryService(Clock c, Consumer<StockLevel> alert) { clock = c; lowStockAlert = alert; }

    public Reservation reserve(String orderId, List<Line> lines) {
        List<StockLevel> rows = lines.stream().map(l -> stock.get(l.sku() + "@" + l.wh()))
            .sorted(Comparator.comparing(StockLevel::key)).distinct().toList();       // consistent lock order → no deadlock
        rows.forEach(r -> r.lock.lock());
        try {
            for (Line l : lines) if (stock.get(l.sku() + "@" + l.wh()).available() < l.qty())
                throw new InsufficientStockException(l.sku());                         // all-or-nothing
            for (Line l : lines) stock.get(l.sku() + "@" + l.wh()).reserved += l.qty();
        } finally { rows.forEach(r -> r.lock.unlock()); }
        Reservation res = new Reservation(UUID.randomUUID().toString(), orderId, List.copyOf(lines), clock.instant().plus(ttl));
        reservations.put(res.id, res); return res;
    }

    public void confirm(String resId) { transition(resId, ResStatus.CONFIRMED, false); }   // payment ok: keep reserved until ship
    public void release(String resId) { transition(resId, ResStatus.RELEASED, true); }

    public void ship(String resId) {
        Reservation r = reservations.get(resId);
        if (r.status != ResStatus.CONFIRMED) throw new IllegalStateException("Not confirmed");
        for (Line l : r.lines) { StockLevel s = stock.get(l.sku() + "@" + l.wh()); s.lock.lock();
            try { s.reserved -= l.qty(); s.onHand -= l.qty(); if (s.available() < 10) lowStockAlert.accept(s); } finally { s.lock.unlock(); } }
    }

    /** run every minute */
    public void expireStale() {
        Instant now = clock.instant();
        reservations.values().stream().filter(r -> r.status == ResStatus.ACTIVE && r.expiresAt.isBefore(now))
            .forEach(r -> transition(r.id, ResStatus.EXPIRED, true));
    }

    private void transition(String resId, ResStatus to, boolean giveBack) {
        Reservation r = reservations.get(resId);
        synchronized (r) {
            if (r.status != ResStatus.ACTIVE) return;                                  // idempotent
            r.status = to;
        }
        if (giveBack) for (Line l : r.lines) { StockLevel s = stock.get(l.sku() + "@" + l.wh()); s.lock.lock();
            try { s.reserved -= l.qty(); } finally { s.lock.unlock(); } }
    }
}
```

#### Concurrency and edge cases
- Locks are acquired in sorted key order across lines, so two orders with overlapping SKUs can't deadlock.
- Payment confirmation arrives after the reservation expired: `confirm` finds it EXPIRED, so try to re-reserve, or refund. The same race as BookMyShow.
- Idempotent transitions (the status check under the reservation's monitor).
- Negative stock must be impossible: assert it in tests; in a DB, add a CHECK constraint `on_hand >= reserved AND reserved >= 0`.

#### Extensions the interviewer may add
?? "Flash sale: 100k users, 500 units. How do you avoid DB meltdown?"
Move the hot counter to **Redis**: `DECRBY` via a Lua script that checks available ≥ qty (atomic, about 100k ops/s), issue reservation tokens, and write orders to the DB asynchronously through a queue. Add a virtual waiting room or rate limiting at the edge, and per-user purchase limits. Reconcile Redis and DB stock afterwards.

?? "Choose the warehouse for an order."
A `WarehouseSelectionStrategy`: nearest with full stock (fewest shipments), otherwise a split across warehouses minimising cost (distance × shipments), constrained by SLAs. A simple greedy works for the interview.

?? "Inventory counts drift from reality. How do you keep them correct?"
An append-only **stock movement ledger** (received, reserved, released, shipped, adjusted) as the source of truth; derived quantities can be recomputed; periodic cycle counts produce adjustment entries; alerts on anomalies.

#### Interview simulation
Lead with the model: "Available = on-hand minus reserved. Checkout reserves with a TTL; payment confirms; dispatch deducts." Then the concurrency strategy (sorted locking or conditional SQL updates). Code reserve, confirm, release, ship and expiry, and demo two concurrent orders for the last unit. Close with the flash-sale Redis approach. This is the backbone of the BookMyShow, Amazon and Flipkart cart questions.

### Hotel booking system

#### Clarifying questions to ask
- *Search by city and dates?* → Yes: availability per room type for a date range.
- *Book specific rooms or room types?* → Room **types** (the hotel assigns the actual room at check-in). That's how real systems work.
- *Overbooking allowed?* → Usually no for the interview (some hotels overbook by a percentage).
- *Cancellation policy and refunds?* → Free until 24h before; otherwise a fee.
- *Payment hold?* → Hold inventory briefly while paying.

#### Requirements (agreed scope)
1. Search: available count per room type for check-in to check-out.
2. Book N rooms of a type for a date range; no overbooking under concurrency.
3. Cancel with a policy; release the inventory.
4. Pricing per night (weekend or seasonal rates via strategy).

#### Entities and class diagram
```
Hotel(id, city)  RoomType(id, hotelId, name, totalRooms)
Inventory(hotelId, roomTypeId, date, total, booked)   ← one row per night per type (the key modelling choice)
Booking(id, guestId, hotelId, roomTypeId, checkIn, checkOut, rooms, amount, status{HELD, CONFIRMED, CANCELLED})
PricingStrategy(nightlyRate(roomType, date))  CancellationPolicy(refund(booking, now))
BookingService: search, hold, confirm, cancel
```

#### Key design decisions
- **Inventory per (room type, night)**: a booking for 3 nights must reserve each of the 3 rows. That makes availability queries a simple `MIN(total - booked)` over the range.
- **All nights or none**, locked in date order (no deadlocks).
- In SQL: `UPDATE inventory SET booked = booked + :n WHERE hotel=? AND type=? AND date >= :in AND date < :out AND total - booked >= :n` and check that affected rows = number of nights; otherwise roll back.
- Check-out date exclusive: the night of check-out isn't consumed.

#### Core code
```java
record NightKey(String roomTypeId, LocalDate date) implements Comparable<NightKey> {
    public int compareTo(NightKey o) { int c = roomTypeId.compareTo(o.roomTypeId); return c != 0 ? c : date.compareTo(o.date); }
}
final class Night { final int total; int booked; Night(int total) { this.total = total; } int free() { return total - booked; } }

class HotelInventory {
    private final ConcurrentHashMap<NightKey, Night> nights = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<NightKey, ReentrantLock> locks = new ConcurrentHashMap<>();
    HotelInventory(Map<String, Integer> roomsPerType, LocalDate from, int days) {
        roomsPerType.forEach((type, total) -> { for (int i = 0; i < days; i++) nights.put(new NightKey(type, from.plusDays(i)), new Night(total)); });
    }
    private List<NightKey> keys(String type, LocalDate in, LocalDate out) {
        if (!out.isAfter(in)) throw new IllegalArgumentException("check-out must be after check-in");
        return in.datesUntil(out).map(d -> new NightKey(type, d)).toList();        // sorted ascending by date
    }
    public int available(String type, LocalDate in, LocalDate out) {
        return keys(type, in, out).stream().mapToInt(k -> nights.get(k).free()).min().orElse(0);
    }
    public boolean reserve(String type, LocalDate in, LocalDate out, int rooms) {
        List<NightKey> ks = keys(type, in, out);
        List<ReentrantLock> held = new ArrayList<>();
        try {
            for (NightKey k : ks) { ReentrantLock l = locks.computeIfAbsent(k, x -> new ReentrantLock()); l.lock(); held.add(l); }
            if (ks.stream().anyMatch(k -> nights.get(k).free() < rooms)) return false;   // all-or-nothing
            ks.forEach(k -> nights.get(k).booked += rooms);
            return true;
        } finally { held.forEach(ReentrantLock::unlock); }
    }
    public void release(String type, LocalDate in, LocalDate out, int rooms) {
        for (NightKey k : keys(type, in, out)) { ReentrantLock l = locks.computeIfAbsent(k, x -> new ReentrantLock()); l.lock();
            try { nights.get(k).booked -= rooms; } finally { l.unlock(); } }
    }
}

interface PricingStrategy { long nightly(String roomType, LocalDate date); }
class WeekendPricing implements PricingStrategy {
    private final Map<String, Long> base; WeekendPricing(Map<String, Long> base) { this.base = base; }
    public long nightly(String type, LocalDate d) {
        long b = base.get(type); DayOfWeek w = d.getDayOfWeek();
        return (w == DayOfWeek.FRIDAY || w == DayOfWeek.SATURDAY) ? b * 120 / 100 : b;
    }
}
```

#### Concurrency and edge cases
- Per-night locks are acquired in ascending date order, so overlapping bookings can't deadlock.
- Date validation: past dates, check-out ≤ check-in, the maximum stay length.
- **Holds**: reserve at the start of checkout with a TTL (as in inventory management); confirm on payment; release on expiry.
- Cancellation releases exactly the reserved nights; the refund comes from `CancellationPolicy`.

#### Extensions the interviewer may add
?? "How do OTAs like Booking.com or MakeMyTrip sync availability with hotels?"
Hotels manage inventory in a PMS or channel manager, which pushes availability and rates to the OTAs (ARI updates). OTAs cache it and confirm bookings with the hotel's system (sometimes asynchronously), so race conditions are handled by confirmation and rejection plus overbooking buffers. In an interview, mention that the source of truth lives outside your system.

?? "Allow overbooking by 5%."
Treat `total` as physical rooms and allow `booked ≤ total × 1.05` via an `OverbookingPolicy` strategy. Walk-out compensation is a business process.

?? "Search across 10,000 hotels in a city for dates fast."
Precompute availability into a search index (Elasticsearch or a cache) updated on every booking event; the search shows approximate availability, and the booking step re-checks against the source of truth.

#### Interview simulation
Clarify "room type vs specific room" early. The insight interviewers want: **inventory per night per room type**, with all nights reserved atomically. Code `available`, `reserve` (sorted locks) and pricing, then demo two overlapping bookings competing for the last room on one night. Give the SQL version too, since it shows you can move from in-memory to a real database.

### Notification service

#### Clarifying questions to ask
- *Channels?* → Email, SMS, push (FCM/APNs), WhatsApp, in-app.
- *Triggered by?* → Other services calling an API or publishing events (order placed, OTP, marketing).
- *User preferences and opt-outs?* → Yes, per channel and category; quiet hours.
- *Templates and localisation?* → Template ids with variables; language per user.
- *Priorities?* → OTP and transactional messages must go out fast; marketing can wait.
- *Retries and provider failover?* → Yes; a fallback provider for SMS.
- *Rate limits?* → Per user (don't spam) and per provider (their quotas).

#### Requirements (agreed scope)
1. `send(NotificationRequest)` with a userId, template, params, channels and priority.
2. Respect preferences and quiet hours; deduplicate.
3. Render templates; dispatch through channel providers.
4. Retry with backoff; fail over to an alternate provider; track status.
5. Extensible: new channels and providers without core changes.

#### Entities and class diagram
```
NotificationRequest(id/idempotencyKey, userId, templateId, params, channels, priority, category)
Template(id, channel, locale, subject, body)   UserPreferences(userId, optedOut: Set<(category, channel)>, quietHours, locale)
NotificationService: send(req) → validates, filters by preferences, renders, enqueues per channel/priority
ChannelSender (interface): channel(), send(RenderedMessage) → DeliveryResult
   ← EmailSender, SmsSender, PushSender ; SmsSender wraps List<SmsProvider> (failover chain)
DeliveryRecord(notificationId, channel, status{QUEUED, SENT, FAILED, DELIVERED}, attempts, providerMessageId)
```

#### Key design decisions
- **Strategy per channel** (`ChannelSender`), registered in a map: adding WhatsApp means one new class.
- **Template Method / renderer** separates content from delivery.
- **Priority queues**: OTP isn't stuck behind 1M marketing emails. Use separate queues or topics per priority, each with its own workers.
- **Idempotency key** dedupes retries from callers.
- **Chain of providers** for failover (primary SMS provider down, try the secondary).
- **Async**: the API enqueues and returns 202; workers deliver.

#### Core code
```java
enum Channel { EMAIL, SMS, PUSH }
enum Priority { HIGH, LOW }
record NotificationRequest(String idempotencyKey, String userId, String templateId, Map<String, String> params,
                           Set<Channel> channels, Priority priority, String category) {}
record Rendered(String userId, Channel channel, String to, String subject, String body, String notificationId) {}
interface UserPreferences { boolean optedOut(String category, Channel ch); boolean inQuietHours(Instant now); String locale(); }
interface PreferenceStore { UserPreferences get(String userId); }                  // cached (Redis) in production
interface TemplateRenderer { Rendered render(NotificationRequest req, Channel ch, UserPreferences prefs); }   // looks up template by id+channel+locale

interface ChannelSender { Channel channel(); void send(Rendered m) throws Exception; }

interface SmsProvider { String name(); void send(String phone, String text) throws Exception; }
class SmsSender implements ChannelSender {                       // failover across providers
    private final List<SmsProvider> providers; SmsSender(List<SmsProvider> p) { providers = p; }
    public Channel channel() { return Channel.SMS; }
    public void send(Rendered m) throws Exception {
        Exception last = null;
        for (SmsProvider p : providers) { try { p.send(m.to(), m.body()); return; } catch (Exception e) { last = e; } }
        throw last;
    }
}

class NotificationService {
    private final Map<Channel, ChannelSender> senders; private final PreferenceStore prefs; private final TemplateRenderer renderer;
    private final Set<String> seenKeys = ConcurrentHashMap.newKeySet();                 // prod: Redis SET NX with TTL / DB unique key
    private final Map<Priority, BlockingQueue<Rendered>> queues = Map.of(
        Priority.HIGH, new LinkedBlockingQueue<>(), Priority.LOW, new LinkedBlockingQueue<>(100_000));

    NotificationService(List<ChannelSender> s, PreferenceStore p, TemplateRenderer r) {
        senders = s.stream().collect(Collectors.toMap(ChannelSender::channel, x -> x)); prefs = p; renderer = r;
        startWorkers(Priority.HIGH, 8); startWorkers(Priority.LOW, 2);
    }

    public String send(NotificationRequest req) {
        if (!seenKeys.add(req.idempotencyKey())) return "DUPLICATE";
        UserPreferences up = prefs.get(req.userId());
        for (Channel ch : req.channels()) {
            if (up.optedOut(req.category(), ch)) continue;
            if (req.priority() == Priority.LOW && up.inQuietHours(Instant.now())) continue;   // or schedule for later
            Rendered msg = renderer.render(req, ch, up);
            if (!queues.get(req.priority()).offer(msg)) throw new IllegalStateException("Queue full, retry later");
        }
        return "QUEUED";
    }

    private void startWorkers(Priority p, int n) {
        for (int i = 0; i < n; i++) Thread.ofVirtual().start(() -> {
            BlockingQueue<Rendered> q = queues.get(p);
            while (true) {
                try { deliverWithRetry(q.take()); } catch (InterruptedException e) { return; }
            }
        });
    }
    private void deliverWithRetry(Rendered m) throws InterruptedException {
        for (int attempt = 1; attempt <= 3; attempt++) {
            try { senders.get(m.channel()).send(m); /* record SENT */ return; }
            catch (Exception e) { Thread.sleep((long) (200 * Math.pow(2, attempt) * (0.5 + Math.random()))); }
        }
        // record FAILED → dead-letter for inspection / alternate channel
    }
}
```

#### Concurrency and edge cases
- Separate worker pools per priority stop marketing floods from starving OTPs.
- Per-provider rate limits: a token bucket in each sender (providers like Twilio limit requests per second).
- **Duplicate sends** from caller retries are caught by the idempotency key. At-least-once delivery from workers means rare duplicates are possible; that's acceptable for most notifications, but not for OTPs, which you track by id.
- Delivery receipts (provider webhooks) update `DeliveryRecord` to DELIVERED or BOUNCED; hard bounces disable that address.

#### Extensions the interviewer may add
?? "Scale to 100 million notifications a day."
Make it distributed: the API writes to Kafka topics per priority and channel; stateless worker fleets consume, render and send; preferences cached in Redis; a status store (Cassandra/DynamoDB); per-provider rate limiting; scheduled sends via a delayed queue. This becomes the HLD "notification system" problem.

?? "Add a digest (batch 10 low-priority notifications into one email)."
A `DigestAggregator` buffers LOW-priority items per user for a window (e.g. 1 hour), then emits one rendered message. A new pipeline stage, without touching the senders.

?? "A user complains they didn't receive an OTP."
Trace by request id: was the request received? Filtered by preferences (never for transactional messages)? Queued? Which provider was used, and what did it respond? Is there a delivery receipt? That's why every stage records status.

#### Interview simulation
Clarify the channels, priorities, preferences and reliability. Draw the pipeline: **API → validate/dedupe → preferences → render → priority queue → channel worker → provider (with failover) → status tracking**. Code the sender strategy, provider failover, priority queues and retry. Mention async 202 responses and idempotency. Interviewers appreciate the pipeline view, because it maps directly to the distributed HLD version.

### Key-value store with TTL

#### Clarifying questions to ask
- *Operations?* → `put(key, value, ttl?)`, `get`, `delete`; maybe `incr`.
- *Expiry semantics?* → An expired key behaves as absent; memory must eventually be reclaimed.
- *Concurrency?* → Many threads.
- *Memory bound and eviction?* → Max entries with LRU eviction (extension).
- *Persistence?* → Optional: snapshots or an append-only log (extension, Redis-like).

#### Requirements (agreed scope)
1. Thread-safe get/put/delete with optional TTL.
2. An expired key is never returned.
3. Expired keys are cleaned up without scanning everything constantly.
4. Optional max size with LRU eviction.
5. Optional transactions or atomic increments (discussion).

#### Entities and class diagram
```
KVStore<K,V>: put(k, v, ttl?) ; get(k) ; delete(k) ; size()
Entry(value, expiresAtNanos)    Clock (injectable)
Expirer: background cleanup — sampled (Redis-style) or DelayQueue-based
```

#### Key design decisions
- **Lazy expiry on read** (correctness: never return expired data) + **active cleanup** (reclaim memory):
  - Redis approach: periodically **sample** 20 random keys that have TTLs and delete the expired ones; repeat if more than 25% were expired. Cheap, probabilistic.
  - Deterministic approach: a `DelayQueue` (or min-heap) of (expiry, key). A cleaner thread takes items as they become due and deletes the key **only if** its entry still has that same expiry (it could have been overwritten with a new TTL).
- `ConcurrentHashMap` for storage; per-key atomic operations through `compute`.

#### Core code
```java
public class TtlKvStore<K, V> implements AutoCloseable {
    private record Entry<V>(V value, long expiresAt) { boolean expired(long now) { return expiresAt != 0 && now >= expiresAt; } }
    private record Expiry<K>(K key, long at) implements Delayed {
        public long getDelay(TimeUnit u) { return u.convert(at - System.nanoTime(), TimeUnit.NANOSECONDS); }
        public int compareTo(Delayed o) { return Long.compare(at, ((Expiry<?>) o).at); }
    }
    private final ConcurrentHashMap<K, Entry<V>> map = new ConcurrentHashMap<>();
    private final DelayQueue<Expiry<K>> expiries = new DelayQueue<>();
    private final Thread cleaner;

    public TtlKvStore() {
        cleaner = Thread.ofPlatform().daemon().name("kv-expirer").start(() -> {
            while (!Thread.currentThread().isInterrupted()) {
                try {
                    Expiry<K> e = expiries.take();
                    map.computeIfPresent(e.key(), (k, cur) -> cur.expiresAt() == e.at() ? null : cur);   // only if not overwritten
                } catch (InterruptedException ie) { return; }
            }
        });
    }

    public void put(K key, V value, Duration ttl) {
        long at = ttl == null ? 0 : System.nanoTime() + ttl.toNanos();
        map.put(key, new Entry<>(value, at));
        if (at != 0) expiries.add(new Expiry<>(key, at));
    }
    public Optional<V> get(K key) {
        long now = System.nanoTime();
        Entry<V> e = map.get(key);
        if (e == null) return Optional.empty();
        if (e.expired(now)) { map.remove(key, e); return Optional.empty(); }          // lazy expiry, remove only that exact entry
        return Optional.of(e.value());
    }
    public boolean delete(K key) { return map.remove(key) != null; }
    public long incr(K key, long by) {                                                // atomic read-modify-write
        @SuppressWarnings("unchecked")
        Entry<V> r = map.compute(key, (k, cur) -> {
            long now = System.nanoTime();
            long base = (cur == null || cur.expired(now)) ? 0 : (Long) cur.value();
            return new Entry<>((V) Long.valueOf(base + by), cur == null || cur.expired(now) ? 0 : cur.expiresAt());
        });
        return (Long) r.value();
    }
    public void close() { cleaner.interrupt(); }
}
```

#### Concurrency and edge cases
- Overwriting a key with a new TTL: the old expiry event must not delete the new value. The `expiresAt` comparison handles this.
- `remove(key, e)` (conditional remove) avoids deleting a value written concurrently after our check.
- **Memory**: the DelayQueue holds one item per TTL'd put. Many overwrites cause queue bloat; that's acceptable, or use the Redis sampling approach instead.
- Monotonic `nanoTime` for TTLs, not wall-clock time.

#### Extensions the interviewer may add
?? "Add max memory with LRU eviction."
Combine with the LRU design: an access-ordered structure under a lock, or segment the store into N shards, each with its own LRU and lock, for concurrency. Redis uses approximated LRU by sampling keys for eviction (`maxmemory-policy allkeys-lru`).

?? "Make it durable across restarts."
Append-only log (AOF) of write commands, fsynced every second or on every write (a trade-off), replayed on startup, with periodic compaction (rewrite the current state). Plus snapshots (RDB-style: fork plus copy-on-write). That's exactly Redis's persistence model.

?? "Make it distributed."
Shard keys across nodes with consistent hashing; replicate each shard (leader-follower); clients route by key. Discuss consistency (async replication may lose recent writes on failover). This is the HLD "distributed cache / key-value store" question.

#### Interview simulation
Clarify the TTL semantics and concurrency. Explain "lazy plus active expiry" and **why both** (correctness vs memory). Code put/get with lazy expiry and the cleaner with the overwrite guard, and demo: put with a 100ms TTL, get immediately (hit), sleep 150ms, get (miss). Then mention Redis's sampling strategy, which shows you know how real systems do it.

### Task scheduler (cron-like job scheduler)

#### Clarifying questions to ask
- *Job types?* → One-time at time T, fixed-rate or fixed-delay recurring, cron expressions.
- *Execution?* → A thread pool with a configurable size; long-running jobs mustn't block the scheduler thread.
- *Missed runs (system was down)?* → A misfire policy: run once immediately, or skip.
- *Overlapping runs of the same job?* → Usually disallowed (skip if the previous run is still running).
- *Retries, timeouts, cancellation?* → Yes for retries and cancel; timeouts are nice to have.
- *Distributed (multiple instances)?* → Discuss later: only one instance should run each job.

#### Requirements (agreed scope)
1. Schedule one-time and recurring jobs; cancel by id.
2. Execute on time using a worker pool; the scheduler thread never runs the job itself.
3. No overlapping executions per job.
4. Retry failed runs with backoff; record history.
5. Pluggable trigger types (fixed rate, cron).

#### Entities and class diagram
```
Job(id, name, Runnable task, Trigger trigger, maxRetries, allowConcurrent=false)
Trigger (interface): nextFireTime(Instant lastFire) → Optional<Instant>
   ← OnceTrigger(at), FixedRateTrigger(start, period), CronTrigger(expression)
ScheduledItem(jobId, fireAt) in PriorityQueue/DelayQueue ordered by fireAt
Scheduler: schedule(job) ; cancel(jobId) ; dispatcher loop ; worker pool
ExecutionRecord(jobId, startedAt, endedAt, status, attempt, error)
```

#### Key design decisions
- **Min-heap / DelayQueue ordered by the next fire time**: the dispatcher sleeps until the head is due, so there's no busy polling. A `DelayQueue.take()` blocks exactly until the earliest item is due.
- **Dispatcher vs workers**: one dispatcher thread hands due jobs to a worker pool, so a slow job doesn't delay others.
- **Strategy** for triggers.
- After each run, compute the next fire time and re-enqueue (recurring jobs).
- A per-job `AtomicBoolean running` prevents overlap.

#### Core code
```java
interface Trigger { Optional<Instant> next(Instant after); }
record OnceTrigger(Instant at) implements Trigger { public Optional<Instant> next(Instant after) { return at.isAfter(after) ? Optional.of(at) : Optional.empty(); } }
record FixedRateTrigger(Instant start, Duration period) implements Trigger {
    public Optional<Instant> next(Instant after) {
        if (after.isBefore(start)) return Optional.of(start);
        long n = Duration.between(start, after).toMillis() / period.toMillis() + 1;      // skip missed slots
        return Optional.of(start.plusMillis(n * period.toMillis()));
    }
}

final class Job {
    final String id; final Runnable task; final Trigger trigger; final int maxRetries;
    final AtomicBoolean running = new AtomicBoolean(false); volatile boolean cancelled;
    Job(String id, Runnable task, Trigger t, int maxRetries) { this.id = id; this.task = task; this.trigger = t; this.maxRetries = maxRetries; }
}

class JobScheduler implements AutoCloseable {
    private record Due(Job job, Instant at) implements Delayed {
        public long getDelay(TimeUnit u) { return u.convert(Duration.between(Instant.now(), at)); }
        public int compareTo(Delayed o) { return at.compareTo(((Due) o).at); }
    }
    private final DelayQueue<Due> queue = new DelayQueue<>();
    private final Map<String, Job> jobs = new ConcurrentHashMap<>();
    private final ExecutorService workers; private final Thread dispatcher;

    JobScheduler(int poolSize) {
        workers = new ThreadPoolExecutor(poolSize, poolSize, 0, TimeUnit.SECONDS, new ArrayBlockingQueue<>(1000),
                                         r -> new Thread(r, "job-worker"), new ThreadPoolExecutor.CallerRunsPolicy());
        dispatcher = Thread.ofPlatform().name("job-dispatcher").start(this::dispatchLoop);
    }

    public void schedule(Job job) {
        jobs.put(job.id, job);
        job.trigger.next(Instant.now()).ifPresent(t -> queue.add(new Due(job, t)));
    }
    public void cancel(String jobId) { Job j = jobs.remove(jobId); if (j != null) j.cancelled = true; }   // lazily dropped when due

    private void dispatchLoop() {
        while (!Thread.currentThread().isInterrupted()) {
            try {
                Due due = queue.take();                                      // blocks until earliest is due
                Job job = due.job();
                if (job.cancelled) continue;
                job.trigger.next(due.at()).ifPresent(t -> queue.add(new Due(job, t)));   // schedule next fire first
                if (!job.running.compareAndSet(false, true)) { System.out.println("skip overlapping run " + job.id); continue; }
                workers.execute(() -> runWithRetry(job));
            } catch (InterruptedException e) { return; }
        }
    }
    private void runWithRetry(Job job) {
        try {
            for (int attempt = 0; attempt <= job.maxRetries; attempt++) {
                try { job.task.run(); return; }
                catch (RuntimeException e) {
                    if (attempt == job.maxRetries) { System.err.println("job " + job.id + " failed: " + e); return; }
                    try { Thread.sleep(100L << attempt); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); return; }
                }
            }
        } finally { job.running.set(false); }
    }
    public void close() { dispatcher.interrupt(); workers.shutdown(); }
}
```

#### Concurrency and edge cases
- The dispatcher never executes the jobs itself; workers do. A full worker queue falls back to CallerRuns (the dispatcher runs the job, which delays dispatch; acceptable backpressure, or alert instead).
- Cancel: a flag checked at fire time (O(1) cancel, lazy removal from the heap).
- Clock changes: `Instant.now()` follows the wall clock, so a system clock jump shifts schedules. For intervals, a monotonic base is better; cron jobs legitimately follow the wall clock and time zone (DST!).
- Misfires after downtime: `FixedRateTrigger.next` skips missed slots (the "skip" policy). The alternative is to run once immediately.

#### Extensions the interviewer may add
?? "Run this scheduler on 5 instances. How do you make sure each job runs once?"
Options: a **DB lock per job run** (`INSERT INTO job_runs(job_id, fire_time)` with a unique constraint; only the winner executes), **ShedLock** (a lock row with lock-until), `SELECT … FOR UPDATE SKIP LOCKED` over a jobs table, Redis `SET NX PX` locks with fencing tokens, or a leader-elected scheduler (one active, others standby). Plus idempotent jobs, because lock expiry during a long run can cause a double run.

?? "Support cron expressions."
A `CronTrigger` that parses the 5 or 6 fields into allowed-value sets and computes the next matching time by incrementing the fields (minute → hour → day → month), honouring the time zone. In practice, reuse Spring's `CronExpression.parse("0 */5 * * * *").next(time)`.

?? "How would you build this as a service (like AWS EventBridge Scheduler or Airflow)?"
Persist jobs and next-fire times in a DB indexed on `next_fire_at`; partition jobs across scheduler nodes (by hash); each node polls its due jobs, publishes execution messages to a queue, and executors consume them; status is tracked per run with retries and DLQ; a timing wheel helps for very large numbers of near-term timers. That's the HLD "distributed job scheduler" problem.

#### Interview simulation
Clarify the job types, overlap policy and misfire policy. Present the architecture in one breath: "a DelayQueue of next-fire times, one dispatcher thread, a worker pool; triggers compute the next fire time; a per-job running flag prevents overlap." Code it, demo a one-time job plus a fixed-rate job and a cancel, then answer "exactly once across instances" with the DB-unique-run approach and the idempotency caveat. That last answer is what senior interviewers wait for.
