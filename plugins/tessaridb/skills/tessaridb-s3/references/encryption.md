# Server-side encryption and the keys vault

Checked against TessariDB S3 0.2.1-beta (the two commands below ran: the object answered
`ServerSideEncryption: AES256`, the bucket default read back). Upstream: <https://docs.tessaridb.com/s3/data-and-access/encryption>.

Each sealed object's data is encrypted in blocks under a data key of its own; that data key is
wrapped by a key the server holds or by the key the customer sends.

## Three ways to seal

| request header | sealed under | notes |
|---|---|---|
| `x-amz-server-side-encryption: AES256` | the server's key | SSE-S3 |
| `x-amz-server-side-encryption: aws:kms` + a key id | a named key this node holds | an unknown key is refused |
| `x-amz-server-side-encryption-customer-*` | the customer's key | SSE-C: TLS only; the key is never stored |

```bash
aws s3 cp ./report.pdf s3://first/reports/ --sse AES256
aws s3api put-bucket-encryption --bucket first --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

- Applies to PutObject, CopyObject, multipart uploads and part copies; GetObject/HeadObject open it.
- Replicas and erasure shards stay sealed.
- A version sealed with a customer key is not replicated, gets no renditions and cannot be downloaded
  through the console, because none of those holds the key.

## Bucket default

`PutBucketEncryption` sets what a write that asks for nothing gets (`AES256`, or `aws:kms` with a key
id). A request's own header wins. Customer keys are refused in a bucket unless its
`BlockedEncryptionTypes` is `NONE`.

## The keys vault

The server's keys live in a vault of their own in the metadata store, sealed under a passphrase of at
least 15 characters. **Until it is opened, a request that needs one of its keys answers
`503 ServiceUnavailable`.**

- `TESSARIDB_S3_KEYS_PASSPHRASE` opens it at start, or
- an operator unseals it in the console (Overview → Encryption keys, `POST /api/v1/encryption/unseal`).

Opened keys live only in the process's memory; a restart seals them again unless the variable is set.

## Rotating and destroying

Rotating the server key in the console makes a new key current; every data key is re-wrapped under
it in the background and object bytes are never rewritten. Each older key shows how many data keys it
still wraps and can be destroyed once that count is zero.

## TLS

`TESSARIDB_S3_TLS_CERT` and `_KEY` serve the S3 API over TLS 1.2 and 1.3. Customer keys need it.
