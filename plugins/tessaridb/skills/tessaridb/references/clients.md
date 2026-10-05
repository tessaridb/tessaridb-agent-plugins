# Clients, the wire protocol and HTTP

## The five clients

| Language | Package | Install |
|---|---|---|
| Rust | `tessaridb-client` | `cargo add tessaridb-client` (crates.io) |
| Python | `tessaridb-client`, imported as `tessaridb` | from its repository, `github.com/tessaridb/tessaridb-sdk-python` |
| TypeScript / Node | `@tessaridb/client` | from its repository, `github.com/tessaridb/tessaridb-sdk-js` |
| Go | `github.com/tessaridb/tessaridb-sdk-go` | `go get github.com/tessaridb/tessaridb-sdk-go` |
| Kotlin / JVM | `com.tessaridb:tessaridb-client` | from its repository, `github.com/tessaridb/tessaridb-sdk-kotlin` |

All are Apache-2.0, written from the protocol specification alone, and checked against the same
conformance corpus. Version 0.9.0 of each speaks protocol 1.3, follows a cluster's redirects, exposes a refusal's class,
and
speaks TLS 1.3 to a node given a certificate. Each checks the certificate chain and the host name,
has no option to skip that check, and never falls back to the clear after a failed handshake. Trust
comes from a PEM authority or the system store: Rust `Tls::trusting_pem`, Python
`tessaridb.tls_context("ca.pem")` passed as `tls=`, TypeScript `connect({ …, tls: { ca } })`, Go
`TrustPEM` with `DialTLS`, Kotlin `Trust.fromPem`. The prompt takes `--tls-authority ca.pem`.
The node's major protocol version must match the client's.

## Connecting and asking

Python:

```python
import tessaridb

with tessaridb.connect("127.0.0.1:9080", user="owner", password="…") as db:
    reply = db.execute(
        "USE NAMESPACE prod; USE DATABASE shop; SELECT * FROM users WHERE name = $who;",
        {"who": tessaridb.Text("ada")},
    )
    records = reply.outcomes[-1]
    for row in records.rows:
        print(row.identity, row.value)
```

TypeScript:

```ts
import { connect } from '@tessaridb/client';

const db = await connect({ host: '127.0.0.1', port: 9080 });
const reply = await db.execute(
  'USE NAMESPACE prod; USE DATABASE shop; SELECT * FROM users;',
);
```

Every client has the same shape: `connect`, `execute(script, parameters)`, and a reply holding one
outcome per statement. The last outcome is usually the one you want.

## Rules for application code

- **One connection is one session.** `USE`, a signed-in user and an open transaction belong to it.
  Send the `USE` lines with every unit of work, and never share one connection between threads that
  issue transactions.
- **Bind every value.** Pass parameters (`$who`), never formatted text. Each client also has a
  query builder (`select('users').field('name').where(compare('city', '=', …))`) that binds values
  and checks names against a pattern narrower than the language's own.
- **Keep `NONE` and `NULL` apart**, even in a language with one word for both. The clients model
  them as different values.
- **Read the notes.** A reply's outcome carries notes, for example "a comparison skipped records of
  another kind" or "a source hit its ceiling". Log or surface them; never drop them.
- **Branch on the refusal's class.** Every refusal carries one of nine classes: `invalid`,
  `unauthenticated`, `forbidden`, `throttled`, `elsewhere`, `retry`, `conflict`, `unavailable`,
  `internal`. Over HTTP it is the body's `code` and the status follows it; over the wire it is one
  byte at protocol 1.3. Retry only `retry`. `retry` and `conflict` are both HTTP `409`, so branch on
  the class rather than the number, and never on text parsed from a message: refusal names are not
  on the wire.
- **Following changes takes the connection.** A subscription (change feed) consumes the connection
  it runs on, so open a second connection for queries. Resume from the last sequence you handled
  **plus one**.

## On a cluster

A client connected to a node that can't run a statement gets a redirect to the node that can, and
the 0.7 clients follow it. They check that the node they reach is the one named, refuse a redirect
older than one already followed, give up after three hops, and re-send the session's `USE` there.
A write sent to a follower is forwarded to the leader by the node itself.

## HTTP

Port 8000 (when started with `--http`) serves:

| Route | For |
|---|---|
| `POST /script` | run a script; JSON answer |
| `POST /session` | exchange a password for a token, once |
| `GET /health`, `GET /ready`, `GET /metrics` | probes and Prometheus metrics, no credential |
| `GET /backup` | a backup of the store, for an operator |
| `GET /watch` | a change feed over a WebSocket |
| `GET /wire` | the wire protocol over a WebSocket, for browsers |
| `/` | the web console |

- Over HTTP, sign in once at `POST /session` and send the token afterwards. A password sent with every
  request pays an Argon2id hash on every request (about 130 ms).
- `401` means "sign in"; `403` means "signing in again won't help". Keep them apart.
- JSON loses types (decimal, datetime, record links). Use the wire protocol for data, and HTTP for
  probes, files, backups and browsers.
