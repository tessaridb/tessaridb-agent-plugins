# Operating TessariDB OAuth

## The admin console and its API

`<ADMIN_URL>/admin/<company>/` is the console; `<ADMIN_URL>/admin/<company>/signin` signs an operator in
through that company's own issuer, as the client `admin-console`. A console session opens only for an
operator who signed in with two factors and holds a current role; it lasts at most 8 hours and ends after
30 minutes unused.

Every change is JSON from the console's own origin with a `reason` (1 to 500 characters) and an
`Idempotency-Key` header (16 to 128 of letters, digits, `-`, `_`); the same key within a day gets the first
answer back. Every change is recorded as `admin_action` with the operator, the role and the reason.

| Role | Reaches |
|---|---|
| `users` | accounts (`/api/users`: create, enrolment code or link, disable, enable, reveal an address), groups and their roles |
| `clients` | client registrations (`/api/clients`: list, register, remove) |
| `policy` | two-factor policy, self-registration, branding, mail wording |
| `keys` | signing keys (`/api/keys`: list, rotate, withdraw) |
| `audit` | the audit trail (`/api/audit?after=&limit=`) |
| `companies` | only in `system`: make, suspend and resume companies |

A role is granted by an operator who holds it, for `valid_days` (90 unless given, at most 365), never to
oneself. Addresses are masked (`k***@acme.example`) until revealed with a reason; lists page by cursor
with no total.

## Incidents

| Situation | Do |
|---|---|
| a signing key may be exposed | `POST /admin/<company>/api/keys/<kid>/withdraw` with a reason: it leaves the key set at once (a replacement is made first if nothing else could sign); tokens it signed stop verifying, within five minutes where a service cached the key set; refresh tokens stay valid |
| the KEK may be exposed | stop every node of the region, make a new 32-byte key, run `tessaridb-oauth reseal --old-kek <old file>` with `KEK` naming the new one until its last line says `"finished":true`, start the nodes; backups made before still open with the old key |
| a client's key leaked | `POST /admin/<company>/api/clients/<id>/remove`: grants and refresh families are revoked, its access tokens end by `access_tokens_end_by` (at most five minutes); register it again with a new key |
| an account is taken | `POST /admin/<company>/api/users/<user>/disable`: sessions end (clients told by back channel), refresh families revoked; enable later and have the owner reset the password, which keeps the second factor |

## Logs worth an alert

JSON on standard output; a line about something that happened carries an `event`.

- `ERROR`: `break_glass` (the emergency operator path ran), `audit_unrecorded` (an issuance could not be
  recorded and was not answered).
- `WARN`, on any occurrence: `code_replayed`, `refresh_reused`, `passkey_clone_suspected`,
  `recovery_code_used`, `operator_reads_high`.
- `WARN`, on a rise: `signin_rejected`, `breach_check_unchecked`, `authorization_refused`,
  `userinfo_refused`, `logout_untold`, `mail_abandoned`.

The audit trail is a TessariDB topic in each company's database, kept 400 days, never carrying a token,
code, verifier, assertion or proof.

## Sign-in protection

Reads, authorization requests, token requests and sign-in steps are counted per client address in the
store (`429` with `Retry-After` past a limit; `X-RateLimit-Limit`, `-Remaining`, `-Class` on every counted
answer). A wrong password is also counted per account and per pair: past a few failures that key is held for
a short, growing time that ends by itself, never a lockout. A wrong password and an unknown address get the
same `401`.

## Backup and restore

Everything is in the store, so a backup is a TessariDB snapshot taken while it serves:

```bash
TESSARIDB_PASSWORD=<owner password> tessaridb --at <store address> --user <owner> --backup oauth.snap
tessaridb --verify oauth.snap --backup-key-file <key file>     # where it was written, before keeping it
```

A snapshot does not hold `KEK` or `PEPPER`: keep both, with the store's encryption key, apart from the
snapshots. To restore, replay into an empty directory, serve it, and start the server with the same KEK,
pepper and `REGION`; a key withdrawn after the snapshot comes back as it stood, so withdraw it again
before serving traffic. Delete old snapshots on a schedule: each holds every password hash and sealed key.

## Upgrades

Pin the image (`tessaridb/oauth:0.1.0`). A start provisions every company again, so a newer release's tables
reach each of them; a start takes longer the more companies there are.
