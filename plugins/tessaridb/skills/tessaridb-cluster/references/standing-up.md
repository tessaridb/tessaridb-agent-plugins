# Standing up a cluster, and adding or removing a node

Checked against TessariDB 0.39.2 by building a three-node cluster from nothing and joining a fourth
node with a token. Upstream: <https://docs.tessaridb.com/cluster/adding-a-node> and
`/security/encryption-in-transit`.

## Two statements, two scopes

| statement | describes | stored | in a backup |
|---|---|---|---|
| `DEFINE NODE ROLES … ENDPOINTS …` | **this machine**: what it is for | locally | no |
| `DEFINE REPLICA name AT … NODE … ROLES … REPLICATES …` | the **topology**: which peers exist, where, what each collects | the catalog, replicated | yes |

Roles: `serving` (answers reads), `writable` (the operator wants it to take writes),
`coordinating` (stands for leadership and votes). A peer row without `ROLES` has **no** roles.

## Founding a cluster, step by step

What the cluster needs per node: a store directory, its **node id**, a **peer certificate** issued
for `<node id>.peer.tessari` by one cluster authority, and five start options.

**1. Read each node's id.** A store makes it on first open:

```sh
tessaridb /var/lib/tessaridb/store -e 'INFO FOR NODE;'      # → id: '4e2be334e51bf6556f7db2233dd934d4'
```

**2. Issue the certificates.** One authority for the cluster, one certificate per node whose
subject alternative name is `DNS:<node id>.peer.tessari`, usable for both TLS directions:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=tessaridb cluster authority" -keyout ca.key -out ca.pem
ID=4e2be334e51bf6556f7db2233dd934d4
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$ID.peer.tessari" \
  -keyout peer.key -out peer.csr
printf 'subjectAltName=DNS:%s.peer.tessari\nextendedKeyUsage=serverAuth,clientAuth\n' "$ID" > ext
openssl x509 -req -in peer.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 -extfile ext -out peer.pem
chmod 600 peer.key
```

Keep `ca.key` off the nodes. Each node gets `ca.pem`, its own `peer.pem` and `peer.key`.

**3. Declare the membership on every founding node, before it serves.** The same rows, the same
names, the same order, the node itself included, in one transaction, and the node's own roles last:

<!-- not run: the node ids are this cluster's; the same file ran on three stores of a local cluster -->
```tessariql
BEGIN;
DEFINE USER owner ROLE owner PASSWORD 'a long owner password';
DEFINE REPLICA n1 AT 'db-1.internal:9000' CLIENTS AT 'db-1.example:9080' NODE '4e2be334e51bf6556f7db2233dd934d4'
    ROLES serving, writable, coordinating REPLICATES STORE;
DEFINE REPLICA n2 AT 'db-2.internal:9000' CLIENTS AT 'db-2.example:9080' NODE '0d3287057a9365c01de318eb47f7e54b'
    ROLES serving, writable, coordinating REPLICATES STORE;
DEFINE REPLICA n3 AT 'db-3.internal:9000' CLIENTS AT 'db-3.example:9080' NODE '26b91df0ddfaed5a4ce1e51ac388fbd0'
    ROLES serving, writable, coordinating REPLICATES STORE;
DEFINE NODE ROLES serving, writable, coordinating;
COMMIT;
```

```sh
tessaridb /var/lib/tessaridb/store -f members.tessariql
```

- **One transaction**, because the first committed `DEFINE REPLICA` makes the node clustered, and a
  clustered node with no leader refuses every catalog write, the next `DEFINE REPLICA` included.
- **The same rows everywhere, self included**: identical rows replicate idempotently; different
  rows on different nodes collide.
- `AT` is where **peers** dial (a host name or an address; a name is resolved on every dial).
  `CLIENTS AT` and `HTTP AT` are where clients are redirected; without them redirects name `AT`.
  `KAFKA AT` is where Kafka clients are told to reach the node, on a node serving `--kafka`.
  The clauses are read in order: `AT`, `CLIENTS AT`, `HTTP AT`, `KAFKA AT`, `NODE`, `ROLES`,
  `REPLICATES`, `LEADS`, `FINGERPRINT`, `REGION` (a clause out of place is `UnexpectedToken`).
- `writable` on every coordinating row, because the node that wins an election must be able to
  write; a row's roles are also what the node adopts at its next start.
- Declaring the owner here closes each store; the user replicates with the store line.

**4. Start every node with all five cluster options** (all or none; a key file others can read
stops the node):

```sh
tessaridb /var/lib/tessaridb/store --serve 0.0.0.0:9080 --http 0.0.0.0:8000 \
  --tls-cert client.pem --tls-key client.key \
  --cluster-credential peer.pem --cluster-key peer.key --cluster-authority ca.pem \
  --cluster-address 0.0.0.0:9000 \
  --seed 0d3287057a9365c01de318eb47f7e54b@db-2.internal:9000
```

A seed names a node **and** an address, because the peer handshake checks the certificate against
the node id. Each founding node seeds from another one; the seed is read only while the catalog
names no other peer, so a node finds its way back after a restart without it. `--tls-cert` /
`--tls-key` are the separate, optional **client** TLS (see the tessaridb skill); peers always speak
mutual TLS.

With the published image, pass the whole command line; any first argument other than `serve` is
handed to `tessaridb` as is:

```sh
docker run -d --name db-1 -p 9080:9080 -p 9000:9000 -v db1:/var/lib/tessaridb \
  -v /etc/tessaridb/cluster:/run/cluster:ro tessaridb/tessaridb:0.39.2 \
  /var/lib/tessaridb/store --serve 0.0.0.0:9080 --http 0.0.0.0:8000 \
  --cluster-credential /run/cluster/peer.pem --cluster-key /run/cluster/peer.key \
  --cluster-authority /run/cluster/ca.pem --cluster-address 0.0.0.0:9000 \
  --seed 0d3287057a9365c01de318eb47f7e54b@db-2.internal:9000
```

(The node runs as uid 10001: the key file must be readable by it and by nobody else.)

**5. Check it.** Within about a second one node leads:

<!-- not run: needs the running cluster -->
```tessariql
INFO FOR NODE;
```

Look for `cluster.leaders: [{ epoch: 7, node: …, range: 'STORE' }]` on every node, a `lease`
counting on the leader, and on the leader a `followers` row per other node with `behind: 0`.

**6. Create data with an explicit replication**, on the leader:

```tessariql
DEFINE NAMESPACE IF NOT EXISTS prod REPLICATION FACTOR 3;
USE NAMESPACE prod;
DEFINE DATABASE IF NOT EXISTS shop;
```

**7. Rehearse a failover** before relying on it: stop the leader and confirm a survivor takes
writes about a second later under a higher epoch, then start the old leader with the same flags and
confirm it rejoins as a follower and catches up.

## Adding a node to a running cluster

The newcomer **declares no membership**: the membership reaches it by replication. Two statements,
one on each side, and a token, node id or certificate fingerprint to approve it.

On the cluster's leader:

<!-- not run: needs the running cluster -->
```tessariql
DEFINE REPLICA n4 AT 'db-4.internal:9000' CLIENTS AT 'db-4.example:9080'
    ROLES serving REPLICATES STORE;
CREATE JOIN TOKEN FOR REPLICA n4 EXPIRES 10m;
```

`CREATE JOIN TOKEN` answers 64 hex digits **once**; the row keeps only a digest. Alternatives on the
row itself: `NODE '<id>'` before `ROLES` (read from the newcomer's `INFO FOR NODE`), or
`FINGERPRINT '<sha256 of its peer certificate>'` after `REPLICATES`. A row with none of the three
grants nothing.

On the newcomer (a fresh store, with its own peer certificate):

```sh
tessaridb /var/lib/tessaridb/store -e 'DEFINE NODE ROLES serving;'
tessaridb /var/lib/tessaridb/store --serve 0.0.0.0:9080 \
  --cluster-credential peer.pem --cluster-key peer.key --cluster-authority ca.pem \
  --cluster-address 0.0.0.0:9000 \
  --seed <leader id>@db-1.internal:9000 --join-token <token>
```

It bootstraps by replaying the leader's log; nothing is stopped and no snapshot is taken by hand.
Give it `serving, writable, coordinating` (with `ALTER REPLICA n4 ROLES …`) when it should vote and
be able to lead; a row's roles are adopted at the node's next start.

- **A newcomer that already holds namespaces is refused** before it dials (`WouldReinterpret`):
  joining would reinterpret its records under the cluster's definitions. Wipe it, or drop its
  namespaces first (`DEFINE NODE ROLES writable; DROP NAMESPACE x; DEFINE NODE ROLES serving;`).
- `REPLICATES NAMESPACE prod` (or `DATABASE prod.shop`, or `SHARD prod.shop.orders 2`) makes a
  selective follower. A subscription carries the users, credential hashes and grants inside its
  reach, so `REPLICATES STORE` hands over every tenancy and is written deliberately.

## Changing and removing members

- `ALTER REPLICA n2 ROLES serving` / `CLIENTS AT '…'` / `REGION 'eu'` / `LEADS …` amends one
  clause, keeping the node it is bound to and its subscription. `DEFINE REPLICA` of an existing name
  is refused (`NameTaken`); use `IF NOT EXISTS` in re-runnable scripts.
- `DROP REPLICA n4` removes the member **for good**: its node id is tombstoned, its greeting is
  refused at the handshake, and a row naming it is refused (`NodeTombstoned`). A machine coming back
  is wiped and joins under a new id. Don't drop and re-declare to edit a row.
- Draining a machine for maintenance without removing it: `DEFINE NODE ROLES NONE` on it (a local
  override); to keep it drained across restarts, change its row.

## Certificates over time

- A node re-reads its peer and client certificate files every two seconds, so renewing is replacing
  the files. The **authority** is not reloaded: trusting a new root is a planned restart with both
  roots in place.
- `INFO FOR NODE` → `certificates` lists what the node presents, with `fingerprint` and `expires`;
  `/metrics` has `tessari_tls_certificate_expires_seconds{surface}`.
- `REVOKE CERTIFICATE '<sha256>'` (on the leader, as a store operator) refuses a leaked certificate
  on every node in both directions, open links included, and is never taken back.
- A request a node carries to the leader for a client travels under an assertion signed with the
  node's peer key; no password crosses the peer link, and sign-in attempts are budgeted
  cluster-wide.
