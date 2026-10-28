# Operating a cluster: upgrades, backups, monitoring, multi-master, diagnosis

Checked against TessariDB 0.39.2 (a snapshot taken on a follower and verified whole). Upstream: <https://docs.tessaridb.com/cluster/upgrading-a-cluster>,
`/cluster/two-writers-on-one-range`, `/operations/backup-and-restore`.

## Rolling upgrades

From 0.23 a cluster moves to the **next minor release** without stopping:

1. Find the leaders: `INFO FOR NODE` → `cluster.leaders`.
2. Replace the **followers** one at a time: stop, start the new release on the same store directory
   with the same flags, wait until it answers and has caught up.
3. Replace the **store line's leader last**. Writes pause for about one lease and an election while
   it is down. A node leading a placed range pauses that range; move the placement to an upgraded
   node first to avoid it.

- One minor version at a time; two steps are two upgrades.
- Turn on what the new release adds (new clauses, a transaction across leaders, `BALANCE LEADERSHIPS`)
  only after every node runs it.
- Until `ALTER STORE FINALIZE FORMAT`, a newer release keeps the store's format, so going back is
  starting the previous release on the same directory. Finalize only when no node will go back; on a
  cluster it is refused (`FormatPeerTooOld`) until every replica runs the new release and has
  collected once.
- **0.35 → 0.36 is not a rolling upgrade.** 0.36.0 moved to the TessariKV storage engine and refuses
  a store an earlier engine wrote. Snapshot each store with the build that wrote it and restore into
  0.36 (`tessaridb new --restore snap.tessarisnap`), then form the cluster again.
- **0.39.1 → 0.39.2 can't be undone by starting 0.39.1 again.** 0.39.2 runs on TessariKV 0.2.0, whose
  first open stamps the node's storage files with a newer format that 0.39.1 refuses, whatever
  `ALTER STORE FINALIZE FORMAT` says. Going back is restoring a snapshot taken before the upgrade.
- Take a snapshot before any upgrade.

## Backups on a cluster

- A snapshot (`BACKUP`, `GET /backup`, `tessaridb --at <node> --user owner --backup file`) can be
  taken on **any node holding the whole place**: a follower keeps the load off the leader.
- A node holding only some shards refuses (`NotHeldHere`); there is no gathered backup.
- A backup carries the topology (member rows, failover policy) but not the machine's identity or
  roles. A cluster rebuilt from backups is configured node by node.
- Each node bounds its own log (`DEFINE NODE RETAIN …`, 100 000 records by default). A follower that
  falls behind the leader's pruned point copies the leader's state instead of the log.

## Monitoring

- `INFO FOR NODE` on every node: `cluster.leaders`, `lease`, `followers` (`behind`, `quiet_for`,
  `copy_age`), `peers` (with `subscription`, `roles`, `leads`, `region`), `failover`, `across`
  (`committed`, `aborted`, `in_doubt`), `tombstoned`, `revoked`, `certificates`.
- `/metrics` (signed in for cluster figures): `tessari_lease_remaining_seconds` (absent on a node
  holding no lease), `tessari_log_divergences`, `tessari_transactions_across_leaders_total{outcome}`,
  `tessari_shard_records{table, shard}`, `tessari_balancer_moves_total`,
  `tessari_tls_certificate_expires_seconds{surface}`.
- The web console's Cluster screen draws the same map, composes the membership transaction, issues
  join tokens and revokes certificates, showing each statement before sending it.

## Two writers on one range: `MULTI MASTER`

```tessariql
DEFINE NAMESPACE shared MULTI MASTER;
DEFINE NAMESPACE ledger SINGLE LEADER;
USE NAMESPACE shared;
DEFINE DATABASE app;
USE DATABASE app;
DEFINE TABLE counters SCHEMALESS LAST WRITER WINS;
DEFINE TABLE orders SCHEMALESS REFUSE CONFLICTS;
CREATE orders:1 = { total: 1 };
INFO FOR VERSIONS OF orders:1;
```

- `MULTI MASTER` lets several nodes accept writes to one namespace. It **gives up single-copy
  semantics**: two nodes can write one record without seeing each other, and neither version is
  newer.
- `REFUSE CONFLICTS` (the default) refuses the next write onto such a record (`ConcurrentVersions`),
  naming both versions: read both and write what they mean. That refusal is the only moment the
  choice is visible.
- `LAST WRITER WINS` takes the incoming write and drops the versions it didn't see. They stay on disk
  and vanish from every answer; the engine counts them, and somebody must read that count.
- Use it only with a written answer to "two nodes wrote one record without seeing each other", and
  never as a throughput setting. `REPLICATION` (copies) is a separate question.

## Diagnosis

| Symptom | Look at | Usually |
|---|---|---|
| every write refused "holds no leadership" for more than a few seconds | `INFO FOR NODE` → `leaders`, roles | no node has `coordinating`, fewer than a majority of voters are up, or a node's row lacks `writable` |
| a write refused "led by another node" from the CLI | `cluster.leaders` | send it to the leader, or use a client that follows redirects |
| one node's data never changes | leader's `followers`; that peer's `subscription` | its row has no `REPLICATES` (subscribed to nothing), or its certificate is refused |
| a follower's `behind` keeps growing | network, disk, `COLLECTION` period | the follower can't keep up |
| a newcomer never joins | its log; the row on the leader | no `NODE` / `FINGERPRINT` / token on the row, token expired, wrong certificate name, or it holds namespaces of its own (`WouldReinterpret`) |
| a node refuses to start | its log | some but not all of the five cluster options, a key file others can read, or a tombstoned id |
| `NotAcknowledgedInTime` | follower rows | the write is committed on the leader; followers are slow or down |
| `MajorityUnreachable` | subscriptions vs voters | too few voters subscribe to the written range |
| all inserts go to one node | `INFO FOR TABLE` shards | split over generated uuids without `SPREAD` |
| `log divergence at …` | `tessari_log_divergences` | two histories; the follower re-bootstraps |
