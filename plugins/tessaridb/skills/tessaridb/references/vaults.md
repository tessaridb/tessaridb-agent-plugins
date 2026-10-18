# Vaults: secrets the database can't read back

Checked against TessariDB 0.36.1. Full detail: <https://docs.tessaridb.com/query-language/vaults>.

A vault stores records whose `SECRET` fields are encrypted under a key derived from a passphrase.
The key is in memory only while the process is unsealed; it is never written unwrapped, replicated
or put in a backup. **An unseal belongs to one process**, so each example below unseals first.

```tessariql
UNSEAL VAULT WITH 'the operator passphrase';
DEFINE VAULT team;
DEFINE FIELD login ON team TYPE string;
DEFINE FIELD token ON team TYPE string SECRET;
CREATE team:'github' = { login: 'boog', token: 'the secret' };
REVEAL token FROM team:'github';
INFO FOR SEAL;
SEAL VAULT;
```

## Unsealing

- On a store that has never held a vault, the first `UNSEAL` **sets** the passphrase (it answers
  `initialised`). A typo there is the passphrase until someone changes it.
- An unseal lasts ten minutes and then the store seals itself; use is not renewal. Start the node
  with `--unseal-for 1h` (or `TESSARIDB_UNSEAL_FOR`) for longer. A restart seals the store, so an
  unattended restart can't open secrets until somebody unseals again.
- Wrong passphrases are throttled (`PassphraseThrottled`).
- `CHANGE VAULT PASSPHRASE FROM '…' TO '…'` re-wraps the same key; nothing is re-encrypted, and a
  backup taken before the change still opens with the old passphrase.
- `INFO FOR SEAL` answers `{ state, seals_at, unseal_for }` for this process.

**Prefer the surface that keeps the passphrase out of statements.** A passphrase written in a
statement can end up in a console history or a client's error log. HTTP has `POST /vault/unseal`
(the body is the passphrase), `POST /vault/seal`, `POST /vault/passphrase` and `GET /vault`; the wire
protocol has a vault frame, and every client exposes it as functions ([clients.md](clients.md)).

## A vault with its own passphrase

```tessariql
DEFINE VAULT payroll PASSPHRASE 'the payroll passphrase';
DEFINE FIELD iban ON payroll TYPE string SECRET;
CREATE payroll:'ada' = { iban: 'DE00 0000' };
REVEAL iban FROM payroll:'ada';
SEAL VAULT payroll;
INFO FOR SEAL OF payroll;
```

Its key is under its own passphrase: the store's passphrase doesn't open it, and no authority in the
store does either. It can be declared on a store that was never unsealed. `INFO FOR VAULT v` shows
`custody: 'own'` or `'store'`, and which one a vault is can't change later. Declaring it is
possible without putting the passphrase in a script: `POST /vault/{ns}/{db}/{vault}/declare` with
the passphrase as the body, or the client's declare function (node 0.36.1, protocol minor 6).

## Writing and reading

```tessariql
UNSEAL VAULT WITH 'the operator passphrase';
UPDATE team:'github' SET token = 'the rotated secret';
REVEAL * FROM team:'github';
INFO FOR VAULT team RECORDS;
SEAL VAULT;
```

- A vault is strict: every field is declared, and only `SECRET` fields are encrypted. A field nobody
  declared is refused (`VaultIsStrict`), because it would otherwise be stored in the clear.
- `REVEAL field FROM v:id` (or `REVEAL *`) is the only way to read a secret. It names one record and
  takes no `WHERE` or `ORDER BY`, because a filter over a secret leaks one bit per statement.
  `SELECT` on a vault is refused, and so is an index on a secret field.
- Prefer `SET` / `MERGE` for rotation: replacing the whole record (`= { … }`) mints a new data key
  and clears the recipients.
- An edit can't compute from the record (`SET token = token` is refused,
  `VaultEditComputesFromTheRecord`).
- Record ids are not encrypted and are listed by `INFO FOR VAULT v RECORDS`, so never name a record
  after what it holds.

## Every read is recorded, or refused

`REVEAL` records who asked, which vault, record and fields, and whether it was served, **before** it
answers, and a read that can't be recorded is refused. `INFO FOR AUDIT` and
`INFO FOR AUDIT BY 'ada'` answer a store-wide administrator: "this credential leaked; what did it
open?"

## Sharing

`ADD RECIPIENT 'ada@example.com' TO team:'github' KEY 0x…` keeps a recipient's own material beside
the record; `REMOVE RECIPIENT …` takes it away. The store interprets neither the name nor the
material: the sharing scheme (whose public key wrapped what) is yours.

## What a vault does not defend against

It protects the **stored bytes**: someone holding the backend, a backup or a replica gets no secret.
It does not defend against: the memory of a running unsealed node; privileged code on the host; a
malicious operator; a client holding a valid credential; existence, size and access patterns;
timing; issuing short-lived credentials (it holds secrets, it doesn't mint them); and an attacker who
can **write** the backend, who can roll a rotated secret back. Rotate at the source.

## Destroying a secret is two acts

`DROP VAULT team` destroys the key, so every copy taken from then on is unreadable. A backup taken
**before** the drop still restores a vault that opens with the passphrase. Destroying a secret means
dropping the vault **and** expiring every backup that predates the drop, and rotating the credential
where it was issued.
