## DBMS & SQL | P2 | must

### ACID and isolation levels

#### Core idea
**ACID** is the set of guarantees a transactional database gives:
- **Atomicity**: all of a transaction's changes apply, or none do.
- **Consistency**: a transaction moves the DB from one valid state to another (constraints hold).
- **Isolation**: concurrent transactions don't see each other's intermediate states, to the degree set by the **isolation level**.
- **Durability**: once committed, data survives crashes (via the write-ahead log).

#### How it works
**Read anomalies** that weaker isolation levels allow:
| Anomaly | What happens |
|---|---|
| **Dirty read** | read another transaction's *uncommitted* change (which may roll back) |
| **Non-repeatable read** | read the same row twice and get different values (another transaction updated and committed in between) |
| **Phantom read** | re-run a range query and get new rows (another transaction inserted matching rows) |
| **Lost update** | two transactions read-modify-write the same value; one overwrites the other |
| **Write skew** | two transactions read overlapping data and write *different* rows based on it, together violating an invariant |

**SQL standard isolation levels**
| Level | Dirty | Non-repeatable | Phantom |
|---|---|---|---|
| Read Uncommitted | possible | possible | possible |
| **Read Committed** (Postgres, Oracle, SQL Server default) | prevented | possible | possible |
| **Repeatable Read** (MySQL InnoDB default) | prevented | prevented | possible in the standard; prevented in Postgres and mostly in InnoDB |
| Serializable | prevented | prevented | prevented |

**Real engines differ from the standard:**
- **Postgres** Repeatable Read = **Snapshot Isolation** (no phantoms, but **write skew is possible**). Postgres Serializable = **SSI** (Serializable Snapshot Isolation): it detects dangerous patterns and aborts with `could not serialize access` (SQLSTATE 40001), so the application **must retry**.
- **MySQL InnoDB** Repeatable Read uses MVCC snapshots for plain reads, plus **next-key / gap locks** for locking reads (`SELECT … FOR UPDATE`) to block phantom inserts.

**Write skew example (doctors on call)**: the rule is at least one doctor on call. Alice and Bob are both on call. Two transactions concurrently check "count on-call = 2 ≥ 2, OK", and each sets themselves off-call (different rows). Both commit, and nobody is on call. Snapshot isolation allows this. Fixes: `SERIALIZABLE`, `SELECT … FOR UPDATE` on the rows read, or a materialised constraint.

**Durability**: commit = the WAL record flushed to disk (`fsync`). `synchronous_commit=off` in Postgres trades a small window of possible loss for speed.

#### Real-world example
**Booking a meeting room**: two users check "is 3–4pm free?" and both insert a booking: a phantom/write-skew problem. Solutions: a Postgres **exclusion constraint** (`EXCLUDE USING gist (room_id WITH =, during WITH &&)`), which makes the database reject overlaps, or `SERIALIZABLE` with retry, or locking the room row first (`SELECT … FROM rooms WHERE id = ? FOR UPDATE`).

#### Interview questions
?? Explain ACID with an example.
A bank transfer of ₹500 from A to B. **Atomicity**: the debit and credit both happen or neither does. **Consistency**: the balance ≥ 0 constraint and the sum of money are preserved. **Isolation**: a concurrent report doesn't see A debited but B not yet credited. **Durability**: after "Transfer successful", a power failure doesn't undo it (the WAL is on disk).

?? Which isolation level would you use for a typical web app, and why?
Read Committed (the Postgres default) for most operations, since it's cheap and has no serialization failures, and handle specific races explicitly: atomic updates, `SELECT … FOR UPDATE`, optimistic version checks, unique constraints. Use Serializable for complex invariants spanning several rows, with retry logic.

?? What is a lost update and does Read Committed prevent it?
Two transactions read the same value, both modify it in application code, and both write, so the first write is lost. Read Committed doesn't prevent it. Prevent it with atomic SQL (`SET x = x + 1`), `SELECT … FOR UPDATE`, optimistic locking (version column), or a higher isolation level (Postgres Repeatable Read detects it and aborts).

#### Tricky questions
?? Is Postgres "Repeatable Read" the same as MySQL "Repeatable Read"?
No. Postgres RR is true snapshot isolation (no phantoms; concurrent updates to the same row cause serialization errors). MySQL RR uses a consistent snapshot for plain SELECTs, but **UPDATEs and locking reads see the latest committed data**, plus gap locks. So the same application code can behave differently. Always know your engine.

?? Can you have consistency issues even with ACID transactions?
Yes, through weak isolation (write skew under snapshot isolation), application-level invariants not encoded as constraints, and in distributed systems where multiple databases or services aren't covered by one transaction (that's the saga problem).

#### Interview simulation
**Interviewer:** "Two users try to book the last seat simultaneously. How do you ensure only one succeeds?"

**Clarify:** "Is it a single database? Is the seat a row, or a count? What's the expected concurrency: a flash sale or normal traffic?"

**Answer:** Options: (1) a row per seat with `UPDATE seats SET user_id = ? WHERE id = ? AND user_id IS NULL`, where 1 row affected means success. (2) A unique constraint on `(show_id, seat_no)` in the bookings table: the second insert fails, giving 409. (3) `SELECT … FOR UPDATE` on the seat row. (4) Serializable isolation with retry. Recommend (1) or (2) for simplicity and performance, and mention temporary holds with an expiry for the payment window (the BookMyShow pattern in the HLD track).

### Normalization and denormalization

#### Core idea
**Normalization** organises tables to remove redundancy and update anomalies: each fact is stored once. **Denormalization** deliberately adds redundancy to make reads faster, accepting extra write complexity.

#### How it works
**Anomalies normalization prevents**: *update* (changing a customer's city in one of 50 order rows creates an inconsistency), *insert* (you can't add a product until someone orders it), *delete* (deleting the last order loses the customer's info).

**Normal forms**
- **1NF**: atomic values, no repeating groups (no `phone1, phone2` columns, no comma-separated lists).
- **2NF**: 1NF, and no **partial dependency**: every non-key column depends on the *whole* composite key. (In `order_items(order_id, product_id, qty, product_name)`, `product_name` depends only on `product_id`, so move it to `products`.)
- **3NF**: 2NF, and no **transitive dependency**: non-key columns depend only on the key. (`employees(id, dept_id, dept_name)`: `dept_name` depends on `dept_id`, so move it to `departments`.)
- **BCNF**: for every functional dependency X → Y, X is a superkey. A stricter 3NF for tables with overlapping candidate keys.
- 4NF and 5NF deal with multi-valued and join dependencies (rare in interviews).

**Denormalization techniques**: storing derived values (an `order.total_amount` instead of summing items), duplicating fields to avoid joins (`order.customer_name` as a snapshot at purchase time, which is also *correct* historically), materialised views, read models (CQRS), and document stores (embedding).

**When to denormalize**: read-heavy hot paths where joins are the measured bottleneck, analytics (star schemas), caching layers, and sharded systems where cross-shard joins are impossible.

#### Real-world example
E-commerce orders **copy** the product price and name into `order_items` at purchase time. That's not a normalization failure: the price *at time of purchase* is a different fact from the current price. Analytics warehouses (BigQuery, Redshift) use **star schemas**: a big fact table (`sales`) plus denormalized dimension tables, so queries do fewer joins over billions of rows.

#### Interview questions
?? Explain 1NF, 2NF and 3NF with one example.
Start with `orders(order_id, customer_name, customer_city, products="Dolo, Crocin")`. 1NF: split products into rows → `order_items(order_id, product_id, qty)`. 2NF: if the item table's key is `(order_id, product_id)`, the product's name depends only on `product_id`, so move it to `products`. 3NF: `customer_city` depends on the customer, not the order, so move customer data to `customers` and keep `customer_id` in orders.

?? When would you denormalize?
When a measured read bottleneck comes from joins or aggregations on hot paths, and you can manage the consistency of the duplicated data (triggers, application logic, events or materialised views). Examples: counters (likes count), feed tables, search indexes, reporting tables.

#### Tricky questions
?? Is storing `total_amount` on an order a 3NF violation?
Technically it's derived data (a transitive dependency through the items). But it's often intentional: immutable historical totals, faster reads, and it captures discounts and taxes computed at that moment. Justify it as deliberate denormalization with a single writer path.

#### Interview simulation
If given "Design the schema for a library system", clarify the entities (books vs copies, members, loans, reservations, fines), then normalise: `books(isbn, title)`, `authors`, `book_authors` (many-to-many), `copies(copy_id, isbn, status)`, `members`, `loans(copy_id, member_id, borrowed_at, due_at, returned_at)`. Add indexes for the common queries and constraints (one active loan per copy: a partial unique index `WHERE returned_at IS NULL`). Mention which denormalizations you'd consider (`available_copies` count) and the trade-off.

### Indexes: B+ trees, composite, covering and selectivity

#### Core idea
An **index** is an auxiliary data structure that lets the database find rows without scanning the whole table, like a book's index. The usual structure is a **B+ tree**. Indexes speed up reads but cost **write performance and storage**.

#### How it works
**B+ tree**
- A balanced tree with high fan-out (hundreds of keys per node/page, around 8–16KB). With 3–4 levels it indexes millions to billions of rows, so a lookup is about 3–4 page reads, and the top levels are usually cached.
- **All values live in leaves**, and leaves are **linked**, so range scans (`BETWEEN`, `>`, `ORDER BY`) walk the leaves sequentially.
- Inserts may split pages; random keys (UUIDv4) cause scattered page splits and a bloated index. Sequential keys (bigserial, **UUIDv7**/ULID) append neatly.

**Clustered vs secondary**
- **MySQL InnoDB**: the table *is* a B+ tree clustered on the primary key (rows are stored in PK order). Secondary indexes store the PK, so a lookup through a secondary index takes **two** tree traversals.
- **Postgres**: tables are heaps; all indexes point to tuple locations (ctid). There's no clustered index (the `CLUSTER` command is a one-time reorder).

**Composite indexes and the leftmost-prefix rule**
Index `(user_id, status, created_at)` supports:
- ✅ `WHERE user_id = ?`
- ✅ `WHERE user_id = ? AND status = ?`
- ✅ `WHERE user_id = ? AND status = ? ORDER BY created_at DESC` (no sort step needed)
- ❌ `WHERE status = ?` alone (it can't use the leading column; Postgres 18 adds skip scans for some cases)
- ⚠️ `WHERE user_id = ? AND created_at > ?` uses `user_id`, but `status` is skipped, so it's less efficient.

**Column order**: equality columns first, then range or sort columns. Among equality columns, order by query patterns (selectivity helps, but which queries you need to serve matters more).

**Covering index / index-only scan**: if the index contains every column the query needs, the DB doesn't touch the table. Postgres: `CREATE INDEX … (user_id, created_at) INCLUDE (total)`.

**Other index types**: hash (equality only), **GIN** (full-text, JSONB, arrays), **GiST** (geometric, ranges, exclusion constraints), **BRIN** (huge append-only tables with natural ordering, e.g. time-series), **partial indexes** (`WHERE status = 'PENDING'`), **expression indexes** (`lower(email)`), and vector indexes (HNSW/IVFFlat in pgvector).

**When indexes aren't used**: functions on the column (`WHERE lower(email) = …` without an expression index), implicit type casts, a leading wildcard `LIKE '%abc'`, low selectivity (the planner prefers a sequential scan when a large fraction of rows match), `OR` across different columns (sometimes), and stale statistics.

**Cost**: every INSERT, UPDATE or DELETE must update every index, which also adds write amplification, WAL volume and storage. Drop unused indexes (`pg_stat_user_indexes.idx_scan = 0`).

#### Real-world example
Your resume says "tuned PostgreSQL indexes… query time −50%". A typical story: the medicine search filtered by `category_id` and `is_available` and sorted by `popularity DESC LIMIT 20`. With separate single-column indexes, Postgres scanned many rows and sorted them. A composite index `(category_id, is_available, popularity DESC)` let it read just the first 20 index entries in order. And a GIN trigram index (`pg_trgm`) on `name` supported `ILIKE '%dolo%'` substring search. Be ready to describe the `EXPLAIN ANALYZE` before and after.

#### Interview questions
?? Why do databases use B+ trees rather than binary trees or hash tables?
B+ trees have high fan-out, so the tree is shallow (few disk or page reads), with nodes sized to disk pages. Leaves are linked for efficient range scans and ordered access, and the tree stays balanced on inserts and deletes. Hash indexes are only for equality (no ranges or sorting); binary trees are too deep and cache-unfriendly for disk.

?? Explain composite index column ordering.
The index is sorted by the first column, then the second within equal firsts, and so on. Queries can use any **leftmost prefix**. Put equality-filtered columns first and the range or sort column last, so the DB can seek to the exact range and read it in order.

?? Why not index every column?
Each index slows writes (every insert or update maintains it), uses storage and memory (competing for cache), and adds planning overhead. Many single-column indexes are often less useful than one well-designed composite index. Index according to actual query patterns.

#### Tricky questions
?? You have an index on `created_at` but `WHERE DATE(created_at) = '2026-10-01'` is slow. Why?
Applying a function to the column prevents a plain index from being used. Rewrite as a range: `created_at >= '2026-10-01' AND created_at < '2026-10-02'`, or create an expression index.

?? Why can UUIDv4 primary keys hurt insert performance in MySQL?
InnoDB clusters rows by primary key, so random UUIDs insert into random pages: page splits, fragmentation and a poor buffer-pool hit rate. They're also 16 bytes, duplicated in every secondary index. Use time-ordered IDs (UUIDv7, ULID, Snowflake) or bigint auto-increment.

?? The query uses an index on a low-cardinality `status` column and is slower than a full scan. Why?
If 40% of rows match, random index lookups into the table cost more than a sequential scan. The planner usually prefers a seq scan here; forcing the index makes it worse. A partial index for the rare status (`WHERE status = 'FAILED'`) is the right tool.

#### Interview simulation
**Interviewer:** "This query is slow: `SELECT * FROM orders WHERE user_id = ? AND status = 'DELIVERED' ORDER BY created_at DESC LIMIT 20`. How do you fix it?"

**Clarify:** "How big is the table? Which indexes exist? How many orders does a typical user have? Can I see the EXPLAIN ANALYZE output?"

**Answer:** Read the plan (a seq scan, or an index on user_id followed by a sort). Propose `CREATE INDEX CONCURRENTLY idx_orders_user_status_created ON orders (user_id, status, created_at DESC);` so the DB seeks to the user and status and reads the 20 newest in order (no sort). Avoid `SELECT *` if a covering index is possible. Verify with EXPLAIN ANALYZE (look for an Index Scan, no Sort node, low "rows removed by filter"), and check the write overhead. That walk-through is exactly what interviewers want.

### Query plans and EXPLAIN

#### Core idea
The **query planner** turns SQL into an execution plan (which indexes, which join algorithms, in what order) using **cost estimates** from table **statistics**. `EXPLAIN` shows the plan; `EXPLAIN ANALYZE` runs the query and shows actual times and row counts. Reading plans is the core skill of database performance work.

#### How it works
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.total FROM orders o JOIN users u ON u.id = o.user_id
WHERE u.city = 'Bengaluru' AND o.created_at > now() - interval '7 days';
```
```text
Hash Join  (cost=1250.3..9821.7 rows=4200 width=16) (actual time=12.1..48.3 rows=3912 loops=1)
  Hash Cond: (o.user_id = u.id)
  ->  Index Scan using idx_orders_created on orders o  (cost=0.43..8100.2 rows=52000 …) (actual … rows=50877)
        Index Cond: (created_at > (now() - '7 days'::interval))
  ->  Hash  (cost=1100.0..1100.0 rows=12000 …)
        ->  Seq Scan on users u  (… rows=11850)
              Filter: (city = 'Bengaluru')  Rows Removed by Filter: 488150
Planning Time: 0.4 ms   Execution Time: 49.1 ms
```
**What to read**
- **Node types**: Seq Scan, Index Scan, Index Only Scan, Bitmap Heap Scan (many matches, batched page reads), and the joins (Nested Loop, Hash Join, Merge Join), Sort, Aggregate, Limit.
- **cost=startup..total**: planner units (not ms). **rows**: estimated vs **actual**. A big mismatch means bad statistics or correlated columns, which leads to a bad plan.
- **Rows Removed by Filter**: lots of work thrown away, so an index candidate.
- **loops**: the inner side of a nested loop runs N times (multiply).
- **Buffers: shared hit/read**: cache hits vs disk reads.
- **Sort Method: external merge Disk**: the sort spilled to disk, so consider raising `work_mem` or adding an index for the order.

**Common fixes**: add or adjust an index; rewrite non-sargable predicates; `ANALYZE` to refresh statistics; extended statistics for correlated columns; avoid `SELECT *`; reduce the result size; and partition huge tables.

**Finding slow queries in production**: the `pg_stat_statements` extension (top queries by total time), `log_min_duration_statement`, `auto_explain`, the MySQL slow query log, or APM traces.

#### Real-world example
A report query ran in 200ms in staging but 40s in production. The plan showed a nested loop whose inner index scan was estimated at 1 row but actually returned 80,000 rows per loop, because the statistics were stale after a bulk import. `ANALYZE orders;` fixed the estimate, the planner switched to a hash join, and it ran in 300ms. The lesson: check estimated vs actual first.

#### Interview questions
?? How do you find and fix a slow query?
Identify it (pg_stat_statements, slow logs, APM). Reproduce it with `EXPLAIN (ANALYZE, BUFFERS)` on production-like data. Find the expensive node (seq scan on a big table, a huge sort, bad estimates, a nested loop with many loops). Fix with an index, a query rewrite, updated statistics, or a schema change. Verify the improvement and check the write cost. Monitor afterwards.

?? Index Scan vs Index Only Scan vs Bitmap Heap Scan?
An Index Scan walks the index and fetches each matching table row (random I/O). An Index Only Scan answers from the index alone when it covers all the needed columns (and the visibility map says the pages are all-visible). A Bitmap scan collects matching row locations from one or more indexes into a bitmap, then reads table pages in physical order: good when many rows match, and it can combine indexes with AND/OR.

#### Tricky questions
?? Why might the same query be fast with one parameter value and slow with another?
Data skew: `status = 'FAILED'` (0.1% of rows) suits an index, `status = 'DELIVERED'` (80%) suits a seq scan. With prepared statements, Postgres may switch to a **generic plan** after 5 executions, which can be bad for skewed values. Watch `plan_cache_mode` and use partial indexes for the rare values.

#### Interview simulation
If shown a plan in an interview, narrate it bottom-up: "The innermost node does X, estimated N rows, actual M. Here's the mismatch or the expensive step. I'd fix it by Y and expect the plan to change to Z." Calm, systematic reading beats guessing.

### MVCC and locking

#### Core idea
**MVCC (Multi-Version Concurrency Control)** keeps **multiple versions of rows**, so readers see a consistent **snapshot** without blocking writers, and writers don't block readers. Locks are still used for **writer-writer** conflicts and explicit locking reads.

#### How it works
**Postgres MVCC**
- Each row version (tuple) has `xmin` (the transaction that created it) and `xmax` (the transaction that deleted or updated it).
- An UPDATE = mark the old version's `xmax` + insert a **new version**. Old versions stay until no snapshot needs them.
- A transaction's **snapshot** decides which versions are visible (committed before the snapshot started).
- **VACUUM** removes dead tuples, and autovacuum must keep up. **Long-running transactions** prevent cleanup, so tables and indexes bloat.
- **HOT updates** (heap-only tuples) avoid index updates when no indexed column changes and the page has room.
- **Transaction ID wraparound**: 32-bit XIDs require freezing old tuples; neglected vacuum can force an emergency shutdown.

**MySQL InnoDB MVCC**: updates happen in place, with old versions kept in **undo logs**; consistent reads rebuild old versions from undo. The purge thread cleans up.

**Lock types**
- **Row locks**: `FOR UPDATE` (exclusive), `FOR SHARE`, and in Postgres the finer `FOR NO KEY UPDATE`/`FOR KEY SHARE`. UPDATE and DELETE take row locks automatically.
- **Table locks**: DDL takes heavy locks (`ACCESS EXCLUSIVE` for most `ALTER TABLE` operations), which can block all reads and writes. Even a quick ALTER waiting behind a long query blocks everything queued behind it. Use `lock_timeout` for migrations.
- **Gap / next-key locks** (InnoDB): lock ranges between index records to prevent phantoms in RR.
- **Advisory locks** (Postgres): application-defined locks (`pg_advisory_lock(key)`), e.g. making sure only one instance runs a cron job.
- **Deadlocks**: detected automatically; one transaction is aborted.

#### Real-world example
An analytics query left in an open transaction for 6 hours (a forgotten psql session or a BI tool) caused severe table bloat. Autovacuum couldn't remove dead tuples newer than that snapshot, so a hot `orders` table grew from 5GB to 40GB and queries slowed down. The fixes: `idle_in_transaction_session_timeout`, monitoring the oldest transaction age (`pg_stat_activity`), and running analytics on a replica.

#### Interview questions
?? How does MVCC let readers and writers not block each other?
Writers create new row versions instead of overwriting in place (Postgres) or keep old versions in undo (InnoDB). Readers use a snapshot and read the version that was committed as of their snapshot, so they never wait for writers' locks. Writers only conflict with other writers on the same row.

?? What is VACUUM in Postgres and why does it matter?
It reclaims space from dead tuples left by updates and deletes, updates the visibility map (enabling index-only scans), and freezes old transaction IDs to prevent wraparound. Without it, tables bloat, scans slow down, and eventually the DB shuts down to prevent XID wraparound.

#### Tricky questions
?? Why can adding a column with a simple `ALTER TABLE` take down production?
`ALTER TABLE` needs an `ACCESS EXCLUSIVE` lock. If a long-running query holds a conflicting lock, the ALTER waits, and every new query on that table queues **behind the ALTER**, so the table is effectively offline. Use `SET lock_timeout = '3s'` and retry, and do schema changes at quiet times.

?? Does SELECT ever block in Postgres?
Plain SELECTs don't block on row locks held by writers. But they're blocked by `ACCESS EXCLUSIVE` table locks (DDL, `VACUUM FULL`, `TRUNCATE`, some `ALTER`s), and `SELECT … FOR UPDATE` does block on rows locked by others.

#### Interview simulation
If asked "Why are updates slow and the table huge even though row count hasn't changed?": suspect MVCC bloat. Check dead tuples (`pg_stat_user_tables.n_dead_tup`), autovacuum activity, and long-running or idle-in-transaction sessions. Fixes: tune autovacuum per table (scale factor), kill long transactions, `pg_repack` to remove bloat online, and consider the fillfactor for HOT updates on frequently updated tables.

### Joins: types and algorithms

#### Core idea
A **join** combines rows from tables based on a condition. You need to know both the **logical join types** (what rows come back) and the **physical algorithms** (how the database computes them), because the algorithm choice drives performance.

#### How it works
**Logical types**
| Join | Returns |
|---|---|
| INNER | rows with matches in both |
| LEFT (OUTER) | all left rows; right columns NULL if no match |
| RIGHT | all right rows |
| FULL OUTER | all rows from both sides |
| CROSS | Cartesian product |
| SELF | a table joined to itself (employee → manager) |
| SEMI (`EXISTS`/`IN`) | left rows having at least one match (no duplication) |
| ANTI (`NOT EXISTS`) | left rows with no match |

**Physical algorithms**
| Algorithm | How | Best when | Cost |
|---|---|---|---|
| **Nested Loop** | for each outer row, look up matches in the inner (ideally via an index) | small outer side + an indexed inner | O(N × lookup) |
| **Hash Join** | build a hash table on the smaller input, probe it with the other | large unsorted inputs, equality joins | O(N + M), needs memory (`work_mem`) |
| **Merge Join** | sort both inputs on the key (or use sorted indexes), then merge | both inputs already sorted, large | O(N log N + M log M), or O(N + M) if presorted |

**Pitfalls**
- `NOT IN (subquery)` returns **no rows** if the subquery contains a NULL. Use `NOT EXISTS`.
- A LEFT JOIN with a filter on the right table in `WHERE` (`WHERE r.status = 'X'`) silently becomes an INNER JOIN. Put the condition in `ON` instead.
- Joining two one-to-many relations at once multiplies rows (a Cartesian explosion): orders × items × payments.

#### Real-world example
"Find users who haven't ordered in 90 days": an **anti-join**.
```sql
SELECT u.id FROM users u
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id AND o.created_at > now() - interval '90 days');
```
With an index on `orders(user_id, created_at)`, the planner does a fast anti-join; the `NOT IN` version would break if `user_id` could be NULL.

#### Interview questions
?? Explain the difference between INNER JOIN and LEFT JOIN with an example.
Customers and orders: an INNER JOIN returns only customers who have orders (one row per order). A LEFT JOIN returns every customer, with NULL order columns for customers without orders. You'd use LEFT JOIN plus `WHERE o.id IS NULL` to find customers with no orders.

?? When does the database choose a hash join vs a nested loop?
Nested loop when one side is small and the other has an index on the join key (or for non-equality joins). Hash join for larger inputs with equality conditions and enough memory for the build side. Merge join when inputs are sorted or very large. The planner decides by estimated row counts, so bad estimates lead to bad choices.

#### Tricky questions
?? `SELECT * FROM a LEFT JOIN b ON a.id = b.a_id WHERE b.type = 'X'` returns fewer rows than table a. Why?
The WHERE filter eliminates rows where b is NULL (`NULL = 'X'` isn't true), turning it into an inner join. Move it into the ON clause: `LEFT JOIN b ON a.id = b.a_id AND b.type = 'X'`.

?? Why does `NOT IN` return nothing when the subquery has a NULL?
`x NOT IN (1, 2, NULL)` means `x <> 1 AND x <> 2 AND x <> NULL`. The last comparison is UNKNOWN, so the whole predicate is never TRUE. SQL's three-valued logic strikes again.

#### Interview simulation
In SQL rounds, before writing the query, **clarify the cardinalities and NULLs**: "Can a customer have zero orders? Can `manager_id` be NULL? Should duplicates appear?" Interviewers grade that care. Then write the query, explain which join type and why, and mention the index you'd want.

### SQL patterns: window functions, CTEs and classic problems

#### Core idea
Most SQL interview questions are a handful of patterns: aggregation with `GROUP BY`/`HAVING`, **window functions** (ranking, running totals, comparing to previous rows), **CTEs** for readability and recursion, and set operations. Master these and you can solve the classic "Nth highest salary" and "top N per group" questions.

#### How it works
**Order of logical execution**: `FROM/JOIN → WHERE → GROUP BY → HAVING → SELECT (window functions here) → DISTINCT → ORDER BY → LIMIT`. That's why you can't use a window function in WHERE (wrap it in a subquery or CTE), and why WHERE can't reference a SELECT alias.

**Window functions**: compute over a "window" of related rows without collapsing them:
```sql
SELECT emp_id, dept_id, salary,
       ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rn,       -- 1,2,3,4
       RANK()       OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rnk,      -- 1,2,2,4 (gaps)
       DENSE_RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS drnk,     -- 1,2,2,3
       SUM(salary)  OVER (PARTITION BY dept_id) AS dept_total,
       salary - LAG(salary) OVER (PARTITION BY dept_id ORDER BY hired_at) AS diff_vs_prev
FROM employees;
```

**Classic problems (practise all of these)**
```sql
-- 1. Nth highest salary (handles ties, returns NULL if none)
SELECT DISTINCT salary FROM (
  SELECT salary, DENSE_RANK() OVER (ORDER BY salary DESC) dr FROM employees) t WHERE dr = :n;

-- 2. Top 3 earners per department
WITH ranked AS (
  SELECT *, DENSE_RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC) dr FROM employees)
SELECT * FROM ranked WHERE dr <= 3;

-- 3. Running total of daily revenue
SELECT day, revenue, SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running
FROM daily_revenue;

-- 4. 7-day moving average
SELECT day, AVG(revenue) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) FROM daily_revenue;

-- 5. Duplicate emails (and delete all but the lowest id)
SELECT email, COUNT(*) FROM users GROUP BY email HAVING COUNT(*) > 1;
DELETE FROM users u USING users d WHERE u.email = d.email AND u.id > d.id;

-- 6. Employees earning more than their manager (self join)
SELECT e.name FROM employees e JOIN employees m ON e.manager_id = m.id WHERE e.salary > m.salary;

-- 7. Consecutive login streaks (gaps and islands)
WITH d AS (SELECT DISTINCT user_id, login_date FROM logins),
g AS (SELECT user_id, login_date, login_date - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY login_date))::int AS grp FROM d)
SELECT user_id, MIN(login_date) start_d, MAX(login_date) end_d, COUNT(*) streak
FROM g GROUP BY user_id, grp HAVING COUNT(*) >= 3;

-- 8. Month-over-month growth
SELECT month, revenue, ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month)) / LAG(revenue) OVER (ORDER BY month), 2) AS pct
FROM monthly_revenue;

-- 9. Org chart / hierarchy (recursive CTE)
WITH RECURSIVE chain AS (
  SELECT id, name, manager_id, 1 AS lvl FROM employees WHERE id = :ceo
  UNION ALL
  SELECT e.id, e.name, e.manager_id, c.lvl + 1 FROM employees e JOIN chain c ON e.manager_id = c.id)
SELECT * FROM chain;

-- 10. Customers who bought product A but never B
SELECT customer_id FROM orders WHERE product = 'A'
EXCEPT
SELECT customer_id FROM orders WHERE product = 'B';
```
**Other must-knows**: `COUNT(*)` vs `COUNT(col)` (the latter skips NULLs); `WHERE` vs `HAVING` (row filter vs group filter); `UNION` (dedupes, slower) vs `UNION ALL`; `COALESCE`; `CASE WHEN` for pivoting (`SUM(CASE WHEN status='PAID' THEN amount END)`); upsert (`INSERT … ON CONFLICT (key) DO UPDATE`).

#### Real-world example
Real dashboards are built from these patterns: daily active users (`COUNT(DISTINCT user_id)` by day), retention cohorts (window functions over the first-order month), top-selling medicines per city (top N per group), and session streaks (gaps and islands). Product companies often have a SQL round for backend roles, especially Amazon and Meta data-heavy teams.

#### Interview questions
?? ROW_NUMBER vs RANK vs DENSE_RANK?
For salaries 100, 90, 90, 80: ROW_NUMBER gives 1,2,3,4 (unique, ties broken arbitrarily); RANK gives 1,2,2,4 (ties share a rank, then there's a gap); DENSE_RANK gives 1,2,2,3 (no gaps). Use DENSE_RANK for "Nth highest distinct value", ROW_NUMBER for "exactly N rows per group" or for deduplication.

?? WHERE vs HAVING?
WHERE filters rows before grouping and can't use aggregates. HAVING filters groups after aggregation (`HAVING COUNT(*) > 5`). Putting non-aggregate filters in WHERE is more efficient, because fewer rows get grouped.

?? CTE vs subquery: any performance difference?
Logically equivalent in most cases. In Postgres 12+, non-recursive CTEs are inlined unless they're referenced multiple times or marked `MATERIALIZED`. Before 12 they were always materialised (an "optimisation fence"). Use CTEs for readability; check plans when it matters.

#### Tricky questions
?? `SELECT dept_id, name, MAX(salary) FROM employees GROUP BY dept_id` — what's wrong?
`name` isn't aggregated or grouped, so it's invalid in standard SQL and Postgres (old MySQL would return an arbitrary name). For the top earner per department, use a window function (`ROW_NUMBER` … `WHERE rn = 1`) or `DISTINCT ON (dept_id)` in Postgres.

?? What does `COUNT(DISTINCT col)` do with NULLs?
It ignores them. `COUNT(*)` counts all rows, `COUNT(col)` counts non-NULL values, and `COUNT(DISTINCT col)` counts distinct non-NULL values.

#### Interview simulation
**Interviewer:** "Find the second-highest salary in each department."

**Clarify first:** "If two people tie for the highest, is the second-highest the next distinct salary? Should departments with only one distinct salary appear (with NULL), or be excluded? Return names or just the amount?"

**Answer:** DENSE_RANK partitioned by department, filtered on 2, with the reasoning about ties. Then mention an index on `(dept_id, salary DESC)` for large tables. Asking about ties before writing a line of SQL is exactly the habit interviewers look for.

### WAL, checkpoints and replication

#### Core idea
- The **Write-Ahead Log (WAL)** (InnoDB: redo log) is how databases achieve **durability and crash recovery**: changes are first appended to a sequential log on disk, then applied to the data files later.
- **Replication** copies changes (usually by shipping the WAL or binlog) to other servers for **read scaling, high availability and backups**.

#### How it works
**WAL**
1. A transaction modifies pages in the buffer cache (memory).
2. Change records are written to the WAL, and on commit the WAL is **fsync**ed. Sequential writes are fast.
3. Dirty data pages are written to the data files **later** (by checkpoints or the background writer).
4. After a crash: replay the WAL from the last **checkpoint** to restore committed changes (redo); uncommitted work is ignored (Postgres) or rolled back via undo (InnoDB).

**Checkpoint**: flush all dirty pages, so recovery only needs WAL after this point. Frequent checkpoints mean faster recovery but more I/O (and full-page writes in Postgres).

**Replication**
- **Physical/streaming replication** (Postgres): replicas replay the WAL byte-for-byte, giving an exact copy, read-only.
- **Logical replication**: row-level change events (inserts, updates, deletes per table), so you can replicate a subset or to a different version. It's the basis of **CDC** (Debezium reads the Postgres logical decoding stream or the MySQL binlog and publishes to Kafka).
- **Synchronous**: commit waits for a replica to confirm, so no data loss on failover, at a latency cost. **Asynchronous**: commit returns immediately, giving **replication lag**; a failover can lose the last few transactions.
- **Replication lag** causes **read-your-writes** anomalies: a user updates their profile (primary), the page reloads from a replica, and the old data shows. Fixes: read from the primary for a short period after a user's write, route by session, or wait for the replica to reach the write's LSN.

**High availability**: a primary + standby with automatic failover (Patroni, AWS RDS Multi-AZ which is synchronous storage-level replication, Aurora's shared storage). There's a split-brain risk if two nodes both believe they're primary, so fencing is needed.

#### Real-world example
AWS **RDS Multi-AZ** keeps a synchronous standby in another availability zone, with automatic DNS failover in about 60–120s. **Read replicas** are asynchronous and used for reporting and read scaling. At 1mg-scale, search reads can go to replicas, while checkout must read its own writes from the primary. Your Kafka integration could have been fed by CDC (Debezium) to reliably publish DB changes, which is the **outbox pattern** in the HLD track.

#### Interview questions
?? How does a database guarantee durability if it doesn't write data pages on every commit?
Write-ahead logging: the change log is flushed to disk on commit (sequential, cheap), and data pages are written lazily. If the server crashes, recovery replays the WAL from the last checkpoint and reconstructs all committed changes.

?? Synchronous vs asynchronous replication?
Synchronous: the commit is acknowledged only after a replica confirms receipt. Zero data loss on failover, but higher write latency, and availability depends on the replica. Asynchronous: lower latency, but replicas lag, and you may lose recent commits on failover. Many systems use semi-synchronous replication (wait for at least one of N replicas).

?? What is replication lag and how does it affect applications?
Async replicas apply changes after a delay (milliseconds to minutes under load). Reads from replicas may be stale, which breaks read-your-writes and monotonic reads. Mitigate by routing post-write reads to the primary, using sticky sessions per user, or using causal consistency tokens (LSNs).

#### Tricky questions
?? Why is the WAL a sequential append rather than updating data in place directly?
Sequential I/O is much faster than random I/O (even on SSDs it's cheaper, with less write amplification), group commit batches many transactions into one fsync, and a log gives a simple, robust recovery story (replay). The same idea underlies Kafka's log and LSM trees.

#### Interview simulation
If asked "How would you scale reads for a database-heavy service?": caching (Redis) for hot keys → read replicas for query-heavy endpoints that can tolerate lag → handling read-your-writes (route to the primary after writes) → read-optimised models (Elasticsearch for search, materialised views) → sharding only when writes or data size require it. Mention monitoring replica lag and failing over replicas out of the pool when lag is too high.
