# Transactions, scripts and history

Checked against TessariDB 0.38.2. Full detail: <https://docs.tessaridb.com/query-language/transactions>
and `/query-language/paging-and-history`.

## A transaction

```tessariql
DEFINE TABLE accounts (owner string, balance int);
BEGIN;
CREATE accounts:1 = { owner: 'ada', balance: 100 };
CREATE accounts:2 = { owner: 'grace', balance: 0 };
COMMIT;
```

```tessariql
BEGIN;
UPDATE accounts:1 SET balance = 60;
UPDATE accounts:2 SET balance = 40;
COMMIT;
```

- `BEGIN … COMMIT` applies everything or nothing. `CANCEL` discards the work.
- `VERIFY` runs every check a commit would and then **discards** the work: a dry run. Don't
  write `VERIFY` where you meant `COMMIT`, or the writes will vanish.
- A definition commits with the writes beside it, so a migration can create a table and fill it
  atomically.
- Isolation is snapshot isolation; the database is the unit a transaction spans.
- A transaction left open when the script or connection ends is discarded.
- Two transactions that write the same record are told so at commit (`CommitContention` /
  `Conflict`). The store doesn't wait or retry for you. Retry refusals of the class `retry`
  explicitly, with a bound, and treat every other refusal as final.
- There is one boundary, not a stack: `BEGIN` twice is `NestedTransaction`, and `COMMIT` with nothing
  open is `NoOpenTransaction`. Part of a transaction rolls back to a `SAVEPOINT` (below).
- The unit is the **database**: a table, a space, a queue and a topic in one database commit
  together.
- On a cluster, a transaction over ranges two nodes lead must say `COMMIT ACROSS LEADERS` (see the
  tessaridb-cluster skill).

`THROW 'message'` refuses on purpose, inside a transaction to abandon it:

```tessariql
-- refused: Thrown
BEGIN;
UPDATE accounts:1 SET balance = 0;
THROW 'balance would go negative';
COMMIT;
```

`SAVEPOINT name` marks a place inside `BEGIN … COMMIT`; `ROLLBACK TO name` puts back what the
transaction had done there and keeps the savepoint; `RELEASE SAVEPOINT name` forgets it and keeps
the work:

```tessariql
BEGIN;
CREATE accounts:3 = { owner: 'kate', balance: 5 };
SAVEPOINT before_four;
CREATE accounts:4 = { owner: 'ken', balance: 5 };
ROLLBACK TO before_four;
COMMIT;
```

Only `accounts:3` lands. Outside a transaction a savepoint is `SavepointOutsideATransaction`, an
unknown name is `NoSuchSavepoint`, and a rollback over a queue claim (or work sent to other
leaders) taken since the savepoint is refused, `SavepointCrossesClaim`, rather than half done.

## A script is not a transaction

A file (`-f`) or piped input runs statement by statement. It **stops at the first refusal and
keeps everything before it**. A one-line `-e '…'` string is parsed whole first, so one syntax error
means nothing in it runs. Neither is all-or-nothing on its own. Put the part that must be atomic
inside `BEGIN … COMMIT`, and rehearse it with `VERIFY`.

In deployment scripts use `IF NOT EXISTS` on every `DEFINE`, so a restart can re-run the script.

## Paging

Page with `AFTER` the last record you saw, never with a growing `START`:

```tessariql
SELECT * FROM accounts ORDER BY owner LIMIT 1;
SELECT * FROM accounts ORDER BY owner AFTER accounts:1 LIMIT 1;
```

When the order can't seek to the anchor, the read walks and says so in a note ("this page was
reached by reading the records rather than seeking"). Same answer, but the cost of the whole read:
fine in development, quadratic in production. Order by the identity or by an indexed field.

## Reading the past

```tessariql
SELECT * FROM accounts:1 VERSION 4;
INFO FOR HISTORY OF accounts:1;
INFO FOR VERSIONS OF accounts:1;
```

- `VERSION n` reads the store as it stood at record version `n`, the store's own commit counter.
  It is a sequence, never a timestamp. A version that hasn't happened yet is refused, and the
  refusal names the current one.
- The schema is read at that version too: a table defined later is unknown there.
- A historical read is served by a **plain** value index (it keeps retired entries since
  0.34.0-beta, re-testing each candidate at the version), so `USING INDEX` holds on it. A `UNIQUE`,
  full-text, spatial, containment or vector index is not used at an earlier version, and neither is
  a plain one beyond what housekeeping kept; `USING INDEX` then is `IndexNotUsed`.
- `VERSION` can't run inside a transaction (`VersionInsideTransaction`) and can't be combined with
  `STALENESS`.
- `INFO FOR HISTORY OF r` lists every write to one record, newest first, each with the value it
  became. Its `at` is the write's position in that database's log, **not** a number to pass to
  `VERSION`: the log counts this database's commits, the version counts every commit in the store.
  Read `complete` before trusting the oldest entry. `false` means the walk stopped at its bound or
  at a pruned log.
- `INFO FOR VERSIONS OF r` answers whether a record is contested right now (multi-master), and its
  current version.
- Old versions are reclaimed after a while. A read below the reclaim floor is refused
  (`VersionReclaimed`) rather than answered from what is left.
