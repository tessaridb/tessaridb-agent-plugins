# Opening, writing and reading

Checked against `tessarikv` 0.1.0 (each snippet compiled and run in one program against a disk
database). Upstream: <https://docs.tessaridb.com/kv/start/getting-started>,
`/kv/engine/writes-and-durability`, `/kv/engine/reads-and-snapshots`; API on
<https://docs.rs/tessarikv>.

## Opening

```rust
use tessarikv::{Db, DbOptions, WalRecovery};

async fn open() -> tessarikv::Result<Db> {
    let options = DbOptions::builder()
        .block_cache_bytes(1 << 30)          // 1 GiB, shared by every keyspace
        .background_threads(8)               // flushes and compactions
        .wal_recovery(WalRecovery::Absolute) // refuse to open over a damaged log end
        .build()?;                           // an out-of-range value: Error::InvalidOptions
    Db::open("data/inventory", options).await
}
```

- `Db::open(path, options)`: creates the directory's database when it holds none
  (`create_if_missing`, default `true`; `error_if_exists` refuses an existing one).
- `DbOptions::in_memory()`: the same engine on process memory; the path only names it. It cannot be
  checkpointed (`unsupported`).
- A second open of an open directory → `Error::Locked` (code `locked`, category `Unavailable`,
  retryable once the holder closes).
- `db.close().await` drains and releases the lock.

## Writing: batches

```rust
use tessarikv::{Db, KeyspaceId, WriteBatch, WriteOptions};

async fn move_stock(db: &Db) -> Result<(), Box<dyn std::error::Error>> {
    let mut batch = WriteBatch::new();
    batch.put(KeyspaceId::DEFAULT, b"sku:1001", b"11 in stock")?;
    batch.delete(KeyspaceId::DEFAULT, b"reservation:77")?;
    // every key from "cart:42:" up to, not including, "cart:42;"
    batch.delete_range(KeyspaceId::DEFAULT, b"cart:42:", b"cart:42;")?;
    db.write(&batch, &WriteOptions::default()).await?;
    Ok(())
}
```

- `put` replaces a key's value; `delete` removes one key; `delete_range(start, end)` removes
  `[start, end)` (`start` below `end`), and a key written after it is visible again.
- A batch may name several keyspaces and is atomic across them and across a crash.
- Limits: key ≤ 8 MiB, value ≤ 1 GiB, encoded batch ≤ 2 GiB; past them `TooLarge` and the batch is
  unchanged.
- Batch methods return the table format's error type (not `tessarikv::Error`), hence the boxed error.

## Durability

| `Durability` | `write` returns when | survives |
|---|---|---|
| `Sync` (default) | the log record is on stable storage | power loss |
| `Buffered` | the log record is handed to the OS | a process crash; not a power loss until a later sync |
| `NoWal` | it is in the in-memory table, unlogged | nothing until its table is flushed |

```rust
use tessarikv::{Durability, WriteOptions};

fn buffered() -> WriteOptions {
    let mut options = WriteOptions::default();
    options.durability = Durability::Buffered;
    options
}
```

- Concurrent `Sync` writers share one log sync.
- `db.sync_wal().await` makes every earlier batch (Buffered too) durable with one sync: write
  `Buffered`, then sync at your own commit point.
- `db.flush().await` writes every earlier batch into table files.
- When compaction falls behind, writes slow and then stop (see keyspaces-and-options.md). With
  `WriteOptions::no_slowdown = true` a write fails `Error::WriteStalled` (retryable) instead of
  waiting.
- If a log write or sync, a flush or a compaction fails, the database stops accepting writes;
  `db.background_error()` returns the failure; reads go on; reopen to write again.

## Recovery after a crash

Opening replays the log above the last flush. `DbOptions::wal_recovery`:

- `WalRecovery::PointInTime` (default): recover every batch up to the first damaged frame, discard
  the rest, open. Every write acknowledged at a durability that survives that crash is there.
- `WalRecovery::Absolute`: refuse to open over any damaged frame and leave the files for an operator.

## Reading

```rust
use tessarikv::{Db, KeyspaceId, ReadOptions};

async fn reads(db: &Db) -> tessarikv::Result<()> {
    let one = db.get(KeyspaceId::DEFAULT, b"sku:1001", &ReadOptions::default()).await?; // None if absent
    let keys: [&[u8]; 3] = [b"sku:1001", b"sku:1002", b"sku:1003"];
    let many = db.multi_get(KeyspaceId::DEFAULT, keys, &ReadOptions::default()).await?; // in key order given
    let _ = (one, many);
    Ok(())
}
```

Every read sees one snapshot: never half a batch; a multi-key read sees all keys at one moment.

### A range, page by page

`scan(keyspace, start, end, limit, options)` → `ScanPage { entries, next }`: up to `limit` pairs,
ascending, from `start` up to but not including `end` (`None`: the end of the keyspace). `next` is the
key the next page starts at, `None` when done.

```rust
use tessarikv::{Db, KeyspaceId, ReadOptions};

async fn every_sku(db: &Db) -> tessarikv::Result<usize> {
    let options = ReadOptions::default();
    let mut start = b"sku:".to_vec();
    let mut seen = 0;
    loop {
        let page = db.scan(KeyspaceId::DEFAULT, &start, Some(b"sku;"), 100, &options).await?;
        seen += page.entries.len();
        match page.next {
            Some(next) => start = next,
            None => return Ok(seen),
        }
    }
}
```

Each page is its own snapshot. `multi_scan(keyspace, ranges, options)` reads several
`ScanRange { start: &[u8], end: Option<&[u8]>, limit }` at one snapshot, one page each.

### Iterators

`db.iter(keyspace, &options)?` returns a `DbIterator` positioned nowhere: `seek_to_first`,
`seek_to_last`, `seek(key)` (first at or after), `seek_for_prev(key)` (last at or before), then
`next`/`prev` (async), and `valid`, `key`, `value`.

```rust
use tessarikv::{Db, KeyspaceId, ReadOptions};

async fn users(db: &Db) -> tessarikv::Result<Vec<Vec<u8>>> {
    let options = ReadOptions::default().with_prefix(b"user/");
    let mut iterator = db.iter(KeyspaceId::DEFAULT, &options)?;
    let mut keys = Vec::new();
    iterator.seek_to_first().await?;
    while iterator.valid() {
        keys.push(iterator.key().to_vec());
        iterator.next().await?;
    }
    Ok(keys)
}
```

An iterator holds its snapshot while it lives.

### Snapshots

```rust
use tessarikv::{Db, KeyspaceId, ReadOptions};

async fn consistent_pair(db: &Db) -> tessarikv::Result<(Option<Vec<u8>>, Option<Vec<u8>>)> {
    let snapshot = db.snapshot()?;
    let options = ReadOptions::default();
    let order = snapshot.get(KeyspaceId::DEFAULT, b"order:9", &options).await?;
    let stock = snapshot.get(KeyspaceId::DEFAULT, b"sku:1001", &options).await?;
    Ok((order, stock))
}
```

A `Snapshot` offers `get`, `multi_get`, `scan`, `multi_scan`, `iter`; `sequence()` is where it reads.
While it lives compaction keeps every version it can see. `db.oldest_snapshot()` reports the oldest
held (snapshot, iterator or transaction); it walks them all, so read it as a metric.

### Read options

| field | default | effect |
|---|---|---|
| `verify_checksums` | `true` | verify each table block read; off, corruption may decode to wrong data |
| `fill_cache` | `true` | keep loaded blocks in the cache; `false` for a one-off scan |
| `lower_bound` / `upper_bound` | `None` | an iterator's inclusive / exclusive bound (iterators only) |

`with_prefix(p)` sets both bounds to the keys starting with `p`.

`db.approximate_size(keyspace, start, Some(end))?` estimates a range's bytes in table files from the
indexes, without reading data.
