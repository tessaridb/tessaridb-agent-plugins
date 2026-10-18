---
name: tessaridb-s3-cluster
description: Deploy and run TessariDB S3 as a cluster of several nodes. Use when choosing an erasure code (k+m) and failure zones, issuing the nodes' mutual-TLS certificates, starting founding members, joining or removing a node with a join token, staging and applying a new layout, reading healing and move backlogs, putting the metadata on a TessariDB cluster, replicating buckets to another region or failing a region over, or explaining why a cluster node refuses to start or answers SlowDown. For one S3 node, buckets, keys and policies use the tessaridb-s3 skill; for the TessariDB cluster under the metadata use tessaridb-cluster.
---

# TessariDB S3 clusters

Setting `TESSARIDB_S3_ERASURE=k+m` makes an S3 node a cluster member. Each object becomes k data
shards and m parity shards, one per node of an **erasure set**; the placement is computed from
`TESSARIDB_S3_CLUSTER_SECRET`, so every node finds every object without asking anyone. The facts
(buckets, versions, membership, layouts, the heal list) stay in TessariDB, which can be a cluster of
its own.

Checked against **TessariDB S3 0.2.1-beta** with metadata on **TessariDB 0.36.1**: a three-node 2+1
cluster in Docker (built by `scripts/local-s3-cluster.sh`) wrote through one node and read the same
bytes through another; with one node stopped reads and writes went on; with two stopped both were
refused `503 SlowDown`; after the restart the heal pass reported `examined 1, healed 1`; a fourth node
joined by token and a new layout moved the shards onto it; a node outside the founding members, and a
node presenting another node's certificate, refused to start.

## Pick the reference for the task

| Task | Read |
|---|---|
| Plan a cluster, issue certificates, start founding members, the metadata store | [references/standing-up.md](references/standing-up.md) |
| Quorums, failures, healing, zones, layouts, joining and removing nodes | [references/layouts-healing-membership.md](references/layouts-healing-membership.md) |
| Regions, bucket replication, failing a region over | [references/regions-and-replication.md](references/regions-and-replication.md) |

## Try it locally first

```bash
sh scripts/local-s3-cluster.sh ./s3c        # 2+1 on 127.0.0.1:48187-48189, console 48190, secrets in ./s3c/env
. ./s3c/env
AWS_ACCESS_KEY_ID=local-root AWS_SECRET_ACCESS_KEY=$ROOT_SECRET AWS_DEFAULT_REGION=us-east-1 \
  aws --endpoint-url http://127.0.0.1:48187 s3 mb s3://first
docker stop s3c-s2                          # one node down: reads and writes go on
docker rm -f s3c-db s3c-s1 s3c-s2 s3c-s3; docker volume rm s3c-db s3c-s1 s3c-s2 s3c-s3; docker network rm s3c
```

## Rules that prevent quiet mistakes

1. **Pick k+m against what you must survive.** A write needs k shards durable (k + 1 when k = m); a
   read needs any k that verify. With m = 1 one node may be down; a second loss refuses both.
2. **Give every node the same `TESSARIDB_S3_ERASURE` and `TESSARIDB_S3_CLUSTER_SECRET`** (≥ 32 bytes).
   The secret decides placement; change it and nodes look for shards in the wrong places.
3. **Name failure domains.** `TESSARIDB_S3_ZONE` per node, so a layout never puts more of one object's
   shards in a zone than m. Without it each node is its own zone.
4. **One certificate per node, named `<node id>.peer.tessari-s3`**, from one authority, usable as server
   and client. A node whose certificate names another node does not start.
5. **Members are admitted, not discovered.** A new cluster starts from `TESSARIDB_S3_FOUNDING_MEMBERS`;
   later nodes join by console approval or a one-time `TESSARIDB_S3_JOIN_TOKEN`. An unadmitted node
   does not start.
6. **Removal is for good.** A removed node id is never admitted again; give a replacement a new id.
7. **The internal surface is mutual TLS only.** Expose `TESSARIDB_S3_INTERNAL_LISTEN` only to the other
   nodes; `TESSARIDB_S3_INTERNAL_ADVERTISE` is the address they dial.
8. **`503 SlowDown` from a cluster can mean too few shards reachable**, not only load. Check the members
   in `/metrics` or the console before raising limits.
9. **Every node needs its own `TESSARIDB_S3_DATA_DIR`** and the same metadata store settings.
10. **A metadata cluster needs the replication stated** (`TESSARIDB_S3_META_REPLICATION`, and the same
    on the `s3` namespace); a TessariDB cluster refuses a namespace whose replication was never stated.
11. **A layout change moves bytes in the background.** Watch the objects still to move; throttle with
    `TESSARIDB_S3_MOVE_BYTES_PER_SEC` (`0` pauses). Old shards go only after the reclaim grace.
12. **Back up the metadata and every node's data directory together,** and keep the cluster secret, the
    internal authority and `TESSARIDB_S3_IAM_KEY` outside both.

## Related skills

- `tessaridb-s3` — everything a single node does (buckets, keys, policies, encryption, events).
- `tessaridb-cluster` — standing up the TessariDB cluster that holds the metadata.
