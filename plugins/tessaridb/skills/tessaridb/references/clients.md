# Clients, the wire protocol and HTTP

Checked against TessariDB 0.38.3 and clients 0.12.0. Each language has a page with its whole
surface: <https://docs.tessaridb.com/clients/choosing>.

## The five clients

| Language | Package | Install |
|---|---|---|
| Rust | `tessaridb-client` | `cargo add tessaridb-client` (crates.io) |
| Python ≥ 3.11 | `tessaridb-client`, imported as `tessaridb` | `pip install git+https://github.com/tessaridb/tessaridb-sdk-python` |
| TypeScript, Node ≥ 22 and browsers | `@tessaridb/client` | clone `github.com/tessaridb/tessaridb-sdk-js`, `npm install && npm run build`, then `npm install ../tessaridb-sdk-js` |
| Go | `github.com/tessaridb/tessaridb-sdk-go` | `go get github.com/tessaridb/tessaridb-sdk-go` |
| Kotlin / JVM | `com.tessaridb:tessaridb-client` | from `github.com/tessaridb/tessaridb-sdk-kotlin` |

All are Apache-2.0 with no runtime dependencies, written from the protocol specification and
checked against one conformance corpus. A client's version is its own: what must match is the
protocol **major** (1). Clients 0.12.0 speak protocol 1.6 and send newer frames only to a node that
announces the minor that reads them.

## Connecting and asking

Python:

```python
import tessaridb

with tessaridb.connect("127.0.0.1:9080", user="owner", password=password) as db:
    reply = db.execute(
        "USE NAMESPACE prod; USE DATABASE shop; SELECT * FROM customers WHERE name = $who;",
        {"who": tessaridb.Text("Ada")},
    )
    for row in reply.outcomes[-1].rows:
        print(row.identity, row.value)
```

TypeScript:

```ts
import { connect } from '@tessaridb/client';

const db = await connect({ host: '127.0.0.1', port: 9080 });
const reply = await db.execute('USE NAMESPACE prod; USE DATABASE shop; SELECT * FROM customers;');
```

Rust:

```rust
let mut client = Client::connect("127.0.0.1:9080").await?;
let answers = client
    .run("USE NAMESPACE prod; USE DATABASE shop; SELECT * FROM customers;", None)
    .await?;
```

Every client has the same shape: connect to a bare `host:port` (no URL scheme), run a script with a
parameters map, and get one outcome per statement. The last one is usually the read you wanted; the
`USE` lines answer `Done`. The password is spent once, on the connection's first request.

## Rules for application code

- **One connection is one session.** `USE`, the signed-in user and an open transaction belong to
  it. Send the `USE` lines with every unit of work (a pooled connection that reconnected has
  forgotten them), and never share one connection between threads issuing transactions.
- **Bind every value.** Pass parameters, never formatted text. Values are typed: `Text`,
  `Integer`, `Float`, `Decimal`, `Datetime` and so on; a 64-bit integer stays an integer.
- **Use the builder when it fits.** It binds every value and checks every name against a pattern
  narrower than the language's own:

```python
from tessaridb import select, compare, Text

statement = (
    select("customers")
    .field("name")
    .where(compare("city", "=", Text("Paris")))
    .order_by("name")
    .limit(50)
)
rendered = statement.render()
reply = db.execute("USE NAMESPACE prod; USE DATABASE shop;")
reply = db.execute(rendered.script, rendered.parameters)
```

- **Keep `NONE` and `NULL` apart**, even in a language with one word for both
  (`tessaridb.NONE` and `tessaridb.NULL` in Python).
- **Read the notes** each outcome carries ("a comparison skipped records of another kind", "a source
  hit its ceiling", "estimated"). Log or surface them; never drop them.
- **Branch on the refusal's class**, never on its text. One of nine: `invalid`, `unauthenticated`,
  `forbidden`, `throttled`, `elsewhere`, `retry`, `conflict`, `unavailable`, `internal`
  (Python `Refused.refusal_class`, TypeScript `RefusalError.refusalClass`). Retry only `retry`,
  bounded. Details in [refusals.md](refusals.md).
- **TLS has no off switch.** Against a node with a certificate, trust its authority:
  Python `tessaridb.tls_context("ca.pem")` passed as `tls=`, TypeScript `connect({ …, tls: { ca } })`,
  Rust `Tls::trusting_pem`, Go `TrustPEM` with `DialTLS`, Kotlin `Trust.fromPem`. The prompt takes
  `--tls-authority ca.pem`. The client checks the chain and the host name, and never falls back to
  the clear.
- **On a cluster** the clients follow a redirect to the node that can answer (three hops at most)
  and re-send the session's `USE` there.

## Following changes

```python
watcher = tessaridb.connect("127.0.0.1:9080", user="owner", password=password)
watcher.execute("USE NAMESPACE prod; USE DATABASE shop;")
changes = watcher.subscribe(from_=0)
for change in changes:
    print(change.sequence, change.table, change.identity, change.removed)
```

- **Subscribing consumes the connection**: open a second one for queries.
- The node drops a subscriber that stops reading for 30 seconds; nothing is lost, because the log
  is the buffer. Reconnect and subscribe from `changes.resume_from` (the last sequence handled
  **plus one**). Resuming at a handled position delivers it twice; resuming past one skips it.
- A feed over one table can be narrowed by a condition with bound values; a record that stops
  matching arrives as a removal, and a feed that skipped changes sends a `Progress`. **Store a
  Progress exactly like a change's position**, or a quiet feed keeps a resume point the log may
  have pruned:

```python
from tessaridb import Integer, Progress

feed = conn.subscribe(0, "orders", condition="total > $least", parameters={"least": Integer(100)})
for arrived in feed:
    if isinstance(arrived, Progress):
        continue
    print(arrived.identity, arrived.removed)
```

## Worker loops the clients carry

Each client has the same helpers (Python names shown; the others are on each language's page):

```python
from tessaridb import Ack, Cache, Consumer, Finish, Queue, Text, Vault
from tessaridb.query import compare

consumer = Consumer(conn, "prod", "shop", "events", "mailer", batch=10)
consumer.run_auto(handle)                    # returning acks, raising hands the message back

worker = Queue(conn, "prod", "shop", "jobs", "resizer", batch=10,
               where=compare("kind", "=", Text("image")))
worker.run_auto(lambda job: resize(job))     # returning deletes the record, raising releases it

cache = Cache(conn, "prod", "shop", "cache")
cache.set("session:abc", Text("ada"), ttl=1800)
lease = cache.lock("nightly-report", ttl=30)

tessaridb.unseal(conn, store_passphrase)     # the passphrase travels in its own frame
vault = Vault(conn, "prod", "shop", "team")
secret = vault.reveal("github", ["token"])
```

- Topic groups and queues are **at least once**: key outside effects on topic + group + position,
  or on queue + record id.
- The loops are synchronous in Python; run them in a thread and call `stop()` from another.
- `Vault.declare(…)` creates a vault with its own passphrase without putting it in a script
  (engine 0.36.1 and later).

## HTTP

A node started with `--http` (port 8000 in the container) serves:

| Route | For |
|---|---|
| `POST /session` | exchange a password for a token, once |
| `POST /script` | run a script with parameters; JSON answer |
| `PUT`, `GET`, `HEAD`, `DELETE /files/{ns}/{db}/{bucket}/{path}` | files in a bucket |
| `/kv/…` | a space as a cache |
| `POST /series/{ns}/{db}/{series}` | append events to a time series |
| `/vault…` | seal status, unseal, seal, change passphrase, declare a vault with its own |
| `GET /watch` | a change feed over a WebSocket |
| `GET /wire` | the wire protocol over a WebSocket, for browsers |
| `GET /backup` | a snapshot of the store, for an operator |
| `GET /health`, `/ready`, `/metrics` | probes and Prometheus metrics, no credential |
| `/` | the web console |

- Sign in once at `POST /session` and send the token afterwards. A password sent with every request
  pays an Argon2id hash every time (roughly 100 ms).
- Error bodies are `{"error": "…", "code": "<class>"}` and the status follows the class: `invalid`
  400, `unauthenticated` 401, `forbidden` 403, `throttled` 429, `retry` and `conflict` 409,
  `unavailable` 503, `internal` 500. Keep `401` (sign in) and `403` (signing in won't help) apart,
  and branch `409` on the `code`.
- JSON loses types (decimal, datetime, record links, 64-bit integers). Use the wire protocol for
  data, and HTTP for files, probes, backups and browsers.

The protocol itself (frames, the greeting, the 16 MiB frame ceiling, the conformance corpus) is at
<https://docs.tessaridb.com/clients/protocol> and in `github.com/tessaridb/tessaridb-protocol`.
