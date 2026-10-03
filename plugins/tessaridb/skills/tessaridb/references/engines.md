# The other engines

One record can carry text, a vector, a shape and links all at once, and one transaction can write
across every engine. Pick the engine by the question you need answered:

| Question | Engine |
|---|---|
| Records like this one, by meaning | vector |
| What is near, inside or crossing a place | geometry |
| What is linked to what, several hops out | graph |
| One value under one key, fast, maybe expiring | space (key-value) |
| Bytes that aren't a document | bucket (files) |
| Work handed to exactly one worker at a time | queue |
| Events every reader sees, each at its own pace, in commit order | topic |
| Measurements over time, grouped by window | series |
| A secret the database must not be able to read back | vault |

## Vectors

```tessariql
DEFINE VECTOR embeddings DIMENSION 3 DISTANCE cosine;
CREATE embeddings:'intro' = { vector: [0.1, 0.2, 0.3], label: 'intro' };
CREATE embeddings:'setup' = { vector: [0.3, 0.1, 0.0], label: 'setup' };
SELECT label FROM embeddings ORDER BY vector::cosine(vector, [0.1, 0.2, 0.25]) LIMIT 5;
```

`DEFINE VECTOR` declares the field (`vector<3>`, required), the index and the distance in one
statement, so the parts can't drift apart. `DIMENSION` and `DISTANCE` are required with no default.
Distances: `cosine`, `euclidean`, `dot`.

- **Declare the width.** A vector in a field declared plain `array` with the wrong length is
  infinitely far from everything, and it produces a plausible ordering instead of an error.
  `vector<n>` refuses it at write time.
- **A vector read is exact** (a full scan) unless the statement says `APPROXIMATE`. That is the one
  place an index may change an answer, and the statement has to ask for it:

```tessariql
SELECT label FROM embeddings
ORDER BY vector::cosine(vector, [0.1, 0.2, 0.25]) LIMIT 2 APPROXIMATE EFFORT 200;
REBUILD INDEX vector ON embeddings;
INFO FOR VECTOR embeddings;
```

- `EFFORT` tunes that one read. Recall is measured by `REBUILD INDEX`, and `INFO FOR VECTOR` reports
  it. It reports `NONE` when nobody has measured. Never quote a recall figure nobody measured.
- Filter first, then rank: `SELECT … WHERE live = true ORDER BY vector::cosine(…) LIMIT k`. With
  `APPROXIMATE` the graph serves that read too: it tests the whole condition on every record it
  admits, and when it cannot fill the page it hands the read to the exact path (a `fell-back` note)
  rather than answering short.
- `QUANTIZED` keeps one byte per component in the index and re-ranks the candidates on the full
  vectors: about a fifth of the bytes for a few points of recall. Measure recall after choosing it.

```tessariql
DEFINE VECTOR compact DIMENSION 3 DISTANCE euclidean QUANTIZED;
CREATE compact:'a' = { vector: [0.1, 0.2, 0.3] };
SELECT id FROM compact ORDER BY vector::euclidean(vector, [0.1, 0.2, 0.3]) LIMIT 1 APPROXIMATE;
```

- To combine vector similarity with text relevance, use `ORDER BY FUSE (…)`, never a sum.

## Geometry

```tessariql
DEFINE GEO places;
CREATE places:'paris' = { geometry: geometry { type: 'Point', coordinates: [2.35, 48.85] }, name: 'Paris' };
CREATE places:'lyon' = { geometry: geometry { type: 'Point', coordinates: [4.83, 45.76] }, name: 'Lyon' };
SELECT name FROM places WHERE geo::within(geometry, geometry { type: 'Polygon',
  coordinates: [[[2, 48], [3, 48], [3, 49], [2, 49], [2, 48]]] });
SELECT name, geo::distance(geometry, geometry { type: 'Point', coordinates: [2.29, 48.86] }) AS metres
FROM places ORDER BY metres LIMIT 1;
```

- Coordinates are GeoJSON order: `[longitude, latitude]`. Getting it backwards produces valid,
  wrong answers.
- Seven geometry types (Point, LineString, Polygon and their Multi forms, GeometryCollection).
  Distances are in **metres** on the sphere, not degrees.
- Predicates: `geo::intersects`, `geo::within`, `geo::covered_by`, `geo::contains`, `geo::covers`,
  `geo::touches`, `geo::equals`, `geo::disjoint`. `within` excludes the boundary and `covered_by`
  includes it, so choose deliberately.
- Shapes crossing the antimeridian are handled. Invalid shapes (unclosed rings, longitude 181) are
  refused at write.

## Graphs

Two ways to store links. A **declared graph** keeps adjacency next to each node, so a hop doesn't
get slower as degree grows:

```tessariql
DEFINE GRAPH social;
CREATE social:1 = { name: 'ada' };
CREATE social:2 = { name: 'grace' };
CREATE social:3 = { name: 'katherine' };
DEFINE EDGE knows IN social FROM social TO social;
RELATE social:1->knows->social:2;
RELATE social:2->knows->social:3;
SELECT name FROM social:1->knows->social;
SELECT name FROM social:3<-knows<-social;
SELECT name FROM social:1->knows->social DEPTH 2;
```

An **edge table** is a table whose rows are links, for when edges carry a lot of data or are queried
like rows:

```tessariql
DEFINE COLLECTION users;
DEFINE TABLE follows EDGE;
CREATE users:1 = { handle: 'ada' };
CREATE users:2 = { handle: 'grace' };
RELATE users:1->follows->users:2 = { since: datetime '2026-01-01T00:00:00Z' };
SELECT * FROM users:1->follows->users;
```

`->` follows links out and `<-` follows them in. Chains such as `a->x->b->y->c` walk several hops,
and `DEPTH n` repeats one hop up to n times.

`PATH TO` answers one path through a declared graph, start to end, with a `path` note giving its
steps and cost. `DEPTH` is required, and `WEIGHT field` makes it the cheapest path within that many
steps:

```tessariql
SELECT name FROM social:1->knows->social PATH TO social:3 DEPTH 3;
```

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
SET locks:'report' = 'free' IF = 'worker-7' EXPIRE 1ms;
```

- `SET … IF ABSENT` takes a lock; `SET … IF = <value>` changes it only if you still hold it.
- **A plain `SET` clears an expiry.** Refreshing an expiring key with `SET` and no `EXPIRE` makes it
  permanent. Use `EXPIRE key 10m` to change only the expiry, and `PERSIST key` to remove it.
- `DEFINE SPACE cache MAX 10000` bounds a space and evicts least recently modified keys;
  `MAX n EVICT NONE` refuses writes when full (`SpaceFull`).
- Spaces are also reachable over HTTP and from every client as a cache handle.

## Files (buckets)

```tessariql
DEFINE BUCKET media;
PUT media:'/notes.txt' = 'ada wrote this';
READ media:'/notes.txt';
SELECT size FROM media:'/notes.txt';
```

## Queues

```tessariql
DEFINE QUEUE jobs TIMEOUT 30s ATTEMPTS 5;
CREATE jobs = { url: 'https://example.com/a' };
CREATE jobs = { url: 'https://example.com/b' };
CLAIM 1 FROM jobs;
```

`CLAIM` hands a job to one worker and holds it for `TIMEOUT`. A worker that finishes deletes the
job (`DELETE jobs:<id>`), and one that gives up calls `RELEASE jobs:<id>`. A hold that lapses
returns the job to the queue, and `attempts` counts how often it has been handed out. `TIMEOUT` is
required: how long a job may take is your decision, not the store's.

`PRIORITY BY f` hands out the greatest `f` first (ties in arrival order), and `NOT BEFORE g` holds a
record back until the instant in `g`:

```tessariql
DEFINE QUEUE alerts TIMEOUT 1m PRIORITY BY severity;
CREATE alerts = { severity: 2, text: 'disk at 80%' };
CREATE alerts = { severity: 9, text: 'disk full' };
CLAIM FROM alerts;
DEFINE QUEUE mail TIMEOUT 5m NOT BEFORE send_at;
```

## Topics

```tessariql
DEFINE TOPIC events;
CREATE events = { kind: 'paid', order: 'o-17' };
CREATE events = { kind: 'shipped', order: 'o-17' };
READ FROM events;
```

Every reader sees every event, in commit order, at dense positions. A consumer's position is kept
in the store and moves **in the same transaction** as what the consumer did with the events, so
"processed but not acknowledged" can't happen:

```tessariql
DEFINE COLLECTION invoices;
BEGIN;
READ FROM events FOR CONSUMER 'billing' LIMIT 10;
CREATE invoices = { order: 'o-17', total: 40 };
COMMIT;
```

For worker pools, `DEFINE GROUP 'mailer' ON TOPIC events ACK DEADLINE 30s` gives per-message `ACK`
and `NACK`, redelivery, a delivery limit and `DEAD LETTER TO <topic>`.

`RETAIN 7d` keeps messages for a time and `RETAIN BYTES n` keeps at most n bytes of them; an append
past the limit removes the oldest in the same commit. A reader that missed removed messages gets a
`lapsed` note once, saying how many.

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

`RETAIN` is required. It is the floor below which readings are dropped. There is also `FILL`
for gaps, `ASOF JOIN` to match each reading with the latest earlier row of another series,
counter folds (`increase`, `delta`, `rate`) and `DEFINE ROLLUP` for maintained per-window
summaries.

## Vaults

A vault stores secrets encrypted with a key the database derives from a passphrase. The database
can't read them back without it.

```tessariql
UNSEAL VAULT WITH 'the operator passphrase';
DEFINE VAULT team;
DEFINE FIELD login ON team TYPE string;
DEFINE FIELD token ON team TYPE string SECRET;
CREATE team:'github' = { login: 'boog', token: 'the secret' };
REVEAL token FROM team:'github';
SEAL VAULT;
```

- On a store that has never held a vault, the first `UNSEAL` sets the passphrase. An unseal lasts
  for a set time (`--unseal-for`, ten minutes by default) and then the store seals itself.
- A vault is strict: every field is declared, and only `SECRET` fields are encrypted.
- Every `REVEAL` is recorded or refused.
- **Dropping a vault does not destroy its secrets** while a backup taken before the drop exists.
  Destroying a secret takes two acts: drop it, and expire every older backup. Rotate the secret at
  its source as well.
