# Shards, placement and transactions across leaders

Checked against TessariDB 0.36.1 (on a local three-node cluster: a table split at `'m'`, shard 2
placed on a second node, which was elected for it; a transaction writing both shards refused
without `COMMIT ACROSS LEADERS` and committed with it). Upstream:
<https://docs.tessaridb.com/cluster/splitting-a-table>, `/cluster/who-leads-what`,
`/cluster/transactions-across-leaders`.

## Splitting a table: `SPLIT AT`

```tessariql
DEFINE TABLE orders (total int, customer string) IDENTITY uuid SPLIT AT 'g', 'p';
INFO FOR TABLE orders;
```

- The points are where shards **begin**: two points, three shards (1 before `'g'`, 2 from `'g'`,
  3 from `'p'`). Each shard has its own log and can have its own leader and its own subscribers.
- A split table needs `IDENTITY uuid` or ids you name (`SplitNeedsGeneratedUuid` otherwise), points
  strictly ascending, written literally (not parameters).
- **Generated uuids are time-ordered, so every insert lands in the last shard.** That's sharding by
  time. To spread writes:

```tessariql
DEFINE TABLE events (kind string) IDENTITY uuid SPREAD SPLIT AT '40', '80', 'c0';
DEFINE TABLE customers (region string, name string) IDENTITY uuid PARTITION BY region SPLIT AT 'de', 'fr';
```

  `SPREAD` prefixes ids with one of 256 random buckets (`'3f:01926f…'`); `ORDER BY id` is then not
  creation order. `PARTITION BY region` names records `'<region>:<uuid>'`, so a region is a shard,
  and a read with `WHERE region = 'de'` touches only that shard.

## Changing the map while it serves

```tessariql
ALTER TABLE orders SPLIT AT 'm';
ALTER TABLE orders MERGE SHARD 4, 5;
ALTER TABLE events SPLIT AUTOMATICALLY ABOVE 100000 RECORDS OR 500 WRITES PER SECOND MERGE BELOW 20000 RECORDS;
ALTER TABLE events SPLIT MANUALLY;
```

- A split retires the shard and mints two new numbers; a merge retires two neighbours and mints one.
  **No record moves**; retired shards' logs are still collected, fed and backed up.
- `SPLIT AUTOMATICALLY` lets the store's leader split and merge within bounds (`MERGE BELOW` must be
  under half of `ABOVE`). New shards are led by the store line until a row places them.
- A shard named by a member row (`REPLICATES SHARD`, `LEADS SHARD`) can't be split or merged until
  the row changes (`ShardNamedByAReplica`).
- A change ends every change feed over the table; a feed over a split table resumes with the
  **cursor** each change carries, not a sequence.

## Placing a leader: `LEADS`

<!-- not run: needs the running cluster -->
```tessariql
ALTER REPLICA n2 LEADS SHARD prod.shop.orders 2;
ALTER REPLICA n3 LEADS SHARD prod.shop.orders 2 PREFERRED;
ALTER REPLICA n2 LEADS NONE;
```

- `LEADS NAMESPACE | DATABASE | SHARD …` on a member row carves that range into its own line with
  its own election. Several rows naming one range are candidates for it. Only a node that may write
  stands for a placed range.
- From the moment the placement commits, writes into the range are refused `NoLeadershipYet` until a
  candidate is elected (a second or so), then go to that leader. The store's leader is deliberately
  not a fallback.
- `PREFERRED` names the candidate that should lead when it is caught up; it hands over at most once
  every 30 seconds.
- **Moving** a placement: put another row on the range, then `LEADS NONE` on the first. **Giving it
  back** to the store line: `LEADS NONE` on the last row. `DROP REPLICA` on the last row placing a
  range is refused (`PlacementCannotBeDropped`).
- `DEFINE FAILOVER … BALANCE LEADERSHIPS` lets the store's leader move a busy node's own placement
  to an idle voter, at most once per two leases. It moves leaderships, never data.
- `INFO FOR NODE` → `cluster.leaders` lists every range's leader and epoch.

## A node holding part of a table

A node with only some shards answers a whole-table read by **gathering** the other shards from their
leaders (filters, limits and folds run on the leaders, under the reader's field visibility). The
answer is complete but **not one snapshot**, and carries a `gathered` note. Reads inside a
transaction, under `VERSION`, or the read an `UPDATE`/`DELETE` makes are not gathered: they are
refused `NotHeldHere` (or redirected to a node holding the whole table). `NotGathered` refuses the
whole read when one shard's leader can't answer; `GatheredTooMuch` stops at 100 000 records.

## Transactions across leaders

A transaction writing ranges two different nodes lead is refused `SpansLeaderships`, naming both.
Ask for it explicitly:

<!-- not run: needs two shards led by two nodes; ran on the local cluster -->
```tessariql
BEGIN;
UPDATE accounts:'a17' SET balance = 60;
UPDATE accounts:'x17' SET balance = 40;
COMMIT ACROSS LEADERS;
```

- It commits whole or not at all in one round to each leader (about 2.5 times one write); asking
  costs nothing when the transaction turns out to touch one leader.
- Every reader sees all of it or none of it. It is **atomic, not globally ordered**: two readers on
  two ranges aren't ordered against each other.
- Only tables, collections and edges commit across leaders (`AcrossKind` otherwise).
- Answers: committed; `AcrossAborted` (nothing applied; a conflict inside is retriable);
  **`AcrossInDoubt`** (the outcome couldn't be learned: read the records, retry only idempotently);
  `AcrossNotHeldHere` (run it on a node holding every range it writes).
- While in flight, its records are locked: another write gets `Conflict` (retriable).
- Prefer keeping related records under one leader (`PARTITION BY`, a shared key prefix) so most
  transactions commit in one step.
