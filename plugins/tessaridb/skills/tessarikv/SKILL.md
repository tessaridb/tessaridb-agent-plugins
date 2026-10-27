---
name: tessarikv
description: Use TessariKV, the embedded LSM key-value storage engine in pure Rust that TessariDB runs on, from your own Rust program. Use when adding the tessarikv crate, opening a database on disk or in memory, writing batches, choosing durability, reading keys, ranges, iterators and snapshots, running snapshot or serializable transactions, using keyspaces, choosing options, compaction styles and presets, encrypting at rest, taking checkpoints, reading statistics, upgrading across releases, or handling a tessarikv::Error. It is a library on your tokio runtime, not a server; for the TessariDB database itself use the tessaridb skill.
---

# TessariKV

TessariKV is an embedded key-value engine (a log-structured merge tree) written in pure Rust, and the
storage engine under TessariDB from 0.36. It is a **library**: no server, no protocol. Your program
links it, opens a directory, and reads and writes byte-string keys.

Checked against **`tessarikv` 0.1.2** from crates.io (Rust 1.89+, tokio): every example in these files
was compiled and run. From 0.1.0 the **on-disk format is stable**; the API may still change in a minor
release before 1.0. Pin the version: `tessarikv = "=0.1.2"` or `"0.1"`.

## Pick the reference for the task

| Task | Read |
|---|---|
| Add the crate, open, write batches, durability, reads, scans, iterators, snapshots | [references/reads-and-writes.md](references/reads-and-writes.md) |
| Transactions, conflicts, serializable, savepoints | [references/transactions.md](references/transactions.md) |
| Keyspaces, every option, presets, compaction styles, backpressure | [references/keyspaces-and-options.md](references/keyspaces-and-options.md) |
| Checkpoints, verify, destroy, statistics, encryption, upgrades, errors | [references/operations.md](references/operations.md) |

## Start here

```bash
cargo add tessarikv
cargo add tokio --features macros,rt-multi-thread
```

```rust
use tessarikv::{Db, DbOptions, KeyspaceId, ReadOptions, WriteBatch, WriteOptions};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let db = Db::open("data/inventory", DbOptions::default()).await?; // created if empty

    let mut batch = WriteBatch::new();
    batch.put(KeyspaceId::DEFAULT, b"sku:1001", b"12 in stock")?;
    batch.put(KeyspaceId::DEFAULT, b"sku:1002", b"out of stock")?;
    db.write(&batch, &WriteOptions::default()).await?; // durable when it returns

    let value = db.get(KeyspaceId::DEFAULT, b"sku:1001", &ReadOptions::default()).await?;
    assert_eq!(value.as_deref(), Some(&b"12 in stock"[..]));

    db.close().await?;
    Ok(())
}
```

For tests and caches, `DbOptions::in_memory()` runs the same engine with nothing written to disk.

## Rules that prevent quiet mistakes

1. **Run it on your tokio runtime.** Every call that can touch storage is `async`; the library never
   creates a runtime. Do not wrap it in a private runtime and `block_on` it from async code.
2. **One `Db` per directory.** A second open of the same path, in this process or another, is refused
   `Locked`. Share one handle between tasks (`Arc<Db>`; every method takes `&self`).
3. **Close it.** `db.close().await` finishes a running flush, syncs every acknowledged write and
   releases the lock. Dropping it leaves the log writer finishing unobserved.
4. **`WriteOptions::default()` is `Durability::Sync`.** `Buffered` survives a process crash but not a
   power loss until a later `db.sync_wal()`; `NoWal` survives nothing until a flush.
5. **A batch is atomic, across keyspaces and crashes.** Group the puts and deletes that must land
   together into one `WriteBatch`; separate writes are separate commits.
6. **`WriteBatch` methods return the format crate's error type**, which `tessarikv::Error` does not
   convert from: return `Box<dyn std::error::Error>` where you build batches.
7. **An absent key is `Ok(None)`,** never an error.
8. **Each `scan` page is its own snapshot.** For several pages at one moment, scan through
   `db.snapshot()`.
9. **A held snapshot, iterator or transaction keeps old versions on disk.** Drop them; watch
   `db.oldest_snapshot()` as a metric (not per request).
10. **Snapshot isolation admits write skew.** When two transactions each read what the other writes,
    open with `serializable_transactions(true)` and begin with `Isolation::Serializable`.
11. **`Error::Conflict` means nothing was written.** Re-run the whole transaction from `begin`; the
    engine never retries for you.
12. **Name every keyspace at every open.** The database records which keyspaces it holds, not their
    options; an open that omits one is refused, and a new one is added only with
    `create_missing_keyspaces(true)`.
13. **After a background failure, writes stop until reopen.** `db.background_error()` says why; reads
    still work. Do not loop on retries.
14. **Branch on `error.category()` / `code()` / `is_retryable()`,** never on the message.
15. **Upgrading is one-way.** Opening stamps the release's store format; take `db.checkpoint(dir)`
    first and keep it until the new release has run.

## Related skills

- `tessaridb` — the database built on this engine; you do not need this skill to use TessariDB.
