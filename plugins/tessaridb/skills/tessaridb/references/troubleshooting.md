# Troubleshooting: nothing, too little, too slow, or refused

Checked against TessariDB 0.38.4. Start every investigation by running something, not by reasoning:
`EXPLAIN` the read, `INFO FOR TABLE` the table, and read the notes the answer carries.

## A read returned nothing

| Check | Why |
|---|---|
| Which namespace and database is this connection in? `RETURN session::context();` | a pooled connection that reconnected lost its `USE` and is reading somewhere else, with no error |
| Does the field exist with that name and shape? `SELECT * FROM t LIMIT 3;` | a route that reaches nothing is not an error, it just doesn't match |
| `NONE` vs `NULL`: `WHERE f = NONE` (no field) vs `WHERE f = NULL` (present, null) | they are different facts and compare unequal |
| Is the value the same kind? `SELECT type::of(f) AS k, count(*) AS n FROM t GROUP BY type::of(f);` | `age > 18` over strings answers only about the numbers, with a note |
| Full text: does the **field** have an analyzer? `INFO FOR TABLE t` | a field with no analyzer holds no terms, so `MATCHES` finds nothing |
| Full text: was the analyzer declared in the same transaction as the writes, on a build before 0.36.0? | those rows posted no terms; `REBUILD INDEX` |
| Full text after an upgrade across 0.26: is there a `needs-rebuild` note? | `REBUILD INDEX` once |
| Vector: are the stored vectors the declared width? | a wrong-width vector in an `array` field is infinitely far from everything |
| Did the record expire? `INFO FOR TABLE t` shows `expire` | an expired record is gone from every read at its instant |
| Is this a view or a grant narrowing it? `INFO FOR USER me`, `INFO FOR ACCESS TO TABLE t` | a user with one grant sees only what was granted; a view runs with the caller's permissions |
| On a cluster: `STALENESS` / which node answered? | a follower may legitimately lag; use `ANSWERED BY LEADER` when you need the leader's view |

## A read returned too little

- **Read the notes.** "this source hit its ceiling" means a subquery or `collect` stopped at its
  bound: give it a `LIMIT` that states how many records the question is about. "comparison skipped
  records of another kind" means mixed types. "estimated" means an `approx_` fold.
- A `LIMIT` larger than what a `FUSE` read placed answers with fewer: records no branch placed
  within its `DEPTH` are not in the answer.
- `IF … THEN … ELSE` over an optional field puts records without it in the `ELSE` branch.
- An `APPROXIMATE` vector read can miss neighbours; measure recall (`REBUILD INDEX`,
  `INFO FOR VECTOR`) and raise `EFFORT`, or drop `APPROXIMATE` for the exact answer.

## A write lost data

- `UPDATE t:1 = { … }` replaced the record and dropped every field not named. Use `MERGE` or `SET`.
- A script run with `-f` stopped at a refusal and kept everything before it. Use `BEGIN … COMMIT`.
- A `CommitContention` or `Conflict` caught by a generic error handler drops the work: retry the
  transaction.
- A space key refreshed with `SET` and no `EXPIRE` became permanent; one refreshed with `EXPIRE`
  only keeps its value.
- `VERIFY` was written where `COMMIT` was meant: it discards the work by design.

## A read is slow

1. `EXPLAIN <read>`: `access: 'scan'` means no index served it. Look at `estimate`.
2. Add the index the condition needs (`DEFINE INDEX … FIELDS f`), then `USING INDEX name` on the
   read so a future regression refuses instead of scanning.
3. Paging with `START n` costs `n` rows; switch to `AFTER`. A "page was reached by reading the
   records" note means the order can't seek: order by the identity or an indexed field.
4. `search::score` without `LIMIT` scores every record; with `LIMIT` it stops early and stays exact.
5. A `geo::distance(…) > r` condition can't use the spatial index; `< r` can.
6. `ANALYZE TABLE t` refreshes the statistics the planner estimates from.
7. Measure through a client or HTTP, not by timing a whole CLI script, and compare a read only
   against a scan answering the **same** predicate.

## A connection or sign-in fails

| Symptom | Likely |
|---|---|
| `NotSignedIn` from the CLI | the store has users; add `--user name` and `TESSARIDB_PASSWORD` |
| `SignInRefused` / `SignInThrottled` | wrong password / too many attempts: wait (up to 30 s) |
| `401` vs `403` over HTTP | sign in vs the grant doesn't cover it; don't retry `403` |
| TLS handshake error | the client trusts the wrong authority, or the certificate doesn't name the host dialled |
| the node won't start: key file readable by others | `chmod 600` (container: owned by uid 10001) |
| the node won't start: only one `INITIAL_*` variable | set both or neither |
| "written by an earlier storage engine" | a pre-0.36 store: move it with a snapshot ([operations.md](operations.md)) |
| `NotWritable` | the node was drained (`DEFINE NODE ROLES serving`) or is a follower |
| `Stopped` | a write couldn't be made durable; reads still work; restart the node |

## Proving a fix

Write the failing case as a script against an in-memory store, see it fail, fix, see it pass:

```tessariql
DEFINE TABLE probe (name string, age int);
CREATE probe:1 = { name: 'ada', age: 36 };
SELECT * FROM probe:1;
EXPLAIN SELECT * FROM probe WHERE age > 18;
```

```tessariql
-- refused: UndeclaredField
UPDATE probe:1 MERGE { city: 'London' };
```

The refusal reads `table probe declares no field city … declare it with DEFINE FIELD city ON probe
TYPE string`: precise, in the store's own words, and already carrying the fix.
