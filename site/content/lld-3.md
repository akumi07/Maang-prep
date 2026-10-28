## LLD problems II | P3 | must

### Tic-tac-toe and Snake & Ladder

#### Clarifying questions to ask
**Tic-tac-toe**
- *Board size: always 3×3 or N×N?* → N×N, with N in a row to win.
- *Players: 2 humans? A bot?* → Two players; a bot is an extension.
- *Undo? Game history?* → Extension.

**Snake & Ladder**
- *Board size, number of snakes and ladders, positions given as input?* → 100 cells; positions in the input.
- *Players and dice: one or more dice?* → N players, 1 die (pluggable).
- *Rules: exact roll needed to reach 100? Extra turn on a 6? Three 6s cancel the turn?* → Ask; make the rules configurable.

#### Requirements (agreed scope)
1. Play turns until a winner or a draw.
2. Validate moves (cell occupied, out of bounds).
3. Detect a win efficiently.
4. Pluggable players (human or bot) and dice.

#### Entities and class diagram
```
Tic-tac-toe:  Game(board, players, turn, status) ; Board(n, cells[][]) ; Player(name, symbol, MoveStrategy)
              WinChecker: O(1) per move using row/col/diag counters
Snake&Ladder: Game(board, players: Queue<Player>, dice) ; Board(size, jumps: Map<Integer,Integer>) ; Dice(interface)
```

#### Key design decisions
- **O(1) win check for N×N tic-tac-toe**: keep counters per row, column and both diagonals. Player X adds +1, O adds −1. If any counter reaches ±N, that player wins. No board scan.
- Snakes and ladders are just a **jump map** (start → end), so both are the same concept. Validate: no cycles, no jump starting at the last cell, no two jumps from one cell.
- **Strategy** for player moves (human input vs bot) and for dice (normal, loaded for tests, multiple dice).
- A **queue** for turn order (poll the current player, offer them back).

#### Core code
```java
// ---------- Tic-tac-toe (N x N) ----------
class TicTacToe {
    private final int n; private final char[][] board; private final int[] rows, cols; private int diag, anti, moves;
    private char turn = 'X'; private Character winner = null;
    TicTacToe(int n) { this.n = n; board = new char[n][n]; rows = new int[n]; cols = new int[n]; }

    /** returns winner symbol, 'D' for draw, or null if game continues */
    public Character move(int r, int c) {
        if (winner != null) throw new IllegalStateException("Game over");
        if (r < 0 || c < 0 || r >= n || c >= n || board[r][c] != 0) throw new IllegalArgumentException("Invalid cell");
        board[r][c] = turn; moves++;
        int d = turn == 'X' ? 1 : -1;
        rows[r] += d; cols[c] += d; if (r == c) diag += d; if (r + c == n - 1) anti += d;
        if (Math.abs(rows[r]) == n || Math.abs(cols[c]) == n || Math.abs(diag) == n || Math.abs(anti) == n) winner = turn;
        else if (moves == n * n) winner = 'D';
        turn = turn == 'X' ? 'O' : 'X';
        return winner;
    }
}

// ---------- Snake & Ladder ----------
interface Dice { int roll(); }
class StandardDice implements Dice { private final Random rnd; StandardDice(Random r) { rnd = r; } public int roll() { return rnd.nextInt(6) + 1; } }

record Player(String name) {}

class SnakeLadderGame {
    private final int size; private final Map<Integer, Integer> jumps; private final Dice dice;
    private final Deque<Player> turns; private final Map<Player, Integer> pos = new HashMap<>();

    SnakeLadderGame(int size, Map<Integer, Integer> jumps, List<Player> players, Dice dice) {
        validate(size, jumps);
        this.size = size; this.jumps = Map.copyOf(jumps); this.dice = dice; this.turns = new ArrayDeque<>(players);
        players.forEach(p -> pos.put(p, 0));
    }
    private static void validate(int size, Map<Integer, Integer> jumps) {
        for (var e : jumps.entrySet()) {
            int from = e.getKey(), to = e.getValue();
            if (from <= 1 || from >= size || to < 1 || to > size || from == to) throw new IllegalArgumentException("Bad jump " + from + "->" + to);
            if (jumps.containsKey(to)) throw new IllegalArgumentException("Chained jump at " + to);   // avoid cycles/chains
        }
    }
    /** plays until someone wins; returns winner */
    public Player play() {
        while (true) {
            Player p = turns.pollFirst(); int roll = dice.roll(); int next = pos.get(p) + roll;
            if (next <= size) {                                     // exact roll needed to finish
                next = jumps.getOrDefault(next, next);
                pos.put(p, next);
                System.out.printf("%s rolled %d -> %d%n", p.name(), roll, next);
                if (next == size) return p;
            }
            turns.addLast(p);
        }
    }
}
```

#### Concurrency and edge cases
- These are single-game, turn-based designs, so there's no concurrency within a game. For an online multiplayer server, each game is handled by one actor/thread or under a per-game lock; validate that it's the requesting player's turn.
- Tic-tac-toe: a move after the game is over, an occupied cell, out of bounds.
- Snake & Ladder: invalid configurations (a jump from 100, chained jumps), and the exact-finish rule.
- Testing randomness: inject a `Dice` that returns a scripted sequence.

#### Extensions the interviewer may add
?? "Add a bot for tic-tac-toe."
A `MoveStrategy` interface: `HumanStrategy` reads input; `BotStrategy` uses minimax with alpha-beta pruning (feasible for 3×3), or heuristics (win if possible, block if needed, take the centre, take a corner) for larger N.

?? "Support undo in tic-tac-toe."
Command pattern: each `Move` is a command with `undo()` (reverse the counters, clear the cell, restore the turn). Keep a stack of moves.

?? "Play many games concurrently on a server."
A `GameManager` with a `ConcurrentHashMap<gameId, Game>`; each game guarded by its own lock or processed sequentially through a single-threaded executor per game (actor model). Persist moves as events (an event log) for replay and recovery.

#### Interview simulation
These are warm-up LLD problems (30–45 minutes). Clarify the board size and rules, then highlight the **one clever bit** (the O(1) win counters; the jump map unifying snakes and ladders), code it cleanly, and show testability by injecting the dice. Interviewers use them to judge code clarity, so keep the classes small and well named.

### Chess

#### Clarifying questions to ask
- *Full rules (castling, en passant, promotion, check/checkmate/stalemate)?* → Core movement, check and checkmate; the special moves as extensions (state that clearly).
- *Two humans locally, or online?* → Two players, a local engine.
- *Timers (chess clock)?* → Extension.
- *Move notation input?* → Coordinates like `e2 e4`.

#### Requirements (agreed scope)
1. Initialise the board; alternate turns between white and black.
2. Validate moves per piece type, including path blocking.
3. Disallow moves that leave your own king in check.
4. Detect check, checkmate and stalemate.
5. Keep the move history.

#### Entities and class diagram
```
Game(board, players, currentTurn, status, moves: List<Move>)
Board(cells[8][8] of Piece?) : pieceAt(pos), move(from,to), isPathClear(from,to), kingPosition(color)
Position(row, col)   Color {WHITE, BLACK}   Move(from, to, piece, captured)
Piece (abstract: color) ── canMove(board, from, to) ; <|-- King, Queen, Rook, Bishop, Knight, Pawn
GameStatus {ACTIVE, CHECK, CHECKMATE, STALEMATE, RESIGNED}
```

#### Key design decisions
- **Polymorphism**: each piece implements its own movement rules via `canMove` (OCP: fairy-chess pieces become new classes).
- Shared sliding logic (rook, bishop, queen) in a helper: direction vectors plus `isPathClear`.
- **Legal move = pseudo-legal move that doesn't leave your own king attacked.** Implement it by trying the move on the board, checking `isUnderAttack(kingPos, opponent)`, then undoing it.
- **Command** for moves (enables undo and history); captured pieces are stored in the Move.

#### Core code
```java
enum Color { WHITE, BLACK; Color opposite() { return this == WHITE ? BLACK : WHITE; } }
record Position(int r, int c) { boolean valid() { return r >= 0 && r < 8 && c >= 0 && c < 8; } }

abstract class Piece {
    final Color color; Piece(Color c) { color = c; }
    abstract boolean canMove(Board b, Position from, Position to);          // pseudo-legal
    protected boolean slide(Board b, Position f, Position t, int[][] dirs) {
        int dr = Integer.signum(t.r() - f.r()), dc = Integer.signum(t.c() - f.c());
        boolean dirOk = Arrays.stream(dirs).anyMatch(d -> d[0] == dr && d[1] == dc)
                     && (f.r() == t.r() || f.c() == t.c() || Math.abs(t.r() - f.r()) == Math.abs(t.c() - f.c()));
        return dirOk && b.isPathClear(f, t) && b.isEmptyOrEnemy(t, color);
    }
}
class Rook extends Piece { Rook(Color c) { super(c); } boolean canMove(Board b, Position f, Position t) { return slide(b, f, t, new int[][]{{1,0},{-1,0},{0,1},{0,-1}}); } }
class Bishop extends Piece { Bishop(Color c) { super(c); } boolean canMove(Board b, Position f, Position t) { return slide(b, f, t, new int[][]{{1,1},{1,-1},{-1,1},{-1,-1}}); } }
class Queen extends Piece { Queen(Color c) { super(c); } boolean canMove(Board b, Position f, Position t) { return new Rook(color).canMove(b, f, t) || new Bishop(color).canMove(b, f, t); } }
class Knight extends Piece { Knight(Color c) { super(c); }
    boolean canMove(Board b, Position f, Position t) { int dr = Math.abs(f.r() - t.r()), dc = Math.abs(f.c() - t.c());
        return dr * dc == 2 && b.isEmptyOrEnemy(t, color); } }
class King extends Piece { King(Color c) { super(c); }
    boolean canMove(Board b, Position f, Position t) { return Math.max(Math.abs(f.r() - t.r()), Math.abs(f.c() - t.c())) == 1 && b.isEmptyOrEnemy(t, color); } }
class Pawn extends Piece { Pawn(Color c) { super(c); }
    boolean canMove(Board b, Position f, Position t) {
        int dir = color == Color.WHITE ? 1 : -1, start = color == Color.WHITE ? 1 : 6, dr = t.r() - f.r(), dc = Math.abs(t.c() - f.c());
        if (dc == 0 && dr == dir) return b.pieceAt(t) == null;
        if (dc == 0 && dr == 2 * dir && f.r() == start) return b.pieceAt(t) == null && b.isPathClear(f, t);
        if (dc == 1 && dr == dir) { Piece p = b.pieceAt(t); return p != null && p.color != color; }
        return false;
    }
}

class Board {
    private final Piece[][] g = new Piece[8][8];
    Piece pieceAt(Position p) { return g[p.r()][p.c()]; }
    void set(Position p, Piece x) { g[p.r()][p.c()] = x; }
    boolean isEmptyOrEnemy(Position p, Color me) { Piece x = pieceAt(p); return x == null || x.color != me; }
    boolean isPathClear(Position f, Position t) {
        int dr = Integer.signum(t.r() - f.r()), dc = Integer.signum(t.c() - f.c());
        for (int r = f.r() + dr, c = f.c() + dc; r != t.r() || c != t.c(); r += dr, c += dc) if (g[r][c] != null) return false;
        return true;
    }
    Position kingOf(Color col) { for (int r = 0; r < 8; r++) for (int c = 0; c < 8; c++) if (g[r][c] instanceof King k && k.color == col) return new Position(r, c); throw new IllegalStateException(); }
    boolean isAttacked(Position target, Color by) {
        for (int r = 0; r < 8; r++) for (int c = 0; c < 8; c++) { Piece p = g[r][c];
            if (p != null && p.color == by && p.canMove(this, new Position(r, c), target)) return true; }
        return false;
    }
}

class ChessGame {
    private final Board board; private Color turn = Color.WHITE; private final Deque<Move> history = new ArrayDeque<>();
    record Move(Position from, Position to, Piece moved, Piece captured) {}
    ChessGame(Board b) { board = b; }

    public String move(Position from, Position to) {
        Piece p = board.pieceAt(from);
        if (p == null || p.color != turn) throw new IllegalArgumentException("Not your piece");
        if (!to.valid() || !p.canMove(board, from, to)) throw new IllegalArgumentException("Illegal move");
        Move m = apply(from, to);
        if (board.isAttacked(board.kingOf(turn), turn.opposite())) { undo(m); throw new IllegalArgumentException("King would be in check"); }
        history.push(m); turn = turn.opposite();
        boolean inCheck = board.isAttacked(board.kingOf(turn), turn.opposite());
        boolean hasMove = hasAnyLegalMove(turn);
        return !hasMove ? (inCheck ? "CHECKMATE" : "STALEMATE") : (inCheck ? "CHECK" : "OK");
    }
    private Move apply(Position f, Position t) { Move m = new Move(f, t, board.pieceAt(f), board.pieceAt(t)); board.set(t, m.moved()); board.set(f, null); return m; }
    private void undo(Move m) { board.set(m.from(), m.moved()); board.set(m.to(), m.captured()); }
    private boolean hasAnyLegalMove(Color col) {
        for (int r = 0; r < 8; r++) for (int c = 0; c < 8; c++) {
            Position f = new Position(r, c); Piece p = board.pieceAt(f); if (p == null || p.color != col) continue;
            for (int r2 = 0; r2 < 8; r2++) for (int c2 = 0; c2 < 8; c2++) { Position t = new Position(r2, c2);
                if (!p.canMove(board, f, t)) continue;
                Move m = apply(f, t); boolean safe = !board.isAttacked(board.kingOf(col), col.opposite()); undo(m);
                if (safe) return true; }
        }
        return false;
    }
}
```

#### Concurrency and edge cases
- A local game is single-threaded. Online, a per-game lock; validate the player's identity against the turn.
- Moving the opponent's piece, moving onto your own piece, moving through pieces (except knights), pinned pieces (handled by the "king would be in check" test).
- Brute-force checkmate detection is 64×64 per position, fine for an interview. Engines use move generation instead.

#### Extensions the interviewer may add
?? "Add castling, en passant and promotion."
Track extra state: `hasMoved` per king and rook, the last move (for en passant), and a promotion choice. These are special-case moves in `ChessGame`, using a `MoveType` enum, so the regular piece logic stays clean. Castling also requires the king not to be in check and not to pass through attacked squares.

?? "Add a chess clock."
A `Clock` per player with remaining time. On each move, stop the mover's clock and start the opponent's (with an increment if configured). A scheduled timer flags a loss on timeout. Inject time for tests.

?? "How would you support online play and spectators?"
A game service holding authoritative state; moves submitted via WebSocket, validated server-side; events broadcast to both players and spectators; moves persisted as an event log (PGN) for replay and reconnection.

#### Interview simulation
Agree on scope early ("core moves plus check, checkmate and stalemate; castling, en passant and promotion as extensions"). Draw the Piece hierarchy, explain pseudo-legal vs legal moves (try, check the king, undo), code two or three pieces in full and the game loop, and describe the rest. Interviewers judge the **polymorphic piece design** and how you handle "can't leave the king in check", not a complete rules engine.

### Vending machine

#### Clarifying questions to ask
- *Payment: coins, notes, cards, UPI?* → Coins and notes for now; payment methods should be pluggable.
- *Return change? With limited coin inventory?* → Yes, with limited denominations (greedy change-making with inventory).
- *Multiple products, slots, restocking?* → Yes; an admin restocks.
- *Cancel mid-transaction?* → Refund the inserted amount.

#### Requirements (agreed scope)
1. Select a product, insert money, dispense the product and change.
2. Reject a selection when sold out; refund on cancel.
3. Reject the sale if exact change can't be made.
4. Admin: restock products and coins.
5. Behaviour depends on the current state.

#### Entities and class diagram
```
VendingMachine(state, inventory, coinBox, selected, balance)
State (interface): selectProduct, insertMoney, dispense, cancel
   <|-- IdleState, ProductSelectedState (accepting money), DispensingState
Inventory: Map<slotCode, Slot(product, count)>    Product(name, pricePaise)
CoinBox: Map<Denomination, count> ; makeChange(amount) -> Optional<Map<Denomination,count>>
Denomination enum {ONE(100), TWO(200), FIVE(500), TEN(1000), TWENTY(2000), FIFTY(5000), HUNDRED(10000)}
```

#### Key design decisions
- **State pattern**: the canonical example. Each state handles events differently (inserting money while idle is rejected, selecting while dispensing is ignored).
- **Change-making** with limited coins: greedy works for canonical coin systems (like INR) **when inventory isn't a constraint**. With limited coins, greedy can fail even though change is possible (use bounded DP for correctness; mention this).
- Check change *before* dispensing (atomic sale): if change can't be made, refund and don't dispense.

#### Core code
```java
enum Denomination { ONE(100), TWO(200), FIVE(500), TEN(1000), TWENTY(2000), FIFTY(5000), HUNDRED(10000);
    final long paise; Denomination(long p) { paise = p; } }
record Product(String name, long pricePaise) {}

class CoinBox {
    private final EnumMap<Denomination, Integer> coins = new EnumMap<>(Denomination.class);
    void add(Denomination d, int n) { coins.merge(d, n, Integer::sum); }
    /** greedy over available inventory; returns empty if exact change impossible with greedy */
    Optional<Map<Denomination, Integer>> makeChange(long amount) {
        Map<Denomination, Integer> out = new EnumMap<>(Denomination.class);
        Denomination[] ds = Denomination.values();
        for (int i = ds.length - 1; i >= 0 && amount > 0; i--) {
            int use = (int) Math.min(amount / ds[i].paise, coins.getOrDefault(ds[i], 0));
            if (use > 0) { out.put(ds[i], use); amount -= use * ds[i].paise; }
        }
        return amount == 0 ? Optional.of(out) : Optional.empty();
    }
    void remove(Map<Denomination, Integer> change) { change.forEach((d, n) -> coins.merge(d, -n, Integer::sum)); }
}

interface State {
    default void select(VendingMachine m, String slot) { throw new IllegalStateException("Cannot select now"); }
    default void insert(VendingMachine m, Denomination d) { throw new IllegalStateException("Cannot insert now"); }
    default void cancel(VendingMachine m) { /* nothing to cancel */ }
}
class IdleState implements State {
    public void select(VendingMachine m, String slot) {
        if (!m.inventory.inStock(slot)) throw new IllegalStateException("Sold out");
        m.selected = slot; m.state = new HasSelectionState();
    }
}
class HasSelectionState implements State {
    public void insert(VendingMachine m, Denomination d) {
        m.inserted.add(d); m.balance += d.paise; m.coinBox.add(d, 1);
        long price = m.inventory.price(m.selected);
        if (m.balance >= price) m.completeSale(price);
    }
    public void cancel(VendingMachine m) { m.refundAll(); }
}

class VendingMachine {
    State state = new IdleState(); String selected; long balance; final List<Denomination> inserted = new ArrayList<>();
    final Inventory inventory; final CoinBox coinBox;
    VendingMachine(Inventory i, CoinBox c) { inventory = i; coinBox = c; }

    public synchronized void select(String slot) { state.select(this, slot); }
    public synchronized void insert(Denomination d) { state.insert(this, d); }
    public synchronized void cancel() { state.cancel(this); }

    void completeSale(long price) {
        Optional<Map<Denomination, Integer>> change = coinBox.makeChange(balance - price);
        if (change.isEmpty()) { System.out.println("Cannot make change, refunding"); refundAll(); return; }
        coinBox.remove(change.get()); inventory.decrement(selected);
        System.out.println("Dispensed " + selected + ", change " + change.get());
        reset();
    }
    void refundAll() {
        Map<Denomination, Integer> back = new EnumMap<>(Denomination.class);
        inserted.forEach(d -> back.merge(d, 1, Integer::sum)); coinBox.remove(back);
        System.out.println("Refunded " + back); reset();
    }
    private void reset() { selected = null; balance = 0; inserted.clear(); state = new IdleState(); }
}

class Inventory {
    private final Map<String, Product> products = new HashMap<>(); private final Map<String, Integer> counts = new HashMap<>();
    void restock(String slot, Product p, int n) { products.put(slot, p); counts.merge(slot, n, Integer::sum); }
    boolean inStock(String slot) { return counts.getOrDefault(slot, 0) > 0; }
    long price(String slot) { return products.get(slot).pricePaise(); }
    void decrement(String slot) { counts.merge(slot, -1, Integer::sum); }
}
```

#### Concurrency and edge cases
- A physical machine has one user at a time, but the methods are `synchronized` since the hardware sensors (coin acceptor, keypad) call in from different threads.
- Refund the exact coins inserted (simplest, always possible).
- Change can't be made: refund and don't dispense. Sold out after selection (another slot jams): refund.
- Coins that the inventory can't return: greedy limitations. For correctness with limited coins, use bounded-knapsack DP (amount ≤ a few thousand paise steps).

#### Extensions the interviewer may add
?? "Add card or UPI payment."
A `PaymentMethod` strategy: `CashPayment` (the coin flow above), `UpiPayment` (show a QR code, wait for the callback with a timeout, which becomes a new `AwaitingPaymentState`). The states coordinate; payment logic stays in the strategy.

?? "When does greedy change-making fail?"
For non-canonical coin systems (coins 1, 3, 4, amount 6: greedy gives 4+1+1, optimal is 3+3), or with limited inventory (needing 6 with coins {5×1, 3×2}: greedy takes the 5 and then fails, while 3+3 works). The fix is DP over the available counts.

?? "How do you monitor a fleet of 10,000 machines?"
Each machine reports telemetry (sales, stock levels, faults) over MQTT to a backend. Restock routes are planned from predicted depletion. Prices are pushed down as configuration. That links LLD to an IoT system design.

#### Interview simulation
Say "This is a natural State machine" in the first minute, and draw the state diagram: `Idle --select--> HasSelection --insert (enough)--> Dispensing --> Idle`, with cancel going back to Idle via refund. Code the states, the change-making and the sale's atomicity check, and demo: buy a ₹15 item with a ₹20 note and get ₹5 change; then a no-change scenario with a refund. Mention the greedy-vs-DP caveat unprompted.

### ATM

#### Clarifying questions to ask
- *Operations?* → Balance inquiry, withdrawal, deposit, PIN change, mini statement.
- *Authentication?* → Card plus PIN, verified by the bank; card blocked after 3 wrong attempts.
- *Cash dispensing?* → Notes of ₹2000/500/200/100 with limited counts; dispense the minimum number of notes.
- *Who holds account state?* → The bank's backend (the ATM is a client), so we need network failure handling.
- *Limits?* → A daily withdrawal limit per card.

#### Requirements (agreed scope)
1. Card insertion, PIN validation (3 attempts).
2. Withdraw: check balance and limits, dispense notes, debit the account, consistently.
3. Deposit, balance check.
4. Handle partial failures (debited but cash not dispensed).
5. Session state machine.

#### Entities and class diagram
```
ATM(id, state, cashDispenser, cardReader, bankClient, session)
ATMState: Idle, CardInserted, Authenticated, Transacting (State pattern)
CashDispenser: chain of NoteDispenser(₹2000) -> NoteDispenser(₹500) -> NoteDispenser(₹200) -> NoteDispenser(₹100)
BankClient (interface): verifyPin(card, pin), authorizeWithdrawal(txnId, card, amt), confirm(txnId), reverse(txnId), balance(card)
Transaction(id, type, amount, status{INITIATED, AUTHORIZED, DISPENSED, CONFIRMED, REVERSED})
```

#### Key design decisions
- **State pattern** for the session flow.
- **Chain of Responsibility** for note dispensing (each handler takes as many of its notes as possible and passes the remainder). It's the classic textbook example.
- **Two-phase withdrawal**: *authorize (hold funds) → dispense → confirm*; if dispensing fails, *reverse*. Every bank call carries an **idempotent transaction id**, so retries after network failures are safe.
- Check that the cash can be dispensed **before** authorising (avoid unnecessary holds).

#### Core code
```java
abstract class NoteDispenser {
    private final int noteValue; private int available; private NoteDispenser next;
    NoteDispenser(int noteValue, int available) { this.noteValue = noteValue; this.available = available; }
    NoteDispenser then(NoteDispenser n) { this.next = n; return n; }

    /** plan only (no mutation): returns notes to give or empty if impossible */
    Optional<Map<Integer, Integer>> plan(int amount) {
        int use = Math.min(amount / noteValue, available);
        for (int u = use; u >= 0; u--) {                                    // backtrack: fewer big notes if remainder unpayable
            int rest = amount - u * noteValue;
            Optional<Map<Integer, Integer>> tail = rest == 0 ? Optional.of(new HashMap<>()) : (next == null ? Optional.empty() : next.plan(rest));
            if (tail.isPresent()) { if (u > 0) tail.get().put(noteValue, u); return tail; }
        }
        return Optional.empty();
    }
    void dispense(Map<Integer, Integer> plan) { available -= plan.getOrDefault(noteValue, 0); if (next != null) next.dispense(plan); }
}
class Note2000 extends NoteDispenser { Note2000(int n) { super(2000, n); } }
class Note500 extends NoteDispenser { Note500(int n) { super(500, n); } }
class Note200 extends NoteDispenser { Note200(int n) { super(200, n); } }
class Note100 extends NoteDispenser { Note100(int n) { super(100, n); } }

interface BankClient {
    boolean verifyPin(String card, String pin);
    boolean authorize(String txnId, String card, long amount);     // idempotent on txnId: holds funds
    void confirm(String txnId);                                     // idempotent
    void reverse(String txnId);                                     // idempotent: releases hold
}

class WithdrawalService {
    private final NoteDispenser chain; private final BankClient bank;
    WithdrawalService(NoteDispenser chain, BankClient bank) { this.chain = chain; this.bank = bank; }

    public synchronized Map<Integer, Integer> withdraw(String card, int amount) {
        if (amount <= 0 || amount % 100 != 0) throw new IllegalArgumentException("Amount must be a multiple of 100");
        Map<Integer, Integer> plan = chain.plan(amount).orElseThrow(() -> new IllegalStateException("Cannot dispense this amount"));
        String txnId = UUID.randomUUID().toString();
        if (!bank.authorize(txnId, card, amount)) throw new IllegalStateException("Insufficient funds or limit exceeded");
        try {
            chain.dispense(plan);              // hardware call in real life; may fail (jam)
            bank.confirm(txnId);
            return plan;
        } catch (RuntimeException hardwareFailure) {
            bank.reverse(txnId);               // money never left the machine → release hold
            throw hardwareFailure;
        }
    }
}
```

#### Concurrency and edge cases
- One customer per ATM, but cash inventory and network calls need care. The `synchronized` withdraw is a single-session critical section.
- **Network timeout after authorize**: we don't know if the bank holds the funds. Retry `authorize` with the **same txnId** (idempotent), or `reverse(txnId)`, which is safe even if nothing was held. The bank reconciles from the ATM's journal.
- **Notes dispensed but the customer didn't take them**: the machine retracts the cash and reverses. **Power failure mid-dispense**: the electronic journal plus reconciliation.
- PIN attempts: count per card at the bank, block after 3. Never log the PIN; the PIN block is encrypted in hardware (HSM).

#### Extensions the interviewer may add
?? "Why not just call debit(amount) and then dispense?"
If dispensing fails after the debit, the customer loses money until manual reconciliation. Authorize (hold) → dispense → confirm, with reverse on failure, gives a clear recovery path, and the idempotent txnId makes the network retries safe. It's a mini two-phase commit or saga.

?? "Dispense with the fewest notes but also preserve small notes for later customers."
Change the planning strategy: a `DispenseStrategy` interface, with `FewestNotes` and `BalancedNotes` (mix in some ₹500s even when ₹2000s are available, based on inventory levels). Bank ATMs do tune this.

?? "Add cardless (UPI) withdrawal."
A new authentication path: the ATM shows a QR code with a session id, the user approves in their UPI app, and the bank notifies the ATM backend. That's a new state (`AwaitingUpiApproval`) with a timeout. The withdrawal flow afterwards is unchanged.

#### Interview simulation
Clarify the operations, the note types and who owns the balances. Highlight two things: **Chain of Responsibility** for dispensing (show the planning with backtracking, which handles cases like ₹600 when only ₹500 and ₹200 notes are left) and **the failure-safe withdrawal protocol**. When you narrate "authorize, dispense, confirm, or reverse, all idempotent by txnId", interviewers recognise distributed-systems maturity in an LLD round.

### Library management system

#### Clarifying questions to ask
- *Books vs copies?* → A book (ISBN, title, authors) has many physical copies (barcodes).
- *Members and limits?* → Members can borrow up to 5 books for 14 days.
- *Reservations/holds when all copies are out?* → Yes, a FIFO waitlist.
- *Fines for late returns?* → ₹10 per day (configurable).
- *Search?* → By title, author, ISBN.

#### Requirements (agreed scope)
1. Add books and copies; search the catalogue.
2. Issue a copy to a member (enforce limits and availability).
3. Return a copy; compute fines; notify the next reservation.
4. Reserve a book when no copies are available.
5. Renew if nobody is waiting.

#### Entities and class diagram
```
Book(isbn, title, authors, subjects)  BookCopy(barcode, isbn, status{AVAILABLE, LOANED, RESERVED_HOLD, LOST})
Member(id, name, maxLoans, activeLoans)   Librarian
Loan(id, copy, member, issuedAt, dueAt, returnedAt)   Reservation(isbn, memberId, createdAt, status)
Catalog: search(byTitle/author/isbn) — inverted indexes
LibraryService: issue, returnCopy, reserve, renew
FinePolicy (strategy): fine(loan, returnedAt)
NotificationService (observer): onCopyAvailableForReservation(...)
```

#### Key design decisions
- **Book vs BookCopy** separation (the most common modelling mistake is merging them).
- Reservations are a **per-ISBN FIFO queue**. On return, if the queue is non-empty, the copy goes to `RESERVED_HOLD` for the first member (with a pickup deadline) instead of AVAILABLE.
- **Strategy** for the fine policy; **Observer** for notifications.
- Simple **inverted index** maps for search (word → ISBNs).

#### Core code
```java
enum CopyStatus { AVAILABLE, LOANED, ON_HOLD, LOST }
record Book(String isbn, String title, List<String> authors) {}
final class BookCopy { final String barcode, isbn; CopyStatus status = CopyStatus.AVAILABLE; String holdFor;
    BookCopy(String b, String i) { barcode = b; isbn = i; } }
final class Member { final String id; final int maxLoans; final Set<String> activeLoanIds = new HashSet<>();
    Member(String id, int max) { this.id = id; this.maxLoans = max; } }
record Loan(String id, String barcode, String memberId, LocalDate issued, LocalDate due) {}

interface FinePolicy { long finePaise(Loan l, LocalDate returned); }
class PerDayFine implements FinePolicy { public long finePaise(Loan l, LocalDate r) { long late = ChronoUnit.DAYS.between(l.due(), r); return Math.max(0, late) * 1000; } }

class LibraryService {
    private final Map<String, Book> books = new HashMap<>(); private final Map<String, BookCopy> copies = new HashMap<>();
    private final Map<String, Member> members = new HashMap<>(); private final Map<String, Loan> loansByBarcode = new HashMap<>();
    private final Map<String, Deque<String>> reservations = new HashMap<>();            // isbn -> memberIds FIFO
    private final FinePolicy fines; private final Clock clock; private final Consumer<String> notifier;
    LibraryService(FinePolicy f, Clock c, Consumer<String> notifier) { fines = f; clock = c; this.notifier = notifier; }

    public synchronized Loan issue(String barcode, String memberId) {
        BookCopy c = copies.get(barcode); Member m = members.get(memberId);
        if (m.activeLoanIds.size() >= m.maxLoans) throw new IllegalStateException("Loan limit reached");
        boolean heldForMe = c.status == CopyStatus.ON_HOLD && memberId.equals(c.holdFor);
        if (c.status != CopyStatus.AVAILABLE && !heldForMe) throw new IllegalStateException("Copy not available");
        if (heldForMe) reservations.get(c.isbn).remove(memberId);
        LocalDate today = LocalDate.now(clock);
        Loan loan = new Loan(UUID.randomUUID().toString(), barcode, memberId, today, today.plusDays(14));
        c.status = CopyStatus.LOANED; c.holdFor = null; loansByBarcode.put(barcode, loan); m.activeLoanIds.add(loan.id());
        return loan;
    }

    public synchronized long returnCopy(String barcode) {
        Loan loan = Optional.ofNullable(loansByBarcode.remove(barcode)).orElseThrow(() -> new IllegalStateException("Not on loan"));
        members.get(loan.memberId()).activeLoanIds.remove(loan.id());
        long fine = fines.finePaise(loan, LocalDate.now(clock));
        BookCopy c = copies.get(barcode);
        Deque<String> q = reservations.getOrDefault(c.isbn, new ArrayDeque<>());
        if (!q.isEmpty()) { c.status = CopyStatus.ON_HOLD; c.holdFor = q.peekFirst(); notifier.accept("Book " + c.isbn + " ready for " + c.holdFor); }
        else c.status = CopyStatus.AVAILABLE;
        return fine;
    }

    public synchronized void reserve(String isbn, String memberId) {
        boolean anyAvailable = copies.values().stream().anyMatch(c -> c.isbn.equals(isbn) && c.status == CopyStatus.AVAILABLE);
        if (anyAvailable) throw new IllegalStateException("Copies available — just issue one");
        Deque<String> q = reservations.computeIfAbsent(isbn, k -> new ArrayDeque<>());
        if (q.contains(memberId)) throw new IllegalStateException("Already reserved");
        q.addLast(memberId);
    }
}
```

#### Concurrency and edge cases
- Several librarian desks may issue at once, so the service methods are synchronised (a fine granularity isn't needed at library scale; in a DB, use row locks on the copy).
- A hold expires if the member doesn't pick up within N days: the next member in the queue gets it (a scheduled job).
- A lost copy: mark it LOST and charge the replacement cost. Renewal is blocked if others are waiting.
- A member with unpaid fines over a threshold can't borrow (a policy check).

#### Extensions the interviewer may add
?? "Add search by title or author with partial matches."
Build an inverted index: tokenize titles and authors (lowercase), map token → set of ISBNs, and intersect the sets for multi-word queries. For production, push to Elasticsearch.

?? "Different member types (student, faculty) with different limits and loan periods."
A `MembershipPlan` (maxLoans, loanDays, finePolicy) attached to the Member: data or strategy, not subclasses with hardcoded numbers.

?? "Send due-date reminders."
A daily scheduled job queries loans due in 2 days and publishes reminder events to a NotificationService (Observer/pub-sub). It must be idempotent, so record the reminders sent.

#### Interview simulation
Show the modelling insight first: "Book is the catalogue entry, BookCopy is the physical item that gets loaned." Then the reservation flow on return. Code issue, return and reserve with the validations. Demo: two members, one copy; A borrows, B reserves, A returns late (fine), B gets notified and borrows. Clean domain modelling is the main thing being evaluated here.

### In-memory pub-sub message queue

#### Clarifying questions to ask
- *Topics with multiple subscribers, each getting every message (pub-sub)? Or competing consumers (queue)?* → Topics; also consumer groups as a follow-up.
- *Ordering guarantees?* → Per topic (or per partition key).
- *Delivery semantics?* → At-least-once, with acknowledgement and retry.
- *Persistence?* → In memory; retention by count or time.
- *Slow subscribers?* → Must not block the publisher or other subscribers.

#### Requirements (agreed scope)
1. Create topics; publish messages; subscribe with a handler.
2. Every subscriber gets every message, in order.
3. Each subscriber consumes at its own pace (offset per subscriber).
4. Retry on handler failure; dead-letter after N attempts.
5. Replay from an offset (reset).

#### Entities and class diagram
```
Message(id, key, payload, timestamp)
Topic(name, log: List<Message>)                          // append-only log, like Kafka
Subscriber(id, handler, offset: AtomicLong, maxRetries)
SubscriberWorker (Runnable): loop { wait for new msg at offset; handle; on success offset++ ; on failure retry/DLQ }
Broker: createTopic, publish(topic, msg), subscribe(topic, subscriber), resetOffset(...)
```

#### Key design decisions
- Model each topic as an **append-only log** with **per-subscriber offsets** (the Kafka model), instead of copying messages into per-subscriber queues. One storage copy, independent consumers, and replay for free.
- **One worker thread per subscriber** (or a virtual thread): a slow subscriber only delays itself.
- Workers **wait/notify** (or a `Condition`) on new appends instead of busy-polling.
- **At-least-once**: advance the offset only after the handler succeeds; retry with backoff; dead-letter after N attempts.

#### Core code
```java
record Message(String id, String key, String payload, Instant ts) {}

class Topic {
    final String name; private final List<Message> log = new ArrayList<>();
    private final ReentrantLock lock = new ReentrantLock(); private final Condition appended = lock.newCondition();
    Topic(String name) { this.name = name; }
    long append(Message m) { lock.lock(); try { log.add(m); appended.signalAll(); return log.size() - 1; } finally { lock.unlock(); } }
    /** blocks until a message exists at offset (or timeout) */
    Optional<Message> awaitAt(long offset, Duration timeout) throws InterruptedException {
        lock.lock();
        try {
            long nanos = timeout.toNanos();
            while (offset >= log.size()) { if (nanos <= 0) return Optional.empty(); nanos = appended.awaitNanos(nanos); }
            return Optional.of(log.get((int) offset));
        } finally { lock.unlock(); }
    }
}

interface MessageHandler { void handle(Message m) throws Exception; }

class Subscriber implements Runnable {
    final String id; private final Topic topic; private final MessageHandler handler; private final AtomicLong offset = new AtomicLong();
    private final int maxRetries; private final Consumer<Message> deadLetter; private volatile boolean running = true;
    Subscriber(String id, Topic t, MessageHandler h, int maxRetries, Consumer<Message> dlq) { this.id = id; topic = t; handler = h; this.maxRetries = maxRetries; deadLetter = dlq; }

    public void run() {
        while (running) {
            try {
                Optional<Message> m = topic.awaitAt(offset.get(), Duration.ofSeconds(1));
                if (m.isEmpty()) continue;
                deliver(m.get());
                offset.incrementAndGet();                        // commit after processing → at-least-once
            } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
        }
    }
    private void deliver(Message m) throws InterruptedException {
        for (int attempt = 1; ; attempt++) {
            try { handler.handle(m); return; }
            catch (Exception e) {
                if (attempt > maxRetries) { deadLetter.accept(m); return; }
                Thread.sleep(Math.min(1000, 50L << attempt));   // exponential backoff
            }
        }
    }
    void resetTo(long newOffset) { offset.set(newOffset); }
    void stop() { running = false; }
}

class Broker {
    private final Map<String, Topic> topics = new ConcurrentHashMap<>();
    private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
    private final List<Message> dlq = Collections.synchronizedList(new ArrayList<>());
    public void createTopic(String name) { topics.putIfAbsent(name, new Topic(name)); }
    public long publish(String topic, String key, String payload) {
        return Optional.ofNullable(topics.get(topic)).orElseThrow().append(new Message(UUID.randomUUID().toString(), key, payload, Instant.now()));
    }
    public Subscriber subscribe(String topic, String subId, MessageHandler h) {
        Subscriber s = new Subscriber(subId, topics.get(topic), h, 3, dlq::add); workers.submit(s); return s;
    }
}
```

#### Concurrency and edge cases
- Publishers append under the topic lock (short); subscribers read under it and process **outside** it, so a slow handler never blocks publishing.
- **At-least-once** means a crash between handling and the offset increment causes redelivery, so handlers must be **idempotent** (dedupe by message id).
- Unbounded log growth: add retention (drop messages below the minimum subscriber offset, or older than T), adjusting offsets with a base index.
- Backpressure: if a subscriber lags too far behind retention, alert or skip ahead (a policy decision).

#### Extensions the interviewer may add
?? "Add consumer groups (competing consumers sharing work)."
Partition the topic into P logs by `hash(key) % P`. Each group assigns partitions to its members (each partition to exactly one member), giving parallelism with per-key ordering. Rebalance on join and leave. That's literally Kafka's model; explain it.

?? "How is this different from Kafka or RabbitMQ in production?"
Kafka: a durable, replicated, partitioned log on disk, consumer offsets stored in Kafka, huge throughput, replay. RabbitMQ: a broker pushing messages from queues, per-message ack and routing (exchanges), messages deleted after ack. Our design mirrors Kafka's log + offsets, minus durability and replication.

?? "Guarantee exactly-once processing?"
Practically: at-least-once delivery + idempotent consumers (a dedupe table keyed by message id, written in the same transaction as the side effect). Kafka's exactly-once (transactions) covers read-process-write within Kafka itself, not arbitrary external side effects.

#### Interview simulation
Clarify pub-sub vs queue semantics and the delivery guarantee. Present the core idea ("append-only log per topic, offset per subscriber, one worker per subscriber; commit the offset after processing gives at-least-once"), code Topic's await mechanism and the Subscriber loop with retries and DLQ, and demo two subscribers at different speeds. Then answer consumer groups and partitions. That bridge to Kafka is what makes this answer stand out.

### Cab booking (Uber / Ola)

#### Clarifying questions to ask
- *Core flow?* → A rider requests a ride (pickup, drop) → nearby available drivers are matched → a driver accepts → trip starts → trip ends → fare → payment.
- *Matching rule?* → The nearest available driver within a radius; offer to one driver at a time with a timeout, or to several drivers.
- *Vehicle types?* → Mini, Sedan, SUV, Auto with different fares.
- *Surge pricing?* → Pricing strategy; surge as an extension.
- *Cancellations, ratings?* → Ratings are an extension; cancellation with a fee is a nice touch.

#### Requirements (agreed scope)
1. Drivers go online or offline and update their location.
2. A rider requests a ride for a vehicle type; the system finds the nearest available driver.
3. A driver accepts or rejects; reassign on rejection or timeout.
4. Trip lifecycle: REQUESTED → ACCEPTED → STARTED → COMPLETED (or CANCELLED).
5. Fare calculation with a pluggable pricing strategy.
6. No driver can be assigned to two trips at once.

#### Entities and class diagram
```
Rider(id, name)  Driver(id, vehicle, status{OFFLINE, AVAILABLE, ON_TRIP}, location)
Vehicle(number, type{AUTO, MINI, SEDAN, SUV})   Location(lat, lng)
Trip(id, rider, driver?, pickup, drop, type, status, fare, timestamps)
DriverLocator (interface): nearestAvailable(location, type, radius, exclude) -> List<Driver>   ← GridIndexLocator
MatchingStrategy: NearestFirst, HighestRatedNearby
PricingStrategy: BaseFarePricing(base + perKm + perMin) , SurgePricing(decorator)
TripService: requestRide, accept, reject, start, end, cancel
```

#### Key design decisions
- **Spatial index**: for the interview, a **grid** (cells of about 1km keyed by `floor(lat/size), floor(lng/size)`), searching the neighbouring cells in growing rings. In production: **geohash** or **H3** cells, Redis GEO, or a quadtree.
- **Atomic driver claim**: `driver.status` goes AVAILABLE → ON_TRIP via a CAS, so two concurrent requests can't grab the same driver.
- **State machine** for Trip transitions (reject invalid ones: you can't end a trip that hasn't started).
- **Strategies** for matching and pricing; **Decorator** for surge.

#### Core code
```java
enum VehicleType { AUTO, MINI, SEDAN, SUV }
enum DriverStatus { OFFLINE, AVAILABLE, ON_TRIP }
enum TripStatus { REQUESTED, ACCEPTED, STARTED, COMPLETED, CANCELLED }
record Location(double lat, double lng) {
    double kmTo(Location o) { double dLat = Math.toRadians(o.lat - lat), dLng = Math.toRadians(o.lng - lng);
        double a = Math.pow(Math.sin(dLat / 2), 2) + Math.cos(Math.toRadians(lat)) * Math.cos(Math.toRadians(o.lat)) * Math.pow(Math.sin(dLng / 2), 2);
        return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)); }               // haversine
}

final class Driver {
    final String id; final VehicleType type; volatile Location location;
    private final AtomicReference<DriverStatus> status = new AtomicReference<>(DriverStatus.OFFLINE);
    Driver(String id, VehicleType t, Location l) { this.id = id; type = t; location = l; }
    boolean claim() { return status.compareAndSet(DriverStatus.AVAILABLE, DriverStatus.ON_TRIP); }
    void free() { status.set(DriverStatus.AVAILABLE); }
    void goOnline() { status.set(DriverStatus.AVAILABLE); }
    boolean available() { return status.get() == DriverStatus.AVAILABLE; }
}

/** simple grid spatial index: cell = floor(coord / CELL) */
class GridIndex {
    private static final double CELL = 0.01;                                 // ~1.1 km
    private final Map<Long, Set<Driver>> cells = new ConcurrentHashMap<>();
    private final Map<String, Long> cellOf = new ConcurrentHashMap<>();
    private static long key(int x, int y) { return ((long) x << 32) ^ (y & 0xffffffffL); }
    private static int cx(double v) { return (int) Math.floor(v / CELL); }

    void update(Driver d) {
        long k = key(cx(d.location.lat()), cx(d.location.lng()));
        Long old = cellOf.put(d.id, k);
        if (old != null && old != k) cells.getOrDefault(old, Set.of()).remove(d);
        cells.computeIfAbsent(k, x -> ConcurrentHashMap.newKeySet()).add(d);
    }
    List<Driver> nearby(Location at, VehicleType t, int maxRings) {
        int x = cx(at.lat()), y = cx(at.lng());
        for (int ring = 0; ring <= maxRings; ring++) {                       // expand search ring by ring
            List<Driver> found = new ArrayList<>();
            for (int i = x - ring; i <= x + ring; i++) for (int j = y - ring; j <= y + ring; j++)
                for (Driver d : cells.getOrDefault(key(i, j), Set.of())) if (d.type == t && d.available()) found.add(d);
            if (!found.isEmpty()) { found.sort(Comparator.comparingDouble(d -> d.location.kmTo(at))); return found; }
        }
        return List.of();
    }
}

interface PricingStrategy { long farePaise(VehicleType t, double km, long minutes); }
class BasePricing implements PricingStrategy {
    public long farePaise(VehicleType t, double km, long min) {
        long base = switch (t) { case AUTO -> 3000; case MINI -> 5000; case SEDAN -> 7000; case SUV -> 9000; };
        long perKm = switch (t) { case AUTO -> 1200; case MINI -> 1400; case SEDAN -> 1800; case SUV -> 2200; };
        return base + Math.round(km * perKm) + min * 150;
    }
}
class SurgePricing implements PricingStrategy {                                // decorator
    private final PricingStrategy inner; private final DoubleSupplier multiplier;
    SurgePricing(PricingStrategy inner, DoubleSupplier m) { this.inner = inner; multiplier = m; }
    public long farePaise(VehicleType t, double km, long min) { return Math.round(inner.farePaise(t, km, min) * multiplier.getAsDouble()); }
}

final class Trip {
    final String id, riderId; final Location pickup, drop; final VehicleType type; volatile Driver driver;
    private final AtomicReference<TripStatus> status = new AtomicReference<>(TripStatus.REQUESTED); Instant startedAt; long fare;
    Trip(String id, String rider, Location p, Location d, VehicleType t) { this.id = id; riderId = rider; pickup = p; drop = d; type = t; }
    void transition(TripStatus from, TripStatus to) {
        if (!status.compareAndSet(from, to)) throw new IllegalStateException("Trip " + id + " is " + status.get() + ", cannot go to " + to);
    }
    TripStatus status() { return status.get(); }
}

class TripService {
    private final GridIndex index; private final PricingStrategy pricing; private final Map<String, Trip> trips = new ConcurrentHashMap<>(); private final Clock clock;
    TripService(GridIndex i, PricingStrategy p, Clock c) { index = i; pricing = p; clock = c; }

    public Trip requestRide(String riderId, Location pickup, Location drop, VehicleType type) {
        Trip trip = new Trip(UUID.randomUUID().toString(), riderId, pickup, drop, type);
        for (Driver d : index.nearby(pickup, type, 3)) {
            if (d.claim()) {                                     // atomic: only one trip wins this driver
                trip.driver = d; trip.transition(TripStatus.REQUESTED, TripStatus.ACCEPTED);   // assume auto-accept here
                trips.put(trip.id, trip); return trip;
            }
        }
        throw new IllegalStateException("No drivers nearby");
    }
    public void start(String tripId) { Trip t = trips.get(tripId); t.transition(TripStatus.ACCEPTED, TripStatus.STARTED); t.startedAt = clock.instant(); }
    public long end(String tripId, double km) {
        Trip t = trips.get(tripId); t.transition(TripStatus.STARTED, TripStatus.COMPLETED);
        long minutes = Duration.between(t.startedAt, clock.instant()).toMinutes();
        t.fare = pricing.farePaise(t.type, km, minutes); t.driver.free(); return t.fare;
    }
    public void cancel(String tripId) {
        Trip t = trips.get(tripId);
        t.transition(TripStatus.ACCEPTED, TripStatus.CANCELLED);    // only before start (fee policy could apply)
        t.driver.free();
    }
}
```

#### Concurrency and edge cases
- **Two riders and one driver**: the CAS in `claim()` means only one wins; the loser tries the next driver.
- Locations update every few seconds, so the index update must be cheap (it moves between cell sets).
- Driver rejects or times out: in the real flow, offer to the driver with a 10–15s timeout; on reject, `free()` the driver and offer to the next candidate (keep an exclusion list per trip).
- Rider cancels after the driver accepted (a fee policy); the driver goes offline mid-trip (a support flow).

#### Extensions the interviewer may add
?? "How does real Uber do matching at scale?"
Driver locations stream in (every 4s) to a location service that stores them in an in-memory geo index sharded by region (Uber uses H3 hexagons). Matching considers ETA (from road routing, not straight-line distance), batches requests in short windows to optimise globally (a bipartite matching problem), and predicts supply and demand for surge. That's the HLD version (see the HLD track).

?? "Add ride pooling."
Match riders whose routes overlap: when a trip is in progress with free seats, evaluate the detour cost of inserting a new pickup and drop into the driver's route, and accept if it's under a threshold for all riders. Much more complex, so describe the approach rather than code it.

?? "Add ratings and prefer highly rated drivers."
A `MatchingStrategy` that ranks candidates by a weighted score (ETA × w1 − rating × w2) instead of pure distance. A new strategy; the service is unchanged.

#### Interview simulation
Clarify the flow and matching rules, then call out the two hard parts: "**finding nearby drivers efficiently** (a spatial grid index) and **never double-assigning a driver** (an atomic status CAS)." Code the grid, the claim, the trip state machine and pricing with a surge decorator. Demo three drivers and two concurrent requests. Close with the "real Uber" scaling answer. That combination scores at Uber, Ola and Rapido-style interviews.
