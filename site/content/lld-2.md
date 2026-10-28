## LLD problems I | P3 | must

### Parking lot

#### Clarifying questions to ask
Ask these before designing, with the typical answers interviewers give:
- *How many floors? Spot types?* → Multiple floors; spots are Compact, Regular, Large, plus EV (charging) and Bike.
- *Vehicle types and fit rules?* → Bike → Bike spot; Car → Compact or Regular; Truck/Bus → Large. Can a car take a large spot if regular is full? (Usually yes, as a fallback.)
- *Multiple entry/exit gates?* → Yes, so concurrent allocation must be safe.
- *Ticketing and payment?* → A ticket at entry, payment at exit; hourly pricing per vehicle type.
- *Display boards showing free spots?* → Nice to have.
- *Reservations? Monthly passes?* → Out of scope (note it as an extension).

#### Requirements (agreed scope)
1. Park a vehicle: find a suitable free spot, issue a ticket.
2. Unpark: compute the fee, take payment, free the spot.
3. Show availability per floor and type.
4. Support multiple gates concurrently.
5. Pricing and allocation rules should be pluggable.

#### Entities and class diagram
```
ParkingLot 1 ◆── * ParkingFloor 1 ◆── * ParkingSpot(id, type, occupiedBy?)
Vehicle(plate, type)    VehicleType {BIKE, CAR, TRUCK, EV_CAR}    SpotType {BIKE, COMPACT, REGULAR, LARGE, EV}
Ticket(id, vehicle, spot, entryTime)    Payment(ticketId, amount, mode, status)
SpotAllocationStrategy <|.. LowestFloorFirstStrategy, NearestToGateStrategy
PricingStrategy <|.. HourlyPricing
ParkingService: park(vehicle, gateId) -> Ticket ; unpark(ticketId, payMode) -> Receipt
```

#### Key design decisions
- **Strategy** for allocation and pricing (the most common follow-ups).
- **Fit rules as data** (`Map<VehicleType, List<SpotType>>` in preference order), not `instanceof` chains.
- **Concurrency**: two gates mustn't allocate the same spot. Use per-spot atomic claiming (CAS), or keep free spots in concurrent per-type queues so allocation is O(1).
- Money as `long` paise; time via an injected `Clock` (testable).

#### Core code
```java
enum VehicleType { BIKE, CAR, TRUCK, EV_CAR }
enum SpotType { BIKE, COMPACT, REGULAR, LARGE, EV }
record Vehicle(String plate, VehicleType type) {}

final class ParkingSpot {
    private final String id; private final SpotType type; private final int floor;
    private final AtomicReference<String> occupiedBy = new AtomicReference<>(null);   // plate or null
    ParkingSpot(String id, SpotType type, int floor) { this.id = id; this.type = type; this.floor = floor; }
    boolean tryOccupy(String plate) { return occupiedBy.compareAndSet(null, plate); }   // atomic claim
    void release() { occupiedBy.set(null); }
    boolean isFree() { return occupiedBy.get() == null; }
    String id() { return id; } SpotType type() { return type; } int floor() { return floor; }
}

record Ticket(String id, Vehicle vehicle, ParkingSpot spot, Instant entryTime) {}

interface SpotAllocationStrategy { Optional<ParkingSpot> allocate(List<ParkingSpot> candidates, Vehicle v); }

class LowestFloorFirst implements SpotAllocationStrategy {
    public Optional<ParkingSpot> allocate(List<ParkingSpot> candidates, Vehicle v) {
        return candidates.stream().sorted(Comparator.comparingInt(ParkingSpot::floor))
            .filter(s -> s.isFree() && s.tryOccupy(v.plate())).findFirst();      // claim while scanning
    }
}

interface PricingStrategy { long fee(VehicleType t, Duration parked); }
class HourlyPricing implements PricingStrategy {
    private final Map<VehicleType, Long> perHourPaise;
    HourlyPricing(Map<VehicleType, Long> rates) { this.perHourPaise = rates; }
    public long fee(VehicleType t, Duration d) {
        long hours = Math.max(1, (d.toMinutes() + 59) / 60);                   // round up, min 1 hour
        return hours * perHourPaise.get(t);
    }
}

class ParkingService {
    private static final Map<VehicleType, List<SpotType>> FITS = Map.of(
        VehicleType.BIKE, List.of(SpotType.BIKE),
        VehicleType.CAR, List.of(SpotType.COMPACT, SpotType.REGULAR, SpotType.LARGE),
        VehicleType.EV_CAR, List.of(SpotType.EV, SpotType.COMPACT, SpotType.REGULAR),
        VehicleType.TRUCK, List.of(SpotType.LARGE));

    private final Map<SpotType, List<ParkingSpot>> spotsByType;
    private final Map<String, Ticket> activeTickets = new ConcurrentHashMap<>();
    private final Set<String> parkedPlates = ConcurrentHashMap.newKeySet();
    private final SpotAllocationStrategy allocator; private final PricingStrategy pricing; private final Clock clock;

    ParkingService(List<ParkingSpot> spots, SpotAllocationStrategy a, PricingStrategy p, Clock c) {
        this.spotsByType = spots.stream().collect(Collectors.groupingBy(ParkingSpot::type));
        this.allocator = a; this.pricing = p; this.clock = c;
    }

    public Ticket park(Vehicle v) {
        if (!parkedPlates.add(v.plate())) throw new IllegalStateException("Vehicle already inside: " + v.plate());
        try {
            for (SpotType t : FITS.get(v.type())) {                          // preference order
                Optional<ParkingSpot> spot = allocator.allocate(spotsByType.getOrDefault(t, List.of()), v);
                if (spot.isPresent()) {
                    Ticket ticket = new Ticket(UUID.randomUUID().toString(), v, spot.get(), clock.instant());
                    activeTickets.put(ticket.id(), ticket);
                    return ticket;
                }
            }
            throw new NoSpotAvailableException(v.type());
        } catch (RuntimeException e) { parkedPlates.remove(v.plate()); throw e; }
    }

    public long unpark(String ticketId) {
        Ticket t = Optional.ofNullable(activeTickets.remove(ticketId))           // remove = exactly-once exit
            .orElseThrow(() -> new IllegalArgumentException("Invalid or used ticket"));
        long fee = pricing.fee(t.vehicle().type(), Duration.between(t.entryTime(), clock.instant()));
        t.spot().release(); parkedPlates.remove(t.vehicle().plate());
        return fee;                                                              // payment handled by PaymentService
    }

    public Map<SpotType, Long> availability() {
        return spotsByType.entrySet().stream().collect(Collectors.toMap(Map.Entry::getKey,
            e -> e.getValue().stream().filter(ParkingSpot::isFree).count()));
    }
}
class NoSpotAvailableException extends RuntimeException { NoSpotAvailableException(VehicleType t) { super("No spot for " + t); } }
```

#### Concurrency and edge cases
- **Double allocation** is prevented by `compareAndSet` on each spot: if two gates race for the same spot, one CAS fails and that gate moves on to the next spot.
- **Double exit / ticket reuse** is prevented by `activeTickets.remove()`, which is atomic and happens exactly once.
- The same vehicle entering twice is caught by the `parkedPlates` set.
- Scanning lists is O(spots). For large lots, keep a `ConcurrentLinkedDeque<ParkingSpot>` of *free* spots per type (poll on park, offer on release), giving O(1).
- Lost ticket: a fee policy (max daily rate) plus lookup by plate.

#### Extensions the interviewer may add
?? "Add EV charging spots that charge extra per kWh."
Add `SpotType.EV` (already in the fit list) and a `ChargingSession` attached to the ticket. Make pricing a composite: `TotalPricing(parkingPricing, chargingPricing)`, where charging is billed per kWh reported by the charger. No change to allocation logic beyond the fit list.

?? "Different rates on weekends and peak hours."
A new `PricingStrategy` implementation (`TimeBasedPricing`) that splits the parked interval into slots and applies a rate per slot, or a decorator (`PeakHourSurcharge(base)`). The service is unchanged because it depends on the interface.

?? "Show live free counts on each floor's display board."
**Observer**: `ParkingSpot` state changes publish events to `DisplayBoard` listeners, or the boards poll an `availability()` view. Keep per-floor `AtomicInteger` counters updated on claim and release for O(1) reads.

?? "How would you persist this and scale across many lots?"
Repository interfaces with a DB: `spots(id, lot_id, type, status, vehicle_plate, version)`. Allocation becomes `UPDATE spots SET status='OCCUPIED', vehicle_plate=? WHERE id = (SELECT id FROM spots WHERE lot_id=? AND type=? AND status='FREE' ORDER BY floor LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING id`. Each lot is an independent partition, so it scales naturally.

#### Interview simulation
**Minute 0–6, clarify:** ask the questions above; write the agreed list of requirements in a corner of the board.
**Minute 6–12, entities:** say "Nouns: lot, floor, spot, vehicle, ticket, payment. Variation points: allocation and pricing, so they're strategies. Fit rules are data." Draw the diagram.
**Minute 12–45, code:** models → strategies → `ParkingService` → `Main` demo (park 3 cars, fill the compact spots, show the fallback to regular, unpark with a fee).
**Minute 45–55, concurrency:** explain the CAS claim, the atomic ticket removal, and why scanning is fine at this size, plus the free-queue optimisation.
**Minute 55–60, extensions:** walk through EV and peak pricing quickly.
**Say this line:** "Every requirement change you might add (new vehicle, new pricing, new allocation rule) lands in a new class or a data entry, not in an if-else."

### Elevator system

#### Clarifying questions to ask
- *How many elevators and floors?* → N elevators, M floors (e.g. 4 elevators, 20 floors).
- *Request types?* → Hall calls (floor + direction: UP/DOWN buttons) and car calls (a floor button pressed inside the elevator).
- *Optimise for what?* → Minimise average wait time; avoid starvation.
- *Capacity or weight limits? Emergency or maintenance modes?* → Mention them; usually handled as states.
- *Do we simulate time (ticks) or real threads?* → Usually a discrete tick-based simulation, which is easier to test.

#### Requirements (agreed scope)
1. Accept hall calls and car calls.
2. A dispatcher assigns each hall call to the best elevator.
3. Each elevator serves requests efficiently (no ping-ponging).
4. Show each elevator's current floor, direction and state.
5. Pluggable dispatch strategy; maintenance mode.

#### Entities and class diagram
```
ElevatorSystem 1 ◆── * ElevatorCar ; ElevatorSystem ──> DispatchStrategy
ElevatorCar(id, currentFloor, direction, state, upStops: TreeSet, downStops: TreeSet)
Direction {UP, DOWN, IDLE}   ElevatorState {MOVING, STOPPED, DOORS_OPEN, MAINTENANCE}
HallRequest(floor, direction)   CarRequest(elevatorId, floor)
DispatchStrategy <|.. NearestSuitableCarStrategy, ZoneBasedStrategy
```

#### Key design decisions
- **SCAN / LOOK algorithm per car** (like a disk head): keep moving in the current direction, serving all stops that way, then reverse. Two `TreeSet`s (up stops and down stops) give O(log n) ordered next-stop lookup.
- **Dispatcher (Strategy)** scores each car: a car moving toward the floor in the same direction is cheapest, an idle car is next, a car moving away is the most expensive.
- **State** for car behaviour (maintenance cars are excluded from dispatch).
- A **tick-based simulation** (`step()`) keeps it deterministic and testable. Production systems are event-driven.

#### Core code
```java
enum Direction { UP, DOWN, IDLE }

class ElevatorCar {
    final int id; int floor = 0; Direction dir = Direction.IDLE; boolean maintenance = false;
    private final TreeSet<Integer> up = new TreeSet<>(), down = new TreeSet<>();
    ElevatorCar(int id) { this.id = id; }

    synchronized void addStop(int target) {
        if (target > floor) up.add(target); else if (target < floor) down.add(target);
        else { openDoors(); return; }
        if (dir == Direction.IDLE) dir = target > floor ? Direction.UP : Direction.DOWN;
    }

    /** advance one tick: move one floor, stop if needed (LOOK algorithm) */
    synchronized void step() {
        if (dir == Direction.UP) {
            if (up.isEmpty()) { dir = down.isEmpty() ? Direction.IDLE : Direction.DOWN; return; }
            floor++;
            if (up.remove(floor)) openDoors();
        } else if (dir == Direction.DOWN) {
            if (down.isEmpty()) { dir = up.isEmpty() ? Direction.IDLE : Direction.UP; return; }
            floor--;
            if (down.remove(floor)) openDoors();
        }
    }
    private void openDoors() { System.out.printf("Car %d stops at %d%n", id, floor); }
    synchronized int pendingStops() { return up.size() + down.size(); }
}

interface DispatchStrategy { ElevatorCar choose(List<ElevatorCar> cars, int floor, Direction requested); }

class NearestSuitableCar implements DispatchStrategy {
    public ElevatorCar choose(List<ElevatorCar> cars, int floor, Direction req) {
        return cars.stream().filter(c -> !c.maintenance)
            .min(Comparator.comparingInt(c -> cost(c, floor, req)))
            .orElseThrow(() -> new IllegalStateException("No elevator available"));
    }
    private int cost(ElevatorCar c, int floor, Direction req) {
        int distance = Math.abs(c.floor - floor);
        if (c.dir == Direction.IDLE) return distance;
        boolean movingToward = (c.dir == Direction.UP && floor >= c.floor) || (c.dir == Direction.DOWN && floor <= c.floor);
        if (movingToward && c.dir == req) return distance;                 // on the way, same direction
        return distance + 2 * 20 + c.pendingStops();                        // must finish sweep first: penalise
    }
}

class ElevatorSystem {
    private final List<ElevatorCar> cars; private final DispatchStrategy strategy;
    ElevatorSystem(int n, DispatchStrategy s) { cars = IntStream.range(0, n).mapToObj(ElevatorCar::new).toList(); strategy = s; }
    void hallCall(int floor, Direction d) { strategy.choose(cars, floor, d).addStop(floor); }
    void carCall(int carId, int floor) { cars.get(carId).addStop(floor); }
    void tick() { cars.forEach(ElevatorCar::step); }
}
```

#### Concurrency and edge cases
- Requests arrive from many buttons concurrently, so per-car methods are `synchronized` (the state is small), and the dispatcher reads approximate state (good enough for a decision).
- **Starvation**: LOOK guarantees every stop is served within one full sweep.
- A duplicate request for the same floor is a no-op thanks to the TreeSet.
- Maintenance: excluded from dispatch; its pending hall calls are reassigned.
- Capacity: if full, skip hall-call pickups (keep the stop for later) and let the dispatcher reassign.

#### Extensions the interviewer may add
?? "Optimise for the morning rush (everyone going up from the lobby)."
Add a `ZoneBasedStrategy`: cars serve floor zones (1–10, 11–20), idle cars return to the lobby, and there's **destination dispatch** (people enter their destination floor in the lobby, and the system groups passengers by destination). That's what modern skyscrapers use (Otis CompassPlus, Schindler PORT).

?? "How would you test this?"
The tick-based design makes it deterministic: create the system, issue requests, call `tick()` N times, and assert the sequence of floors visited and that every request was served. Property tests: no request waits more than (2 × floors) ticks; a car never skips a requested floor in its direction of travel.

?? "Why not FCFS per elevator?"
FCFS ping-pongs (floor 1 → 20 → 2 → 19), wasting travel time and raising average wait. SCAN/LOOK orders stops by position, like disk scheduling.

#### Interview simulation
**Clarify** (requests, number of cars, objective), **name the algorithm early** ("each car uses LOOK, the dispatcher scores cars by cost"), draw the two-TreeSet idea, code the car's `addStop` and `step` plus the dispatcher, and run a scenario with 2 cars and 5 requests in `main`. Close with destination dispatch and testing. Interviewers mostly assess whether you separate **per-car scheduling** from **global dispatch**.

### Movie ticket booking (BookMyShow)

#### Clarifying questions to ask
- *Scope: browse movies and shows, select seats, book, pay?* → Yes; search can be simple.
- *Seat categories and pricing?* → Silver, Gold, Recliner with different prices; maybe dynamic pricing later.
- *How do we prevent two users booking the same seat?* → This is the core of the problem: temporary **seat hold** with expiry while paying.
- *Hold duration?* → e.g. 10 minutes.
- *Payment failures? Cancellation and refunds?* → Release the seats on failure; cancellation is an extension.
- *Multiple cities, theatres, screens?* → Yes (it's the hierarchy).

#### Requirements (agreed scope)
1. List shows for a movie in a city; show the seat map with availability.
2. Select seats and **hold** them for N minutes (exclusive).
3. Confirm the booking after successful payment; release on failure or expiry.
4. No double booking under concurrency.
5. Pricing per seat category (strategy).

#### Entities and class diagram
```
City 1──* Theatre 1──* Screen 1──* Seat(id, row, number, category)
Movie(id, title, duration)    Show(id, movie, screen, startTime)
ShowSeat(showId, seatId, status{AVAILABLE, HELD, BOOKED}, heldBy, holdExpiresAt, version)
Booking(id, userId, showId, seatIds, amount, status{PENDING, CONFIRMED, CANCELLED, EXPIRED})
BookingService: holdSeats(user, show, seats) -> Booking ; confirm(bookingId, paymentRef) ; release(bookingId)
PricingStrategy <|.. CategoryPricing, DynamicPricing
```

#### Key design decisions
- A **ShowSeat** row per (show, seat) is the unit of locking: seats are physical, availability is per show.
- **All-or-nothing hold**: holding 4 seats must claim all 4 or none.
- **Deadlock avoidance**: lock seats in **sorted id order**.
- **Expiry**: held seats carry `holdExpiresAt`; a seat whose hold has expired counts as available (lazy release), plus a background sweeper.
- **State machine** for Booking.
- In production: a DB with `SELECT … FOR UPDATE` on the seat rows (or a conditional UPDATE), or Redis `SET seat:{show}:{seat} user NX EX 600` for holds.

#### Core code
```java
enum SeatStatus { AVAILABLE, HELD, BOOKED }
final class ShowSeat {
    final String seatId; SeatStatus status = SeatStatus.AVAILABLE; String heldBy; Instant holdExpiresAt;
    ShowSeat(String seatId) { this.seatId = seatId; }
    boolean isAvailable(Instant now) {
        return status == SeatStatus.AVAILABLE || (status == SeatStatus.HELD && holdExpiresAt.isBefore(now));
    }
}

class Show {
    final String id; final Map<String, ShowSeat> seats; final ReentrantLock lock = new ReentrantLock();
    Show(String id, List<String> seatIds) { this.id = id; this.seats = seatIds.stream().collect(Collectors.toMap(s -> s, ShowSeat::new)); }
}

enum BookingStatus { PENDING, CONFIRMED, EXPIRED, CANCELLED }
interface PricingStrategy { long price(String showId, List<String> seatIds); }
class SeatUnavailableException extends RuntimeException { SeatUnavailableException(String s) { super("Seat unavailable: " + s); } }
class HoldExpiredException extends RuntimeException { HoldExpiredException(String b) { super("Hold expired for booking " + b); } }
record Booking(String id, String userId, String showId, List<String> seatIds, long amountPaise, Instant expiresAt, BookingStatus status) {
    Booking with(BookingStatus s) { return new Booking(id, userId, showId, seatIds, amountPaise, expiresAt, s); }
}

class BookingService {
    private final Map<String, Show> shows; private final Map<String, Booking> bookings = new ConcurrentHashMap<>();
    private final PricingStrategy pricing; private final Clock clock; private final Duration holdFor = Duration.ofMinutes(10);
    BookingService(Map<String, Show> shows, PricingStrategy p, Clock c) { this.shows = shows; this.pricing = p; this.clock = c; }

    public Booking hold(String userId, String showId, List<String> seatIds) {
        Show show = shows.get(showId); Instant now = clock.instant();
        show.lock.lock();                       // per-show lock: simple & correct in-memory (DB: row locks in sorted order)
        try {
            for (String s : seatIds) {
                ShowSeat ss = show.seats.get(s);
                if (ss == null || !ss.isAvailable(now)) throw new SeatUnavailableException(s);   // all-or-nothing check
            }
            Instant exp = now.plus(holdFor);
            for (String s : seatIds) { ShowSeat ss = show.seats.get(s); ss.status = SeatStatus.HELD; ss.heldBy = userId; ss.holdExpiresAt = exp; }
            Booking b = new Booking(UUID.randomUUID().toString(), userId, showId, List.copyOf(seatIds),
                                    pricing.price(showId, seatIds), exp, BookingStatus.PENDING);
            bookings.put(b.id(), b);
            return b;
        } finally { show.lock.unlock(); }
    }

    public Booking confirm(String bookingId, String paymentRef) {
        Booking b = bookings.get(bookingId); Show show = shows.get(b.showId());
        show.lock.lock();
        try {
            if (b.status() != BookingStatus.PENDING) throw new IllegalStateException("Booking is " + b.status());
            Instant now = clock.instant();
            for (String s : b.seatIds()) {                    // hold must still be ours and unexpired
                ShowSeat ss = show.seats.get(s);
                if (ss.status != SeatStatus.HELD || !b.userId().equals(ss.heldBy) || ss.holdExpiresAt.isBefore(now))
                    throw new HoldExpiredException(bookingId);   // caller must refund paymentRef
            }
            b.seatIds().forEach(s -> show.seats.get(s).status = SeatStatus.BOOKED);
            Booking confirmed = b.with(BookingStatus.CONFIRMED); bookings.put(b.id(), confirmed); return confirmed;
        } finally { show.lock.unlock(); }
    }

    public void release(String bookingId) {                   // payment failed / user cancelled before paying
        Booking b = bookings.get(bookingId); Show show = shows.get(b.showId());
        show.lock.lock();
        try {
            if (b.status() != BookingStatus.PENDING) return;
            for (String s : b.seatIds()) { ShowSeat ss = show.seats.get(s);
                if (ss.status == SeatStatus.HELD && b.userId().equals(ss.heldBy)) { ss.status = SeatStatus.AVAILABLE; ss.heldBy = null; } }
            bookings.put(b.id(), b.with(BookingStatus.CANCELLED));
        } finally { show.lock.unlock(); }
    }
}
```

#### Concurrency and edge cases
- A **per-show lock** is coarse but correct and simple in memory: different shows don't contend, and one show's seat selection is a tiny critical section. For finer granularity, per-seat locks acquired **in sorted order**.
- **Payment succeeds after the hold expired**: `confirm` detects it and the caller must **refund automatically**. This is the tricky case interviewers probe.
- **Payment callback received twice**: `confirm` is idempotent via the status check (a second call sees CONFIRMED). Make that path return the existing booking instead of throwing.
- Expired holds are released lazily by `isAvailable(now)`; a periodic sweeper marks PENDING bookings as EXPIRED for cleanliness.

#### Extensions the interviewer may add
?? "How would this work with a database and multiple app servers?"
`show_seats(show_id, seat_id, status, held_by, hold_expires_at)`. Hold = in one transaction, `SELECT … FROM show_seats WHERE show_id=? AND seat_id IN (…) ORDER BY seat_id FOR UPDATE`, check all are available (or have expired holds), then update them to HELD. Alternatively, a conditional update `UPDATE … SET status='HELD' … WHERE … AND (status='AVAILABLE' OR hold_expires_at < now())` and check the count equals the number of seats requested (otherwise roll back). For extreme traffic (a big-release first-day rush), use Redis `SET NX EX` holds plus a virtual waiting room.

?? "Add dynamic pricing (prices rise as the show fills up)."
`DynamicPricing implements PricingStrategy`: base category price × a multiplier from occupancy (e.g. >70% full gives +20%). Lock in the price at hold time (stored on the Booking) so it can't change during payment.

?? "Users complain seats show available but fail on selection."
Seat maps are cached or stale, so expect conflicts. The hold must be the source of truth, with a clear "seat just got taken" message and a refreshed map. Push real-time seat updates via WebSocket for popular shows.

#### Interview simulation
Lead with the core insight: "The hard part is concurrent seat selection and the hold-then-pay window." Clarify the hold duration and payment flow, draw `ShowSeat` as the locking unit, code hold, confirm and release with the expiry checks, then **explicitly narrate the race**: "User A's hold expires at 10:00:00, user B grabs the seat at 10:00:01, A's payment success arrives at 10:00:05. Confirm fails, and we refund A automatically." Naming that scenario unprompted is what separates strong candidates.

### Splitwise (expense sharing)

#### Clarifying questions to ask
- *Split types?* → EQUAL, EXACT amounts, PERCENT (and SHARES as an extension).
- *Groups or just individuals?* → Both: expenses within groups and between friends.
- *Show balances: per pair, per user, per group?* → Yes; plus "simplify debts" (minimise transactions) as a follow-up.
- *Currency?* → Single currency, amounts in paise.
- *Settle up?* → Record a payment that reduces a balance.

#### Requirements (agreed scope)
1. Add users and groups.
2. Add an expense: payer, amount, participants, split type with its values.
3. Show balances: who owes whom, and how much.
4. Settle up between two users.
5. (Follow-up) Simplify group debts.

#### Entities and class diagram
```
User(id, name)  Group(id, name, members)
Expense(id, paidBy, amountPaise, splits: List<Split>, groupId?, description)
Split(userId, amountPaise)
SplitStrategy <|.. EqualSplit, ExactSplit, PercentSplit    (validate + compute splits)
BalanceSheet: Map<String, Map<String, Long>>   // balances[a][b] = how much b owes a (+) 
ExpenseService: addExpense(...) ; balancesOf(user) ; settle(from, to, amount) ; simplify(group)
```

#### Key design decisions
- **Strategy** for split types, each responsible for **validation** (percentages sum to 100, exact amounts sum to the total).
- **Rounding**: ₹100 split 3 ways is 3333 + 3333 + 3334 paise; give the remainder to the first participants deterministically. Never use `double`.
- Store **net pairwise balances**, updated incrementally per expense: O(participants) per expense.
- **Simplify debts**: compute each user's net position, then greedily match the biggest creditor with the biggest debtor using two heaps. That's at most n−1 transactions (the exact minimum is NP-hard in general; greedy is what Splitwise-style apps use).

#### Core code
```java
record Split(String userId, long amountPaise) {}

interface SplitStrategy { List<Split> split(long total, List<String> users, List<Long> values); }

class EqualSplit implements SplitStrategy {
    public List<Split> split(long total, List<String> users, List<Long> ignored) {
        long base = total / users.size(), rem = total % users.size(); List<Split> out = new ArrayList<>();
        for (int i = 0; i < users.size(); i++) out.add(new Split(users.get(i), base + (i < rem ? 1 : 0)));
        return out;
    }
}
class ExactSplit implements SplitStrategy {
    public List<Split> split(long total, List<String> users, List<Long> amounts) {
        if (amounts.stream().mapToLong(Long::longValue).sum() != total) throw new IllegalArgumentException("Exact splits must sum to total");
        return IntStream.range(0, users.size()).mapToObj(i -> new Split(users.get(i), amounts.get(i))).toList();
    }
}
class PercentSplit implements SplitStrategy {
    public List<Split> split(long total, List<String> users, List<Long> pct) {
        if (pct.stream().mapToLong(Long::longValue).sum() != 100) throw new IllegalArgumentException("Percents must sum to 100");
        List<Split> out = new ArrayList<>(); long allocated = 0;
        for (int i = 0; i < users.size(); i++) {
            long amt = (i == users.size() - 1) ? total - allocated : total * pct.get(i) / 100;   // last absorbs rounding
            allocated += amt; out.add(new Split(users.get(i), amt));
        }
        return out;
    }
}

class BalanceSheet {
    // owes[debtor][creditor] = amount debtor owes creditor (always kept net & positive in one direction)
    private final Map<String, Map<String, Long>> owes = new HashMap<>();
    synchronized void record(String debtor, String creditor, long amt) {
        if (debtor.equals(creditor) || amt == 0) return;
        long reverse = get(creditor, debtor);
        if (reverse >= amt) { put(creditor, debtor, reverse - amt); }          // net against existing reverse debt
        else { put(creditor, debtor, 0); put(debtor, creditor, get(debtor, creditor) + amt - reverse); }
    }
    synchronized long get(String d, String c) { return owes.getOrDefault(d, Map.of()).getOrDefault(c, 0L); }
    private void put(String d, String c, long v) {
        if (v == 0) { var m = owes.get(d); if (m != null) m.remove(c); } else owes.computeIfAbsent(d, k -> new HashMap<>()).put(c, v);
    }
    synchronized Map<String, Long> netPositions() {          // + means others owe you
        Map<String, Long> net = new HashMap<>();
        owes.forEach((d, m) -> m.forEach((c, v) -> { net.merge(d, -v, Long::sum); net.merge(c, v, Long::sum); }));
        return net;
    }
}

class ExpenseService {
    private final BalanceSheet sheet = new BalanceSheet(); private final Map<SplitType, SplitStrategy> strategies;
    ExpenseService(Map<SplitType, SplitStrategy> s) { strategies = s; }
    public void addExpense(String paidBy, long total, SplitType type, List<String> users, List<Long> values) {
        for (Split s : strategies.get(type).split(total, users, values)) sheet.record(s.userId(), paidBy, s.amountPaise());
    }
    public void settle(String from, String to, long amt) { sheet.record(to, from, amt); }   // payment reduces from's debt
    public List<String> simplify() {
        PriorityQueue<Map.Entry<String, Long>> creditors = new PriorityQueue<>((a, b) -> Long.compare(b.getValue(), a.getValue()));
        PriorityQueue<Map.Entry<String, Long>> debtors = new PriorityQueue<>((a, b) -> Long.compare(a.getValue(), b.getValue()));
        sheet.netPositions().entrySet().forEach(e -> { if (e.getValue() > 0) creditors.add(e); else if (e.getValue() < 0) debtors.add(e); });
        List<String> txns = new ArrayList<>();
        while (!creditors.isEmpty() && !debtors.isEmpty()) {
            var c = creditors.poll(); var d = debtors.poll(); long amt = Math.min(c.getValue(), -d.getValue());
            txns.add(d.getKey() + " pays " + c.getKey() + " " + amt);
            if (c.getValue() - amt > 0) creditors.add(Map.entry(c.getKey(), c.getValue() - amt));
            if (d.getValue() + amt < 0) debtors.add(Map.entry(d.getKey(), d.getValue() + amt));
        }
        return txns;
    }
}
enum SplitType { EQUAL, EXACT, PERCENT }
```

#### Concurrency and edge cases
- Balance updates are `synchronized` on the sheet. For scale: per-group sheets or a ledger table with a single writer per group.
- The payer included in the participants: their own share yields no debt (`debtor == creditor` is skipped).
- Rounding remainder handling; validation errors per strategy.
- **Better persistence model**: an append-only **ledger** of expenses and settlements, with balances derived or materialised. That gives auditability and allows editing or deleting expenses by reversing entries.

#### Extensions the interviewer may add
?? "Allow editing or deleting an expense."
With the ledger approach, record a reversing entry for the old expense and apply the new one. Never mutate balances by hand. That's why storing the expense history matters.

?? "Why is minimising the number of transactions hard?"
Finding the minimum number of transfers to settle a set of net balances reduces to partitioning the users into the maximum number of zero-sum subsets, which is NP-hard. The greedy max-creditor/max-debtor approach gives at most n−1 transactions and is good in practice.

?? "Support multiple currencies."
Store a currency per expense; keep balances per currency pair, or convert at expense time using a rate snapshot (stored with the expense). Never mix currencies in one number.

#### Interview simulation
Clarify the split types and balance views, then say: "I'll model split types as strategies with validation, store amounts in paise with deterministic rounding, and keep net pairwise balances." Code the strategies and the balance sheet, demo a dinner split among A, B and C, then a settlement, then `simplify`. Interviewers often add "edit an expense" at the end, so be ready with the ledger answer.

### Rate limiter

#### Clarifying questions to ask
- *Limit by what key?* → Per user / API key / IP; maybe per endpoint.
- *Algorithm preference? Bursts allowed?* → Token bucket allows bursts; sliding window is smoother.
- *Single process or distributed?* → Start in-process, then discuss the distributed version (Redis).
- *What happens when limited?* → Reject with 429 + `Retry-After`; maybe queue.
- *Different limits per tier?* → Free 100/min, Pro 1000/min, so the config is per plan.

#### Requirements (agreed scope)
1. `boolean allow(String key)`: decide per request, O(1).
2. Configurable limits per key or tier.
3. Pluggable algorithm.
4. Thread-safe under concurrent requests.
5. Memory-bounded (evict idle keys).

#### Entities and class diagram
```
RateLimiter (interface): allow(key) -> boolean
TokenBucketLimiter, SlidingWindowLogLimiter, SlidingWindowCounterLimiter, FixedWindowLimiter implements RateLimiter
LimitConfig(capacity, refillPerSecond | windowSize, maxRequests)
LimitConfigProvider: configFor(key) -> LimitConfig     (per tier)
```

#### Key design decisions (algorithms)
| Algorithm | How | Pros | Cons |
|---|---|---|---|
| **Fixed window** | count per `floor(now / window)` | simplest, O(1) memory | burst at window edges (2× limit across a boundary) |
| **Sliding window log** | store request timestamps, drop the old ones | exact | O(limit) memory per key |
| **Sliding window counter** | current + previous window counts weighted by overlap | O(1), smooth, approximate | small inaccuracy |
| **Token bucket** | tokens refill at rate r up to capacity b; each request takes 1 | allows bursts up to b, smooth average | two parameters to tune |
| **Leaky bucket** | a queue drained at a constant rate | smooths output | adds latency (queueing) |

#### Core code
```java
interface RateLimiter { boolean allow(String key); }

/** Token bucket, lazy refill, lock-free per key using synchronized on a small bucket object */
class TokenBucketLimiter implements RateLimiter {
    private static final class Bucket { double tokens; long lastNanos; Bucket(double t, long n) { tokens = t; lastNanos = n; } }
    private final ConcurrentHashMap<String, Bucket> buckets = new ConcurrentHashMap<>();
    private final double capacity, refillPerNano; private final LongSupplier nanoClock;

    TokenBucketLimiter(long capacity, double refillPerSecond, LongSupplier nanoClock) {
        this.capacity = capacity; this.refillPerNano = refillPerSecond / 1e9; this.nanoClock = nanoClock;
    }
    public boolean allow(String key) {
        long now = nanoClock.getAsLong();
        Bucket b = buckets.computeIfAbsent(key, k -> new Bucket(capacity, now));
        synchronized (b) {                                         // per-key lock: no global contention
            b.tokens = Math.min(capacity, b.tokens + (now - b.lastNanos) * refillPerNano);
            b.lastNanos = now;
            if (b.tokens >= 1) { b.tokens -= 1; return true; }
            return false;
        }
    }
}

/** Sliding window log: exact, memory O(limit) per key */
class SlidingWindowLogLimiter implements RateLimiter {
    private final ConcurrentHashMap<String, Deque<Long>> logs = new ConcurrentHashMap<>();
    private final int max; private final long windowNanos; private final LongSupplier clock;
    SlidingWindowLogLimiter(int max, Duration window, LongSupplier clock) { this.max = max; this.windowNanos = window.toNanos(); this.clock = clock; }
    public boolean allow(String key) {
        long now = clock.getAsLong(); Deque<Long> q = logs.computeIfAbsent(key, k -> new ArrayDeque<>());
        synchronized (q) {
            while (!q.isEmpty() && now - q.peekFirst() >= windowNanos) q.pollFirst();
            if (q.size() < max) { q.addLast(now); return true; }
            return false;
        }
    }
}

/** Sliding window counter: approximation with O(1) memory */
class SlidingWindowCounterLimiter implements RateLimiter {
    private static final class W { long windowStart; int curr, prev; }
    private final ConcurrentHashMap<String, W> map = new ConcurrentHashMap<>();
    private final int max; private final long win; private final LongSupplier clock;
    SlidingWindowCounterLimiter(int max, Duration window, LongSupplier clock) { this.max = max; this.win = window.toNanos(); this.clock = clock; }
    public boolean allow(String key) {
        long now = clock.getAsLong(), start = now - (now % win); W w = map.computeIfAbsent(key, k -> new W());
        synchronized (w) {
            if (w.windowStart != start) { w.prev = (start - w.windowStart == win) ? w.curr : 0; w.curr = 0; w.windowStart = start; }
            double weight = 1.0 - (double) (now - start) / win;          // portion of previous window still in view
            if (w.prev * weight + w.curr < max) { w.curr++; return true; }
            return false;
        }
    }
}
```

#### Concurrency and edge cases
- Per-key `synchronized` on the bucket object: no global lock, and contention only among requests for the same key. A lock-free alternative: pack (tokens, timestamp) into an `AtomicLong` and use a CAS loop.
- Use `System.nanoTime()` (monotonic), not `currentTimeMillis` (wall clock jumps).
- **Memory**: evict idle buckets. Use Caffeine with `expireAfterAccess(10m)` instead of a raw map.
- Return `Retry-After` (for a token bucket: `(1 - tokens) / rate`).

#### Extensions the interviewer may add
?? "Make it work across 20 API servers."
A shared store: **Redis** with a Lua script so read-refill-decrement is atomic (a token bucket stored as a hash `{tokens, ts}` with a TTL). Or a sliding window counter with `INCR` + `EXPIRE` on per-window keys. Trade-off: one network round trip per request (about 1ms). Mitigations: local pre-allowance (each node gets a share of tokens and syncs periodically), and failing open if Redis is down (availability over strictness, a business decision). This is also an HLD topic.

?? "Where should rate limiting live?"
Layered: the API gateway or edge (per IP / API key, cheap rejection), service-level (per user, per expensive endpoint), and downstream protection (client-side limiter or bulkhead toward partner APIs). Return 429 with headers: `X-RateLimit-Limit`, `-Remaining`, `-Reset`, `Retry-After`.

?? "Why does a fixed window allow 2× bursts?"
With a limit of 100/min, a client sends 100 requests at 12:00:59 and 100 at 12:01:00. Both windows allow them, so that's 200 requests in 2 seconds. Sliding windows and token buckets avoid this.

#### Interview simulation
Clarify the key, limits, burst policy and distribution. Present the algorithm table (1 minute), pick the token bucket (explain why: burst-friendly, O(1)), implement it with an injectable clock, and write a quick test: capacity 5, refill 1/s, 6 immediate calls give 5 true and 1 false; advance the fake clock 1s, and one more is allowed. Then discuss the distributed Redis + Lua version. Your OnTheMove resume lists rate limiting, so tie it in: "We limited per API key at the gateway and per user at the service."

### LRU and LFU cache

#### Clarifying questions to ask
- *Capacity by number of entries or by memory?* → Count.
- *Operations?* → `get(key)` and `put(key, value)`, both O(1).
- *Eviction policy?* → LRU first; the follow-up is LFU (with LRU tie-breaking).
- *Thread safety?* → Discuss it after a single-threaded version.
- *TTL?* → An extension.

#### Requirements (agreed scope)
1. `get` returns the value or a miss, and marks the key as recently used.
2. `put` inserts or updates; evicts by policy when capacity is exceeded.
3. O(1) for both operations.
4. Pluggable eviction policy (LRU, LFU).
5. Thread-safe version.

#### Entities and class diagram
```
Cache<K,V>: get(K) -> Optional<V>, put(K,V)
LRUCache: HashMap<K, Node> + doubly linked list (head = most recent, tail = least)
LFUCache: HashMap<K, Node> + HashMap<freq, LinkedHashSet<K>> + minFreq
```

#### Core code
```java
public class LRUCache<K, V> {
    private final class Node { K key; V val; Node prev, next; Node(K k, V v) { key = k; val = v; } }
    private final int capacity; private final Map<K, Node> map = new HashMap<>();
    private final Node head = new Node(null, null), tail = new Node(null, null);   // sentinels: no null checks
    public LRUCache(int capacity) { if (capacity <= 0) throw new IllegalArgumentException(); this.capacity = capacity; head.next = tail; tail.prev = head; }

    public synchronized Optional<V> get(K key) {
        Node n = map.get(key); if (n == null) return Optional.empty();
        unlink(n); addFirst(n); return Optional.of(n.val);
    }
    public synchronized void put(K key, V val) {
        Node n = map.get(key);
        if (n != null) { n.val = val; unlink(n); addFirst(n); return; }
        if (map.size() == capacity) { Node lru = tail.prev; unlink(lru); map.remove(lru.key); }
        n = new Node(key, val); addFirst(n); map.put(key, n);
    }
    private void unlink(Node n) { n.prev.next = n.next; n.next.prev = n.prev; }
    private void addFirst(Node n) { n.next = head.next; n.prev = head; head.next.prev = n; head.next = n; }
}

public class LFUCache<K, V> {
    private record Entry<V>(V value, int freq) {}
    private final int capacity; private int minFreq = 0;
    private final Map<K, Entry<V>> entries = new HashMap<>();
    private final Map<Integer, LinkedHashSet<K>> buckets = new HashMap<>();     // freq -> keys in LRU order
    public LFUCache(int capacity) { this.capacity = capacity; }

    public synchronized Optional<V> get(K key) {
        Entry<V> e = entries.get(key); if (e == null) return Optional.empty();
        touch(key, e); return Optional.of(e.value());
    }
    public synchronized void put(K key, V value) {
        if (capacity == 0) return;
        Entry<V> e = entries.get(key);
        if (e != null) { entries.put(key, new Entry<>(value, e.freq())); touch(key, entries.get(key)); return; }
        if (entries.size() == capacity) {
            K evict = buckets.get(minFreq).iterator().next();                  // least freq, oldest within it
            buckets.get(minFreq).remove(evict); entries.remove(evict);
        }
        entries.put(key, new Entry<>(value, 1)); buckets.computeIfAbsent(1, f -> new LinkedHashSet<>()).add(key); minFreq = 1;
    }
    private void touch(K key, Entry<V> e) {
        int f = e.freq(); LinkedHashSet<K> set = buckets.get(f); set.remove(key);
        if (set.isEmpty()) { buckets.remove(f); if (minFreq == f) minFreq = f + 1; }
        entries.put(key, new Entry<>(e.value(), f + 1));
        buckets.computeIfAbsent(f + 1, x -> new LinkedHashSet<>()).add(key);
    }
}
```

#### Concurrency and edge cases
- `synchronized` methods are correct but serialise everything, and even `get` mutates the order, so a read-write lock doesn't help for LRU.
- High-throughput designs: **segmented / striped caches** (N independent LRUs by key hash, each with its own lock), or **Caffeine's approach**: reads are recorded into a lock-free ring buffer and replayed into the eviction policy asynchronously (approximate ordering, near-lock-free reads).
- Capacity 0 or 1, updating an existing key (no eviction), null keys (reject them).

#### Extensions the interviewer may add
?? "Add TTL per entry."
Store `expiresAt` in each node. On `get`, if expired, remove it and return a miss (lazy expiry). Add a periodic cleanup, or a min-heap/timing wheel keyed by expiry for proactive removal. Caffeine offers `expireAfterWrite` and `expireAfterAccess`, plus variable expiry via a timer wheel.

?? "LRU or LFU: which is better for a product cache?"
LRU adapts quickly to changing popularity but is polluted by one-off scans (a crawler). LFU keeps long-term hot items but adapts slowly. Modern caches blend them: W-TinyLFU (Caffeine) uses a frequency sketch for admission plus an LRU window, giving better hit rates for skewed, real-world workloads.

?? "Make eviction policy pluggable."
Define `EvictionPolicy<K>` with `onAccess(k)`, `onInsert(k)`, `onRemove(k)` and `victim()`. The cache holds the map, delegates ordering to the policy, and asks it for a victim when full.

#### Interview simulation
State the O(1) requirement and immediately name the structure: "a HashMap for lookup plus a doubly linked list for recency, with sentinel head and tail to avoid null checks." Code LRU in about 10 minutes, then test it verbally with capacity 2: put 1, put 2, get 1, put 3 evicts 2. If asked about LFU, explain the freq → LinkedHashSet buckets and `minFreq`, the trickiest part being updating `minFreq` when a bucket empties. Finish with the concurrency discussion.

### Logging framework

#### Clarifying questions to ask
- *Log levels?* → DEBUG, INFO, WARN, ERROR (FATAL optional); filter below the configured level.
- *Destinations (appenders)?* → Console, file, maybe a remote one; multiple at once.
- *Formatting?* → Configurable layout: timestamp, level, thread, logger name, message.
- *Sync or async?* → Async must not block request threads.
- *Per-logger configuration?* → Hierarchical loggers (`com.acme.orders` inherits from `com.acme`).

#### Requirements (agreed scope)
1. `logger.info("msg {}", arg)` style API with levels.
2. Level filtering per logger.
3. Multiple appenders, each with a formatter.
4. Thread-safe; async option.
5. Extensible: new appenders and formats without changing core code.

#### Entities and class diagram
```
LogLevel {DEBUG, INFO, WARN, ERROR}    LogEvent(timestamp, level, loggerName, thread, message, throwable)
Logger(name, level, appenders): debug/info/warn/error(...)
LoggerFactory: getLogger(name) → cached, inherits config from nearest parent
Appender (interface): append(LogEvent)   ← ConsoleAppender, FileAppender, AsyncAppender(decorator)
Formatter (interface): format(LogEvent)  ← PatternFormatter, JsonFormatter
```

#### Key design decisions
- **Chain of Responsibility / level checks**: the cheap level check happens before formatting (avoid building strings for disabled levels).
- **Strategy** for formatters; **Observer-like fan-out** to appenders.
- **Decorator**: `AsyncAppender` wraps any appender with a bounded queue and a background thread.
- **Singleton-ish factory** caching loggers per name.
- Parameterised messages (`{}`) so formatting is lazy.

#### Core code
```java
enum LogLevel { DEBUG, INFO, WARN, ERROR }
record LogEvent(Instant ts, LogLevel level, String logger, String thread, String message, Throwable error) {}

interface Formatter { String format(LogEvent e); }
class PatternFormatter implements Formatter {
    public String format(LogEvent e) {
        return "%s %-5s [%s] %s - %s".formatted(e.ts(), e.level(), e.thread(), e.logger(), e.message())
             + (e.error() != null ? "\n" + stackTrace(e.error()) : "");
    }
    private String stackTrace(Throwable t) { var sw = new StringWriter(); t.printStackTrace(new PrintWriter(sw)); return sw.toString(); }
}

interface Appender { void append(LogEvent e); default void close() {} }
class ConsoleAppender implements Appender {
    private final Formatter f; ConsoleAppender(Formatter f) { this.f = f; }
    public synchronized void append(LogEvent e) { (e.level() == LogLevel.ERROR ? System.err : System.out).println(f.format(e)); }
}
class FileAppender implements Appender {
    private final Formatter f; private final BufferedWriter out;
    FileAppender(Path p, Formatter f) throws IOException { this.f = f; this.out = Files.newBufferedWriter(p, StandardOpenOption.CREATE, StandardOpenOption.APPEND); }
    public synchronized void append(LogEvent e) { try { out.write(f.format(e)); out.newLine(); out.flush(); } catch (IOException ex) { System.err.println("log write failed: " + ex); } }
}
/** Decorator: makes any appender asynchronous; drops DEBUG/INFO when queue is full, never blocks callers */
class AsyncAppender implements Appender {
    private final BlockingQueue<LogEvent> q = new ArrayBlockingQueue<>(10_000); private final Appender delegate; private final Thread worker;
    AsyncAppender(Appender delegate) {
        this.delegate = delegate;
        worker = Thread.ofPlatform().daemon().name("async-log").start(() -> {
            try { while (true) delegate.append(q.take()); } catch (InterruptedException ie) { drain(); }
        });
    }
    public void append(LogEvent e) {
        if (!q.offer(e) && e.level().compareTo(LogLevel.WARN) >= 0) {
            try { q.put(e); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); }   // never drop WARN/ERROR
        }
    }
    private void drain() { List<LogEvent> rest = new ArrayList<>(); q.drainTo(rest); rest.forEach(delegate::append); }
    public void close() { worker.interrupt(); }
}

class Logger {
    private final String name; private volatile LogLevel level; private final List<Appender> appenders;
    Logger(String name, LogLevel level, List<Appender> appenders) { this.name = name; this.level = level; this.appenders = appenders; }
    public boolean isEnabled(LogLevel l) { return l.compareTo(level) >= 0; }
    public void info(String fmt, Object... args) { log(LogLevel.INFO, fmt, null, args); }
    public void error(String fmt, Throwable t, Object... args) { log(LogLevel.ERROR, fmt, t, args); }
    public void debug(String fmt, Object... args) { log(LogLevel.DEBUG, fmt, null, args); }
    private void log(LogLevel l, String fmt, Throwable t, Object... args) {
        if (!isEnabled(l)) return;                                  // cheap check first: no formatting cost
        LogEvent e = new LogEvent(Instant.now(), l, name, Thread.currentThread().getName(), render(fmt, args), t);
        for (Appender a : appenders) a.append(e);
    }
    private static String render(String fmt, Object[] args) {
        StringBuilder sb = new StringBuilder(); int ai = 0, i = 0;
        while (i < fmt.length()) {
            if (ai < args.length && fmt.startsWith("{}", i)) { sb.append(args[ai++]); i += 2; } else sb.append(fmt.charAt(i++));
        }
        return sb.toString();
    }
}

class LoggerFactory {
    private static final Map<String, Logger> LOGGERS = new ConcurrentHashMap<>();
    private static volatile Map<String, LogLevel> levels = Map.of("", LogLevel.INFO);   // "" = root
    private static volatile List<Appender> appenders = List.of(new ConsoleAppender(new PatternFormatter()));
    public static Logger getLogger(String name) { return LOGGERS.computeIfAbsent(name, n -> new Logger(n, resolveLevel(n), appenders)); }
    private static LogLevel resolveLevel(String name) {           // nearest configured ancestor: a.b.c → a.b → a → root
        for (String n = name; ; n = n.contains(".") ? n.substring(0, n.lastIndexOf('.')) : "") {
            LogLevel l = levels.get(n); if (l != null) return l; if (n.isEmpty()) return LogLevel.INFO;
        }
    }
}
```

#### Concurrency and edge cases
- Appenders are synchronised individually, so lines never interleave inside one destination.
- The async appender: a bounded queue, never blocking for low-priority logs, and a drain on shutdown (a JVM shutdown hook) so the last logs aren't lost.
- Formatting args lazily; guard expensive messages with `isEnabled`.
- Log injection: escape newlines in user input (attackers forging log lines). Mask PII and secrets.

#### Extensions the interviewer may add
?? "Add a JSON format for ELK/Loki."
A new `JsonFormatter` implementing `Formatter` (escape properly, include MDC fields like traceId). No core changes, which is OCP.

?? "Add MDC (context like requestId on every line)."
A `ThreadLocal<Map<String,String>>` copied into each `LogEvent` at creation (since an async appender runs on another thread). Clear it in request filters. That's how SLF4J's MDC works.

?? "Change log levels at runtime without restart."
`level` is volatile; an admin endpoint updates the configuration map and refreshes cached loggers (or loggers resolve the level through a shared, versioned config object). Spring Boot Actuator's `/loggers` endpoint does exactly this.

#### Interview simulation
Clarify levels, appenders, formats and sync vs async. Name the patterns: "Strategy for formatters, a list of appenders, Decorator for async, and a factory caching loggers." Code `Logger`, two appenders, the formatter and the async decorator. Demo it: create loggers for `com.acme` and `com.acme.orders` with different levels and show the filtering. Mention SLF4J and Logback as the real-world reference, and the async-drop policy, which shows production awareness.
