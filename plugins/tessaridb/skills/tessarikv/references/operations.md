# Operations: checkpoints, verification, statistics, encryption, upgrades, errors

Checked against `tessarikv` 0.1.0 (checkpoint taken and opened as its own database, `verify_checksums`
passed, `destroy` removed the copy, an encrypted database refused a wrong key with code `wrong_key`,
a memory database's checkpoint refused `unsupported`). Upstream:
<https://docs.tessaridb.com/kv/operating/operations>, `/kv/operating/encryption-at-rest`.

## Checkpoints (backups)

```rust
use tessarikv::Db;

async fn backup(db: &Db) -> tessarikv::Result<()> {
    db.checkpoint("backups/2026-10-17").await // empty or absent directory
}
```

A consistent copy holding every batch committed before the call; in-memory batches are flushed
first, then the table files of that moment are copied with a manifest, so the copy needs no log. Reads
and writes continue meanwhile. The copy opens as its own database with the same options (and the same
key provider when encrypted). A memory database cannot be checkpointed.

## Verify and destroy

- `db.verify_checksums().await` re-reads every table file and checks each block; a failure is
  `Corruption` naming file and offset. Restore, do not retry.
- `Db::destroy(path).await` removes every engine file in a crash-safe order; an open database is
  refused.

## Statistics

```rust
use tessarikv::{Db, Histogram, Ticker};

fn report(db: &Db) {
    if let Some(stats) = db.statistics() { // None unless opened with .statistics(true)
        let hits = stats.ticker(Ticker::BlockCacheHit);
        let misses = stats.ticker(Ticker::BlockCacheMiss);
        let p99 = stats.histogram(Histogram::GetMicros).quantile(99, 100);
        println!("block cache {hits} hits, {misses} misses; get p99 {p99} µs");
    }
}
```

`statistics()` returns the counts at the moment it is called; call it again for fresh numbers.
Tickers (since open): `GetCalls`, `MemtableHit`, `MemtableMiss`, `BlockCacheHit`, `BlockCacheMiss`,
`BlockBytesRead`, `BloomUseful`, `BloomMaybe`, `KeysWritten`, `BytesWritten`, `WalBytes`, `WalSyncs`,
`StallMicros`, `FlushBytes`, `CompactionBytesRead`, `CompactionBytesWritten`, `CompactionKeysDropped`.
Histograms (latest interval): `GetMicros`, `WriteMicros`.

## Watching for trouble

- `db.background_error()` is `Some` once a log write, flush or manifest edit failed: writes refused
  until reopen, reads work. A failed compaction is retried after a growing wait instead (from 0.1.2),
  counted by `CompactionFailures`.
- `db.oldest_snapshot()` far behind a new snapshot's `sequence()`: something holds an old snapshot.
- `StallMicros` growing: compaction is behind.

## Encryption at rest

Every data and metadata file (tables, logs, manifests, the options record) is encrypted and
authenticated, each under its own key derived from a 32-byte root key your `KeyProvider` returns by id.
The database stores no key.

```rust
use std::sync::Arc;
use tessarikv::{Db, DbOptions, KeyProvider, RootKey};

struct Keys {
    current: [u8; 32],
}

impl KeyProvider for Keys {
    fn root_key(&self, key_id: u32) -> Option<RootKey> {
        (key_id == 1).then(|| RootKey::new(self.current))
    }
}

async fn open_sealed(root: [u8; 32]) -> tessarikv::Result<Db> {
    let options = DbOptions::builder()
        .encryption(Arc::new(Keys { current: root }), 1) // new files use key id 1
        .build()?;
    Db::open("data/sealed", options).await
}
```

- Load the root key from your own secret store. The provider is called on a blocking thread at open
  and whenever a file is opened; answer from memory where you can.
- Cipher: AES-256-GCM where the processor has AES instructions, else ChaCha20-Poly1305;
  `encryption_cipher(Cipher::Aes256Gcm)` pins one. Each file names its cipher.
- A wrong key, or a provider lacking an id a file names, is refused before any file is read
  (`wrong_key`, `key_not_found`).
- Rotation: add the new root key under a new id (keep the old), open with the new id; new files take
  it and compaction rewrites tables over time; keep the old key while any file names it.
- Not hidden: file names and sizes, block/frame/edit sizes, and each logged batch's sequence number.

## Upgrading and the file format

- Each database records a **store format** (`1` in 0.1.0). A release reads its own and every earlier
  one, so a database written by 0.1.0 opens in later releases.
- A database in a later store format is refused at open `UnsupportedFormat` (code
  `unsupported_format`, `Validation`), before anything is read; open it with the release that wrote it
  or a later one.
- Opening stamps the opening release's format: moving forward is one-way. Checkpoint first, keep the
  copy until the new release has run.
- A 0.0.x database (format 0) opens in 0.1.0; after that, 0.0.x no longer opens it.

## Errors

`tessarikv::Error` with `category()`, a stable `code()` and `is_retryable()` (true for `Locked`,
`WriteStalled`, `Conflict` and interrupted I/O). Branch on these, never on the message. The mapping
below is the crate's own (`Error::category`, 0.1.0):

| `ErrorCategory` | codes | do |
|---|---|---|
| `Validation` | `invalid_options`, `invalid_argument`, `unknown_keyspace`, `unsupported`, `unsupported_format`, `too_large`, `wrong_key` | fix the call; retrying changes nothing |
| `NotFound` | `not_found` (a file the operation needs), `key_not_found` (an encryption key id the provider lacks) | check the path or the provider |
| `Conflict` | `conflict` (retryable), `already_exists` | re-run the transaction / pick another name |
| `Unavailable` | `locked`, `write_stalled` (both retryable) | retry after the holder closes / after waiting |
| `Corruption` | `corruption`, `short_read` (file and offset named) | stop using it, `verify_checksums`, restore |
| `Io` | `io`, and the fail-stop `log_failed`, `flush_failed`, `compaction_failed` | check the disk; after a fail-stop code, read what you need, close, reopen |
| `ShutDown` | `closed` | open again |
| `Internal` | `memtable`, `sequence_exhausted`, `read_failed` | report it |

`ErrorCategory` also has `Timeout` and `ReadOnly`; no 0.1.0 error carries them, but match them anyway
(the enum is non-exhaustive). An absent key is `Ok(None)`, not an error. A `Corruption` message names
where, never the stored bytes.
