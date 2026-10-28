# Every statement, one line each

A quick lookup, checked against TessariDB 0.39.2. Each row links the reference that explains it.
The full list with every clause is <https://docs.tessaridb.com/reference/statements>.

There is no separate schema language, migration tool or admin API: defining a table, declaring a
user and taking a backup are all statements.

## Tenancy

| statement | does |
|---|---|
| `USE NAMESPACE prod DATABASE orders` | selects where the next statements run, for this connection |
| `DEFINE NAMESPACE prod` · `DEFINE DATABASE orders` | create; cluster clauses on the namespace are in the tessaridb-cluster skill |
| `DROP DATABASE orders` · `DROP NAMESPACE prod` | refused while they still hold something; there is no `CASCADE` |

## Structure ([language.md](language.md))

| statement | does |
|---|---|
| `DEFINE TABLE t (a string, b int)` | strict table; `SCHEMALESS`, `EDGE`, `IDENTITY uuid`, `EXPIRE AFTER 7d` are clauses |
| `DEFINE COLLECTION t` | any document shape; `EXPIRE` optional |
| `DEFINE FIELD f ON t TYPE string REQUIRED DEFAULT … ASSERT …` | declare one field |
| `ALTER TABLE t ADD FIELD … / ALTER FIELD … / DROP FIELD … / SET SCHEMAFULL / SET EXPIRE … / DROP EXPIRE` | change a table |
| `ALTER TABLE t RENAME TO u` · `ALTER TABLE t RENAME FIELD a TO b` · `ALTER FIELD f TYPE x USING expr` | rename a table or a field; convert stored values with a type |
| `DEFINE FIELD f ON t TYPE record REFERENCES u [ON DELETE REJECT \| CASCADE \| UNSET]` | a value must name a record of `u`; what deleting it does |
| `DEFINE INDEX i ON t FIELDS a, b [UNIQUE \| SEARCH \| SPATIAL \| VECTOR cosine \| CONTAINS]` | an index |
| `REBUILD INDEX i ON t` · `ANALYZE TABLE t` · `CHECK TABLE t` | rebuild (vector recall), statistics, find records that no longer fit |
| `DEFINE ANALYZER a FILTERS lowercase, ascii, stemmer` | how text becomes terms ([search.md](search.md)) |
| `DEFINE SEARCH s ON t FIELDS … ANALYZER a` · `DEFINE SYNONYMS` · `DEFINE STOPWORDS` | one ranked search over several fields/tables |
| `DEFINE VECTOR v DIMENSION n DISTANCE cosine` · `DEFINE GEO g` · `DEFINE GRAPH g` · `DEFINE EDGE e IN g FROM a TO b` | declared stores ([vectors-geo-graphs.md](vectors-geo-graphs.md)) |
| `DEFINE SPACE s [MAX n [EVICT NONE]]` · `DEFINE BUCKET b [MAX bytes]` | key-value and files ([spaces-queues-topics-series.md](spaces-queues-topics-series.md)) |
| `DEFINE QUEUE q TIMEOUT 30s [ATTEMPTS n] [PRIORITY BY f] [NOT BEFORE f] [DEDUPLICATE 10m] [DEAD LETTER TO topic]` | a work queue |
| `DEFINE TOPIC t [RETAIN 7d] [RETAIN BYTES n] [MAX BYTES n] [DEDUPLICATE 5m ON f]` · `DEFINE GROUP 'g' ON TOPIC t ACK DEADLINE 30s` | an event log, and a consumer group on it |
| `DEFINE SERIES s RETAIN 30d [TIME at]` · `DEFINE ROLLUP r FROM s WINDOW 1h BY k COMPUTE … RETAIN 365d` | time series and maintained per-window summaries |
| `DEFINE VIEW v [MATERIALIZED] AS SELECT …` | a named read |
| `DEFINE EVENT [OR REPLACE] e ON t FOR CREATE, UPDATE, DELETE [WHEN …] THEN …` | runs inside the writer's transaction |
| `DEFINE PARAM [OR REPLACE] $p VALUE …` | a named value the database holds |
| `DEFINE VAULT v [PASSPHRASE '…']` | secrets ([vaults.md](vaults.md)) |
| `DROP <kind> name [IF EXISTS]` | removes the definition; refused while something still depends on it |

Every `DEFINE` takes `IF NOT EXISTS`. A `DROP TABLE` releases the name and the records become
unreachable; a table redefined under the same name is a new, empty table.

## Records

| statement | does |
|---|---|
| `CREATE t = { … }` · `CREATE t:id = { … }` | write a new record (store-made or named id); never replaces |
| `INSERT INTO t (a, b) VALUES (…), (…)` | several records in one statement |
| `UPSERT t:id = { … }` | replace or create |
| `UPDATE t:id SET a = … / MERGE { … } / = { … } [WHERE cond]` | change one record; `= { … }` replaces it whole; `WHERE` is compare-and-set |
| `UPDATE t SET a = … / MERGE { … } WHERE cond [LIMIT n]` | change every match in one transaction; answers how many |
| `INSERT INTO t (a, b) SELECT x, y FROM …` | one record per record read |
| `DELETE t:id` · `DELETE FROM t WHERE … [LIMIT n]` · `DELETE FROM t:1..3` · `TRUNCATE t` | remove one, a matching set, a span, or every record |
| `RELATE a:1->e->b:2 [= { … }]` · `DELETE a:1->e->b:2` | write or remove an edge |
| `… RETURN BEFORE \| RETURN AFTER` | any write answers with the record |
| `SELECT … FROM … [WHERE] [GROUP BY … [HAVING]] [ORDER BY … [NULLS FIRST \| LAST]] [LIMIT] [START \| AFTER] [USING INDEX i] [TIMEOUT d]` | read |
| `… [LEFT \| RIGHT \| FULL] JOIN b ON … [JOIN c ON …]` | match on a value; outer joins keep what nothing matched |
| `WITH n AS (SELECT … LIMIT k) SELECT …` · `… UNION [ALL] \| INTERSECT \| EXCEPT …` · `x IN (SELECT y …)` | name a read, combine reads, compare with a read |
| `f() OVER ([PARTITION BY …] [ORDER BY …])` | a window value per record |
| `SAVEPOINT s` · `ROLLBACK TO s` · `RELEASE SAVEPOINT s` | roll back part of a transaction |
| `THROW 'message'` | abandon the whole transaction |
| `LET $x = …` · `RETURN expr` | bind a value for the rest of the script; answer with a value |

## Keys, files, queues and topics

| statement | does |
|---|---|
| `GET s:k` · `SET s:k = v [EXPIRE d] [IF ABSENT \| IF PRESENT \| IF = v]` · `DEL s:k` | key-value |
| `INCR s:k [BY n]` · `EXPIRE s:k d` · `PERSIST s:k` · `RETURN TTL s:k` · `KEYS FROM s [PREFIX p] [RANGE a..b] [AFTER k] [LIMIT n]` | counters, expiry, listing |
| `PUT b:'/path' = 0x…` · `READ b:'/path'` | files |
| `CLAIM [n] FROM q [WHERE …]` · `CLAIM q:id` · `RELEASE q:id [NOT BEFORE …]` · `RELEASE ALL FROM q` · `USE CONSUMER 'name'` | take and give back queue work; finish with `DELETE q:id` |
| `CREATE topic = { … }` · `READ FROM topic [AFTER n] [FOR CONSUMER 'c'] [LIMIT n]` | append and read |
| `ACK topic FOR CONSUMER 'g' AT 41, 42` · `NACK … AT … [DELAY d]` · `ALTER GROUP 'g' ON TOPIC t START AT n` | consumer groups |

## Transactions ([transactions-and-history.md](transactions-and-history.md))

`BEGIN` · `COMMIT` · `CANCEL` (discard without checking) · `VERIFY` (run every check, then discard).

## Access ([security.md](security.md), [vaults.md](vaults.md))

| statement | does |
|---|---|
| `DEFINE USER u [ON ns.db] ROLE owner \| editor \| viewer PASSWORD '…'` | the first user closes the store |
| `DEFINE USER u AUTHORITIES operate PASSWORD '…'` | by authority set instead of role |
| `ALTER USER u SET PASSWORD '…'` · `ALTER USER u SET ROLE …` · `DROP USER u` | change or remove |
| `GRANT read, write ON t [FIELDS a, b] TO u` · `REVOKE … ON t FROM u` | narrow a user to tables and fields |
| `GRANT manage ON NAMESPACE prod TO u` · `REVOKE … ON … FROM u` | authority over a reach (`STORE`, `NAMESPACE x`, `DATABASE x.y`) |
| `UNSEAL VAULT [v] WITH '…'` · `SEAL VAULT [v]` · `CHANGE VAULT [v] PASSPHRASE FROM '…' TO '…'` | the vault key in this process |
| `REVEAL f FROM v:id` · `REVEAL * FROM v:id` · `ADD RECIPIENT … TO v:id KEY 0x…` · `REMOVE RECIPIENT …` | read and share secrets |

## The node ([operations.md](operations.md))

| statement | does |
|---|---|
| `DEFINE NODE RETAIN 100000 RECORDS` · `DEFINE NODE RETAIN NONE` | how much log this machine keeps (100 000 by default; a prune is irreversible) |
| `BACKUP` (= `BACKUP STATE`) · `BACKUP LOG` · `BACKUP FROM n` · `BACKUP SCRIPT [OF NAMESPACE …]` · `… TO 'name'` | snapshot, log, script; `TO` writes into `--backup-dir` |
| `RESTORE SCRIPT FROM 'file'` | run a script from the backup folder; it only creates |
| `ALTER STORE FINALIZE FORMAT` | raise the on-disk format for good, so older builds can no longer open the store |
| `DEFINE REPLICA …` · `ALTER REPLICA …` · `DROP REPLICA …` · `DEFINE FAILOVER …` · `CREATE JOIN TOKEN …` · `REVOKE CERTIFICATE …` | cluster: see the tessaridb-cluster skill |
| `DEFINE TOPIC CONSUMER …` · `DEFINE KAFKA CONSUMER …` | stream ingestion into a table (at least once; the Kafka one needs a build with the `kafka` feature) |

## Looking

`EXPLAIN <read>` · `INFO FOR STORE | NAMESPACE | DATABASE | TABLE t | SEARCH s | GRAPH g | VECTOR v |
GEO g | USER u | USERS | ACCESS TO TABLE t | SEAL [OF v] | VAULT v RECORDS | NODE | TOPIC t |
VERSIONS OF t:id | HISTORY OF t:id | TOPIC CONSUMER c | KAFKA CONSUMER c`.

At the prompt, `.tables` runs `INFO FOR DATABASE`, `.d t` runs `INFO FOR TABLE t`, `.node` runs
`INFO FOR NODE`, and `.help` lists the rest.

```tessariql
DEFINE TABLE users (name string, email string);
DEFINE INDEX by_email ON users FIELDS email UNIQUE;
INFO FOR DATABASE;
INFO FOR TABLE users;
EXPLAIN SELECT * FROM users WHERE email = 'ada@example.com';
```
