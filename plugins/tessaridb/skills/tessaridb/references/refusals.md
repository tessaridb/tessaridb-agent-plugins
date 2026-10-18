# Refusals: what was refused, and what to do

Checked against TessariDB 0.36.1. Every refusal, by name: <https://docs.tessaridb.com/reference/refusals>.

The principle behind all of them: **an absence narrows a read; a mistake in the statement refuses
it.** A record missing a field just isn't in the answer; a present value of the wrong type, a name
that doesn't exist, or an unbounded write is refused rather than guessed past.

A refusal's message is the store's own words with the place in the script (`at 32..33`). Quote it.

## Names are for tests; classes are for code

The **name** (`RecordExists`, `CommitContention`, …) is stable and is what a test asserts. It is
**not on the wire**. What reaches a client is the message plus one of nine **classes**; branch on the
class, never on text parsed from the message.

| class | HTTP | what the caller does |
|---|---|---|
| `invalid` | 400 | fix the statement or the value; repeating it can't succeed |
| `unauthenticated` | 401 | sign in |
| `forbidden` | 403 | stop: signing in again won't help; the role, tenancy or grant doesn't cover this |
| `throttled` | 429 | wait, then try again (sign-in or passphrase attempts) |
| `elsewhere` | 307 | go to the node named (clients follow this automatically on a cluster) |
| `retry` | 409 | run the **whole transaction** again, with a bounded number of attempts |
| `conflict` | 409 | re-read: the state the request assumed is not the state there is |
| `unavailable` | 503 | this node can't serve it now (no leadership, no majority, draining, busy) |
| `internal` | 500 | a bug or a failing substrate; read the node's log |

`retry` and `conflict` share `409`, so branch on the class, not the status. The store never waits
for you: a `retry` that nobody retries is work silently lost.

## The ones you will meet first

| You see | Because | Do |
|---|---|---|
| `NoNamespaceSelected`, `NoDatabaseSelected` | no `USE` on this connection | send `USE NAMESPACE …; USE DATABASE …;` with the work |
| `UnexpectedToken` on `DELETE FROM t WHERE …;` | a set delete states its reach | add `LIMIT n` or `LIMIT ALL` |
| `UnexpectedToken` on `UPDATE t SET …` | `UPDATE` names one record | read the ids, update each (in a transaction) |
| `RecordExists` | `CREATE` at an id that exists | `UPDATE`, `UPSERT`, or a new id |
| `NoSuchRecord` (class `conflict`) | `UPDATE` of a record that isn't there | `UPSERT`, or re-read |
| `ConditionNotMet` | the `WHERE` of a compare-and-set was false | re-read and decide; nothing was written |
| `UndeclaredField` | a strict table got a field it doesn't declare | the message carries the `DEFINE FIELD` that would accept it |
| `SchemaViolation`, `MissingRequiredField`, `AssertionViolation` | a value doesn't fit its field | fix the value, or `ALTER FIELD` |
| `UniqueViolation` | two records in one unique entry | pick another value or `UPSERT` the existing record |
| `NameTaken`, `ParamExists`, `EventExists` | a definition already exists | `IF NOT EXISTS`, `OR REPLACE` where offered |
| `TableWithoutColumns` | `DEFINE TABLE t;` | `DEFINE COLLECTION t` or `DEFINE TABLE t (…) SCHEMALESS` |
| `StillDepended` | a drop while something depends on it | drop the dependant first; there is no `CASCADE` |
| `UnboundParameter` | `$name` used and never bound | bind it; it is never treated as absent |
| `ReturnedTwice` | two `RETURN`s in one submitted script | one `RETURN` per script |
| `Unbounded`, `UnboundedCollection` | a subquery or fold source passed its ceiling | give the source a `LIMIT` |
| `NotAlone` | `ONLY` matched more than one record | narrow the read, or drop `ONLY` |
| `TimedOut` | the read passed its `TIMEOUT` | narrow it, index it, or raise the bound |
| `IndexNotUsed`, `PathNotTaken` | `USING INDEX` or `USING` was not honoured | fix the read or the index; it refused rather than scanning |
| `NoSearchIndex` | `search::score` without a `SEARCH` index on the field | `DEFINE INDEX … SEARCH` |
| `PrefixTooShort` | a prefix, infix or type-ahead under 3 characters | wait for more input |
| `NegationWithoutTerm` | `MATCHES 'NOT x'` alone | add a word to match |
| `NgramFilter` | an analyzer with an n-gram filter | use `MATCHES PREFIX / INFIX / FUZZY` |
| `NotAnEdgeTable` | `RELATE` or a traversal over a non-edge table | `DEFINE TABLE … EDGE` or a declared graph |
| `NotReadBySelect` | `SELECT` on a vault | `REVEAL field FROM v:id` |
| `VaultIsStrict`, `NotASecret` | an undeclared or non-secret field in a vault | declare it, with `SECRET` if it is one |
| `NoVaultRoot` | a vault before any passphrase exists | the first `UNSEAL VAULT WITH '…'` sets it |
| `QueueFieldIsTheEngines` | a write to `claimed_until` / `attempts` on a queue | let `CLAIM` and `RELEASE` set them |
| `HeldByAnother` | `RELEASE` of another consumer's hold | the `FOR CONSUMER` form, deliberately |
| `TopicIsAppendOnly` | `UPDATE` / `DELETE` of a topic message | append a correction |
| `EventFailed` | an event's body refused (class is the inner refusal's) | read the inner message; contention inside is still `retry` |
| `EventDepth` | events triggering events past 16 | give the body a `WHEN` excluding its own change |
| `VersionInsideTransaction`, `VersionInTheFuture`, `VersionReclaimed` | a historical read in the wrong place or time | read outside `BEGIN`, at a sequence that exists |
| `BelowLogStart` | a feed or log read below the pruned point | take a snapshot and start over from the present |
| `AnswerTooLarge` | an answer above the 16 MiB frame | ask for less, page, or stream a backup |

## Concurrency (`retry`)

| name | means |
|---|---|
| `CommitContention` | this commit couldn't be serialised against another |
| `Conflict` | a record you wrote was committed by someone else after your snapshot |
| `ShardMapMoved`, `AcrossSettling`, `AcrossReadTooOld` | cluster-side moments that pass |

Retry the **whole transaction**, re-reading what it depends on, a bounded number of times with a
little backoff. Never retry `invalid`, `forbidden` or `conflict` as if they were contention.

## Access

`NotSignedIn` (a closed store and no credential) and `RoleForbids` / `NotGranted` (you are signed in
and the answer is no) are the pair to keep apart: the first means sign in, the second means don't
try again. `SignInThrottled` means wait. `LastGrant` means the revoke would have widened the user;
use `DROP USER` to cut access.

## On a cluster

`NotAcknowledgedInTime` says the write **is committed** on the leader but not confirmed by enough
voters in time: it must not be retried as if nothing happened. `AcrossInDoubt` means read the
records back before deciding. `SpansLeaderships`, `NoLeadershipYet`, `NotWritable` and the rest are
explained in the tessaridb-cluster skill.

## Below the language

`Corruption`, `Truncated`, `Io`, `Busy`, `Unavailable`, `Internal` come from storage, not from your
script: read the node's log. `Stopped` is a store that couldn't make a write durable; it keeps
answering reads and takes writes again only after a restart. `UnstampedStore` is a directory holding data with no format stamp. A store written before 0.36.0
is refused at open ("written by an earlier storage engine … take a snapshot with the build that
wrote it"): move it with a snapshot ([operations.md](operations.md)).
