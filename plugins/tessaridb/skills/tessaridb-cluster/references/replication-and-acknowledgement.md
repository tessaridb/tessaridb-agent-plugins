# How many copies exist, who gets them, and when a write counts

Checked against TessariDB 0.39.2. Upstream: <https://docs.tessaridb.com/cluster/what-replicates-where>
and `/cluster/when-a-write-is-acknowledged`.

Three independent questions, written in three places:

| question | written on | statement |
|---|---|---|
| how many copies of this data | the namespace | `REPLICATION FACTOR 3` / `REPLICATION NONE` |
| which data does this machine get | the peer's member row | `REPLICATES STORE \| NAMESPACE n \| DATABASE n.d \| SHARD n.d.t k` |
| how many copies hold a write before the caller hears ok | the namespace, or the request | `ACKNOWLEDGE LEADER \| LOCAL MAJORITY \| MAJORITY` |

How many nodes may **write** a namespace (`SINGLE LEADER` / `MULTI MASTER`) is a fourth question,
in [operating.md](operating.md).

## Replication on the namespace

```tessariql
DEFINE NAMESPACE archive REPLICATION FACTOR 3;
DEFINE NAMESPACE scratch REPLICATION NONE;
ALTER NAMESPACE scratch REPLICATION FACTOR 2;
INFO FOR NAMESPACE;
```

- On a store with peers that could hold a copy, a namespace that doesn't say is refused
  (`ReplicationUnstated`): a default nobody chose looks like a choice afterwards.
- Changing it moves nothing by hand: a node that starts replicating replays the namespace's history
  from the log and serves it only once caught up. There is no repair step.
- **A namespace asking for three copies on a cluster where no peer subscribes to it has one.**
  The factor is a wish; the subscriptions are what make copies.

## Subscriptions on the member row

`REPLICATES` takes the reaches a grant takes. A selective follower (`NAMESPACE`, `DATABASE`,
`SHARD`) receives only the mutations inside its reach, and can't even name another tenancy's
tables. Store-level users replicate everywhere; a tenancy's users and grants travel only within its
reach. `REPLICATES STORE` hands over every tenancy's data and credential hashes.

The quietest failure a cluster has is a row **without** `REPLICATES`: subscribed to nothing, every
node healthy, one copy that never changes. `INFO FOR NODE` shows each peer's subscription (`null` =
nothing) and the follower rows show who is actually collecting.

## Acknowledgement

A write is readable on the leader the moment it commits. `ACKNOWLEDGE` decides when the **caller**
is told, and therefore what losing the leader can take with it:

| level | the caller hears ok once | survives losing the leader |
|---|---|---|
| `LEADER` | the leader holds it durably | no: a leader lost before a follower collected it takes it along |
| `LOCAL MAJORITY` | a majority of the voters in the leader's `REGION` hold it | while the leader lives; **not promised across a failover** |
| `MAJORITY` | a majority of the range's voters (its `coordinating` members) hold it | yes: whichever majority elects the next leader has it |

- **`MAJORITY` is the default** for a namespace kept on more than one node. It costs about one
  round trip to the nearest follower.
- A request may ask for **more** than the namespace's level, never less, unless the namespace says
  `OR WEAKER`:

```tessariql
DEFINE NAMESPACE prod REPLICATION FACTOR 3 ACKNOWLEDGE MAJORITY;
USE NAMESPACE prod;
DEFINE DATABASE app;
USE DATABASE app;
DEFINE COLLECTION event;
BEGIN;
CREATE event:1 = { kind: 'login' };
COMMIT ACKNOWLEDGE MAJORITY;
ALTER NAMESPACE prod ACKNOWLEDGE MAJORITY OR WEAKER;
CREATE event:2 = { kind: 'heartbeat' } ACKNOWLEDGE LEADER;
```

  Without the `OR WEAKER`, the last write is refused `AcknowledgeBelowNamespace` (measured on a
  three-node cluster), and the refusal names the statement that would allow it.
- `LOCAL MAJORITY` needs `REGION 'eu'` on the member rows (`ALTER REPLICA n1 REGION 'eu'`); a leader
  whose own row names no region refuses `LocalMajorityWithoutRegion`.

## The two refusals that mean opposite things

| refusal | what happened | do |
|---|---|---|
| `MajorityUnreachable` | before the commit: the voters subscribed to where the write lands can't make a majority | **nothing was written**; fix the subscriptions, or ask for less if allowed |
| `NotAcknowledgedInTime` | after the commit: the write **is** in the leader's log at the sequence named, but not enough voters confirmed within one failover round | it may or may not survive a failover; retry only a write that says the same thing twice (`UPSERT`, a known id). A repeated `CREATE` is refused as already there |

A client that treats every refusal as "nothing happened" is wrong about the second one.
