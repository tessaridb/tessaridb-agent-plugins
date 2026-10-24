# Running a node: serving, backups, the log, upgrades

Checked against TessariDB 0.38.3. Full detail: <https://docs.tessaridb.com/operations/serving>,
`/operations/backup-and-restore`, `/operations/bounding-the-log`, `/start/in-a-container`. For
several nodes, use the tessaridb-cluster skill.

## Serving

The container (`tessaridb/tessaridb:<version>`, amd64 and arm64) serves the wire protocol on 9080
and HTTP plus the web console on 8000, and keeps the store in the volume at `/var/lib/tessaridb`.
**Pin a released tag** rather than `latest`.

```sh
docker run -d --name tessaridb --restart unless-stopped --stop-timeout 30 \
  -p 9080:9080 -p 8000:8000 \
  -v tessaridb-data:/var/lib/tessaridb \
  -e TESSARIDB_INITIAL_USER=owner -e TESSARIDB_INITIAL_PASSWORD='choose-a-real-one' \
  tessaridb/tessaridb:0.38.3
```

| Variable | Default | Does |
|---|---|---|
| `TESSARIDB_INITIAL_USER`, `TESSARIDB_INITIAL_PASSWORD` | unset | the first owner, declared once on a store with no users; both or neither |
| `TESSARIDB_STORE` | `/var/lib/tessaridb/store` | where the store lives; empty is in memory |
| `TESSARIDB_ADDRESS`, `TESSARIDB_HTTP_ADDRESS` | `0.0.0.0:9080`, `0.0.0.0:8000` | the two surfaces; empty turns one off (not both) |
| `TESSARIDB_TLS_CERT`, `TESSARIDB_TLS_KEY`, `TESSARIDB_REQUIRE_CLIENT_TLS` | unset | TLS 1.3 for clients ([security.md](security.md)) |
| `TESSARIDB_ENCRYPTION_KEY_FILE` | unset | encryption at rest |
| `TESSARIDB_BACKUP_DIR` | `/var/lib/tessaridb/backups` | where `BACKUP … TO 'name'` writes |
| `TESSARIDB_RETAIN_RECORDS` | 100 000 | log records kept per log; `none` keeps all |
| `TESSARIDB_UNSEAL_FOR` | `10m` | how long a vault unseal lasts |
| `TESSARIDB_LOG`, `TESSARIDB_LOG_FORMAT` | `info`, text | log level and `json` output, to standard error |

The image also runs one-off commands: `docker run --rm tessaridb/tessaridb:0.38.3 -e '<script>'`,
`--version`, or `--at host:port --user u` as a client.

The binary does the same without a container:

```sh
tessaridb ./data --serve 0.0.0.0:9080 --http 0.0.0.0:8000 --backup-dir ./backups --unseal-for 1h
```

- There is no configuration file: what you see on the command line is what runs. The machine's own
  roles are statements (`DEFINE NODE ROLES serving, writable`); taking `writable` away drains
  writes while reads continue.
- Probes need no credential: `GET /health` (alive, store open), `GET /ready` (send traffic here;
  `503` while draining), `GET /metrics` (Prometheus; more detail when signed in).
  `tessaridb ./data --health` exits non-zero when a store isn't well.
- `SIGTERM` (what `docker stop` sends) stops in stages: not ready → no new connections → finish
  in-flight work → close. Give the supervisor a grace period longer than the drain.
- Each surface holds up to 16 384 connections and runs up to 400 statements at once; past that a
  statement is refused as busy (HTTP `503` with `Retry-After: 1`). Raise the open-file limit if
  you expect that many connections.
- Logs go to standard error only. In Docker set a log size cap; `json-file` doesn't rotate.
- A store that couldn't make a write durable stops taking writes (`Stopped`) until it is reopened;
  reads still answer.

## Backups

```tessariql
BACKUP;
BACKUP STATE;
BACKUP SCRIPT;
```

| form | file | right for |
|---|---|---|
| snapshot (`BACKUP`, `BACKUP STATE`, `GET /backup`) | `.tessarisnap` | the routine backup: every live record at one moment |
| log (`BACKUP LOG`, `BACKUP FROM n`) | `.tessarilog` | point-in-time recovery on a store that keeps its whole log |
| script (`BACKUP SCRIPT`, `BACKUP SCRIPT OF NAMESPACE crm, prod.orders`) | `.tessariql` | reading, editing, moving a part of a store |

From a shell:

```sh
tessaridb ./data --backup monday.tessarisnap               # a store this process opens
TESSARIDB_PASSWORD='…' tessaridb --at db:9080 --user owner --backup monday.tessarisnap   # a running node, streamed
tessaridb --verify monday.tessarisnap                      # no store needed; non-zero if cut short
tessaridb ./restored --restore monday.tessarisnap          # into an empty store
```

- `BACKUP … TO 'name'` writes into the node's `--backup-dir` and never overwrites. `RESTORE SCRIPT
  FROM 'file'` runs a script from that folder beside what the store holds; it only creates.
- **Verify a backup where it is written, before you keep it**, and rehearse a timed restore: a
  passing `--verify` is not a restore.
- A backup carries the data, the catalog, users and topology, never this machine's roles,
  endpoints or log bound. A restored node is configured on itself.
- `BACKUP` needs a store-wide owner. A pruned log can't be backed up as a log; take a snapshot.
- A store with encryption at rest seals its backups; they open only with the key.

## The log is bounded by default

The log is the store's history and what replicas, feeds and `VERSION` reads replay. **A serving
node keeps the newest 100 000 records of each log** and prunes the rest; a prune is irreversible.

```tessariql
INFO FOR NODE;
DEFINE NODE RETAIN 500000 RECORDS;
DEFINE NODE RETAIN NONE;
```

The setting is local to the machine (it doesn't replicate or travel in a backup). Below the pruned
point, change feeds, `VERSION` reads and log backups are refused rather than answered short, and a
follower that falls behind copies its leader's state instead.

## Upgrading

- **0.36.0 moved TessariDB onto its own storage engine, TessariKV.** A store written by 0.35.3 or
  earlier is refused by name and left untouched. Move it with a snapshot taken by the build that
  wrote it:

```sh
tessaridb ./data --backup ./before-0.36.tessarisnap         # on the old build
tessaridb --verify ./before-0.36.tessarisnap
tessaridb ./data-0.36 --restore ./before-0.36.tessarisnap   # on 0.36.x
```

  Keep the old store until the new one has answered what you need. History (`VERSION` reads,
  feed positions) does not carry over. Every node of a cluster is moved the same way.
- Within a format, a newer build opens an older store and keeps its format, so the older build can
  still open it, until `ALTER STORE FINALIZE FORMAT` raises it for good (needed by a few features
  such as table expiry on an old store). `INFO FOR STORE` shows `format` and `writes`. Finalize only
  when no older build will open the store again.
- Going back to an older build is not promised. **Take a snapshot before every upgrade**, and one
  first on a store that never set a log bound (it starts pruning at its first pass).
- Release notes: <https://github.com/tessaridb/tessaridb/blob/main/CHANGELOG.md>.

## The web console

`http://<node>:8000/` serves a console: a sign-in page, then Query, Data, Users, Node, Cluster,
Topics, Backup and Vault screens. It is a client like any other: it runs the same statements with
the signed-in user's authority and has no private door. Before exposing it, give the node TLS or put
it behind a TLS proxy (a browser won't trust a private authority; see [security.md](security.md)).
