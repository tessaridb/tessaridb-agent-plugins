# Running TessariDB S3 and configuring it

Checked against TessariDB S3 0.8.0 (the repository's `compose.yaml` started with
`docker compose up -d --wait`, then bucket, upload, listing, versioning and refusals sent with the AWS
CLI). Upstream: <https://docs.tessaridb.com/s3/start/running>, `/s3/start/configuration`.

## The container

- Image `tessaridb/s3` (linux/amd64 and linux/arm64): only the `tessaridb-s3` server, distroless,
  non-root, with `tessaridb-s3 health` as its health check.
- The server's repository carries `compose.yaml`, which runs it beside the TessariDB node that holds
  its metadata, and `.env.example` listing every value to set.

## The compose file, step by step

```bash
git clone https://github.com/tessaridb/tessaridb-s3
cd tessaridb-s3
cp .env.example .env
docker compose up -d --wait
```

`.env` needs:

| value | what it is |
|---|---|
| `TESSARIDB_USER` / `TESSARIDB_PASSWORD` | the database owner, declared on its first start |
| `S3_META_PASSWORD` | the server's own database account `s3` (≥ 16 characters, no quote or backslash) |
| `S3_ROOT_ACCESS_KEY` / `S3_ROOT_SECRET_KEY` | the S3 root credential (no `/` in the key; secret ≥ 16 bytes) |
| `S3_IAM_KEY` | 64 hex digits (`openssl rand -hex 32`); without it no user key can be issued |
| `S3_KEYS_PASSPHRASE` | ≥ 15 characters; opens the encryption keys vault at start (empty: sealed until unsealed in the console) |
| `S3_REGION`, `S3_PORT`, `S3_CONSOLE_PORT` | optional (`us-east-1`, `9100`, `9101`) |

What happens:

1. The database (`tessaridb/tessaridb:0.38.3`) declares its owner from `.env` and is reachable only
   from the S3 server over the compose network.
2. A one-shot `s3-account` step signs in as the owner once and declares the namespace `s3`, the
   database `meta` and the server's account `s3`, an editor of `s3.meta` only.
3. The server starts, signs in as `s3`, and publishes S3 on `127.0.0.1:9100` and the console on
   `127.0.0.1:9101`, with data in named volumes.

A metadata store written by TessariDB **0.35.3 or earlier** is refused and left untouched (0.36 moved
to its own storage engine). Stop the server and the database, snapshot the store with the old image
(`tessaridb <store> --backup <file>`), restore it with 0.36 into an empty directory
(`tessaridb <new store> --restore <file>`) and point the database there. Object bytes are not touched.

## The first bucket

```bash
export AWS_ACCESS_KEY_ID=<S3_ROOT_ACCESS_KEY>
export AWS_SECRET_ACCESS_KEY=<S3_ROOT_SECRET_KEY>
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://127.0.0.1:9100     # or --endpoint-url on every command

aws s3 mb s3://first
aws s3 cp ./photo.jpg s3://first/2026/
aws s3 ls s3://first --recursive
aws s3api put-bucket-versioning --bucket first --versioning-configuration Status=Enabled
```

What a wrong request answers (measured): a bad secret → `SignatureDoesNotMatch`; an unsigned
`GET /first/` → `403`; `put-bucket-acl --acl public-read` → `AccessControlListNotSupported`;
`get-bucket-website` → `NotImplemented`.

## Stopping

SIGINT or SIGTERM stops the server after `TESSARIDB_S3_SHUTDOWN_GRACE_SECS` (30 s); requests in
flight get that long. Give the container a longer stop period than that (the compose file uses 40 s).

## Every setting

The server reads the environment and, from 0.8.0, the settings stored in its metadata store (below). A
missing required setting stops it at start, naming the setting. There is no configuration file and no
default credential.

### Core

| Variable | Default | Meaning |
|---|---|---|
| `TESSARIDB_S3_ROOT_ACCESS_KEY` | required | the root credential's access key |
| `TESSARIDB_S3_ROOT_SECRET_KEY` | required, ≥ 16 bytes | the root credential's secret |
| `TESSARIDB_S3_LISTEN` | `127.0.0.1:9100` | the S3 API address (in a container set `0.0.0.0:9100`) |
| `TESSARIDB_S3_TLS_CERT` / `TESSARIDB_S3_TLS_KEY` | unset (plain) | the S3 API over TLS 1.2/1.3; both or neither |
| `TESSARIDB_S3_REGION` | `us-east-1` | the region requests are signed for; another region's bucket answers `301 PermanentRedirect` |
| `TESSARIDB_S3_DOMAINS` | empty | comma-separated domains for `<bucket>.<domain>` addressing |
| `TESSARIDB_S3_MAX_INFLIGHT` | `1024` | requests served at once before `503 SlowDown` |
| `TESSARIDB_S3_SHUTDOWN_GRACE_SECS` | `30` | in-flight grace after SIGTERM |
| `TESSARIDB_S3_DATA_DIR` | required | where object bytes go (`<dir>/s3data/…`) |
| `TESSARIDB_S3_DATA_MIN_FREE_BYTES` | `1073741824` (1 GiB) | below this much free space on the data drive, writes answer `503 ServiceUnavailable` and reads are still served |
| `TESSARIDB_S3_ADVERTISE` | unset | the URL this node's S3 surface is reached at, recorded as where replicas are sent |

### The metadata store

| Variable | Default | Meaning |
|---|---|---|
| `TESSARIDB_S3_META_ADDRESS` | required | TessariDB wire addresses `host:port`, comma-separated; a node silent for 5 s is passed over |
| `TESSARIDB_S3_META_REPLICATION` | `none` for one node; required for several | the namespace's replication: a number or `none` |
| `TESSARIDB_S3_META_USER` / `TESSARIDB_S3_META_PASSWORD` | required | the server's own account, an editor of its database, never the owner |
| `TESSARIDB_S3_META_NAMESPACE` / `TESSARIDB_S3_META_DATABASE` | `s3` / `meta` | where metadata lives; the database is created at start, the namespace only by an account allowed to |
| `TESSARIDB_S3_META_CA` | unset | a PEM authority to verify the node's TLS against; unset speaks in the clear |
| `TESSARIDB_S3_META_MAX_CONNECTIONS` | `32` | connections to the store; at most 4 sign in at once |
| `TESSARIDB_S3_META_STATEMENT_TIMEOUT_SECS` | `30` | past it the request answers `503`; a write's data stays queued because it may have committed |

### Background work

| Variable | Default | Meaning |
|---|---|---|
| `TESSARIDB_S3_RECLAIM_GRACE_SECS` | `86400` | how long a replaced, deleted or abandoned data file is kept |
| `TESSARIDB_S3_RECLAIM_INTERVAL_SECS` | `300` | between reclamation passes |
| `TESSARIDB_S3_UPLOAD_MAX_AGE_SECS` | `604800` | an open multipart upload older than this is aborted |
| `TESSARIDB_S3_USAGE_INTERVAL_SECS` | `60` | between passes measuring each bucket's objects and bytes |
| `TESSARIDB_S3_MEDIA_WORKERS` | `2` | renditions this node makes at once (0–64) |
| `TESSARIDB_S3_FFMPEG` | unset | an ffmpeg (libx264, libvpx-vp9, libopus) for video renditions; the image carries none |

### Keys and access

| Variable | Default | Meaning |
|---|---|---|
| `TESSARIDB_S3_IAM_KEY` | unset (no user keys) | 64 hex digits, the root of each space's key for sealing users' secrets |
| `TESSARIDB_S3_KEYS_PASSPHRASE` | unset (sealed) | ≥ 15 characters, unseals the encryption keys vault at start |
| `TESSARIDB_S3_NOTIFY_TARGETS` | unset (only the built-in topic) | extra notification destinations, `;`-separated: `<id>=kafka:<host:port>[,…]/<topic>` or `<id>=webhook:<url>` |
| `TESSARIDB_S3_AUDIT` | `on` | records every request in the region's `s3_access_log` topic (30 days); `off` records nothing |
| `TESSARIDB_S3_METRICS_LISTEN` | unset | serves `GET /metrics` (Prometheus text) at this address |

### The console

| Variable | Default | Meaning |
|---|---|---|
| `TESSARIDB_S3_CONSOLE_LISTEN` | unset (no console) | the console's own address |
| `TESSARIDB_S3_CONSOLE_TLS_CERT` / `TESSARIDB_S3_CONSOLE_TLS_KEY` | unset (plain) | the console over TLS |
| `TESSARIDB_S3_CONSOLE_SIGN_INS_PER_MINUTE` | `10` | sign-ins per client address per minute (also temporary-credential requests) |
| `TESSARIDB_S3_CONSOLE_REQUESTS_PER_MINUTE` | `600` | console requests per signed-in key per minute |
| `TESSARIDB_S3_CONSOLE_OIDC_ISSUER` | unset (keys only) | an OpenID Connect provider for people (https, or http to this machine) |
| `TESSARIDB_S3_CONSOLE_OIDC_CLIENT_ID` | — | the console's client at the provider |
| `TESSARIDB_S3_CONSOLE_OIDC_CLIENT_SECRET` / `TESSARIDB_S3_CONSOLE_OIDC_CLIENT_KEY` | — | exactly one: a client secret, or (from 0.7.0) the path of an Ed25519 key in PKCS#8 PEM sent as a signed assertion (`private_key_jwt`, EdDSA); with a key the server logs its public JWK at start |
| `TESSARIDB_S3_CONSOLE_OIDC_REDIRECT_URI` | — | exactly `<console address>/api/v1/auth/oidc/callback` |
| `TESSARIDB_S3_CONSOLE_OIDC_MFA_AMR` | `mfa` | `amr` values that prove a second factor |
| `TESSARIDB_S3_CONSOLE_BREAK_GLASS_WEBHOOK` | unset | where a root console sign-in is announced (needs the issuer) |
| `TESSARIDB_S3_CONSOLE_KEY_SIGN_IN` | `all` | `root`: users sign in to the console through the provider only (the S3 API is unaffected) |

The cluster settings (`TESSARIDB_S3_ERASURE`, `_NODE_ID`, `_ZONE`, `_INTERNAL_*`, `_CLUSTER_SECRET`,
`_FOUNDING_MEMBERS`, `_JOIN_TOKEN`, `_HEAL_INTERVAL_SECS`, `_MOVE_BYTES_PER_SEC`) are in the
`tessaridb-s3-cluster` skill.

## Settings kept in the metadata store (from 0.8.0)

The settings every node of a region shares are stored the first time a node starts with them in its
environment: in the `s3_settings` table and, when `TESSARIDB_S3_KEYS_PASSPHRASE` is set, the secrets
(the root secret, the IAM key, the cluster secret, the console provider's secret and key, the
break-glass webhook, the notification targets) in the `s3_secrets` vault under that passphrase.
After that a node's environment needs only how to reach the store (the `_META_*` settings other than
`_META_REPLICATION`), the region, the passphrase and what describes the machine (listen and advertise
addresses, certificates, `_DATA_DIR`, node id and zone).

- The stored value wins. An environment value that differs is logged by name; a different
  `_ERASURE` or `_CLUSTER_SECRET` stops the start by name.
- Without the passphrase, secrets are read from the environment and never stored.
- A running node re-reads the stored settings every 5 seconds and applies the background intervals,
  `_MOVE_BYTES_PER_SEC`, the console's rate limits and `_DOMAINS` without a restart; every other
  setting is read at start.
- Root changes them on the console's overview page or with `PUT /api/v1/settings/{name}`
  `{value, expected, reason, passphrase?}` against the value it read (`GET /api/v1/settings`, a secret
  by name only). Refusals: `setting_fixed` (erasure code, cluster secret), `setting_invalid` (the
  node's own checks), `setting_changed` (someone changed it first; read again), `passphrase_required`.
  Every attempt is in the action record without the value.
- Going back to 0.7.0 reads every setting from the environment again: put them back first.

## Running the server without compose

Use the TessariDB release the S3 release notes name as the metadata store (`0.38.3` for 0.8.0). Declare the namespace, the database and the
server's account once, as the owner. These are the statements the compose file's `s3-account` step
runs (`docker/s3-account.sh`); every one is re-runnable:

```tessariql
DEFINE NAMESPACE IF NOT EXISTS s3 REPLICATION NONE ACKNOWLEDGE MAJORITY OR WEAKER;
USE NAMESPACE s3;
DEFINE DATABASE IF NOT EXISTS meta;
USE NAMESPACE s3 DATABASE meta;
DEFINE USER IF NOT EXISTS s3 ON NAMESPACE s3 ROLE editor PASSWORD 's3-account-password-1';
```

Put the statements in a file only the owner can read and run it with
`tessaridb --at <node> --user <owner> -f <file>` (password in `TESSARIDB_PASSWORD`), so the account's
password never appears in a process's arguments. A new password later is `ALTER USER`, not a re-run.
On a metadata **cluster** say the replication instead of `NONE` (and set
`TESSARIDB_S3_META_REPLICATION` to match).

Then start the server with at least the root key, `TESSARIDB_S3_META_ADDRESS`, `_META_USER`,
`_META_PASSWORD` and `TESSARIDB_S3_DATA_DIR`.
