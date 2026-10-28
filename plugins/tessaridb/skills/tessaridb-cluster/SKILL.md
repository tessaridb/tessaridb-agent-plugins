---
name: tessaridb-cluster
description: Deploy and run a TessariDB cluster. Use when standing up several TessariDB nodes, issuing their peer certificates, adding, approving, draining or removing a node, choosing replication and write acknowledgement, handling leader failover and the refusals around it, splitting a table into shards and placing shard leaders, committing a transaction across leaders, routing reads by staleness or to the leader, running multi-master namespaces, upgrading a cluster node by node, or diagnosing a cluster from INFO FOR NODE. For the language and a single node, use the tessaridb skill.
---

# TessariDB cluster

A TessariDB cluster is a set of nodes that learn about each other **through the same log they
replicate data with**. There is no coordinator process and no config file to keep in step: the
membership is catalog records (`DEFINE REPLICA`), the failover policy is a replicated statement
(`DEFINE FAILOVER`), and everything is a statement you can script and review.

Checked against **TessariDB 0.39.2** on a local three-node cluster: forming it, writing and reading
through followers, a leader killed with `kill -9` (a survivor took writes 0.54 s later), the old
leader rejoining, all three nodes stopped and started together (a write was taken 1.1 s after the
start), a placed shard leader, a transaction across leaders, a fourth node joining with a token, and
a Python client 0.13.0 creating a record and a user through a follower. Upstream reference: <https://docs.tessaridb.com/cluster/what-a-cluster-is>.

## Pick the file for the task

| You are… | Read |
|---|---|
| standing up a cluster, issuing certificates, adding / approving / removing a node | [references/standing-up.md](references/standing-up.md) |
| deciding how many copies exist and when a write counts | [references/replication-and-acknowledgement.md](references/replication-and-acknowledgement.md) |
| understanding leases, failover, the two "no" answers, the failover policy, draining | [references/leadership-and-failover.md](references/leadership-and-failover.md) |
| splitting a table, placing shard leaders, transactions across leaders | [references/shards-and-placement.md](references/shards-and-placement.md) |
| routing reads (`STALENESS`, `ANSWERED BY LEADER`), redirects, follower lag | [references/reads-and-routing.md](references/reads-and-routing.md) |
| upgrading, backing up, monitoring, multi-master, diagnosing a cluster | [references/operating.md](references/operating.md) |

## Try it locally first

[scripts/local-cluster.sh](scripts/local-cluster.sh) builds a three-node cluster on one machine
(its own authority, peer certificates, membership and start flags) in a few seconds:

```sh
sh scripts/local-cluster.sh /tmp/tc /path/to/tessaridb
TESSARIDB_PASSWORD=local-cluster-owner tessaridb --at 127.0.0.1:48161 --user owner -e 'INFO FOR NODE;'
kill $(cat /tmp/tc/n*/pid)
```

Use it to rehearse a change (a placement, a failover policy, an upgrade order) before running it on
a real cluster.

## The one picture

The store is cut into **ranges**: the whole store, or a namespace, database or shard somebody
placed. Each range is a **line**: its own log, its own numbered leaderships (epochs), its own lease.
One node leads a line and takes its writes; every other node holding the range keeps a copy and
votes on who leads next. A cluster nobody placed anything on has one line, the store line.

## Rules that prevent quiet failures

1. **Declare the whole membership in one transaction**, the same rows in the same order on every
   founding node, each node included. From the first committed `DEFINE REPLICA` a node is clustered
   and refuses local writes until a majority elects it, so a statement-at-a-time script declares
   one peer and is refused for the rest.
2. **Every node that may ever lead needs `coordinating`, and in a cluster that can fail over every
   coordinating node is also `writable`.** A node without `coordinating` never stands for
   leadership; a clustered node with no leader stops taking writes and never starts again.
3. **Every peer row needs `REPLICATES`.** A row without it is subscribed to nothing: every node is
   up, every greeting lands, and one copy never changes. Check `INFO FOR NODE` → `followers`, not
   `peers`.
4. **A namespace on a cluster states its replication** (`REPLICATION FACTOR 3` or
   `REPLICATION NONE`). Silence is refused on a store with peers that could hold a copy.
5. **Writes acknowledge at `MAJORITY` by default** where there is more than one copy. A request
   can't ask for less unless the namespace says `… OR WEAKER`.
6. **Tell the two refusals apart:** "holds no leadership" means *wait* (an election is running);
   "this range is led by another node: write it at …" means *go there*. Clients from 0.7 follow the
   second automatically, users and grants included (from 0.38.3); the `tessaridb` command line
   can't, so point it at the leader.
7. **`NotAcknowledgedInTime` means the write IS committed** on the leader; retry only with a write
   that says the same thing twice (`UPSERT`, a known id).
8. **A newcomer joining a running cluster declares no membership**, only its own roles, and a node
   that already holds namespaces of its own is refused rather than merged.
9. **Splitting by generated uuids puts every insert in the last shard** (UUID v7 is time-ordered).
   Use `IDENTITY uuid SPREAD`, `PARTITION BY`, or a varying key prefix.
10. **A transaction writing ranges two nodes lead must say `COMMIT ACROSS LEADERS`**, and an
    `AcrossInDoubt` answer is read back, never assumed either way.
11. **`STALENESS` and `ANSWERED BY LEADER` decide who may answer**; neither marks the answer.
    Reads that must agree with each other belong in one transaction.
12. **`MULTI MASTER` gives up single-copy semantics.** Use it only with a written answer for "two
    nodes wrote one record without seeing each other", and know `LAST WRITER WINS` discards
    versions that stay on disk and vanish from every answer.
13. **Upgrade one minor release at a time, followers first, the store leader last**, and turn on new
    features only after the last node runs the new release. Crossing 0.35 → 0.36 is not rolling: every
    store is moved with a snapshot. 0.39.2 can't be rolled back by starting 0.39.1 again: snapshot first.

## Check before you trust it

`INFO FOR NODE` on **every** machine: `cluster.leaders` (who leads which range, under which
epoch), `cluster.lease` (time left; `null` means never granted), `cluster.peers` versus
`cluster.followers` (declared versus actually collecting), each follower's `behind`, `quiet_for`
and `copy_age`, `cluster.failover`, `cluster.across`, `tombstoned` and `revoked`.
