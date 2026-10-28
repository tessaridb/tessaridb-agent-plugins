# Reads, routing and follower lag

Checked against TessariDB 0.39.2 (follower reads, the staleness floor and a Python client 0.13.0 following a write redirect,
on a local three-node cluster). Upstream: <https://docs.tessaridb.com/cluster/reads-routing-and-staleness>.

## Two controls, both decided before the read runs

```tessariql
DEFINE COLLECTION orders;
DEFINE COLLECTION accounts;
SELECT * FROM orders STALENESS 30s;
SELECT * FROM accounts WHERE id = 1 ANSWERED BY LEADER;
SELECT * FROM accounts WHERE id = 1 STALENESS 30s ANSWERED BY LEADER;
```

- **`STALENESS d`** says which nodes may answer: only those whose copy is at most `d` old. It is a
  filter, **never a marker** on the answer; there's no field to check afterwards. A bound no copy
  meets is refused (`NoCopyWithinStaleness`), not quietly sent to the leader. A bound below the floor
  (twice `AWARENESS`) is refused naming the floor; `STALENESS 0s` is refused outright. It can't be
  combined with `VERSION`.
- **`ANSWERED BY LEADER`** admits only the node that decides writes for these records. It is not a
  tighter staleness: a follower at zero lag is level, not authoritative. `ANSWERED BY ANY` is the
  default.
- On a single node both are satisfied.
- **Answered by the leader is not repeatable**: two such reads with writes between them differ.
  Reads that must agree with each other go in one transaction.

## Redirects

A request this node can't answer comes back as a **redirect** naming the address, the node to expect
and its epoch: a frame with a `settled` (a write; the leadership holds) or `transient` (this read
only) flag, never an error; over HTTP a `307` with `Location`.

- Every client from 0.7 follows it inside the call: at most three hops, never to an older epoch, the
  session's `USE` re-sent on arrival, and the node checked to be the one named
  (`RETURN session::context()` is how). A browser client over a WebSocket hands it back instead.
- A redirect is sent only when nothing in the script has committed; a `BEGIN … COMMIT` refused for
  its leader rolled back and is redirected whole.
- The command-line client can't follow; point it at the leader or a node that may answer.
- `CLIENTS AT` / `HTTP AT` on a member row are the addresses a redirect names.

## Follower numbers

`INFO FOR NODE` on a leader lists `cluster.followers`, one row per node that has **actually
collected** (as opposed to `cluster.peers`, which is what was declared). Each row:

| field | says | catches alone |
|---|---|---|
| `sequence` | highest log position given to it | — |
| `behind` | sequences short of the leader's tail | a follower collecting but unable to keep up |
| `quiet_for` | time since it last collected | a follower that stopped while the leader is idle |
| `copy_age` | how old its data is (an upper bound) | a follower asking often and still serving stale data |

On an idle cluster `quiet_for` grows while `copy_age` stays small; that's healthy. `copy_age: null`
means "beyond every bound". The list isn't persisted: after a restart it fills as followers ask.
A follower collects from whichever peer currently says it may write, preferring the newer epoch.
