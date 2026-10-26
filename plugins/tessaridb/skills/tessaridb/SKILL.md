---
name: tessaridb
description: Work with TessariDB, a multi-model database with its own query language, TessariQL. Use when writing, reviewing or debugging TessariQL; designing tables, fields, indexes or analyzers; adding full-text, vector, geo or graph search; using key-value spaces, files, queues, topics, time series, views, events or vaults; connecting an application from Rust, Python, TypeScript, Go or Kotlin, or over HTTP; pointing existing Kafka or RESP clients at a node; securing, serving, backing up or upgrading a node; or explaining why a statement was refused or returned what it did. For a cluster of nodes use the tessaridb-cluster skill.
---

# TessariDB

TessariDB is one database with several engines: tables and documents, full-text search, vectors,
geometry, graphs, key-value spaces, files, queues, topics, time series and vaults. Every engine is
reached through one language, **TessariQL**, and one transaction can write to all of them.

This skill was checked against **TessariDB 0.39.0** (image `tessaridb/tessaridb:0.39.0`, clients
`0.13.0`, protocol `1.6`). The language and the wire format can still change before 1.0, so name
the version when behaviour matters. The documentation at <https://docs.tessaridb.com> is the
reference; when it and this skill disagree, trust the site.

## Pick the file for the task

| You are… | Read |
|---|---|
| writing any statement: tenancy, tables, fields, types, writes, reads, parameters, events, expiry | [references/language.md](references/language.md) |
| looking up what a statement looks like | [references/statements.md](references/statements.md) |
| making text searchable, ranking, highlighting, type-ahead, one search over several tables | [references/search.md](references/search.md) |
| storing vectors, shapes or graphs | [references/vectors-geo-graphs.md](references/vectors-geo-graphs.md) |
| using spaces (cache, counters, locks), files, queues, topics, time series or views | [references/spaces-queues-topics-series.md](references/spaces-queues-topics-series.md) |
| keeping secrets in a vault | [references/vaults.md](references/vaults.md) |
| writing several statements as one unit, retrying, paging, reading the past | [references/transactions-and-history.md](references/transactions-and-history.md) |
| connecting an application, following changes, the wire protocol, HTTP | [references/clients.md](references/clients.md) |
| pointing existing Kafka producers and consumers, or RESP key-value clients, at a node | [references/kafka-and-resp-clients.md](references/kafka-and-resp-clients.md) |
| declaring users, roles and grants; TLS; encryption at rest | [references/security.md](references/security.md) |
| running a node: the container, serving, backups, the log, upgrades, the console | [references/operations.md](references/operations.md) |
| reaching for a function | [references/functions.md](references/functions.md) |
| a statement was refused, or a client must decide what to do about a refusal | [references/refusals.md](references/refusals.md) |
| a read returned nothing, too little, or was slow | [references/troubleshooting.md](references/troubleshooting.md) |
| doing a common task for the first time | [references/recipes.md](references/recipes.md) |

## Try every statement before you hand it over

TessariDB answers for itself, so check a statement against a real store instead of reasoning about
it. A store in memory costs nothing and disappears when the process exits:

```sh
# with the image (no install):
docker run --rm tessaridb/tessaridb:0.39.0 -e "DEFINE NAMESPACE t; USE NAMESPACE t; DEFINE DATABASE t; USE DATABASE t; DEFINE COLLECTION notes; CREATE notes:1 = { body: 'hi' }; SELECT * FROM notes;"

# a script file, with a bound parameter:
docker run --rm -v "$PWD:/work:ro" tessaridb/tessaridb:0.39.0 -f /work/try.tessariql --param who="'ada'"

# with the binary: in memory, on disk, or against a running node
tessaridb -e '<script>'
tessaridb ./data -f migration.tessariql
TESSARIDB_PASSWORD='…' tessaridb --at 127.0.0.1:9080 --user owner -f check.tessariql
```

- Each answer says how it was read: `(3 record(s), via index)` or `via scan`. `EXPLAIN <read>`
  shows the plan without running it.
- A refusal prints the store's own message with the place in the script, for example
  ``expected `WHERE` and what to remove at 16..17, found `;` ``. Quote it; don't paraphrase it.
- A script run with `-f` stops at the first refusal and keeps everything before it. A `-e` string is
  parsed whole first, so one bad token means none of it runs.

## Start a node

```sh
docker run -d --name tessaridb -p 9080:9080 -p 8000:8000 \
  -v tessaridb-data:/var/lib/tessaridb \
  -e TESSARIDB_INITIAL_USER=owner -e TESSARIDB_INITIAL_PASSWORD='choose-a-real-one' \
  tessaridb/tessaridb:0.39.0
```

Port 9080 is the wire protocol the clients use; port 8000 is HTTP and serves the web console at
`/`. Without the two `INITIAL_*` variables the store has no users and **is open to anyone who
reaches the port**. A first store:

```tessariql
DEFINE NAMESPACE IF NOT EXISTS prod;
USE NAMESPACE prod;
DEFINE DATABASE IF NOT EXISTS shop;
USE DATABASE shop;
DEFINE TABLE IF NOT EXISTS customers (name string REQUIRED, email string REQUIRED, city string);
DEFINE INDEX IF NOT EXISTS by_email ON customers FIELDS email UNIQUE;
CREATE customers = { name: 'Ada', email: 'ada@example.com' };
SELECT name, email FROM customers WHERE email = 'ada@example.com';
```

## Rules that prevent quiet mistakes

TessariDB's worst failures are the ones that **succeed**: the statement runs, the test passes, and
the answer is wrong. Each rule below prevents one of them.

1. **Send the `USE` with the work.** `USE NAMESPACE` and `USE DATABASE` belong to the connection.
   A pooled connection that reconnected has forgotten them, and the next statement either fails or
   answers from somewhere else. Put the `USE` lines in the same script as the statement.
2. **Bind values; never format them into the text.** `WHERE name = $who` with `who` passed as a
   parameter. A bound value can never become syntax. Table and field names are grammar and can't be
   parameters, so never take them from user input.
3. **`= { … }` replaces the whole record.** `UPDATE users:1 = { name: 'x' }` deletes every other
   field. To change some fields, use `SET` or `MERGE`.
4. **A set write states a condition:** `UPDATE t SET … WHERE …` and `DELETE FROM t WHERE …` change
   every match (`LIMIT n` caps it). Without a `WHERE` they are refused, so a lost condition can't
   rewrite or empty a table; `TRUNCATE t` empties one on purpose.
5. **`NONE` and `NULL` are different.** `NONE` means "no such field", `NULL` means "present and
   empty". They compare unequal, and neither takes part in `<` or `>`.
6. **A comparison across kinds is a note, not an error.** `WHERE age > 18` over records where some
   `age` values are strings answers only about the numbers, and the answer carries a note saying so.
   Read the notes, and surface them in an application.
7. **An index changes cost, never the answer.** The one exception is written in the statement: a
   vector read is exact unless it says `APPROXIMATE`.
8. **A script is not a transaction.** Wrap all-or-nothing work in `BEGIN … COMMIT`, and rehearse it
   with `VERIFY`, which runs every check and then throws the work away.
9. **Retry only what says `retry`.** Every refusal carries a class. Only class `retry`
   (`CommitContention`, `Conflict` and a few cluster refusals) means "try again", and the store
   never waits for you. Retry those explicitly, with a bound, and nothing else.
10. **Declare a width for vectors.** `vector<384>`, or `DEFINE VECTOR … DIMENSION 384`. A vector
    of the wrong length in a plain `array` field is infinitely far from everything and sorts last
    without an error.
11. **Put the analyzer on the field, in the order `lowercase, ascii, stemmer`.** A field with no
    analyzer holds no terms and `MATCHES` finds nothing. A stemmer before `lowercase` stems almost
    nothing, so a search just returns fewer rows.
12. **A store with no users is open.** Until the first `DEFINE USER`, anyone who reaches the port
    can read and write everything, and `GET /backup` returns the whole store. Declare an owner
    first.
13. **A node speaks TLS only when given a certificate.** Without `--tls-cert` and `--tls-key` it
    serves in the clear and says so at start. Every client verifies the certificate and has no
    switch to skip it.
14. **An event runs inside the writer's transaction.** It lands with the write or not at all, and a
    refusal in its body refuses the write. Work that must happen after the commit, such as sending
    an email, goes into a topic or a queue that the event writes to.

## How to check what a statement did

- `EXPLAIN <read>` gives the plan: `access: 'index'` or `'scan'`, and the planner's `estimate`.
- `USING INDEX name` on a read turns "I expect this index" into an assertion: if the read can't
  use it, it is refused instead of quietly scanning.
- `INFO FOR DATABASE`, `INFO FOR TABLE t`, `INFO FOR USER u`, `INFO FOR NODE` and `INFO FOR STORE`
  report what the store actually holds, read from its own catalog.
- `CHECK TABLE t` lists stored records that disagree with what the table declares now.

## Writing style

- Keywords UPPERCASE, names `snake_case`, strings in single quotes, one statement per line, each
  ending in `;`. Comments are `-- to the end of the line`.
- Records are addressed as `table:id`: `users:1`, `users:'ada'`, `users:$id`.
  `CREATE users = { … }` lets the store make the id.
- Every `DEFINE` in a deployment script carries `IF NOT EXISTS`, so the script can run again.
- Prefer the declared stores (`DEFINE VECTOR`, `DEFINE GEO`, `DEFINE GRAPH`) over assembling the
  field, index and distance by hand: the parts then can't drift apart.

## Related skills in this plugin

- **tessaridb-cluster** — several nodes: replicas, leadership and failover, splitting tables,
  read routing, upgrades.
- **tessaridb-s3** and **tessaridb-s3-cluster** — the S3-compatible object store that keeps its
  metadata in TessariDB.
- **tessarikv** — the storage engine under TessariDB, as a Rust library of its own.
