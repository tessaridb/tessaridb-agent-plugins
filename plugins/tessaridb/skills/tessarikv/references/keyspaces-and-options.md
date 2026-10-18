# Keyspaces, options, presets, compaction and backpressure

Checked against `tessarikv` 0.1.0 (a FIFO keyspace named at open, a keyspace created while running,
a reopen without naming them refused `invalid_argument`, and `memtable_bytes(1)` refused
``invalid option `keyspace.memtable_bytes`: 1 is outside 65536..=4294967296``). Upstream:
<https://docs.tessaridb.com/kv/engine/keyspaces>, `/kv/operating/options`,
`/kv/engine/compaction-and-backpressure`.

## Keyspaces

Independent sets of keys in one database, each with its own options, in-memory tables, levels and
compactions. `KeyspaceId::DEFAULT` ("default") always exists. Up to 4096 keyspaces; names up to
255 bytes.

Use several when data wants different options (a FIFO cache beside leveled records), when you want to
drop a whole set at once, or both, since a batch stays atomic across keyspaces.

```rust
use tessarikv::{CompactionStyle, Db, DbOptions, KeyspaceOptions};

async fn open_with_sessions() -> tessarikv::Result<Db> {
    let sessions = KeyspaceOptions::builder().compaction(CompactionStyle::fifo()).build()?;
    let options = DbOptions::builder()
        .keyspace("sessions", sessions)
        .create_missing_keyspaces(true) // add it the first time
        .build()?;
    let db = Db::open("data/app", options).await?;
    let _sessions_id = db.keyspace("sessions"); // Some(id): resolve once, keep the id
    Ok(db)
}
```

- Every open must name every keyspace the database holds; a held one left out is refused, a named one
  it lacks is added only with `create_missing_keyspaces`.
- `db.create_keyspace(name, options).await?` returns a new id (recorded before it returns; later opens
  must name it). `db.drop_keyspace(id).await?` removes it with all its keys; later opens must not name
  it. The default keyspace is never dropped.
- `db.keyspace(name)` → `Option<KeyspaceId>`; `db.keyspaces()` lists them.
- Each open writes `OPTIONS-<n>` with the options it ran with. It is a record for people; the engine
  never reads it back.

## Database options (`DbOptions::builder()`)

| option | default | sets |
|---|---|---|
| `create_if_missing` / `error_if_exists` | `true` / `false` | create on an empty path / refuse an existing database |
| `storage` | disk | `DbOptions::in_memory()` for memory |
| `wal_segment_bytes` | 64 MiB | log segment size |
| `wal_recovery` | `PointInTime` | damaged log end: recover the prefix, or refuse (`Absolute`) |
| `block_cache_bytes` | 512 MiB | shared block cache; 0 disables |
| `background_threads` | 4 | flush and compaction threads |
| `compaction_bytes_per_second` | 0 (unpaced) | pace compaction output |
| `delayed_write_bytes_per_second` | 16 MiB/s | write pace while slowed down |
| `serializable_transactions` | `false` | allow `Isolation::Serializable` |
| `total_memtable_bytes` | 0 (no ceiling) | cap on all keyspaces' newest in-memory tables |
| `max_open_files` | 0 (no bound) | table files kept open |
| `max_manifest_bytes` | 64 MiB | manifest rewrite threshold; bounds open time |
| `statistics` | `false` | tickers and histograms |
| `encryption(provider, key_id)` / `encryption_cipher` | off / by processor | encryption at rest |
| `default_keyspace` / `keyspace(name, options)` / `create_missing_keyspaces` | — | keyspaces to open |

`options.to_builder()` derives a variant.

## Keyspace options (`KeyspaceOptions::builder()`)

| option | default | sets |
|---|---|---|
| `memtable_bytes` | 64 MiB (64 KiB … 4 GiB) | in-memory table size before freezing |
| `max_immutable_memtables` | 2 | frozen tables waiting for a flush |
| `block_bytes` / `block_restart_interval` | 4 KiB / 16 | data block size / keys between full keys |
| `bloom_bits_per_key` | 10 | filter size; 0 writes none |
| `compression` / `bottommost_compression` | `Lz4` / same | `None`, `Lz4`, `Snappy`, `Zstd`, `Deflate { level }` |
| `compaction` | leveled | `CompactionStyle::universal()`, `CompactionStyle::fifo()` |
| `level0_compaction_trigger` / `_slowdown_trigger` / `_stop_trigger` | 4 / 20 / 36 | level-0 tables |
| `soft_pending_compaction_bytes` / `hard_…` | 64 GiB / 256 GiB | compaction debt that slows / stops writes |
| `level_base_bytes` / `level_size_multiplier` / `target_file_bytes` | 256 MiB / 10 / 64 MiB | leveled shape |
| `max_compactions` / `max_subcompactions` | 4 / 4 | parallelism |
| `disable_auto_compactions` | `false` | for bulk loads |

## Presets

| preset | for | sets |
|---|---|---|
| `KeyspaceOptions::point_lookup()` | mostly point reads | 16 bloom bits per key |
| `KeyspaceOptions::write_heavy()` | mostly writes | 256 MiB memtables, up to four waiting |
| `KeyspaceOptions::bulk_load()` | one large load | 512 MiB memtables, up to six waiting, 64 KiB blocks |

Start from a preset, adjust with `to_builder()`.

## Compaction styles

- **Leveled** (default): non-overlapping levels below level 0, sized from the bottom up; few tables per
  read, little extra space, rewrites data once per level.
- **Universal**: sorted runs merged by size, everything into the bottom once the runs above reach
  `max_size_amplification_percent` (200) of it; fewer rewrites, more space (up to twice the data during
  a full merge) and more tables per read.
- **FIFO**: tables never merged; past `max_table_bytes` (1 GiB) the oldest are dropped. For data that
  may expire by age (metrics, caches). Data past the cap is lost.

`db.compact_range(keyspace, start, Some(end)).await` compacts a range now (`None` reaches the end). For a bulk load set
`disable_auto_compactions`, load, then compact; the level-0 triggers still hold writes.

## Backpressure

| signal | slow down at | stop at |
|---|---|---|
| level-0 tables | 20 | 36 |
| compaction debt | 64 GiB | 256 GiB |
| in-memory tables | — | active full and `max_immutable_memtables` frozen waiting |

While slowed, writes go at `delayed_write_bytes_per_second`. `WriteOptions::no_slowdown` turns the
wait into `Error::WriteStalled`. Time stalled is the `StallMicros` ticker.
