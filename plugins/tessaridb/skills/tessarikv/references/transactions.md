# Transactions

Checked against `tessarikv` 0.1.0 (the snippets ran; two transactions writing one key: the second
commit answered code `conflict`, category `Conflict`, retryable). Upstream:
<https://docs.tessaridb.com/kv/engine/transactions>.

A transaction reads at its own snapshot plus its own writes, keeps writes private, and commits them
as one atomic batch.

```rust
use tessarikv::{Db, Error, KeyspaceId, ReadOptions, WriteOptions};

async fn reserve(db: &Db) -> tessarikv::Result<bool> {
    let mut transaction = db.begin()?;
    let stock = transaction.get(KeyspaceId::DEFAULT, b"sku:1001", &ReadOptions::default()).await?;
    if stock.is_none() {
        return Ok(false); // dropping the transaction discards it
    }
    transaction.put(KeyspaceId::DEFAULT, b"reservation:78", b"sku:1001")?;
    match transaction.commit(&WriteOptions::default()).await {
        Ok(_sequence) => Ok(true),
        Err(Error::Conflict) => Ok(false), // someone wrote a key we write after we began; nothing written
        Err(other) => Err(other),
    }
}
```

- Reads: `get`, `multi_get`, `scan`, `multi_scan`. Writes: `put`, `delete`, `delete_range` (sync,
  return `tessarikv::Error`).
- `commit(&WriteOptions)` is atomic with the durability named and returns the sequence number.
- Dropping without commit discards it.

## Conflicts: first committer wins

At commit, if any key the transaction writes was written by someone else after it began, the commit
is refused `Error::Conflict` and writes nothing. Re-run from `begin` with a bound on attempts. The
check takes no lock.

## Isolation

| `Isolation` | protects against | admits |
|---|---|---|
| `Snapshot` (default) | lost updates (two writers of one key) | write skew: each reads what the other writes |
| `Serializable` | write skew too: also refused when a key it read, or a range it scanned, changed after it began | nothing; commits behave as if one at a time |

```rust
use tessarikv::{Db, DbOptions, Isolation, TransactionOptions};

async fn open_serializable() -> tessarikv::Result<Db> {
    let options = DbOptions::builder().serializable_transactions(true).build()?;
    Db::open("data/ledger", options).await
}

fn serializable() -> TransactionOptions {
    let mut options = TransactionOptions::default();
    options.isolation = Isolation::Serializable;
    options
}
// let transaction = db.begin_with(&serializable())?;
```

Serializable needs `serializable_transactions` at open; every write then also records its key
prefixes, a few more atomic updates per write.

Use it for check-then-write rules ("at most one active session per user", "balance never below
zero") where two transactions read the same facts and write different keys.

## Savepoints

```rust
use tessarikv::{Db, KeyspaceId, WriteOptions};

async fn partial(db: &Db) -> tessarikv::Result<()> {
    let mut transaction = db.begin()?;
    transaction.put(KeyspaceId::DEFAULT, b"order:9", b"placed")?;
    let mark = transaction.savepoint();
    transaction.put(KeyspaceId::DEFAULT, b"coupon:9", b"applied")?;
    transaction.rollback_to(mark); // the coupon is gone, the order stays
    transaction.commit(&WriteOptions::default()).await?;
    Ok(())
}
```

A transaction holds its snapshot until commit or drop; a long-lived one keeps old versions on disk.
