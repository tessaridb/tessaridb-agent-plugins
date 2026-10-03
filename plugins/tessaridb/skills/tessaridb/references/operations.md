# Running TessariDB: serving, users, backups, clusters

## Serving

```sh
tessaridb ./data --serve 0.0.0.0:9080 --http 0.0.0.0:8000
```

Or the container (`tessaridb/tessaridb:<version>`, amd64 and arm64), which serves both ports and
keeps the store in `/var/lib/tessaridb`. Pin a released tag. Pre-1.0, a store written by one version
is not promised to open under the next, so take a backup and test on a copy before upgrading.

- `tessaridb ./data --health` exits non-zero when the store is not well.
- `--tls-cert` and `--tls-key` make both ports speak TLS 1.3 and nothing else; the files are
  re-read when they change, so a renewed certificate needs no restart. Without them any node
  (single or in a cluster) serves in the clear and says so at start, naming whether it is reachable beyond this machine;
  `INFO FOR NODE` reports `clients: { tls, required }`. `--require-client-tls` (or
  `TESSARIDB_REQUIRE_CLIENT_TLS=1`) makes a node refuse to start without a certificate.
  `--client-plaintext` is retired: accepted in 0.23.0-beta with a notice, refused after.
- A browser warns about any certificate from your own authority. For the console use `localhost`
  or an SSH tunnel, a publicly trusted (ACME) certificate, or a TLS proxy in front of the HTTP
  port with the node's HTTP bound to loopback.
- `--encryption-key-file` (32 bytes, readable only by its owner) encrypts the store at rest and
  seals every backup it writes. A store opens only the way it was created, and a lost key is a lost
  store.

## Backups

```tessariql
BACKUP;
BACKUP STATE;
BACKUP LOG;
BACKUP SCRIPT;
```

- `BACKUP` (= `BACKUP STATE`) is a snapshot of the current state. It is the default, and it
  survives a pruned log. `BACKUP LOG` is the replayable log. `BACKUP SCRIPT` is TessariQL that
  rebuilds the store.
- `BACKUP … TO 'name'` writes to the node's `--backup-dir`. From a shell:
  `tessaridb ./data --backup monday.tessarisnap`, then `tessaridb --verify monday.tessarisnap` (no
  store needed). Restore into an empty store with `--restore`.
- Verify a backup where it was written, before you rely on it.
- A backup carries the topology, never this machine's identity.

## Users and authority

**A store with no users is open to anyone**, for reads as well as writes. The first `DEFINE USER`
closes it, **and from that statement on every statement needs a signed-in user**, even on a local
store. So declare the owner and the first users together in one transaction:

```tessariql
DEFINE COLLECTION orders;
BEGIN;
DEFINE USER root ROLE owner PASSWORD 'the longest one of all';
DEFINE USER writer ON skill.skill ROLE editor PASSWORD 'another long one';
DEFINE USER reader ON skill.skill ROLE viewer PASSWORD 'a long enough one';
GRANT read, write ON orders TO writer;
GRANT read ON orders FIELDS total TO reader;
COMMIT;
```

After that, sign in: `TESSARIDB_PASSWORD=… tessaridb ./data --user root` (or `--at host:port
--user root`). The password always comes from the environment, never from an argument. Then:

```text
INFO FOR USER writer;
INFO FOR ACCESS TO TABLE orders;
```

The container does the first step from `TESSARIDB_INITIAL_USER` and `TESSARIDB_INITIAL_PASSWORD`;
set both or neither. There is no back door: a lost owner password means restoring from a backup.

- Roles (`owner`, `editor`, `viewer`) are shorthands for authority sets. Authority is a **kind**
  (`read`, `write`, `manage`, `operate`, `replicate`) and a **reach** (the store, a namespace, a
  database).
- Grants narrow a user to tables and fields. A user with even one grant can reach exactly what
  was granted and nothing else.
- Revoking a user's last grant is refused (`LastGrant`), because it would widen them back to their
  role.
- A `GRANT` or `REVOKE` applies from the next statement, even on a connection that is already open.

## The log and pruning

The log is the store's history and what replicas copy. A node keeps the last 100 000 log records by
default (`DEFINE NODE RETAIN …`). Pruning is irreversible. A follower that falls behind the pruned
part copies its leader's state instead.

## Clusters, briefly

A cluster starts when the catalog names a peer. Then:

- Declare **every peer in one transaction** on the first node. The first `DEFINE REPLICA` makes the
  node clustered and costs it the authority to commit the next one on its own.
- Give every node that may ever lead the `coordinating` role. Without it, a clustered node stops
  accepting writes and never starts again.
- Each peer row needs a `REPLICATES` clause. A peer subscribed to nothing leaves one copy that never
  changes, with nothing in an error state.
- Start each node with all five cluster options together (`--cluster-credential`, `--cluster-key`,
  `--cluster-authority`, `--cluster-address`, `--seed`) or none of them.
- Peers always speak mutual TLS with a certificate issued for each node's id. A joining node is
  approved by its id, its certificate's fingerprint or a one-time join token, and
  `REVOKE CERTIFICATE '<sha256>'` cuts a peer off, open links included.
- A namespace kept on more than one node answers a write once a majority of its voters hold it
  (`ACKNOWLEDGE MAJORITY`, the default). A refusal saying the write **is** committed but not
  confirmed in time (`NotAcknowledgedInTime`) must not be retried as if nothing happened.
- Read `INFO FOR NODE` on every machine: its lease, epoch, followers and subscriptions.
- Writes go to the leader of the range they touch. Reads can say how stale they may be
  (`STALENESS`), or demand the leader (`ANSWERED BY LEADER`). Both choose which nodes may answer;
  neither marks the answer.
- Tables can be split by key range (`SPLIT AT`), with a leader per range (`LEADS`). A transaction
  that writes ranges led by two different nodes is refused (`SpansLeaderships`).
- `MULTI MASTER` gives up single-copy semantics. Use it only when you can say what happens when two
  nodes write one record without seeing each other. Choose `REFUSE CONFLICTS` to handle that in
  your application, or `LAST WRITER WINS` only if someone will watch its conflict counter.

The cluster section of <https://docs.tessaridb.com> walks through adding a node, failover and
splitting a table in full.
