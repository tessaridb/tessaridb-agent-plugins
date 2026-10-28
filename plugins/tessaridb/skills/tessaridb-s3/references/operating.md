# Operating TessariDB S3: metrics, access log, console, upgrades, backups, refusals

Checked against TessariDB S3 0.8.0. Upstream: <https://docs.tessaridb.com/s3/operating/metrics>,
`/s3/operating/console`, `/s3/data-and-access/security`.

## Health

The image's health check is `tessaridb-s3 health`. The compose file waits on it
(`docker compose up -d --wait`).

## Metrics

`TESSARIDB_S3_METRICS_LISTEN` serves `GET /metrics` (Prometheus text):

- requests by operation, status and error code; duration by size class;
- requests shed under load (`SlowDown`);
- authentication refusals by reason; policy denials;
- heal and replication backlogs; cluster members and those answering a probe (read at the scrape;
  `s3_collect_up` says whether that read worked);
- access-log records written, dropped and failed;
- the node's state (from 0.4.0): build and start time, how long the metadata store takes to answer,
  the keys vault's state, the data drive's size and free space, the latest buckets, objects and
  bytes, open uploads, daemon runs by outcome, and reads of data that failed verification.

## Listener limits

Every listener holds at most 4096 connections, closes one whose headers take over 30 s, and fails a
body that pauses over 60 s.

## The access log

With `TESSARIDB_S3_AUDIT=on` (default) every S3 request is recorded in the region's `s3_access_log`
topic in TessariDB, kept 30 days, under its request id: operation, bucket, key, signing access key,
status, error code, bytes, duration, client address. Never a secret or a signature. A full queue drops
the record and counts it; the request is never held up. Read it with a TessariDB topic consumer.

## The console

`TESSARIDB_S3_CONSOLE_LISTEN` serves the operator console on its own address. It loads nothing from
the network and works through `/api/v1` (see access-and-keys.md). It shows:

- **Overview**: this node's drive; on a cluster its members, zones and the heal backlog; the
  encryption keys (unseal, seal, rotate, destroy).
- **Buckets**: objects and bytes as of the last usage pass, logical and on disk; create, delete,
  quotas, default encryption, media rules, upload keys.
- **Objects**: a page at a time; headers, metadata, tags, checksums, retention and legal hold;
  downloads always as attachments; deletes under the ETag the operator saw (a changed object → `412`,
  kept).
- **Users and keys**, **Groups**, **Cluster**, failed **Renditions**, and the **action record**.

## Upgrading

- Pin the image tag. Read the release notes for the metadata TessariDB version the release expects.
- The S3 server itself keeps no state outside the metadata store and `TESSARIDB_S3_DATA_DIR`; replace
  the container with the same environment and volumes.
- The metadata store moving to TessariDB 0.36 is a snapshot-and-restore, not an in-place upgrade (see
  running-and-configuration.md).
- From 0.8.0 the shared settings live in the metadata store; going back to 0.7.0 reads them from the
  environment again, so put back any that was removed from it first.

## What to back up

Two halves, taken so they agree:

1. **The metadata store** — a TessariDB snapshot of the node (see the `tessaridb` skill, operations):
   buckets, versions, policies, users, sealed keys, the action record.
2. **The object bytes** — `TESSARIDB_S3_DATA_DIR` on every node.

Also keep, outside both: `TESSARIDB_S3_IAM_KEY` (without it no user key can be opened), the keys
vault passphrase, the root credential and, on a cluster, `TESSARIDB_S3_CLUSTER_SECRET` and the
internal certificate authority.

## Reading a refusal

| answer | meaning | do |
|---|---|---|
| `NotImplemented` | the operation does not exist here yet | change the tool's setting; never retry |
| `AccessDenied` | the key lacks a grant, a policy denies, or public access is blocked | check grants and the policy |
| `SignatureDoesNotMatch` | wrong secret, wrong region, or a proxy changed the request | sign for `TESSARIDB_S3_REGION`; keep headers intact |
| `301 PermanentRedirect` | the bucket belongs to another region | send it to that region's endpoint |
| `503 SlowDown` | too many requests in flight, or the metadata store declined a sign-in | back off and retry |
| `503` after a metadata timeout | a metadata statement passed `_META_STATEMENT_TIMEOUT_SECS`; a write may have committed | read before rewriting |
| `503 ServiceUnavailable` on a sealed object | the keys vault is sealed | unseal it |
| `503 ServiceUnavailable` on writes while reads work | the data drive is below `TESSARIDB_S3_DATA_MIN_FREE_BYTES` | free space or add capacity |
| `AccessControlListNotSupported` | an ACL other than `private` / `bucket-owner-full-control` | drop the ACL; use a policy |
| `MalformedPolicy` | a policy statement the server cannot evaluate as written | simplify the statement |
| `InvalidArgument` on notifications | undeclared destination, unsupported event, overlapping rules | declare the target in `TESSARIDB_S3_NOTIFY_TARGETS` |
| `NoSuchVersion`, `405`, `404` + `x-amz-delete-marker` | versioning answers | see s3-surface.md |
| console `401 reauthentication_required` | the change needs a sign-in from the last five minutes | sign in again |

Security reports: security@tessaridb.com.
