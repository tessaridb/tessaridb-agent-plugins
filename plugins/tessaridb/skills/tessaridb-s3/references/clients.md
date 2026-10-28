# Clients: AWS tools, the Rust client and tessaridb-s3-cli

Checked against TessariDB S3 0.8.0 with the AWS CLI v2, and `tessaridb-s3-client` /
`tessaridb-s3-cli` 0.2.1 (the Rust snippet compiled against crates.io 0.2.1 and ran against a server;
every CLI command below was run). Upstream: <https://docs.tessaridb.com/s3/clients/rust-client>,
`/s3/clients/cli`.

## Any S3 tool

Point it at the endpoint, sign for the server's region, use path-style unless the domain is in
`TESSARIDB_S3_DOMAINS`:

```bash
export AWS_ENDPOINT_URL=http://127.0.0.1:9100
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret>
aws s3 ls
```

- An SDK: set the endpoint override, the region, and force path-style addressing.
- Default CRC checksums sent by current SDKs are validated and stored; no setting is needed.
- Features answered `NotImplemented` (website, lifecycle transitions) must be switched off in the
  tool, not retried. An ACL other than `private` or `bucket-owner-full-control` is refused
  `AccessControlListNotSupported`.
- `503 SlowDown` is back-pressure: let the SDK's retry with backoff handle it.

## The Rust client

```bash
cargo add tessaridb-s3-client
```

Apache-2.0, on crates.io; it speaks the S3 API with SigV4, works with any S3-compatible store, and
depends on the protocol, never on the server's code.

```rust
use tessaridb_s3_client::sign::Credentials;
use tessaridb_s3_client::{BucketName, ClientBuilder, ListObjects, ObjectKey};

let client = ClientBuilder::new("https://s3.example.com", Credentials::new("ACCESS_KEY", "SECRET_KEY"))
    .region("us-east-1")
    .build()?;
// Temporary credentials: Credentials::new(…).with_session_token("SESSION_TOKEN")
let bucket = BucketName::new("photos")?;
let key = ObjectKey::new("2026/cat.jpg")?;
client.put_object(&bucket, &key, b"...".to_vec(), Some("image/jpeg")).await?;
let page = client.list_objects(&bucket, &ListObjects::default()).await?;
```

What it does:

- `BucketName::new` and `ObjectKey::new` refuse what S3 would refuse, and keys with a `.` or `..`
  segment (which a URL would silently collapse).
- `upload_file` hashes the file once, then streams 1 MiB signed chunks; over 16 MiB it uploads parts
  of 8 MiB or more, four at a time. Persistent transient failure returns `UploadInterrupted` with the
  upload id; `resume_upload` sends only the missing parts, `abort_upload` discards it.
- `download_file` writes to a hidden `.part` file and renames it only when complete; a resumed
  download uses `Range` + `If-Match`, so a changed object is refused, not spliced.
- Uploads declare CRC64NVME; downloads are checked against every whole-object checksum the server
  keeps, retried on mismatch, then `ChecksumMismatch`.
- `presign_get` / `presign_put`, 1 second to 7 days. A PUT link does not sign the body.
- One `Error` type with a **category** (`NotFound`, `Conflict`, `Unauthorized`, `Unavailable`, …) plus
  the S3 code, status and request id. Branch on the category, never on the message.
- Transient failures (timeout, lost connection, `SlowDown`, 5xx) are retried up to three times with
  randomised backoff, then `RetriesExhausted`.
- TLS uses the platform trust store with no switch to skip checks; `http://` is accepted for a server
  on the same machine or a private network. Path-style only; redirects are not followed.

## tessaridb-s3-cli

The command line is not on crates.io; install it from the repository:

```bash
cargo install --locked --git https://github.com/tessaridb/tessaridb-s3-client tessaridb-s3-cli
```

Credentials come from `TESSARIDB_S3_ENDPOINT`, `TESSARIDB_S3_ACCESS_KEY`, `TESSARIDB_S3_SECRET_KEY`
(optionally `TESSARIDB_S3_REGION`, `TESSARIDB_S3_SESSION_TOKEN`), or else from
`~/.config/tessaridb-s3/credentials`, which must be `chmod 600`:

```ini
[default]
endpoint = https://s3.example.com
access_key = ...
secret_key = ...
```

`--profile <name>` picks a section. There is no flag for a secret.

```bash
tessaridb-s3-cli mb s3://photos
tessaridb-s3-cli cp holiday.jpg s3://photos/2026/
tessaridb-s3-cli ls s3://photos/ --recursive
tessaridb-s3-cli stat s3://photos/2026/holiday.jpg --json
tessaridb-s3-cli presign s3://photos/2026/holiday.jpg --expires 600
tessaridb-s3-cli sync ./albums s3://photos/albums
tessaridb-s3-cli rm s3://photos/2026 --recursive --yes
```

| command | does | changes data |
|---|---|---|
| `ls [s3://bucket[/prefix]]` | buckets, or one level (`--recursive`: all) | no |
| `stat s3://bucket/key` | size, ETag, CRC64NVME, last modified | no |
| `presign s3://bucket/key` | download link (`--put`: upload), `--expires` seconds (3600, at most 604800) | no |
| `mb` · `cp` · `sync` | create a bucket · copy (replace only with `--yes`) · copy what is missing or differs, never delete | yes |
| `rb --yes` · `rm --yes` · `mv --yes` | delete an empty bucket · delete (`--recursive` a prefix) · copy, check, delete source | deletes |

- Every changing command accepts `--dry-run`; a deleting one refuses without `--yes` (exit 2,
  nothing sent).
- After each change it asks again and fails if the result is not what was asked.
- `sync` treats a file as unchanged only when proven (size, then a single-part ETag's MD5, otherwise
  CRC64NVME); a key that would land outside the target directory is skipped and fails the run.

| exit | meaning |
|---|---|
| 0 | done |
| 2 | invalid command, location or settings; nothing was sent |
| 3 | a safety check refused (destination exists, bucket not empty, object missing) |
| 4 | the server or file system failed |
| 5 | it ran, but the check afterwards found a different result |
| 130 | interrupted; an interrupted multipart upload stays open until aborted |
