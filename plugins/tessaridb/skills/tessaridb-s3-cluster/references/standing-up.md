# Standing up a TessariDB S3 cluster

Checked against TessariDB S3 0.8.0 and TessariDB 0.38.3 (the steps below are what
`scripts/local-s3-cluster.sh` runs; it was executed and an object round-tripped across nodes).
Upstream: <https://docs.tessaridb.com/s3/operating/clusters>, `/s3/start/configuration`.

## 1. Decide the shape

| decide | how |
|---|---|
| the code `k+m` | k, m ≥ 1, k + m ≤ 16; an erasure set has k + m nodes |
| what to survive | a write needs k durable shards (k + 1 when k = m, so two halves of a split cannot both accept); a read needs any k that verify |
| zones | `TESSARIDB_S3_ZONE` per node; no more than m shards of an object in one zone |
| node ids | 1–63 lowercase letters, digits, inner hyphens; never reused after a removal |
| the metadata store | one TessariDB node, or a TessariDB cluster (see `tessaridb-cluster`) |

Examples from the documentation:

| code | zones | survives |
|---|---|---|
| 2 + 1 | 3 nodes, no zones | any one node |
| 4 + 2 | 3 zones × 2 nodes | any one zone, or any two nodes |
| 8 + 4 | 4 zones × 3 nodes | any one zone and one more node |
| 6 + 3 | 3 zones × 3 nodes | any one zone |

## 2. Certificates for the internal surface

One authority; one certificate per node issued for `<node id>.peer.tessari-s3`, usable for server and
client authentication. The name is never looked up; it is what the other nodes ask the certificate
for.

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=tessaridb-s3 cluster authority" -keyout ca.key -out ca.pem
for n in s1 s2 s3; do
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$n.peer.tessari-s3" \
    -keyout $n.key -out $n.csr
  printf 'subjectAltName=DNS:%s.peer.tessari-s3\nextendedKeyUsage=serverAuth,clientAuth\n' $n > $n.ext
  openssl x509 -req -in $n.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 -extfile $n.ext -out $n.pem
done
```

Keep `ca.key` off the nodes. Each node gets only `ca.pem`, its own `.pem` and its own `.key` (the
published image runs as a non-root user, so the key must be readable by it).

## 3. The metadata store and the server's account

As in a single node: the namespace `s3`, the database `meta`, and the account `s3` as an editor of
that namespace, declared once by the owner:

```tessariql
DEFINE NAMESPACE IF NOT EXISTS s3 REPLICATION NONE ACKNOWLEDGE MAJORITY OR WEAKER;
USE NAMESPACE s3;
DEFINE DATABASE IF NOT EXISTS meta;
USE NAMESPACE s3 DATABASE meta;
DEFINE USER IF NOT EXISTS s3 ON NAMESPACE s3 ROLE editor PASSWORD 'metadata-account-password';
```

On a TessariDB **cluster**, state the replication on the namespace (`REPLICATION FACTOR 3`, say),
list every node in `TESSARIDB_S3_META_ADDRESS` (comma-separated; a node silent for 5 s is passed
over) and set `TESSARIDB_S3_META_REPLICATION` to the same number. Give `TESSARIDB_S3_META_CA` to verify
the nodes' TLS.

## 4. Start the founding members

Every node, the same except for its own id, addresses and certificate:

| variable | value |
|---|---|
| `TESSARIDB_S3_ERASURE` | `2+1` (the same everywhere) |
| `TESSARIDB_S3_NODE_ID` | `s1` |
| `TESSARIDB_S3_ZONE` | optional, the node's failure domain |
| `TESSARIDB_S3_CLUSTER_SECRET` | ≥ 32 bytes, the same everywhere (`openssl rand -hex 32`) |
| `TESSARIDB_S3_FOUNDING_MEMBERS` | `s1,s2,s3` (only for a cluster that does not exist yet) |
| `TESSARIDB_S3_INTERNAL_LISTEN` | `0.0.0.0:9200` |
| `TESSARIDB_S3_INTERNAL_ADVERTISE` | `s1:9200`, the address the others dial |
| `TESSARIDB_S3_INTERNAL_TLS_CERT` / `_KEY` / `_CA` | `s1.pem`, `s1.key`, `ca.pem` |
| `TESSARIDB_S3_DATA_DIR` | this node's own drive (the image defaults to `/var/lib/tessaridb-s3/data`) |
| root key, `TESSARIDB_S3_META_*`, `TESSARIDB_S3_IAM_KEY`, `TESSARIDB_S3_KEYS_PASSPHRASE` | the same everywhere |

```bash
docker run -d --name s3c-s1 --network s3c --network-alias s1 -p 127.0.0.1:9100:9100 \
  -v s3c-s1:/var/lib/tessaridb-s3 -v "$PWD/certs:/certs:ro" \
  -e TESSARIDB_S3_ROOT_ACCESS_KEY=… -e TESSARIDB_S3_ROOT_SECRET_KEY=… \
  -e TESSARIDB_S3_META_ADDRESS=s3c-db:9080 -e TESSARIDB_S3_META_USER=s3 -e TESSARIDB_S3_META_PASSWORD=… \
  -e TESSARIDB_S3_IAM_KEY=… -e TESSARIDB_S3_ERASURE=2+1 -e TESSARIDB_S3_NODE_ID=s1 \
  -e TESSARIDB_S3_INTERNAL_LISTEN=0.0.0.0:9200 -e TESSARIDB_S3_INTERNAL_ADVERTISE=s1:9200 \
  -e TESSARIDB_S3_CLUSTER_SECRET=… -e TESSARIDB_S3_FOUNDING_MEMBERS=s1,s2,s3 \
  -e TESSARIDB_S3_INTERNAL_TLS_CERT=/certs/s1.pem -e TESSARIDB_S3_INTERNAL_TLS_KEY=/certs/s1.key \
  -e TESSARIDB_S3_INTERNAL_TLS_CA=/certs/ca.pem \
  tessaridb/s3:0.8.0
```

Add `TESSARIDB_S3_CONSOLE_LISTEN` on at least one node for the cluster view, and
`TESSARIDB_S3_METRICS_LISTEN` on every node.

## 5. Check it

- Write through one node and read through another; compare the bytes.
- The log shows the daemons running (`heal`, `notify`, `replicator`, `media-planner`) and
  `metadata schema ready`.
- `/metrics` lists the cluster's members and those answering a probe; the console's cluster view
  shows the sets, zones, admission and the heal backlog.

## Start-up refusals (verbatim)

| message | cause |
|---|---|
| `node s4 is not an admitted member presenting this certificate: approve it in the console, name it in TESSARIDB_S3_FOUNDING_MEMBERS on a new cluster, or start it with a join token issued for it` | a node nobody admitted |
| `TESSARIDB_S3_INTERNAL_TLS_CERT is invalid: issued for another node than TESSARIDB_S3_NODE_ID` | the wrong certificate file for this id |
| a data directory written under another layout (from 0.6.0, per the release notes) | the node's `TESSARIDB_S3_DATA_DIR` belongs to another cluster or node |
| a missing required setting, by name | `TESSARIDB_S3_ERASURE` needs the node id, internal listen/advertise, the cluster secret, the internal TLS trio and the data directory |
