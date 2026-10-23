# Recipes: common tasks, end to end

Each recipe was run against TessariDB 0.38.1 on a fresh store with a namespace and database
selected. Adapt the names; keep the shape.

## A re-runnable schema script

Everything `IF NOT EXISTS`, structure and seed data in one transaction, so a restart can run it
again and a failure leaves nothing half-made:

```tessariql
BEGIN;
DEFINE TABLE IF NOT EXISTS accounts (email string REQUIRED, name string, plan string DEFAULT 'free', created datetime DEFAULT time::now());
DEFINE INDEX IF NOT EXISTS by_email ON accounts FIELDS email UNIQUE;
DEFINE TABLE IF NOT EXISTS invoices (account record REQUIRED, total decimal REQUIRED, status string DEFAULT 'open');
DEFINE INDEX IF NOT EXISTS by_account ON invoices FIELDS account;
COMMIT;
```

Rehearse a risky migration with `VERIFY` in place of `COMMIT` first: it runs every check, then
discards the work. After changing a table, `CHECK TABLE t` lists records that no longer fit.

## Optimistic concurrency and an audit trail

Compare-and-set on a version field, and the old value back from the same write:

```tessariql
DEFINE COLLECTION documents;
CREATE documents:1 = { title: 'Plan', body: 'v1', version: 1 };
UPDATE documents:1 SET body = 'v2', version = 2 WHERE version = 1 RETURN BEFORE;
```

A stale writer's `WHERE version = 1` now fails with `ConditionNotMet` (nothing written): re-read,
merge, try again.

## Search with ranking, highlighting and type-ahead

```tessariql
DEFINE ANALYZER english FILTERS lowercase, ascii, stemmer;
DEFINE COLLECTION articles;
DEFINE FIELD title ON articles TYPE string ANALYZER english;
DEFINE FIELD body ON articles TYPE string ANALYZER english;
DEFINE INDEX by_title ON articles FIELDS title SEARCH;
DEFINE INDEX by_body ON articles FIELDS body SEARCH POSITIONS OFFSETS;
CREATE articles:1 = { title: 'Locks and contention', body: 'Contention appears when two writers want one record' };
CREATE articles:2 = { title: 'Queues', body: 'A queue hands each job to one worker' };
SELECT id, title, search::score(body, 'writers contention') * 1 + search::score(title, 'writers contention') * 3 AS relevance,
       search::highlight(body) AS marks
FROM articles WHERE body MATCHES 'writers contention' OR title MATCHES 'writers contention'
ORDER BY relevance DESC LIMIT 10;
DEFINE ANALYZER plain FILTERS lowercase, ascii;
DEFINE SEARCH suggest ON articles FIELDS title ANALYZER plain;
SELECT term, documents FROM SEARCH suggest COMPLETE 'loc';
```

Type-ahead runs on an unstemmed search so it suggests whole words. Bind the user's input as a
parameter (`MATCHES $q`).

## Hybrid retrieval for RAG: words and meaning

Keep the chunk, its source and its embedding in one record, and fuse a text ranking with a vector
ranking by place:

```tessariql
DEFINE ANALYZER plain_en FILTERS lowercase, ascii, stemmer;
DEFINE VECTOR chunks DIMENSION 3 DISTANCE cosine;
DEFINE FIELD text ON chunks TYPE string ANALYZER plain_en;
DEFINE INDEX by_text ON chunks FIELDS text SEARCH;
CREATE chunks:1 = { vector: [0.9, 0.1, 0.0], text: 'Reset a password from the account page', source: 'help/account.md' };
CREATE chunks:2 = { vector: [0.1, 0.9, 0.0], text: 'Invoices are sent on the first of the month', source: 'help/billing.md' };
SELECT text, source FROM chunks
ORDER BY FUSE (search::score(text, 'reset password') DESC, vector::cosine(vector, [0.8, 0.2, 0.0]))
LIMIT 5;
```

Use the real model width in `DIMENSION`. For large stores, rank the vector branch alone with
`APPROXIMATE` where recall is measured, and keep the fused read exact.

## Sessions, rate limits and a lock

```tessariql
DEFINE SPACE sessions;
DEFINE SPACE limits;
DEFINE SPACE locks;
SET sessions:'tok-123' = { user: 'ada' } EXPIRE 30m;
GET sessions:'tok-123';
INCR limits:'ada:2026-10-18T10:05';
EXPIRE limits:'ada:2026-10-18T10:05' 2m;
SET locks:'nightly-report' = 'worker-7' IF ABSENT EXPIRE 30s;
SET locks:'nightly-report' = 'worker-7' IF = 'worker-7' EXPIRE 30s;
```

A rate-limit key per user and minute, counted with `INCR` and given an expiry. A lock is taken
with `IF ABSENT` and extended or released only by its holder with `IF =`. In code, look the session
up with a bound id: `GET sessions:$token`.

## A background job queue with a dead letter

```tessariql
DEFINE TOPIC failed_jobs RETAIN 30d;
DEFINE QUEUE emails TIMEOUT 2m ATTEMPTS 5 DEAD LETTER TO failed_jobs DEDUPLICATE 1h;
CREATE emails:'welcome:ada' = { to: 'ada@example.com', template: 'welcome' };
CREATE emails:'welcome:ada' = { to: 'ada@example.com', template: 'welcome' };
USE CONSUMER 'mailer';
CLAIM 10 FROM emails;
DELETE emails:'welcome:ada';
READ FROM failed_jobs FOR CONSUMER 'ops';
```

The second `CREATE` writes nothing (deduplicated by id). A worker claims, does the work, deletes the
record; if it crashes the hold lapses and another worker gets it; after 5 attempts the record moves
to `failed_jobs`. The clients' `Queue` helper runs this loop for you.

## A transactional outbox: work after the commit

An event writes a message in the writer's own transaction; a consumer group does the outside work
(email, webhook) at least once:

```tessariql
DEFINE COLLECTION orders;
DEFINE TOPIC order_events RETAIN 7d;
DEFINE EVENT announce ON orders FOR CREATE THEN CREATE order_events = { order: $id, total: $after.total };
DEFINE GROUP 'notifier' ON TOPIC order_events ACK DEADLINE 30s DELIVERIES 5;
CREATE orders:1 = { total: dec 40.00 };
READ FROM order_events FOR CONSUMER 'notifier' LIMIT 10;
ACK order_events FOR CONSUMER 'notifier' AT 1;
```

The order and its message commit together or not at all. Make the outside effect idempotent, keyed
on topic + group + position.

## An API page with a cursor

```tessariql
DEFINE COLLECTION products;
CREATE products:1 = { name: 'anvil' };
CREATE products:2 = { name: 'bell' };
CREATE products:3 = { name: 'chisel' };
SELECT * FROM products LIMIT 2;
-- with --param last=2
SELECT * FROM products AFTER products:$last LIMIT 2;
```

Return the last id of each page as the cursor; the next request binds it. Ordering by the identity
(or an indexed field) keeps every page as cheap as the first.

## One database per tenant, one user per database

Run as the store's owner:

```tessariql
DEFINE NAMESPACE IF NOT EXISTS tenants;
DEFINE USER root ROLE owner PASSWORD 'the owner passphrase, long';
```

```tessariql
USE NAMESPACE tenants;
DEFINE DATABASE IF NOT EXISTS acme;
DEFINE USER acme_app ON tenants.acme ROLE editor PASSWORD 'acme application password';
INFO FOR USER acme_app;
```

`acme_app` can't name anything outside `tenants.acme` (`OutsideTenancy`). Narrow further with
`GRANT … ON table` if needed.

## Nightly backup you have actually checked

```sh
TESSARIDB_PASSWORD="$OWNER_PASSWORD" tessaridb --at db:9080 --user root --backup "/backups/$(date +%F).tessarisnap"
tessaridb --verify "/backups/$(date +%F).tessarisnap"
```

Restore one into a scratch directory now and then (`tessaridb ./scratch --restore file`) and read
something back: a passing `--verify` is not a restore.
