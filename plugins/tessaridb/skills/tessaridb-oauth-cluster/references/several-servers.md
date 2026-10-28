# Several servers on one store

Every server pointed at one TessariDB store is the same authorization server: the codes, sessions,
refresh families, signing keys and counters it uses are records in that store.

## What to give every server

- The same `STORE`, `STORE_USER`, `STORE_PASSWORD` and `STORE_AUTHORITY`.
- The same `REGION`, the same `TENANTS`, and the same `KEK` and `PEPPER` files.
- The same `PUBLIC_URL`: the address of the load balancer in front of them. Each server listens on its
  own `PUBLIC_ADDRESS`; the balancer forwards to them, and each lists it in `TRUSTED_PROXIES`.

## What was checked (two servers, one store, OAuth 0.3.0 on TessariDB 0.39.2)

- A code issued through one server was redeemed at the other.
- UserInfo answered at both; a refresh token from one was used at the other.
- A replayed code was refused `invalid_grant`.
- Both published the same key set.
- With OAuth 0.1.0 on TessariDB 0.38.2 also: the replay revoked the refresh family on both servers,
  `prompt=none` at the second server resumed the session started at the first, and the admin console
  session was shared.

## Operating

- Start or stop servers at any time; there is no membership to change.
- Rotate keys and change companies once, through either server's admin console: the change is a record.
- A rolling upgrade replaces servers one at a time on the same image tag line; read the release notes
  before mixing two minor versions on one store.
