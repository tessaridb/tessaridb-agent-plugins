# Leadership, leases and failover

Checked against TessariDB 0.36.1 (a leader killed with `kill -9` on a local three-node cluster: a
survivor took writes 1.22 s later under the next epoch; the old leader restarted with the same flags
and caught up as a follower). Upstream: <https://docs.tessaridb.com/cluster/leadership-and-failover>.

## How a node comes to write

A clustered node writes **only under a leadership** and only over the ranges it leads. A leadership
is a **lease** a majority of the range's voters grant, numbered by an **epoch**. A leader that can't
renew stops writing on its own at its fence, before the lease ends, and only then may another node
be elected, so no instant has two writers.

- Voters are the `coordinating` members. The majority counts the node itself: three coordinating
  nodes keep electing after losing one.
- A voter refuses a candidate whose log is behind its own, so a node missing writes can't win and
  drop them.
- A node standing alone (no peer declared) is never fenced and takes no lease.
- `INFO FOR NODE` → `cluster.lease`: time left before this node stops writing. `null` means never
  granted (the normal state of a single node), which is a different answer from `0s`. A lease near
  zero on a node still writing is the split-brain window, and the only place it is visible.

## The two "no" answers

| message | means | a client should |
|---|---|---|
| "this node is in a cluster and holds no leadership: it does not accept writes until a majority grants it one …" (`NoLeadershipYet`) | **wait**: an election is running, or no node may stand (check `coordinating`) | retry after a short wait |
| "this range is led by another node: write it at … The node to expect is …, leading under epoch 7" | **go there** | follow it. Clients from 0.7 do it themselves; over HTTP it is a `307` |

Retrying both the same way spins forever on the second and gives up too early on the first. The
`tessaridb` command line can't follow a redirect ("that request belongs at …, which this caller
cannot follow"): connect it to the leader (`INFO FOR NODE` → `cluster.leaders`).

A write sent to a node that may not write at all is **carried** to the leader over the peer link
for callers that can't follow (old wire clients, HTTP), under a signed assertion, one hop only, and
never for statements that change users, grants, membership, the failover policy, backups or vaults.

## The failover policy

<!-- not run: a replicated write, taken only by a cluster's leader; ran on the local cluster -->
```tessariql
DEFINE FAILOVER AWARENESS 1s COLLECTION 1s ROUND 200ms CAMPAIGN 100ms LEASE 800ms;
```

- **All five clauses, always** (a partial statement is refused): it replaces a set, checked as a set.
  `BALANCE LEADERSHIPS` is an optional sixth ([shards-and-placement.md](shards-and-placement.md)).
- Without one, the cluster runs these built-in periods and `cluster.failover` reads `null`
  ("nobody set one"), replacing a lost leader in about a second.
- Enforced relations, each refused with the direction named: every period ≥ 50 ms;
  `CAMPAIGN` ≤ 2 × `ROUND`; `LEASE` > write fence + 2 × `ROUND`; `COLLECTION` < 2 × `AWARENESS`
  (which is also the tightest `STALENESS` a read may ask).
- **Voters far apart:** the defaults hold a lease up to about 90 ms between voters. Further, keep
  `ROUND` above 2.2 round trips and `LEASE` above the fence plus seven, e.g. at 150 ms:
  `ROUND 400ms CAMPAIGN 200ms LEASE 1500ms` (with `AWARENESS`/`COLLECTION` to match).
- It is written by the leader and replicated; it isn't a file or a flag, so two nodes can't disagree
  about when a lease expires.

## Draining and the two kinds of role

- `DEFINE NODE ROLES NONE` on a node: it keeps its data, identity and membership, stops answering
  clients and stops writing. On a node bound to a member row this local override is discarded at the
  next start; to keep it drained, change the row (`ALTER REPLICA n2 ROLES serving`).
- `INFO FOR NODE` shows `roles` (what the node does now; no `writable` while it holds no lease) and
  `cluster.desired` (what its row grants). They may differ, and during maintenance they should.

## When two histories claim one position

If two nodes ever both wrote under different epochs, a follower offered the second branch refuses it
at the first divergent record ("log divergence at 812: this store holds epoch 3, and epoch 4 was
offered"), counts it in `tessari_log_divergences`, and re-bootstraps rather than retrying.
