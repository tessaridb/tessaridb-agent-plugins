# Users, keys, grants, policies and the console API

Checked against TessariDB S3 0.2.1-beta (the console API sequence below was sent to a running server:
sign in as root, create a user, issue its key, grant a bucket read-only, then the user's key listed the
bucket and was refused `AccessDenied` on `PutObject` and `CreateBucket`). Upstream:
<https://docs.tessaridb.com/s3/data-and-access/access>, `/s3/data-and-access/security`,
`/s3/operating/console`.

## The model

- **The root key** (`TESSARIDB_S3_ROOT_ACCESS_KEY`/`_SECRET_KEY`) can do everything. Use it to set up,
  not for applications.
- **Spaces** group users and buckets; `default` exists. A bucket belongs to the space of whoever
  created it, and a user can be granted only buckets in its own space (`bucket_not_in_space`).
- **Users** have a role in their space (`member` or `space_admin`) and optional flags
  (`create_buckets`, `operator`, `cluster_viewer`).
- **Access keys** are issued per user. The secret is shown once, and is sealed at rest under a key
  derived from `TESSARIDB_S3_IAM_KEY`; without that variable no user key can be issued.
- **Grants** are per bucket: `read`, `write`. A revoked key or grant is refused on every node within
  the 5-second resolution window.
- **Groups** carry bucket grants to every member of one space.

## Doing it through the console API

The console (`TESSARIDB_S3_CONSOLE_LISTEN`) is a page over a JSON API under `/api/v1`, which can be
called directly. Every change takes an optional `reason`, which is kept in the action record.

```bash
C=http://127.0.0.1:9101
# 1. sign in (root or a user's key) → a one-hour session cookie
curl -c jar -H 'content-type: application/json' \
  -d '{"access_key_id":"<root key>","secret_access_key":"<root secret>"}' $C/api/v1/session

# 2. a user in the bucket's space
curl -b jar -H 'content-type: application/json' \
  -d '{"name":"backup","space":"default","role":"member","reason":"nightly backup job"}' $C/api/v1/users

# 3. its access key — the secret is in this answer and nowhere else
curl -b jar -H 'content-type: application/json' \
  -d "{\"reason\":\"backup job\",\"idempotency_key\":\"$(uuidgen)\"}" $C/api/v1/users/backup/keys

# 4. a grant on one bucket
curl -b jar -X PUT -H 'content-type: application/json' \
  -d '{"read":true,"write":true,"reason":"backup target"}' $C/api/v1/users/backup/grants/first
```

| route | method | body |
|---|---|---|
| `/api/v1/session` | `POST` sign in · `GET` what this session may do · `DELETE` sign out | `access_key_id`, `secret_access_key` |
| `/api/v1/spaces` | `GET`, `POST` | `name` |
| `/api/v1/users` | `GET`, `POST` | `name`, `space`, `role` (`member`/`space_admin`), `create_buckets`, `operator`, `cluster_viewer` |
| `/api/v1/users/{user}/disabled` | `PUT` | `disabled` |
| `/api/v1/users/{user}/keys` | `GET` (no secrets), `POST` issue | `idempotency_key` (required: the same key returns the same answer instead of a second key) |
| `/api/v1/users/{user}/keys/{key}` | `DELETE` revoke | |
| `/api/v1/users/{user}/grants/{bucket}` | `PUT`, `DELETE` | `read`, `write` |
| `/api/v1/spaces/{space}/groups` | `GET`, `POST` | `name` |
| `/api/v1/spaces/{space}/groups/{group}/members/{user}` | `PUT`, `DELETE` | |
| `/api/v1/spaces/{space}/groups/{group}/grants/{bucket}` | `PUT`, `DELETE` | `read`, `write` |
| `/api/v1/buckets` | `GET`, `POST` | `name` |
| `/api/v1/buckets/{bucket}/quota` | `PUT` | `max_bytes`, `max_objects` |
| `/api/v1/buckets/{bucket}/upload-keys` | `POST` | `key`, `expires_in` (seconds) |
| `/api/v1/actions` | `GET` | `before`, `limit` (query) |
| `/api/v1/usage` | `GET` | |

Refusals carry `code` and `message`, for example `idempotency_key_required`,
`bucket_not_in_space`, `401 reauthentication_required`.

- Sign-ins are limited per client address (`TESSARIDB_S3_CONSOLE_SIGN_INS_PER_MINUTE`, 10) and
  requests per key (`_REQUESTS_PER_MINUTE`, 600).
- Issuing a key or an upload key, linking an identity, setting or removing a grant, setting a quota
  and deleting a bucket need a sign-in from the last five minutes (`401 reauthentication_required`).
- Without console TLS a secret crosses the network in the clear at sign-in.

## One-key upload credentials

Issued by a user who may write the bucket (`POST /api/v1/buckets/{bucket}/upload-keys` with `key` and
`expires_in`), they upload exactly one key (a single PUT or every step of a multipart upload of it),
expire between 60 seconds and 7 days, and work only while the issuer may still write there. Use them
instead of a long-lived key in a browser or a device.

## Quotas

Bytes and objects per bucket, checked on every write that adds, against the last usage measurement
(`TESSARIDB_S3_USAGE_INTERVAL_SECS`) plus the write. A quota is not exact to the byte between passes.

## Bucket policies

`PutBucketPolicy` stores an IAM-style policy, evaluated on every request (the console's too):

- an explicit `Deny` outweighs every grant;
- a request without credentials reaches only what a policy grants everyone;
- a statement the server cannot evaluate as written is refused `MalformedPolicy`.

## Block Public Access

A bucket that set nothing has every switch on: a public policy is refused, and a public policy's
Allows reach only the bucket's own space. `DeletePublicAccessBlock` turns it off. ACLs are never
honoured.

## CORS and browser uploads

`PutBucketCors` takes up to 100 rules; an `OPTIONS` preflight is answered without credentials by the
first rule matching its origin, method and headers. A browser form can `POST /{bucket}` a file under
a signed policy (expiration, `eq`, `starts-with`, `content-length-range`) that must cover every field;
it is authorized as the signer's PutObject. A form without a policy is anonymous.

## Signing in to the console through TessariDB OAuth

TessariDB OAuth issues no client secrets, so the console authenticates with a key (from 0.7.0):

1. `openssl genpkey -algorithm ed25519 -out console.pem`; mount it as a secret file and set
   `TESSARIDB_S3_CONSOLE_OIDC_CLIENT_KEY` to its path, with `_ISSUER` (`https://<oauth host>/<company>`),
   `_CLIENT_ID` and `_REDIRECT_URI`.
2. The server logs the public JWK at start. Register the client at OAuth with `auth_method`
   `private_key_jwt`, `assertion_alg` `EdDSA`, that JWK, the redirect URI exactly, `scope_ceiling`
   `["openid"]` and `grant_types` `["authorization_code"]`.
3. A person's first sign-in is refused `401` and their subject is logged; link it with
   `PUT /api/v1/users/{user}/identity`. An account without a second factor is refused.

## Temporary credentials

With an identity provider configured for the console (`TESSARIDB_S3_CONSOLE_OIDC_*`), a person whose
identity is linked to a user (`PUT /api/v1/users/{user}/identity`) can exchange an ID token for
temporary keys:

```text
POST /
Action=AssumeRoleWithWebIdentity
RoleArn=arn:aws:iam::<space>:role/<user>
RoleSessionName=<name>
WebIdentityToken=<ID token naming a second factor in amr>
DurationSeconds=900…43200
```

The answer is an access key, a secret and a session token, valid 15 minutes to 12 hours (1 hour by
default). Every request sends the token as `x-amz-security-token`. They end at expiry, when the
identity is unlinked, when the user is disabled, or at a provider logout. An optional `Policy`
(≤ 2 048 characters, S3 resources only) narrows them and never grants more than the user has.

## The console's sign-in modes

- Keys: the root key or a user's key.
- An identity provider: authorization code with PKCE at `/api/v1/auth/oidc/start`, a second factor
  required through `amr`.
- Break-glass: beside a provider, a root sign-in owes a reason, lasts 15 minutes, is recorded first
  and announced to `TESSARIDB_S3_CONSOLE_BREAK_GLASS_WEBHOOK`.
- `TESSARIDB_S3_CONSOLE_KEY_SIGN_IN=root` refuses users' keys for the console only
  (`key_sign_in_disabled`); the S3 API is not affected.

## The action record

`GET /api/v1/actions`: every change and every download, with the signed-in key and the reason, newest
first, kept a year in TessariDB, which refuses to change or remove an entry.
