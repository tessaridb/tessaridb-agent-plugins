# TessariQL: the language

Examples assume a namespace and database are already selected. A refused example is marked with
`-- refused:` and the refusal's name.

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
them.

## Kinds of table

| Declaration | What it is |
|---|---|
| `DEFINE TABLE t (name string, age int)` | strict: only the declared fields are accepted |
| `DEFINE TABLE t (…) SCHEMALESS` | declared fields are checked, any others are accepted |
| `DEFINE COLLECTION t` | accepts any document; add typed fields with `DEFINE FIELD` |
| `DEFINE TABLE t EDGE` | an edge table for links between records (see engines.md) |
| `DEFINE VIEW v AS SELECT …` | a name for a read; holds nothing and runs with the caller's permissions |
| `DEFINE VIEW v MATERIALIZED AS SELECT …` | keeps the read's answer as records, brought current from the source's changes after each commit |
| `DEFINE VECTOR`, `DEFINE GEO`, `DEFINE GRAPH`, `DEFINE SPACE`, `DEFINE QUEUE`, `DEFINE TOPIC`, `DEFINE SERIES`, `DEFINE VAULT`, `DEFINE BUCKET` | the other engines (see engines.md) |

A kind can't be changed after the fact; drop and redefine instead. A `DEFINE TABLE` with no
columns is refused. Say `DEFINE COLLECTION` when you mean "any fields".

### Fields, defaults and checks

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
value. Change a declared table with `ALTER TABLE t ADD FIELD …`, `ALTER FIELD …` or `DROP FIELD …`,
and run `CHECK TABLE t` afterwards to list records that no longer fit.

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

Arithmetic never coerces: `1 + '1'` is refused rather than guessed.

### Indexes

```tessariql
DEFINE COLLECTION contacts;
DEFINE INDEX IF NOT EXISTS by_email ON contacts FIELDS email UNIQUE;
DEFINE INDEX by_name ON contacts FIELDS last, first;
REBUILD INDEX by_name ON contacts;
DROP INDEX by_name ON contacts;
```

The other index kinds are `SEARCH` (full text, see search.md), `VECTOR <distance>` and `SPATIAL`
(see engines.md). Name an index for what it serves.

## Writing records

```tessariql
DEFINE TABLE users (name string, email string, age int, city string);
CREATE users = { name: 'ada', email: 'ada@example.com', age: 36 };
CREATE users:'grace' = { name: 'grace', email: 'grace@example.com', age: 45 };
INSERT INTO users (name, email) VALUES ('katherine', 'k@example.com'), ('dorothy', 'd@example.com');
```

`CREATE users = …` lets the store produce the id. `CREATE` with an id that already exists is
refused; `UPSERT` writes it whether or not it exists.

Changing a record, from narrowest to widest:

```tessariql
UPDATE users:'grace' SET age = 46;
UPDATE users:'grace' MERGE { city: 'Arlington' };
UPDATE users:'grace' = { name: 'grace', email: 'grace@example.com' };
```

The first changes one field. The second adds or replaces the named fields and keeps the rest. The
third **replaces the whole record**: `age` and `city` are gone. Use `= { … }` only when you mean
the entire record.

Get the record back from the same statement:

```tessariql
UPDATE users:'grace' SET age = 47 RETURN AFTER;
UPDATE users:'grace' SET age = 48 RETURN BEFORE;
```

`RETURN BEFORE` is the cheapest audit trail there is: the old value, taken in the same
transaction as the write.

### Deleting

```tessariql
DELETE users:'grace';
DELETE FROM users WHERE age < 18 LIMIT 1;
DELETE FROM users WHERE age < 18 LIMIT ALL;
```

A conditional delete must say how far it reaches:

```tessariql
-- refused: Unbounded
DELETE FROM users WHERE age < 18;
```

`UPDATE` always names one record. There is no table-wide `UPDATE … WHERE`: to change many records,
read their ids and update each one, inside one transaction if they must change together.

```tessariql
-- refused: UnexpectedToken
UPDATE users SET age = 0;
```

A `WHERE` on an `UPDATE` of one record is a compare-and-set: `UPDATE users:1 SET age = 37 WHERE age = 36`
refuses, and discards the transaction, when the condition is false.

### Events: statements that run with a write

```tessariql
DEFINE COLLECTION audit;
CREATE users:'kate' = { name: 'kate', email: 'kate@example.com', age: 30 };
DEFINE EVENT log_age ON users FOR UPDATE WHEN $after.age != $before.age THEN
    CREATE audit = { who: $id, was: $before.age ?? 0, now: $after.age ?? 0 };
UPDATE users:'kate' SET age = 31;
SELECT who, was, now FROM audit;
```

An event runs after each `CREATE`, `UPDATE` or `DELETE` of a record of its table, **inside the
writer's transaction and as the writer**: its writes land with the write or not at all, and a
refusal in its body (a `THROW` included) refuses the write as `EventFailed`. `$event`, `$before`,
`$after` and `$id` are bound; `$after.age` reaches into the record, and a step that reaches nothing
is `NONE`. A body writes; it cannot read, define, `USE` or open a transaction. A chain more than 16
events deep is refused, so a body that updates its own record needs a `WHEN` that excludes its own
change. Work after the commit (an email, a call) is a message the body appends to a topic, read by a
consumer.

## Reading

```tessariql
SELECT * FROM users;
SELECT name, email FROM users WHERE age >= 18 ORDER BY name LIMIT 10;
SELECT * FROM users WHERE name LIKE 'ka%';
SELECT * FROM users WHERE city = NONE;
SELECT count(*) AS n FROM users;
SELECT city, count(*) AS n FROM users GROUP BY city;
```

- `doc CONTAINS { customer: { city: 'Paris' } }` asks whether a document holds a sub-document, and
  `DEFINE INDEX … FIELDS doc CONTAINS` serves it. `json::parse(text)` and `json::encode(value)`
  convert between JSON text and documents.
- Conditions use `=`, `!=`, `<`, `<=`, `>`, `>=`, `AND`, `OR`, `NOT`, `IN`, `CONTAINS`, `LIKE` and
  chained comparisons such as `1 < age < 100`.
- `field = NONE` finds records without the field; `field = NULL` finds records where it is present
  and null.
- `ORDER BY a, b DESC`, `LIMIT n`, `START n`.
- Paging: prefer `AFTER` over `START`. `START 500` does 500 pages of work, and shifts when rows are
  inserted. `AFTER <the last record you saw>` seeks there.

```tessariql
SELECT * FROM users ORDER BY name LIMIT 2;
SELECT * FROM users ORDER BY name AFTER users:3 LIMIT 2;
```

### Expressions

`IF … THEN … ELSE … END`, `??` (use the right side when the left is absent), string, math, time,
array and object functions. The function families are `array::`, `string::`, `math::`, `time::`,
`type::`, `rand::`, `crypto::`, `encoding::`, `object::`, `geo::`, `vector::`, `search::`.

```tessariql
SELECT name, IF age >= 18 THEN 'adult' ELSE 'minor' END AS band FROM users;
SELECT name, city ?? 'unknown' AS city FROM users;
SELECT string::upper(name) AS shout, time::now() AS now FROM users LIMIT 1;
```

Be careful with `IF … ELSE` over a field that may be missing: a record without `age` falls into
the `ELSE` branch. Two branches over three states is the shape of a bug.

### Joins and subqueries

```tessariql
DEFINE COLLECTION orders;
CREATE orders = { buyer: 'ada', total: 40 };
SELECT * FROM users JOIN orders ON users.name = orders.buyer;
SELECT * FROM users JOIN (SELECT * FROM orders WHERE total > 5 LIMIT 100) AS big
  ON users.name = big.buyer;
SELECT * FROM (SELECT * FROM users ORDER BY name LIMIT 2) WHERE name = 'ada';
```

A subquery holds at most what its `LIMIT` lets it materialise; give it one, so that a large source
is refused or noted instead of silently cut.

A join matches on a value nobody wrote down as a link. When records point at each other, a graph
traversal is the faster route (see engines.md).

## Parameters

```tessariql
-- with --param who='ada'
SELECT * FROM users WHERE name = $who;
```

From the command line: `--param who="'ada'"` (the value is read as TessariQL, so a string keeps
its quotes). From a client, pass a parameters map. A parameter that is used but never bound is
refused (`UnboundParameter`), not treated as absent.

## What an answer tells you

```tessariql
DEFINE INDEX by_email ON users FIELDS email UNIQUE;
EXPLAIN SELECT * FROM users WHERE email = 'ada@example.com';
SELECT * FROM users WHERE email = 'ada@example.com' USING INDEX by_email;
SELECT * FROM users TIMEOUT 2s;
```

- `EXPLAIN` gives the plan without running the read, and the number of records the planner expects
  (`estimate`). `ANALYZE TABLE t` takes the per-index statistics it estimates from; a serving node
  also refreshes them itself. An estimate chooses a path, never the records.
- `USING INDEX name` turns "I expect this index to be used" into an assertion: if the read can't
  use it, it is refused rather than quietly scanning.
- `TIMEOUT` refuses a read that runs too long, rather than returning part of the answer.
- Notes on an answer, such as "this comparison skipped records of another kind" or "this source hit
  its ceiling", are part of the result. An application that drops them drops the only signal that
  an answer is partial.
