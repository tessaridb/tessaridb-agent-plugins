# Running and configuring TessariDB OAuth

The server reads its configuration from the environment at start, checks all of it, and refuses to start
naming the variable when anything is missing or does not fit. A `.env` file in the working directory is
read first, for development only. Every name below carries the prefix `TESSARIDB_OAUTH_`.

## Variables

| Variable | Meaning | Default |
|---|---|---|
| `PUBLIC_URL` | the https base URL; company `acme`'s issuer is `<PUBLIC_URL>/acme`; its host is the passkey relying party | required |
| `PUBLIC_ADDRESS` | where the public listener binds | `0.0.0.0:8443` |
| `ADMIN_URL` | the console's base URL, at another origin than `PUBLIC_URL`: https, or http on `127.0.0.1` / `[::1]` only; `acme`'s console is `<ADMIN_URL>/admin/acme/` | required |
| `ADMIN_ADDRESS` | where the console's listener binds | `0.0.0.0:9443` |
| `ADMIN_TLS_CERT`, `ADMIN_TLS_KEY` | the console over TLS, PEM, both or neither | unset (plain) |
| `TLS_CERT`, `TLS_KEY` | the public listener over TLS, PEM, both or neither; without them a TLS terminator in front answers at the https `PUBLIC_URL` | unset (plain) |
| `TRUSTED_PROXIES` | proxies in front, addresses or `address/prefix`, comma-separated; a request from one is counted by the right-most `X-Forwarded-For` address that is not a listed proxy | none |
| `KEK` | the 32-byte key-encryption key file, mode 600 or 400 | required |
| `PEPPER` | the password pepper file, at least 32 bytes, mode 600 or 400 | required |
| `PASSWORD_MEMORY_KIB`, `PASSWORD_ITERATIONS`, `PASSWORD_PARALLELISM` | Argon2id cost of new hashes; below the floor stops the start | `65536`, `3`, `1` |
| `PASSWORD_CONCURRENCY` | hashes or checks at once, each holding the cost's memory | `4` |
| `BREACHED_PASSWORDS_URL` | range-query base for breached passwords (sent the first five hex digits of the SHA-1 only); `off` turns it off | `https://api.pwnedpasswords.com/range/` |
| `STORE`, `STORE_USER`, `STORE_PASSWORD` | the TessariDB node (`host:port`, wire) and the account the server signs in with; TessariDB `0.38.2` or later | required |
| `STORE_AUTHORITY` | the PEM the node's certificate must lead to; without it only a loopback store is reached | none |
| `STORE_CONNECTIONS` | connections to the store at most | `16` |
| `REGION` | the region whose companies this server holds (namespace `oauth_<REGION>`) | required |
| `TENANTS` | companies created and activated at start, comma-separated; one an operator suspended stays suspended | required |
| `PEERS`, `PEER_USER`, `PEER_PASSWORD`, `PEER_AUTHORITY` | other regions; see the tessaridb-oauth-cluster skill | none |
| `READ_LIMIT`, `READ_WINDOW_SECS` | metadata, key-set and UserInfo requests per client address per window | `300`, `60` |
| `TOKEN_LIMIT`, `TOKEN_WINDOW_SECS` | token requests per client address per window | `60`, `60` |
| `AUTHORIZE_LIMIT`, `AUTHORIZE_WINDOW_SECS` | authorization requests per client address per window | `120`, `60` |
| `LOGIN_LIMIT`, `LOGIN_WINDOW_SECS` | sign-in steps (and console requests) per client address per window | `30`, `60` |
| `SMTP_URL` | mail relay: `smtps://host[:port]`, `smtp://host[:port]` (STARTTLS required), or `smtp://<loopback IP>:port?plain`; no credentials in the URL; without it no mail is sent and a password reset answers `503` | unset |
| `SMTP_FROM` | the sender, `address` or `Name <address>`; required with `SMTP_URL` | none |
| `SMTP_USER`, `SMTP_PASSWORD_FILE` | the relay account, both or neither; the file mode 600 or 400 | none |
| `SMTP_AUTHORITY` | the PEM the relay's certificate must lead to | system roots |

`RUST_LOG` filters the JSON log on standard output (`info` by default); under `debug` the first line,
`loaded configuration`, is the effective configuration with every default filled in and no password.

## Compose beside a TessariDB node

The image runs as user `65532` and listens on 8443 (public) and 9443 (console). The node below makes
the server's account its first (owner) account and serves its wire port over TLS:

```yaml
services:
  tessaridb:
    image: tessaridb/tessaridb:0.38.2
    restart: unless-stopped
    volumes:
      - tessaridb-data:/var/lib/tessaridb
      - ./keys/store.pem:/keys/store.pem:ro
      - ./keys/store.key:/keys/store.key:ro
    environment:
      TESSARIDB_INITIAL_USER: oauth
      TESSARIDB_INITIAL_PASSWORD: ${STORE_PASSWORD:?set it}
      TESSARIDB_TLS_CERT: /keys/store.pem
      TESSARIDB_TLS_KEY: /keys/store.key

  oauth:
    image: tessaridb/oauth:0.1.0
    restart: unless-stopped
    depends_on: [tessaridb]
    ports:
      - "8443:8443"             # issuers, sign-in pages, account portal
      - "127.0.0.1:9443:9443"   # admin console, this host only
    volumes:
      - ./keys/kek:/keys/kek:ro
      - ./keys/pepper:/keys/pepper:ro
      - ./keys/ca.pem:/keys/ca.pem:ro
    environment:
      TESSARIDB_OAUTH_PUBLIC_URL: https://id.example.com
      TESSARIDB_OAUTH_ADMIN_URL: http://127.0.0.1:9443
      TESSARIDB_OAUTH_KEK: /keys/kek
      TESSARIDB_OAUTH_PEPPER: /keys/pepper
      TESSARIDB_OAUTH_STORE: tessaridb:9080
      TESSARIDB_OAUTH_STORE_USER: oauth
      TESSARIDB_OAUTH_STORE_PASSWORD: ${STORE_PASSWORD:?set it}
      TESSARIDB_OAUTH_STORE_AUTHORITY: /keys/ca.pem
      TESSARIDB_OAUTH_REGION: eu
      TESSARIDB_OAUTH_TENANTS: acme

volumes:
  tessaridb-data:
```

`PUBLIC_URL` is what browsers and applications see. With no `TLS_CERT` the 8443 listener is plain HTTP
for a TLS terminator that answers at that https URL; passwords and tokens cross it, so keep it reachable
from the terminator alone and list the terminator in `TRUSTED_PROXIES`.

## What the server does at start

It records each company in `TENANTS` in the region's directory, provisions its database, registers the
console as the client `admin-console` of that company's issuer, makes a signing key where there is none
and serves the company. It then provisions every other company the directory holds, so a table a newer
release declares reaches each of them. While it serves it re-reads which companies are active every five
seconds and checks every five minutes for keys due to rotate. `SIGINT` / `SIGTERM` stop the listeners,
let requests in flight finish within 25 seconds and exit 0.

## The first operator, and a new company

```bash
tessaridb-oauth bootstrap-operator --email root@example.com
tessaridb-oauth bootstrap-operator --company acme --email ops@acme.example
```

The emergency path: it reads the server's environment and needs only the store. The first form creates the
`system` company when there is none, finds or registers the account and gives it the roles `companies` and
`users`; an account with no password gets a one-time enrolment code for
`POST <PUBLIC_URL>/system/login/api/enroll`. Run it at a terminal: the code is shown once and never
logged. Every run is logged at `ERROR` as `break_glass` and recorded on that company's audit trail.

A company made later in the `system` console (`POST <ADMIN_URL>/admin/system/api/companies` with
`{"id", "name", "reason"}`) is served at once and gets its first operator through
`bootstrap-operator --company <id>`, which gives `users`, `clients`, `policy`, `keys` and `audit` there.

The operator sets a password with the code
(`{"code": "...", "password": "..."}`, at least 15 characters, the code valid 72 hours), signs in,
adds a second factor on `<issuer>/account` (the console admits only two-factor sign-ins), then opens
`<ADMIN_URL>/admin/<company>/`.
