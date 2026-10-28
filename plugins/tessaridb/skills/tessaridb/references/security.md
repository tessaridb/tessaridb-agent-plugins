# Users, authority, grants, TLS and encryption at rest

Checked against TessariDB 0.39.2. Full detail: <https://docs.tessaridb.com/security/users>,
`/security/authority`, `/security/grants`, `/security/encryption-in-transit`,
`/security/encryption-at-rest`.

## The open store, and the statement that closes it

**A store with no users is open to anyone who can reach it**, for reads and writes, and
`GET /backup` returns the whole store without a credential. The first `DEFINE USER` closes it, and
**from that statement on every statement needs a signed-in user**, even on a local store.

So declare the owner first and the other users in the same transaction (only an owner may declare
users, so a script that declares an editor first can't declare the owner afterwards):

```tessariql
DEFINE COLLECTION orders;
BEGIN;
DEFINE USER root ROLE owner PASSWORD 'the longest one of all';
DEFINE USER writer ON skill.skill ROLE editor PASSWORD 'another long one';
DEFINE USER reader ON skill.skill ROLE viewer PASSWORD 'a long enough one';
GRANT read, write ON orders TO writer;
GRANT read ON orders FIELDS total TO reader;
COMMIT;
```

After that, sign in: `TESSARIDB_PASSWORD='…' tessaridb ./data --user root` (or `--at host:port
--user root`). **The password always comes from the environment, never from an argument**, which
the process table would publish. Then check what you declared:

```tessariql
INFO FOR USER writer;
INFO FOR USERS;
INFO FOR ACCESS TO TABLE orders;
```

The container does the first step from `TESSARIDB_INITIAL_USER` and `TESSARIDB_INITIAL_PASSWORD`
(set both or neither; one alone refuses to start). They apply once, to a store with no users, and
are not a password reset. **There is no back door**: a lost owner password means a restore from
backup.

## Roles, kinds and reaches

| role | may |
|---|---|
| `viewer` | read what its tenancy holds |
| `editor` | read and write records, and define structure |
| `owner` | everything, including declaring users |

`ON prod.orders` confines a user to one database; without `ON`, the user belongs to the store. A
store-wide owner is what `BACKUP` needs.

Roles are shorthands for **authority sets**. An authority is a **kind** held over a **reach**:

| kind | means |
|---|---|
| `read` | read records |
| `write` | write records (a write that answers a record, such as `RETURN BEFORE`, also needs `read`) |
| `manage` | create and drop the container's children and define structure on them |
| `govern` | declare users and move authority around |
| `operate` | topology, replicas and backups: running the thing, not using it |
| `replicate` | collect the log as a peer; **store-wide only** |

Reaches are `STORE`, `NAMESPACE x` and `DATABASE x.y`; a kind held at a container holds everything
inside it. No kind implies another, so `write` over a namespace does not let anyone create or drop
its databases.

```tessariql
DEFINE USER ops AUTHORITIES operate PASSWORD 'a long operator one';
DEFINE USER ingest ON skill.skill AUTHORITIES write PASSWORD 'a long ingest one';
GRANT manage ON DATABASE skill.skill TO ops;
REVOKE manage ON DATABASE skill.skill FROM ops;
```

`ops` runs the node and reads no records; `ingest` writes into one database and can't define a
table there. Nobody can hand out an authority they don't hold.

## Grants narrow a user to tables and fields

- `GRANT read, write ON orders TO writer` reduces `writer` to exactly what is granted. **A user
  with even one grant reaches only what was granted.**
- `FIELDS` goes with `read` only: a whole-record write by someone who sees three of eight fields
  would erase the other five.
- **Revoking the last grant is refused** (`LastGrant`), because going from one grant to none would
  widen the user back to their whole role. To cut someone off, `DROP USER`.
- A `GRANT` or `REVOKE` takes effect on the very next statement, even on an open connection.
- There are no custom roles, groups, inheritance or deny rules: grant less instead.
- `INFO FOR ACCESS TO TABLE t` answers who reaches a table when an incident starts from the data.

## Passwords and sign-in

- Passwords are stored as Argon2id and print back as `<redacted>`. `PASSHASH '$argon2id$…'`
  restores a user from a backup script without knowing the password.
- Repeated failures are throttled, not locked out: 3 free, then 250 ms doubling up to 30 s
  (`SignInThrottled`, distinct from `SignInRefused`). On a cluster the budget is the cluster's.
- At most 24 password checks run at once. Over HTTP, exchange the password once at
  `POST /session` for a 12-hour token; `DELETE /session` hands it back.
- Changing a user's password or role, or dropping them, kills their tokens on the next request.
- `ALTER USER ada SET PASSWORD '…'` changes one thing at a time.
- `ALTER USER ada SET LOCKED` takes access away and keeps everything else: sign-in is refused in the
  words of a wrong password, an open session is refused on its next statement, tokens die, and their
  consumers stop. `SET UNLOCKED` restores the same password, role and grants. Use it rather than a
  password rotation or a drop when the access must come back. `INFO FOR USER` reports `locked`.

## TLS for clients

- A node given `--tls-cert` and `--tls-key` (or `TESSARIDB_TLS_CERT` / `TESSARIDB_TLS_KEY`)
  speaks TLS 1.3 on the wire port, HTTP and the WebSocket, and nothing else. The files are re-read
  when they change, so a renewed certificate needs no restart.
- **Without them a node serves in the clear** and says so at start, including whether it is
  reachable beyond this machine. `--require-client-tls` (or `TESSARIDB_REQUIRE_CLIENT_TLS=1`)
  makes it refuse to start instead. `INFO FOR NODE` reports `clients: { tls, required }`.
- A key file anyone else may read stops the node at start: `chmod 600` it (in the container, owned
  by uid 10001, or root-owned mode 440 readable by the node's group).
- Clients verify the chain and host name with no off switch ([clients.md](clients.md)).
- A browser distrusts a private authority: for the console use `localhost` or an SSH tunnel, a
  publicly trusted certificate, or a TLS proxy in front of an HTTP port bound to loopback.
- Nodes of a cluster always speak mutual TLS to each other (tessaridb-cluster skill).

## Encryption at rest

`--encryption-key-file key` (32 bytes from `openssl rand 32`, mode 600; or
`TESSARIDB_ENCRYPTION_KEY_FILE`) encrypts the store's files and seals every backup the node writes.

- A store opens only the way it was created: encrypted with its key, or not at all. **A lost key is
  a lost store.** Keep the key apart from the backups.
- A sealed backup opens only with its key. To move a store to a new key, restore with
  `--backup-key-file old.key` into a store created with the new `--encryption-key-file`.
- It protects files and backups at rest. It does not protect a running node's memory, and a vault
  is still the place for secrets the database itself must not read back ([vaults.md](vaults.md)).
