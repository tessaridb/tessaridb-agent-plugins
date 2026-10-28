---
name: tessaridb-s3
description: Run and use TessariDB S3, an S3-compatible object store whose metadata lives in TessariDB and whose object bytes live on your drives. Use when starting the server (compose or container), setting its environment variables, creating buckets and objects with the AWS CLI, an AWS SDK or the tessaridb-s3 Rust client and command line, issuing users and access keys, writing bucket policies, CORS, quotas, versioning, Object Lock, encryption, notifications, lifecycle rules or media renditions, reading its metrics and access log, or explaining why a request was refused. For several S3 nodes with erasure coding use the tessaridb-s3-cluster skill.
---

# TessariDB S3

TessariDB S3 answers the S3 API, so unmodified S3 tools (the AWS CLI, the AWS SDKs, backup tools)
work against it. It keeps state in two places on purpose:

- **Facts in TessariDB**: buckets, object versions, multipart uploads, policies, users, keys and the
  console's action record are records in a TessariDB database (`s3.meta` by default).
- **Bytes on the drives**: object data is written in 1 MiB blocks under `TESSARIDB_S3_DATA_DIR`,
  each block with a BLAKE3 hash checked on every read. Bytes never enter the database.

Checked against **TessariDB S3 0.8.0** (image `tessaridb/s3:0.8.0`, metadata on
`tessaridb/tessaridb:0.38.3`, the repository's compose file) and the client/CLI **0.2.1**. Where a
feature is missing the server says `NotImplemented` rather than doing something close.
The console's sign-in through TessariDB OAuth with a private key (`TESSARIDB_S3_CONSOLE_OIDC_CLIENT_KEY`) was
checked against **TessariDB S3 0.7.0**, TessariDB OAuth 0.1.0 and TessariDB 0.38.2.

## Pick the reference for the task

| Task | Read |
|---|---|
| Start it, every environment variable, the first bucket | [references/running-and-configuration.md](references/running-and-configuration.md) |
| Which S3 operations exist, versioning, Object Lock, multipart | [references/s3-surface.md](references/s3-surface.md) |
| Users, access keys, grants, groups, policies, CORS, temporary and one-key credentials, the console API | [references/access-and-keys.md](references/access-and-keys.md) |
| Server-side encryption and the keys vault | [references/encryption.md](references/encryption.md) |
| Notifications, lifecycle rules, image and video renditions | [references/events-lifecycle-media.md](references/events-lifecycle-media.md) |
| AWS CLI and SDK settings, the Rust client, `tessaridb-s3-cli` | [references/clients.md](references/clients.md) |
| Metrics, the access log, the console, upgrades, what to back up, refusals | [references/operating.md](references/operating.md) |

## Try it first

The quickest real server is the repository's compose file (S3 beside its TessariDB node):

```bash
git clone https://github.com/tessaridb/tessaridb-s3 && cd tessaridb-s3
cp .env.example .env          # set every value; none has a default worth keeping
docker compose up -d --wait   # S3 on 127.0.0.1:9100, console on 127.0.0.1:9101

export AWS_ACCESS_KEY_ID=<S3_ROOT_ACCESS_KEY> AWS_SECRET_ACCESS_KEY=<S3_ROOT_SECRET_KEY>
export AWS_DEFAULT_REGION=us-east-1 AWS_ENDPOINT_URL=http://127.0.0.1:9100
aws s3 mb s3://first
aws s3 cp ./photo.jpg s3://first/2026/
aws s3 ls s3://first --recursive
```

Prove a claim by sending the request and reading the answer: the server's refusal (`NotImplemented`,
`AccessDenied`, `SignatureDoesNotMatch`, `SlowDown`) is the evidence, not a reading of these pages.

## Rules that prevent quiet mistakes

1. **Sign for the server's region.** Requests are signed for `TESSARIDB_S3_REGION` (`us-east-1` by
   default). Anonymous requests reach only what a bucket policy grants everyone.
2. **Path-style always works.** `<bucket>.<domain>` works only for domains in `TESSARIDB_S3_DOMAINS`.
3. **The server's database account is never the owner.** It signs in as its own user, an editor of
   its one namespace (`DEFINE USER IF NOT EXISTS s3 ON NAMESPACE s3 ROLE editor PASSWORD '…'`). The
   owner is used once, to declare the namespace, the database and that account.
4. **Without `TESSARIDB_S3_IAM_KEY` only the root key signs in.** No user key can be issued, and a
   node that loses that key can open no user's key. Keep it like the root secret.
5. **Put TLS in front of both listeners** (or give each its certificate) before exposing them; a
   console sign-in otherwise sends a secret in the clear.
6. **Unknown operations are refused, never approximated.** Website configuration, lifecycle
   transitions and a few others answer `NotImplemented`; plan around that instead of retrying.
7. **A bucket that set nothing blocks public access.** A public policy is refused until
   `DeletePublicAccessBlock` turns the block off. ACLs grant nothing: a read answers the owner's
   `FULL_CONTROL`, and a write is taken only as `private` or `bucket-owner-full-control`.
8. **Versioning is one-way.** Never versioned → Enabled ↔ Suspended, never back. In an enabled bucket
   a delete adds a marker; removing the marker by id brings the object back.
9. **Object Lock is enforced everywhere.** A kept version cannot be deleted or rewritten by any path,
   lifecycle included. COMPLIANCE is never shortened.
10. **`503 SlowDown` is back-pressure** (`TESSARIDB_S3_MAX_INFLIGHT`, or the metadata store declining
    a sign-in). Retry with backoff; it is not an outage.
11. **A request that needs an encryption key answers `503` while the keys vault is sealed.** Unseal it
    with `TESSARIDB_S3_KEYS_PASSPHRASE` or in the console.
12. **Backing up the metadata store is half a backup.** The database holds the facts; the bytes are
    on the drives under `TESSARIDB_S3_DATA_DIR`. A restore needs both from the same moment.
13. **Name nothing outside the server's own terms.** A bucket notification names a destination by
    `arn:tessaridb:sqs:::<id>`, where `<id>` is declared by the operator; an address is refused.

## Related skills

- `tessaridb` — the database that holds the metadata (users, snapshots, upgrades of that node).
- `tessaridb-s3-cluster` — several S3 nodes: erasure sets, zones, healing, membership, regions.
