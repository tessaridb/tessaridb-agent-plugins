---
name: tessaridb
description: Work with TessariDB, a multi-model database with its own query language, TessariQL. Use when writing or reviewing TessariQL; designing tables, indexes or analyzers; adding full-text, vector, geo or graph search; using key-value spaces, queues, topics, time series or vaults; connecting from Rust, Python, TypeScript, Go or Kotlin; running a node or a cluster; or explaining why a query returned what it did.
---

# TessariDB

TessariDB is one database with several engines: documents and tables, full-text search,
vectors, geometry, graphs, key-value spaces, files, queues, topics, time series and vaults. Each is
reached through one language, **TessariQL**, and one transaction can write across all of them.

This skill was checked against **TessariDB 0.20.1-beta**. The language, the wire format and the
on-disk format can still change before 1.0. When behaviour matters, say which version you checked
it on. The published documentation at <https://docs.tessaridb.com> is the reference; when this
skill and the site disagree, the site wins.

## Files in this skill

Read the one that matches the task:

| File | Read it when |
|---|---|
| [references/language.md](references/language.md) | writing any statement: tenancy, tables, records, conditions, projections, writes |
| [references/search.md](references/search.md) | full-text search, analyzers, scoring, highlighting, `DEFINE SEARCH`, type-ahead |
| [references/engines.md](references/engines.md) | vectors, geometry, graphs, key-value spaces, queues, topics, time series, vaults |
| [references/transactions-and-history.md](references/transactions-and-history.md) | multi-statement writes, scripts, reading the past |
| [references/clients.md](references/clients.md) | connecting from an application, the wire protocol, HTTP |
| [references/operations.md](references/operations.md) | running a node, users and grants, backups, clusters |

## Quick start

```sh
docker run -d --name tessaridb -p 9080:9080 -p 8000:8000 \
  -v tessaridb-data:/var/lib/tessaridb \
  -e TESSARIDB_INITIAL_USER=owner -e TESSARIDB_INITIAL_PASSWORD='choose-a-real-one' \
  tessaridb/tessaridb:0.20.1-beta
```

Port 9080 is the wire protocol that clients use. Port 8000 is HTTP and serves a web console at `/`.

A prompt against it:

```sh
TESSARIDB_PASSWORD='choose-a-real-one' tessaridb --at 127.0.0.1:9080 --user owner
```

Or with no server at all: `tessaridb` with no arguments gives an in-memory store, and
`tessaridb ./data` a store on disk. Add `-e '<script>'` or `-f file.tessariql` to run a script.

A first store:

```tessariql
DEFINE NAMESPACE prod;
USE NAMESPACE prod;
DEFINE DATABASE shop;
USE DATABASE shop;
DEFINE TABLE users (name string, email string);
DEFINE INDEX by_email ON users FIELDS email UNIQUE;
CREATE users = { name: 'ada', email: 'ada@example.com' };
SELECT * FROM users WHERE email = 'ada@example.com';
```

## Rules that prevent quiet mistakes

TessariDB's worst failures are the ones that **succeed**: the statement runs, the test passes, and
the answer is wrong. Each rule below prevents one of them.

1. **Send the `USE` with the work.** `USE NAMESPACE` / `USE DATABASE` belong to the connection. A
   pooled connection that reconnected has forgotten them, and the next read either fails or, worse,
   answers from whatever it now points at. Put the `USE` lines in the same script as the statement.
2. **Bind values; never format them into the text.** `WHERE name = $who` with `who` passed as a
   parameter. A value bound after parsing can never become syntax. Names (tables, fields) are
   grammar and can't be parameters; never take them from user input.
3. **`= { … }` replaces the whole record.** `UPDATE users:1 = { name: 'x' }` deletes every other
   field. To change some fields use `SET` or `MERGE`.
4. **A conditional delete states its reach.** `DELETE FROM t WHERE …` must say `LIMIT n` or
   `LIMIT ALL`. Without either it is refused rather than deleting an unknown number of rows.
5. **`NONE` and `NULL` are different.** `NONE` means "no such field", `NULL` means "the field is
   there and empty". They compare unequal, and neither takes part in `<` / `>`.
6. **A comparison across kinds is a note, not an error.** `WHERE age > 18` over records where some
   `age` values are strings answers only about the numbers, and attaches a note saying so. Read the
   notes an answer carries, and surface them in an application.
7. **An index changes cost, never the answer.** The one exception is written in the statement:
   a vector read is exact unless it says `APPROXIMATE`.
8. **A script is not a transaction.** A file runs statement by statement and stops at the first
   refusal, keeping everything before it. Wrap all-or-nothing work in `BEGIN … COMMIT`.
9. **Contention is reported, not waited out.** `CommitContention` and `Conflict` are the two
   refusals that mean "try again". Retry those explicitly and nothing else.
10. **A store with no users is open.** Until the first `DEFINE USER`, anyone who can reach the port
    can read and write everything. Declare an owner first (the container's
    `TESSARIDB_INITIAL_USER` does this).
11. **Neither port terminates TLS.** Run the node on a trusted network or behind a proxy that does.

## How to check what a statement did

- `EXPLAIN <read>` shows the plan without running the read. `access: 'index'` or `'scan'` says
  which path it takes.
- Every read reports its access path in its answer, for example `(3 record(s), via index)`.
- `INFO FOR TABLE t`, `INFO FOR DATABASE`, `INFO FOR USER u` and `INFO FOR NODE` report what the
  store actually holds, read from the catalog itself.
- `CHECK TABLE t` lists stored records that disagree with what the table declares now.
- A refusal is the database's own answer. Quote it verbatim; it names the place in the script.

## Language at a glance

- Keywords UPPERCASE, names `snake_case`, strings in single quotes, one statement per line,
  each ending in `;`.
- Records are addressed as `table:id`: `users:1`, `users:'ada'`, `readings:uuid '01a0…'`.
  `CREATE users = { … }` lets the store produce the id.
- Every `DEFINE` in a deployment script should carry `IF NOT EXISTS` so the script can be re-run.
- Comments are `-- to the end of the line`.
