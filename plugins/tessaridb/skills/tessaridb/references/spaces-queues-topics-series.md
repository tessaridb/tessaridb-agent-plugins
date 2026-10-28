# Spaces, files, queues, topics, time series and views

Checked against TessariDB 0.39.2. Each engine is a kind of table, so `CREATE`, `SELECT`, grants,
backups and replication work on it as on any table, and one transaction can write to all of them.

| Question | Engine |
|---|---|
| One value under one key, fast, maybe expiring: a cache, a counter, a lock | space |
| Bytes that aren't a document | bucket |
| Work handed to exactly one worker at a time | queue |
| Events every reader sees, each at its own pace, in commit order | topic |
| Measurements over time, grouped by window | series |
| A named read, or a kept answer to one | view |

## Key-value spaces

```tessariql
DEFINE SPACE sessions;
SET sessions:'abc' = { user: 'ada' } EXPIRE 30m;
GET sessions:'abc';
RETURN TTL sessions:'abc';
DEL sessions:'abc';
KEYS FROM sessions PREFIX 'user:42:' LIMIT 100;
```

```tessariql
DEFINE SPACE counters;
DEFINE SPACE locks;
INCR counters:'hits';
INCR counters:'hits' BY 10;
SET locks:'report' = 'worker-7' IF ABSENT EXPIRE 30s;
SET locks:'report' = 'worker-7' IF = 'worker-7' EXPIRE 30s;
DEL locks:'report';
```

- `SET … IF ABSENT` takes a lock and answers whether it wrote. `SET … IF = <value>` changes the key
  only if it still holds that value, which is how you extend a lock you still hold.
- **A plain `SET` clears an expiry.** Refreshing an expiring key with `SET` and no `EXPIRE` makes it
  permanent. Use `EXPIRE key 10m` to move only the expiry, and `PERSIST key` to remove it. (Tables
  that expire behave the other way: a plain write there keeps the instant.)
- `INCR` on a missing key counts from zero and answers the new value.
- `DEFINE SPACE cache MAX 10000` keeps at most that many keys and evicts the least recently written;
  `MAX 500 EVICT NONE` refuses the key past the limit (`SpaceFull`).
- A key from a caller is a value: `GET sessions:$token`.
- Spaces are also reachable over HTTP (`/kv/…`) and from every client as a cache handle
  ([clients.md](clients.md)).

## Files (buckets)

```tessariql
DEFINE BUCKET media;
PUT media:'/notes.txt' = 'ada wrote this';
READ media:'/notes.txt';
SELECT size FROM media:'/notes.txt';
```

`DEFINE BUCKET media MAX 5242880` declares the largest file it takes. Files can be written and read
in ranges, and over HTTP (`PUT /files/…`). For S3-compatible object storage, use TessariDB S3 (the
tessaridb-s3 skill), which keeps its metadata in TessariDB and its bytes on drives.

## Queues

```tessariql
DEFINE QUEUE jobs TIMEOUT 30s ATTEMPTS 5;
CREATE jobs:1 = { url: 'https://example.com/a', kind: 'image' };
CREATE jobs:2 = { url: 'https://example.com/b', kind: 'text' };
CLAIM FROM jobs;
DELETE jobs:1;
CLAIM 5 FROM jobs WHERE kind = 'text';
RELEASE jobs:2;
```

- `CLAIM` hands a record to one worker and holds it for `TIMEOUT`. **Finishing is `DELETE`** of the
  record; giving up is `RELEASE`. A worker that dies just lets the hold lapse, and the record is
  handed out again. Nothing else is needed: no heartbeat, no reaper.
- `TIMEOUT` is required with no default: how long a job may take is your decision.
- Nothing claimable answers **no records and no error**. Concurrent claims take different records.
- `ATTEMPTS n` stops handing out a record after `n` hand-outs. `DEAD LETTER TO <topic>` (needs
  `ATTEMPTS`) moves a spent record to a topic as `{ queue, id, attempts, value }`.
- `CLAIM … WHERE <condition>` takes only matching records, so two kinds of worker can share a queue.
  A value index covering the condition serves it.
- `PRIORITY BY f` hands out the greatest `f` first; `NOT BEFORE f` holds a record back until the
  instant in `f`. `RELEASE q:id NOT BEFORE 10m` releases and delays in one write.
- `DEDUPLICATE 10m` makes a `CREATE` of an identity first written less than 10 minutes ago write
  nothing, whether that record is queued, held, or already done.
- `USE CONSUMER 'billing'` signs this session's holds. `RELEASE ALL FROM jobs` frees this session's
  holds (what a worker does at shutdown); `RELEASE ALL FROM jobs FOR CONSUMER 'billing'` frees the
  whole group's, including live workers'.
- `CLAIM jobs:7` takes a named record: held by someone else answers nothing, missing is an error.

Work on a schedule is a queue record whose `NOT BEFORE` is its next run:

```tessariql
DEFINE QUEUE ticks TIMEOUT 5m NOT BEFORE next;
CREATE ticks:1 = { job: 'cleanup', next: time::now() };
CLAIM FROM ticks;
RELEASE ticks:1 NOT BEFORE 1h;
```

A run can happen twice across a leader change on a cluster, but it is never skipped. Make the work
idempotent.

## Topics

```tessariql
DEFINE TOPIC events RETAIN 7d;
CREATE events = { kind: 'paid', order: 'o-17' };
CREATE events = { kind: 'shipped', order: 'o-17' };
READ FROM events;
READ FROM events AFTER 1 LIMIT 100;
INFO FOR TOPIC events;
```

Every reader sees every message, in commit order, at dense positions. A plain consumer's position
is kept in the store and moves **in the same transaction** as whatever the consumer did, so
"processed but not acknowledged" can't happen. That is exactly-once for effects inside this store:

```tessariql
DEFINE COLLECTION invoices;
BEGIN;
READ FROM events FOR CONSUMER 'billing' LIMIT 10;
CREATE invoices = { order: 'o-17', total: 40 };
COMMIT;
```

For a pool of workers that settle each message on its own, declare a group:

```tessariql
DEFINE TOPIC mail_dead;
DEFINE GROUP 'mailer' ON TOPIC events ACK DEADLINE 30s DELIVERIES 5 IN FLIGHT 10 DEAD LETTER TO mail_dead;
READ FROM events FOR CONSUMER 'mailer' LIMIT 10;
ACK events FOR CONSUMER 'mailer' AT 1;
NACK events FOR CONSUMER 'mailer' AT 2 DELAY 10s;
```

- A group is **at least once**: a worker that crashed before `ACK` sees the message again. Make the
  effect idempotent; topic + group + position is a stable key.
- `IN FLIGHT 1` (the default) keeps strict order; more lets workers run in parallel.
- `ACK … AT $positions` takes a bound array. `ALTER GROUP 'g' ON TOPIC t START AT n` replays or
  skips.
- `RETAIN 7d` / `RETAIN BYTES n` remove the oldest messages; a reader that missed some gets a
  `lapsed` note once, saying how many.
- `DEFINE TOPIC payments DEDUPLICATE 5m ON payment_id` drops a message repeating a key published
  within the window.
- Messages can't be updated or deleted. Every client ships a consumer loop for groups.

To move a topic into a table continuously, declare `DEFINE TOPIC CONSUMER … INTO …` (each message
applied once); for Kafka, `DEFINE KAFKA CONSUMER` (at least once, needs a build with the `kafka`
feature). Both are at <https://docs.tessaridb.com/query-language/stream-ingestion>.

## Time series

```tessariql
DEFINE SERIES readings RETAIN 30d TIME at;
CREATE readings = { sensor: 'boiler', v: 71.5, at: datetime '2026-09-29T10:00:00Z' };
CREATE readings = { sensor: 'boiler', v: 73.0, at: datetime '2026-09-29T12:10:00Z' };
SELECT time::bucket(at, 1h) AS hour, count(*) AS n, mean(v) AS v
FROM readings GROUP BY time::bucket(at, 1h);
DEFINE INDEX by_sensor ON readings FIELDS sensor;
SELECT sensor, v, at FROM readings LATEST BY sensor;
```

- `RETAIN` is required: reads stop at that floor, and older records are removed.
- `TIME at` orders the series by each event's own time rather than by arrival.
- `FILL` fills empty windows; `ASOF JOIN` pairs each reading with the latest earlier row of another
  series; `increase`, `delta` and `rate` fold counters (resets included).
- `DEFINE ROLLUP` keeps per-window summaries in the same transaction as the writes:

```tessariql
DEFINE ROLLUP hourly FROM readings WINDOW 1h BY sensor COMPUTE count(*) AS n, sum(v) AS total RETAIN 365d;
```

A rollup can also keep `approx_distinct` and `approx_quantile`. Services can append events over
HTTP (`POST /series/…`).

## Views

```tessariql
DEFINE COLLECTION staff;
CREATE staff:1 = { name: 'ada', team: 'engine' };
DEFINE VIEW engineers AS SELECT name FROM staff WHERE team = 'engine';
SELECT * FROM engineers;
DEFINE VIEW engineer_count MATERIALIZED AS SELECT team, count(*) AS n FROM staff GROUP BY team;
SELECT * FROM engineer_count;
```

A plain view holds nothing: it is expanded where it is used and runs with the **caller's**
permissions. `MATERIALIZED` keeps its answer as records, brought current from the source's changes
after each commit.
