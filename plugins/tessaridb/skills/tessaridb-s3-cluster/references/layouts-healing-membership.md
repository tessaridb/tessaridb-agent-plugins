# Quorums, failures, healing, layouts and membership

Checked against TessariDB S3 0.8.0 (on a 2+1 Docker cluster: one node stopped → reads and writes
continued; two stopped → `503 SlowDown` on both; restart → the heal pass healed what was written while
a node was down; a fourth node joined by token, a layout `[s1, s2, s4]` was staged and applied, and with
`s2` and `s3` then stopped all four objects still read back intact from `s1` and `s4`). Upstream: <https://docs.tessaridb.com/s3/operating/clusters>.

## What a failure does

| reachable shards | reads | writes |
|---|---|---|
| all k + m | normal | normal |
| at least k (k + 1 when k = m) | answered: a missing or damaged shard is rebuilt from parity for that read, and the object is listed for healing | acknowledged on the quorum; missing shards are healed later |
| fewer | refused (`503 SlowDown`) | refused, nothing acknowledged |

A degraded read costs more, because every read of a damaged object rebuilds it until healing has run.

## Healing

- Every member runs a heal pass every `TESSARIDB_S3_HEAL_INTERVAL_SECS` (60 s): it rewrites the missing
  or damaged shards of objects listed for healing, one node at a time per object, under a claim in
  TessariDB.
- Shard bytes no object can reach any more are swept.
- The log line reads `examined N, healed N, at risk N, held elsewhere N`; `/metrics` carries the heal
  backlog; `GET /api/v1/cluster` answers `heal_backlog: { listed, more, at_risk }` and
  `moving: { listed, more }`, and the console's overview shows the same.

## Failure domains

`TESSARIDB_S3_ZONE` names a node's zone, rack or room. A layout never puts more of one object's shards
in one zone than its parity can lose, so losing a whole zone leaves every object readable. The first
layout takes the registered nodes in id order, passing over a node whose zone already holds m shards.

## Changing the layout

A layout is one or more erasure sets of registered nodes. Root changes it in the console (or the API):

1. **Stage** a layout over the current version: `PUT /api/v1/cluster/layout/staged` with `sets`
   (lists of node ids, one per shard) and a `reason`. It is judged against the registered nodes and
   their zones, and answers `{ id, base, layout }`. `GET` shows the staging, `DELETE` discards it.
2. **Apply** it as the next version: `POST /api/v1/cluster/layout/apply` with that `id`.

```bash
curl -b jar -X PUT -H 'content-type: application/json' \
  -d '{"sets":[["s1","s2","s4"]],"reason":"move off s3"}' $C/api/v1/cluster/layout/staged
curl -b jar -H 'content-type: application/json' \
  -d '{"id":"<id from the staging>","reason":"move off s3"}' $C/api/v1/cluster/layout/apply
curl -b jar $C/api/v1/cluster        # layout.version, moving, heal_backlog, members
```

Either step is refused if the layout or the staging changed meanwhile, needs a fresh sign-in and a
reason, and is recorded in the action record.

After an apply, each member moves objects written under an older layout onto it: it copies and
verifies the shards whose node changes, switches the object, and removes the old shards once the
reclaim grace has passed. Speed: `TESSARIDB_S3_MOVE_BYTES_PER_SEC` (32 MiB/s; `0` pauses). The cluster
view counts objects still to move.

Seen on 0.8.0: after writes refused below quorum (two of three nodes stopped), `moving.listed` stayed
at 3 and the heal pass reported `at risk 2`, with the mover logging `0 shards readable` for those
entries, while every object in the bucket read back intact. Judge a move by reading the objects, not
by the count alone.

## Membership

- **Founding members** (`TESSARIDB_S3_FOUNDING_MEMBERS`) are admitted at their first start, only where
  they have no membership record yet.
- **Any later node** is admitted by root in the console (`POST /api/v1/cluster/members/approve` with
  `node` and optionally the certificate's `fingerprint`) or by a one-time **join token**
  (`POST /api/v1/cluster/members/token` with `node` and `lifetime_secs`, answering `{ node, token,
  expires }`), offered at start in `TESSARIDB_S3_JOIN_TOKEN`; the token binds the node's certificate.
- **A joined node holds nothing** until a layout includes it (measured: after joining, `members` listed
  it and the layout still named only the founding set).
- **Removal** (`POST /api/v1/cluster/members/remove` with `node`) is for good and reaches every node
  within 5 seconds; that id is never admitted again. Move data off it with a layout first.

## Adding capacity, in order (rehearsed)

1. Issue the new node's certificate (`<new id>.peer.tessari-s3`) from the same authority.
2. Issue a join token for the id in the console.
3. Start the node with the cluster's settings, its own id and certificate, and `TESSARIDB_S3_JOIN_TOKEN`
   (no `TESSARIDB_S3_FOUNDING_MEMBERS` needed).
4. Stage a layout with an erasure set that includes it; apply it; watch the move count reach zero.

## Replacing a failed node (assembled from the steps above, not rehearsed)

1. Remove the failed id (for good).
2. Admit a replacement under a **new** id with its own certificate.
3. Apply a layout that uses the new node in place of the old; the move and heal passes rebuild its
   shards.
