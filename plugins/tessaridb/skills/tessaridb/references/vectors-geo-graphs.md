# Vectors, geometry and graphs

Checked against TessariDB 0.39.1. One record can carry text, a vector, a shape and links at once,
and one transaction writes all of them. Full detail:
<https://docs.tessaridb.com/query-language/vectors>, `/geometry`, `/graphs`.

## Vectors

A declared vector store holds the field, the index and the distance in one statement, so the parts
can't drift apart:

```tessariql
DEFINE VECTOR embeddings DIMENSION 3 DISTANCE cosine;
CREATE embeddings:'intro' = { vector: [0.1, 0.2, 0.3], label: 'intro' };
CREATE embeddings:'setup' = { vector: [0.3, 0.1, 0.0], label: 'setup' };
SELECT label FROM embeddings ORDER BY vector::cosine(vector, [0.1, 0.2, 0.25]) LIMIT 5;
```

`DIMENSION` and `DISTANCE` are required with no default. Distances: `cosine`, `euclidean`, `dot`.

A vector can also be a field of a table that exists for its own reasons. **Declare its width**:

```tessariql
DEFINE COLLECTION points;
DEFINE FIELD at ON points TYPE vector<2>;
DEFINE INDEX by_at ON points FIELDS at VECTOR euclidean;
CREATE points:1 = { at: [0.0, 0.0], name: 'origin' };
CREATE points:2 = { at: [0.9, 0.9], name: 'far' };
SELECT name FROM points ORDER BY vector::euclidean(at, [0.0, 0.0]) LIMIT 1;
```

```tessariql
-- refused: SchemaViolation
CREATE points:3 = { at: [0.1, 0.2, 0.3] };
```

A wrong-width vector in a field declared plain `array` is accepted and is then **infinitely far
from everything**: a plausible ordering, never an error. `vector<n>` refuses it at the write.

### Exact by default; approximate only when the statement says so

A vector read is the exact scan unless the statement says `APPROXIMATE`. That is the one place an
index may change an answer, so the statement has to ask for it:

```tessariql
SELECT label FROM embeddings
ORDER BY vector::cosine(vector, [0.1, 0.2, 0.25]) LIMIT 2 APPROXIMATE EFFORT 200;
REBUILD INDEX vector ON embeddings;
INFO FOR VECTOR embeddings;
```

- `EFFORT` tunes that one read: more candidates, better recall, more cost.
- Recall is **measured** by `REBUILD INDEX`, and `INFO FOR VECTOR` reports it, or `NONE` when
  nobody has measured. Never quote a recall figure nobody measured.
- Filter, then rank: `SELECT … WHERE live = true ORDER BY vector::cosine(…) LIMIT k`. With
  `APPROXIMATE` the index tests the whole condition on each candidate; when it can't fill the page
  it hands the read to the exact path with a `fell-back` note rather than answering short.
- `QUANTIZED` keeps one byte per component in the index and re-ranks candidates on the full
  vectors: about a fifth of the bytes for a few points of recall. Measure recall after choosing it.

```tessariql
DEFINE VECTOR compact DIMENSION 3 DISTANCE euclidean QUANTIZED;
CREATE compact:'a' = { vector: [0.1, 0.2, 0.3] };
SELECT id FROM compact ORDER BY vector::euclidean(vector, [0.1, 0.2, 0.3]) LIMIT 1 APPROXIMATE;
```

To combine vector similarity with text relevance or distance, use `ORDER BY FUSE (…)`
([search.md](search.md)), never a sum of the values. For retrieval-augmented generation, store the
chunk text, its source and its vector in one record so a hit carries what you need to cite.

## Geometry

```tessariql
DEFINE GEO places;
CREATE places:'paris' = { geometry: geometry { type: 'Point', coordinates: [2.35, 48.85] }, name: 'Paris' };
CREATE places:'lyon' = { geometry: geometry { type: 'Point', coordinates: [4.83, 45.76] }, name: 'Lyon' };
SELECT name FROM places WHERE geo::within(geometry, geometry { type: 'Polygon',
  coordinates: [[[2, 48], [3, 48], [3, 49], [2, 49], [2, 48]]] });
SELECT name, geo::distance(geometry, geometry { type: 'Point', coordinates: [2.29, 48.86] }) AS metres
FROM places ORDER BY metres LIMIT 1;
SELECT name FROM places
WHERE geo::distance(geometry, geometry { type: 'Point', coordinates: [2.35, 48.85] }) < 10000;
```

- Coordinates are GeoJSON order: **`[longitude, latitude]`**. Backwards gives valid, wrong answers.
- Seven types: Point, LineString, Polygon, their Multi forms, GeometryCollection. Invalid shapes
  (an unclosed ring, longitude 181) are refused at the write. Shapes crossing the antimeridian are
  handled.
- Distances are in **metres** on the sphere, never degrees. `geo::distance` measures between any
  two shapes, to their nearest points.
- `geo::distance(…) < r` is served by the spatial index (`EXPLAIN` shows shape `region`); `> r` is
  the outside of a disc and stays an exact scan.
- Predicates: `geo::intersects`, `within`, `covered_by`, `contains`, `covers`, `touches`, `equals`,
  `disjoint`. `within` excludes the boundary and `covered_by` includes it: choose deliberately.
- `geo::cell(point, level)` is the index's own cell at a level (0 to 32) as a polygon, for map
  clustering: `SELECT geo::cell(geometry, 2) AS cell, count(*) AS n FROM places GROUP BY geo::cell(geometry, 2)`.
  Cells are not equal in area.
- A shape in your own table: `DEFINE FIELD at ON t TYPE geometry` and
  `DEFINE INDEX by_at ON t FIELDS at SPATIAL`. `INFO FOR GEO g` reports what refining the index's
  candidates cost.

## Graphs

Two ways to store links. A **declared graph** keeps adjacency beside each node, so a hop doesn't
get slower as a node's degree grows. Use it when the graph is what you store and hops are what you
pay for:

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
SELECT name FROM social:1->knows->social PATH TO social:3 DEPTH 3;
```

An **edge table** is a table whose rows are links. Use it when edges carry a lot of data or are
queried like rows (`SELECT * FROM follows WHERE since > …`):

```tessariql
DEFINE COLLECTION users;
DEFINE TABLE follows EDGE;
CREATE users:1 = { handle: 'ada' };
CREATE users:2 = { handle: 'grace' };
RELATE users:1->follows->users:2 = { since: datetime '2026-01-01T00:00:00Z' };
SELECT * FROM users:1->follows;
SELECT * FROM users:1->follows->users;
DELETE users:1->follows->users:2;
```

- `->` follows links out, `<-` follows them in. **One arrow answers the edges, two answer the far
  records.** Chains (`a->x->b->y->c`) walk several hops; `DEPTH n` repeats one hop up to `n` times.
- `PATH TO` answers one path with a `path` note giving its steps; `DEPTH` is required, and
  `WEIGHT field` makes it the cheapest path within that many steps.
- `RELATE` is idempotent: an edge is identified by its endpoints.
- **Deleting a record does not delete its edges.** A traversal skips the missing endpoint, but
  `SELECT * FROM users:1->follows` still lists the dangling edge. Delete edges with their records
  when that matters.
- An existing table can join a declared graph with `IN social`. A graph and an edge kind are dropped
  only once nothing still belongs to them.
- A join matches a value nobody wrote down as a link; when records point at each other, traverse.
