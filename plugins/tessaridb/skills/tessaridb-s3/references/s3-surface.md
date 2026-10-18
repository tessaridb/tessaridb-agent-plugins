# The S3 surface: operations, versioning, Object Lock, multipart

Checked against TessariDB S3 0.2.1-beta. Upstream: <https://docs.tessaridb.com/s3/start/compatibility>.

Requests are dispatched by operation name. An operation the server does not implement answers
`NotImplemented`; an unknown or misplaced parameter is refused before any operation runs. Each of
the 116 operations of the S3 model is signed, sent and answered in the server's own tests.

## What it promises

- Every signature and declared checksum is verified before a write is acknowledged, and each
  checksum is stored so a read returns it.
- Strong read-after-write, listings included; keys in byte-wise UTF-8 order; continuation tokens that
  neither skip nor repeat a key.
- A write is acknowledged only when durable, data and metadata committed together.

## Buckets

| operations | notes |
|---|---|
| `CreateBucket` `HeadBucket` `DeleteBucket` `ListBuckets` | a bucket holding only versions is not empty |
| `GetBucketLocation` | the server's region |
| `GetBucketVersioning` `PutBucketVersioning` | never versioned → Enabled ↔ Suspended, never back; MFA delete refused |
| `Get/Put/DeleteBucketLifecycle…` | see events-lifecycle-media.md |
| `Get/PutBucketNotificationConfiguration` | queue configurations only |
| `Get/Put/DeleteBucketReplication` | the `Filter` form, both buckets versioned (tessaridb-s3-cluster) |
| `Get/PutObjectLockConfiguration` | on a bucket created with `x-amz-bucket-object-lock-enabled`, or a versioned one; kept for good, optional default retention |
| `Get/Put/DeleteBucketTagging` | at most 50 tags; none answers `NoSuchTagSet` |
| `Get/Put/DeleteBucketEncryption` | `AES256` or `aws:kms` with a key this node holds |
| `Get/Put/DeleteBucketPolicy` `GetBucketPolicyStatus` | evaluated on every request |
| `Get/Put/DeletePublicAccessBlock` | every switch on for a bucket that set none |
| `Get/Put/DeleteBucketCors` | up to 100 rules; preflights answered without credentials |

## Objects

| operations | notes |
|---|---|
| `PutObject` | up to 5 GiB; payload hash and checksums verified first; SSE-S3, SSE-KMS, SSE-C |
| POST object | a browser form to `POST /{bucket}` under a signed policy |
| `GetObject` `HeadObject` | ranges, `partNumber`, `versionId` |
| `CopyObject` | up to 5 GiB, COPY or REPLACE metadata, copy-source conditions, checksum recomputed |
| `DeleteObject` `DeleteObjects` | with `versionId`, removes that version for good |
| `ListObjectsV2` `ListObjects` | byte order, delimiter roll-up, authenticated tokens, `encoding-type=url` |
| `ListObjectVersions` | keys in byte order, each key newest first with `IsLatest` |
| `Get/Put/DeleteObjectTagging` | at most 10 tags, `aws:` keys refused; `x-amz-tagging` on put, copy and multipart create |
| `Get/PutObjectRetention` `Get/PutObjectLegalHold` | see Object Lock below |

Over 5 GiB use multipart.

## Multipart

| operations | notes |
|---|---|
| `CreateMultipartUpload` `UploadPart` `UploadPartCopy` | part copy from a range or all of a source |
| `ListParts` `ListMultipartUploads` | key and upload-id markers, delimiter roll-up |
| `CompleteMultipartUpload` | multipart ETag, full-object or composite checksum |
| `AbortMultipartUpload` | uploads open longer than `TESSARIDB_S3_UPLOAD_MAX_AGE_SECS` (a week) are aborted by the reaper |

## Versioning in practice

```bash
aws s3api put-bucket-versioning --bucket first --versioning-configuration Status=Enabled
aws s3 rm s3://first/2026/photo.txt
aws s3api list-object-versions --bucket first     # the version AND a delete marker for the key
```

- Enabled keeps every version and a delete adds a marker; Suspended replaces only the null version.
- `GetObject` with a `versionId` naming no version → `NoSuchVersion`; a delete marker named by id →
  `405`; a current delete marker → `404` with `x-amz-delete-marker`.
- Removing a delete marker by id brings the object back.
- Objects written by an earlier build become null versions at start.

## Object Lock

- COMPLIANCE retention is never shortened.
- GOVERNANCE yields only to whoever administers the bucket, with
  `x-amz-bypass-governance-retention: true`.
- A kept version (retention or legal hold) cannot be deleted or rewritten by any path, lifecycle and
  the console included.

## Not implemented yet

ACLs, event holds, website configuration, lifecycle transitions, tag or size lifecycle filters, topic,
function and event-bus notification targets, and dual-layer KMS answer `NotImplemented`. A tool that
needs one gets that refusal, not a quiet success; turn the feature off in the tool rather than retry.
