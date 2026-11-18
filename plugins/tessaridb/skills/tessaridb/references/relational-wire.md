# The relational wire: psql and the drivers on `--pg`

`--pg <host:port>` (or `TESSARIDB_PG`) makes a node speak the Postgres wire
protocol on 5432 by convention, off unless named. `psql`, `psycopg`, the
Rust/Python/JS/Go/Kotlin drivers connect unchanged and work on the store's
own tables, users and transactions. Everything below answers exactly;
anything the mapping cannot serve honestly refuses by name (`0A000`).

The examples are psql text; each maps onto a store statement the port
translates, so what you already know about TessariQL reads (snapshots,
notes, the refusal classes) holds on this surface too.

## Point a client at it

```bash
tessaridb ./data --serve 0.0.0.0:9080 --pg 0.0.0.0:5432
psql "host=localhost port=5432 dbname=main user=app password=…"
```

A connection names its tenancy in the startup database (`<namespace>.<db>`,
else the default namespace) and `SET search_path` moves it. `BEGIN …
COMMIT` is one store transaction with the store's own undo; drivers also
send `BEGIN` on the extended protocol, where it binds and executes like any
prepared statement.

## Paging: LIMIT and OFFSET

```sql
SELECT name FROM orders WHERE band = 3 ORDER BY name LIMIT 20 OFFSET 40;
```

`LIMIT n OFFSET m` asks the store for `n + m` rows in the declared order
and the port drops the first `m` — the page is exact, and the skip's cost
rides on the port. `OFFSET` alone and `LIMIT ALL OFFSET m` read the whole
ordered answer; a parameter or expression in either position refuses by
name, exactly as `LIMIT` always has.

## Schema changes: ALTER TABLE

```sql
ALTER TABLE orders ADD COLUMN qty int NOT NULL DEFAULT 0;
ALTER TABLE orders RENAME COLUMN qty TO quantity;
ALTER TABLE orders ALTER COLUMN quantity TYPE text;
ALTER TABLE orders DROP COLUMN quantity;
```

- `ADD COLUMN` rides the engine's field verbs; the `DEFAULT` backfills
  stored records. `NOT NULL` is the engine's `REQUIRED`.
- `DROP COLUMN` removes the column from the catalog; the values stored in
  existing records are **kept**, and the answer carries a warning saying
  so — never silent.
- Constraints (`ADD CONSTRAINT`, keys), per-option mutations (`ALTER
  COLUMN … SET DEFAULT`), `USING`, and the `IF EXISTS` variants refuse by
  name.

## json and jsonb columns

```sql
CREATE TABLE docs (id int, meta jsonb);
INSERT INTO docs (id, meta) VALUES (1, '{"a": 1, "tags": ["x", "y"]}');
SELECT meta -> 'a' FROM docs WHERE meta @> '{"tags": ["x"]}';
SELECT meta -> 'tags' ->> 1 FROM docs;
```

JSON text written to a json/jsonb column lands as the object it spells —
the declared kind's own reading of the value — and answers render as JSON.
`->` and `->>` navigate (`['key']` and `[n]` on the engine's own path);
`@>` is document containment. The wider operator and function library
(`?`, `#>`, `jsonb_set`, …) refuses by name: the store holds one value
system and does not pretend a json/jsonb split it cannot make.

## Session parameters: accept and report

```sql
SET application_name TO 'the pager';
SHOW client_encoding;
SET TIME ZONE 'UTC';
RESET application_name;
```

The parameters the greeting reports accept `SET` and answer `SHOW` from
the connection's own hold; a changed value rides `ParameterStatus`. Values
the port cannot honestly perform refuse by name (one zone, ISO dates,
UTF-8, conforming strings); read-only parameters refuse `SET` and answer
`SHOW`. `search_path` keeps the only effect — it still moves the
connection between namespaces. `SET LOCAL` is not spoken.

## Refused by name, never approximated

`OFFSET $1` · `ALTER TABLE … ADD CONSTRAINT` · `ALTER COLUMN … USING` ·
`SET work_mem` (unreported settings) · `SET client_encoding TO 'LATIN1'` ·
the wider json functions. Each answers `0A000` naming the thing; the
catalog introspection the dialect's clients send (`psql \d`, listings)
answers from the store's own shape.
