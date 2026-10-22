# TessariQL: the language

Every example here was run against TessariDB 0.37.1 with a namespace and database already
selected. An example that is meant to be refused is marked `-- refused:` with the refusal's name.

Contents: [Tenancy](#tenancy-namespace-database-table) · [Kinds of table](#kinds-of-table) ·
[Fields and types](#fields-defaults-and-checks) · [Indexes](#indexes) ·
[Writing](#writing-records) · [Deleting](#deleting) · [Expiry](#records-that-expire) ·
[Events](#events-statements-that-run-with-a-write) · [Reading](#reading) ·
[Routes](#routes-reaching-inside-a-document) · [Expressions](#expressions) ·
[Joins and subqueries](#joins-and-subqueries) · [Parameters](#parameters-and-bindings) ·
[What an answer tells you](#what-an-answer-tells-you)

## Tenancy: namespace, database, table

A store holds **namespaces**, a namespace holds **databases**, and a database holds tables and the
other kinds of store. `USE` selects where statements run, and it belongs to the connection.

```tessariql
DEFINE NAMESPACE IF NOT EXISTS prod;
USE NAMESPACE prod;
DEFINE DATABASE IF NOT EXISTS shop;
USE DATABASE shop;
```

Send the `USE` lines with every unit of work. A pooled connection that reconnects has forgotten
them. A statement before any `USE` is refused (`NoNamespaceSelected`, `NoDatabaseSelected`).

## Kinds of table

| Declaration | What it is |
|---|---|
| `DEFINE TABLE t (name string, age int)` | strict: only the declared fields are accepted (`UndeclaredField` otherwise) |
| `DEFINE TABLE t (…) SCHEMALESS` | declared fields are checked, any others are accepted |
| `DEFINE COLLECTION t` | accepts any document; add typed fields with `DEFINE FIELD` |
| `DEFINE TABLE t EDGE` | a table whose rows are links between records ([vectors-geo-graphs.md](vectors-geo-graphs.md)) |
| `DEFINE VIEW v AS SELECT …` | a name for a read; holds nothing, runs with the caller's permissions |
| `DEFINE VIEW v MATERIALIZED AS SELECT …` | keeps the read's answer as records, brought current after each commit |
| `DEFINE VECTOR`, `GEO`, `GRAPH` | declared stores for embeddings, shapes and graphs |
| `DEFINE SPACE`, `BUCKET`, `QUEUE`, `TOPIC`, `SERIES`, `VAULT` | key-value, files, work queues, event logs, time series, secrets |

A kind can't be changed after the fact; drop and redefine instead. A `DEFINE TABLE` with no
columns is refused: say `DEFINE COLLECTION` when you mean "any fields".

## Fields, defaults and checks

```tessariql
DEFINE TABLE people (
    name   string REQUIRED,
    rank   string DEFAULT 'viewer',
    joined datetime DEFAULT time::now(),
    level  int ASSERT $value > 0
);
```

On a collection, declare fields one at a time:

```tessariql
DEFINE COLLECTION accounts;
DEFINE FIELD email ON accounts TYPE string REQUIRED;
DEFINE FIELD balance ON accounts TYPE decimal ASSERT $value >= 0;
DEFINE FIELD tier ON accounts TYPE string ASSERT $value IN ['bronze', 'gold'];
```

The default fills first, then `REQUIRED` checks, then `ASSERT` runs, with `$value` as the field's
value. Change a declared table with `ALTER TABLE t ADD FIELD …`, `ALTER FIELD …` or
`DROP FIELD …`, and run `CHECK TABLE t` afterwards to list records that no longer fit.

### Types

`string`, `int`, `float`, `decimal` (exact; use it for money and never mix it with floats),
`bool`, `datetime`, `duration`, `uuid`, `bytes`, `array`, `set`, `object`, `record` (a link to
another record), `geometry`, `vector<n>` (fixed width) and `any`. Literals:

```tessariql
DEFINE COLLECTION literals;
CREATE literals:1 = {
    price: dec 19.99,
    at: datetime '2026-09-29T10:00:00Z',
    wait: 30s,
    id: uuid '01a0ec9b-5d00-7000-9891-000000000000',
    owner: literals:1,
    tags: ['a', 'b']
};
```

Arithmetic never coerces: `1 + '1'` is refused rather than guessed. Time has its own arithmetic:
`datetime + duration`, `datetime - duration`, `datetime - datetime` (a duration), and
`duration::from_secs(n)`.

```tessariql
RETURN datetime '2026-10-01T00:00:00Z' + 36h;
RETURN datetime '2026-10-02T00:00:00Z' - datetime '2026-10-01T00:00:00Z';
```

The full type list with every literal form is at
<https://docs.tessaridb.com/reference/data-types>.

## Indexes

```tessariql
DEFINE COLLECTION contacts;
DEFINE INDEX IF NOT EXISTS by_email ON contacts FIELDS email UNIQUE;
DEFINE INDEX by_name ON contacts FIELDS last, first;
REBUILD INDEX by_name ON contacts;
DROP INDEX by_name ON contacts;
DROP INDEX IF EXISTS by_name ON contacts;
```

Other kinds: `SEARCH` (full text, [search.md](search.md)), `VECTOR` and `SPATIAL`
([vectors-geo-graphs.md](vectors-geo-graphs.md)), and `CONTAINS` for document containment
(below). A route can be indexed (`FIELDS address.city`). Name an index for what it serves, and put
`USING INDEX name` on a read whose cost matters.

## Writing records

```tessariql
DEFINE TABLE users (name string, email string, age int, city string);
CREATE users = { name: 'ada', email: 'ada@example.com', age: 36 };
CREATE users:'grace' = { name: 'grace', email: 'grace@example.com', age: 45 };
INSERT INTO users (name, email) VALUES ('katherine', 'k@example.com'), ('dorothy', 'd@example.com');
```

`CREATE users = …` lets the store produce the id. `CREATE` with an id that already exists is
refused (`RecordExists`); `UPSERT` writes it whether or not it exists.

Changing a record, from narrowest to widest:

```tessariql
UPDATE users:'grace' SET age = 46;
UPDATE users:'grace' MERGE { city: 'Arlington' };
UPDATE users:'grace' = { name: 'grace', email: 'grace@example.com' };
```

The first changes one field. The second adds or replaces the named fields and keeps the rest. The
third **replaces the whole record**: `age` and `city` are gone. Use `= { … }` only when the object
is the entire record, never for a form that posts some of the fields.

Get the record back from the same statement:

```tessariql
UPDATE users:'grace' SET age = 47 RETURN AFTER;
UPDATE users:'grace' SET age = 48 RETURN BEFORE;
```

`RETURN BEFORE` is the cheapest audit trail there is: the old value, taken in the same transaction
as the write. A write that answers a record needs `read` as well as `write` authority.

`UPDATE` always names one record. There is no table-wide `UPDATE … WHERE`: read the ids and update
each one, inside one transaction if they must change together.

```tessariql
-- refused: UnexpectedToken
UPDATE users SET age = 0;
```

A `WHERE` on an `UPDATE` of one record is a compare-and-set: when the condition is false nothing
is written and the transaction is refused (`ConditionNotMet`).

```tessariql
UPDATE users:'grace' SET age = 49 WHERE age = 48;
```

`THROW 'message'` inside a transaction abandons all of it; use it for checks the schema can't state.

## Deleting

```tessariql
DELETE users:'grace';
DELETE FROM users WHERE age < 18 LIMIT 1;
DELETE FROM users WHERE age < 18 LIMIT ALL;
DELETE FROM users WHERE age > 100 LIMIT ALL RETURN BEFORE;
```

A conditional delete must say how far it reaches, so a lost `WHERE` or a wider match than you
expected can't delete by omission:

```tessariql
-- refused: UnexpectedToken
DELETE FROM users WHERE age < 18;
```

With `RETURN BEFORE` a set delete answers the records it removed; without it, how many.

## Records that expire

A table or collection can give its records an expiry instant. At that instant the record is gone
from every read (scans, indexes, joins, followers); space is reclaimed later.

```tessariql
DEFINE TABLE message (chat string, body string) EXPIRE AFTER 7d;
DEFINE COLLECTION drafts EXPIRE;
CREATE drafts:1 = { text: 'later' } EXPIRE 1h;
CREATE message:1 = { chat: 'c1', body: 'hi' };
UPDATE message:1 SET body = 'hello';
UPDATE message:1 SET body = 'hello again' EXPIRE 30m;
ALTER TABLE message DROP EXPIRE;
```

- `EXPIRE AFTER d` stamps every record created afterwards with `commit + d`; `EXPIRE` alone lets
  each write choose. A write can say `EXPIRE 1h`, `EXPIRE datetime '…'` or `EXPIRE NONE`.
- **A plain write keeps the instant**: editing an expiring record neither extends it nor makes it
  permanent. For a sliding lifetime, write the `EXPIRE` on every write. (A key-value space is the
  opposite: a plain `SET` there clears the expiry.)
- Declaring expiry changes no record already stored, and `DROP EXPIRE` leaves stored instants in
  place.
- Expiry fires no event. Work that must follow an expiry is a queue record with a `NOT BEFORE`.

## Events: statements that run with a write

```tessariql
DEFINE COLLECTION audit;
CREATE users:'kate' = { name: 'kate', email: 'kate@example.com', age: 30 };
DEFINE EVENT log_age ON users FOR UPDATE WHEN $after.age != $before.age THEN
    CREATE audit = { who: $id, was: $before.age ?? 0, now: $after.age ?? 0 };
UPDATE users:'kate' SET age = 31;
SELECT who, was, now FROM audit;
```

An event runs after each `CREATE`, `UPDATE` or `DELETE` of its table's records, **inside the
writer's transaction and as the writer**: its writes land with the write or not at all, and a
refusal in its body (`THROW` included) refuses the write as `EventFailed`, with the class of what
it met (so contention inside an event is still `retry`).

- `$event`, `$before`, `$after` and `$id` are bound; `$after.age` reaches into the record.
- A body writes. It cannot define, `USE` or open a transaction; it can read the database's
  `DEFINE PARAM` values.
- A chain more than 16 events deep is refused, so a body that updates its own record needs a
  `WHEN` that excludes its own change.
- `DEFINE EVENT OR REPLACE …` changes an event in one catalog write; `DROP EVENT IF EXISTS name ON t`
  removes it.

```tessariql
DEFINE EVENT OR REPLACE log_age ON users FOR UPDATE WHEN $after.age > $before.age THEN
    CREATE audit = { who: $id, now: $after.age };
```

## Reading

```tessariql
SELECT * FROM users;
SELECT name, email FROM users WHERE age >= 18 ORDER BY name LIMIT 10;
SELECT * FROM users WHERE name LIKE 'ka%';
SELECT * FROM users WHERE city = NONE;
SELECT count(*) AS n FROM users;
SELECT city, count(*) AS n FROM users GROUP BY city;
SELECT * FROM ONLY users:'kate';
```

- Conditions: `=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `NOT`, `IN`, `CONTAINS`, `LIKE`.
  Two comparisons in a row (`1 < age < 100`) are refused; write `age > 1 AND age < 100`.
- `field = NONE` finds records without the field; `field = NULL` finds records where it is
  present and null.
- `ORDER BY a, b DESC`, `LIMIT n`, `START n`. `LIMIT $n` and `START $n` take a bound whole number.
- `ONLY` says exactly one record answers and gives it back unwrapped; more than one is refused
  (`NotAlone`).
- `doc CONTAINS { customer: { city: 'Paris' } }` asks whether a document holds a sub-document;
  `DEFINE INDEX … FIELDS doc CONTAINS` serves it.
- Aggregates: `count`, `sum`, `mean`, `min`, `max`, `median`, `collect`, and
  `approx_distinct(x)` / `approx_quantile(x, q)`, whose answers carry an `estimated` note
  ([functions.md](functions.md)).
- **Paging: prefer `AFTER` over `START`.** `START 500` does 500 pages of work and shifts when rows
  are inserted. `AFTER <the last record you saw>` seeks there, and the anchor can be bound:

```tessariql
SELECT * FROM users ORDER BY name LIMIT 2;
SELECT * FROM users ORDER BY name AFTER users:'kate' LIMIT 2;
```

## Routes: reaching inside a document

```tessariql
DEFINE COLLECTION profiles;
CREATE profiles:1 = { name: 'ada', address: { city: 'Paris' }, tags: ['urgent', 'old'], headers: { 'content-type': 'text/plain' } };
SELECT * FROM profiles WHERE address.city = 'Paris';
SELECT * FROM profiles WHERE tags[0] = 'urgent';
SELECT * FROM profiles WHERE headers['content-type'] = 'text/plain';
UPDATE profiles:1 SET headers['content-type'] = 'application/json';
```

A key that is not a name (a hyphen, a space, a leading digit) is quoted in brackets. A route that
reaches nothing (no such field, past the end of an array, through a non-object) is not an error;
the record just doesn't match. A negative position is refused.

## Expressions

`IF … THEN … ELSE … END`, `??` (the right side when the left is absent), and the function families
(`string::`, `math::`, `time::`, `array::`, `object::`, `type::`, `json::`, `geo::`, `vector::`,
`search::` and more, listed in [functions.md](functions.md)).

```tessariql
SELECT name, IF age >= 18 THEN 'adult' ELSE 'minor' END AS band FROM users;
SELECT name, city ?? 'unknown' AS city FROM users;
SELECT string::upper(name) AS shout, time::now() AS now FROM users LIMIT 1;
```

Be careful with `IF … ELSE` over a field that may be missing: a record without `age` lands in the
`ELSE` branch. Two branches over three states (more, less, absent) is the shape of a bug; test for
`NONE` explicitly when absence means something.

Projections: `SELECT a, b AS c`, `SELECT * OMIT secret`, `SPLIT ON tags` (one row per element),
`FETCH owner` (follow a record link). To keep a field out of an answer, list the fields you want
rather than relying on `OMIT`.

## Joins and subqueries

```tessariql
DEFINE COLLECTION orders;
CREATE orders = { buyer: 'ada', total: 40 };
SELECT * FROM users JOIN orders ON users.name = orders.buyer;
SELECT * FROM users JOIN (SELECT * FROM orders WHERE total > 5 LIMIT 100) AS big
  ON users.name = big.buyer;
SELECT * FROM (SELECT * FROM users ORDER BY name LIMIT 2) WHERE name = 'ada';
```

A subquery holds at most what its `LIMIT` lets it materialise; give it one. A source that passes
its ceiling without a bound is refused (`Unbounded`) rather than silently cut. A join matches on a
value nobody wrote down as a link; when records point at each other, a graph traversal is faster.

## Parameters and bindings

```tessariql
-- with --param who='ada'
SELECT * FROM users WHERE name = $who;
```

From the command line: `--param who="'ada'"` (the value is read as TessariQL, so a string keeps its
quotes). From a client, pass a parameters map. A parameter may stand wherever a **value** stands,
including a record's id (`GET sessions:$token`, `UPDATE users:$id SET …`) and a count
(`LIMIT $n`). It may never stand for a table, field or index name. A parameter that is used but
never bound is refused (`UnboundParameter`), never treated as absent.

`LET` binds a name inside a script, forward only:

```tessariql
LET $city = 'Paris'; SELECT * FROM profiles WHERE address.city = $city;
```

A client sends a whole script at once, so `LET` reaches everything below it. **The command line
sends one line at a time**, so with `-f` a `LET` reaches only the statements on its own line, or
inside the same `BEGIN … COMMIT`.

A database can hold named values that scripts, events and views read as `$name`:

```tessariql
DEFINE PARAM $grace VALUE 10m;
RETURN time::now() - $grace < time::now();
DEFINE PARAM OR REPLACE $grace VALUE 1h;
DROP PARAM IF EXISTS $grace;
```

A parameter bound to the statement wins over a database param of the same name.

`RETURN expr` answers a script with one value, so a submitted script holds at most one `RETURN`
(`ReturnedTwice` otherwise). `RETURN BEFORE` / `RETURN AFTER` on writes are a different thing.

## What an answer tells you

```tessariql
DEFINE INDEX by_email ON users FIELDS email UNIQUE;
EXPLAIN SELECT * FROM users WHERE email = 'ada@example.com';
SELECT * FROM users WHERE email = 'ada@example.com' USING INDEX by_email;
SELECT * FROM users TIMEOUT 2s;
```

- `EXPLAIN` gives the plan without running the read, and the number of records the planner
  expects (`estimate`, `estimated_by`). `ANALYZE TABLE t` refreshes the statistics it estimates
  from; a serving node refreshes them itself too. An estimate chooses a path, never the records.
- `USING INDEX name` makes the index an assertion: if the read can't use it, it is refused
  (`IndexNotUsed`) rather than quietly scanning.
- `TIMEOUT` refuses a read that runs too long (`TimedOut`) rather than returning part of it.
- **Notes are part of the result.** "This comparison skipped records of another kind", "this
  source hit its ceiling", "this figure is estimated": an application that drops notes drops the
  only signal that an answer is partial or approximate.
