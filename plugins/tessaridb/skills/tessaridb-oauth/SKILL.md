---
name: tessaridb-oauth
description: Run and use TessariDB OAuth, an OAuth 2.1 authorization server and OpenID provider whose every piece of state lives in TessariDB. Use when starting the server (container or Compose beside a TessariDB node), setting its TESSARIDB_OAUTH_* variables, making the first operator, adding a company, registering an application (public with PKCE, or private_key_jwt), wiring sign-in into an application (authorization code with PKCE, PAR, DPoP, refresh tokens, client credentials, UserInfo, logout), reading what a token carries, operating the admin console and its API, answering an incident (exposed signing key or KEK, leaked client key, taken account), backing it up, or explaining a refusal. For several servers, regions and the TessariDB cluster underneath use the tessaridb-oauth-cluster skill.
---

# TessariDB OAuth

One Rust binary serves, per company, an OAuth 2.1 issuer and OpenID provider, the sign-in, consent and
account pages its users see, and on a listener of its own an admin console. Companies, users, clients,
codes, grants, consents, sessions, sealed signing keys, request counters and the audit trail are records
in a TessariDB store; the server keeps nothing else. Company `acme` is the issuer `<PUBLIC_URL>/acme`.

Checked against **TessariDB OAuth 0.1.0**, the first release, in alpha (image `tessaridb/oauth:0.1.0`,
linux/amd64 and linux/arm64), on **TessariDB 0.38.2**. The configuration and the HTTP surface may still
change in a minor release before 1.0, so pin the image tag.

## Pick the reference for the task

| Task | Read |
|---|---|
| Start it, every variable, TLS and proxies, the first operator, a new company | [references/running-and-configuration.md](references/running-and-configuration.md) |
| Register an application and sign users in: flows, tokens, DPoP, UserInfo, logout, refusals | [references/applications-and-tokens.md](references/applications-and-tokens.md) |
| The admin console and its API, operator roles, incidents, logs, backup and restore | [references/operating.md](references/operating.md) |

## Try it first

The server beside its TessariDB node, the admin console on this host only:

```bash
mkdir keys && head -c 32 /dev/urandom > keys/kek && head -c 32 /dev/urandom > keys/pepper
chmod 400 keys/kek keys/pepper && sudo chown 65532:65532 keys/kek keys/pepper
# keys/store.pem + store.key: the node's certificate for the name `tessaridb`; keys/ca.pem: its authority
export STORE_PASSWORD='choose-a-real-one'
docker compose up -d          # the compose.yaml in references/running-and-configuration.md
curl -s https://id.example.com/acme/.well-known/openid-configuration   # via the TLS terminator
docker compose exec oauth tessaridb-oauth bootstrap-operator --email root@example.com
```

The last line prints a one-time enrolment code for the `system` company's first operator; the console
is then at `http://127.0.0.1:9443/admin/system/` (the trailing slash matters).

## Rules that prevent quiet mistakes

1. **The issuer is per company.** Every URL an application uses starts with `<PUBLIC_URL>/<company>`;
   discovery is at `<issuer>/.well-known/openid-configuration`. A suspended or unknown company is `404`.
2. **`PUBLIC_URL` is an identity, not a setting.** Its host is the passkey relying party: changing the
   host retires every enrolled passkey and moves every issuer.
3. **Two files the store never sees.** `KEK` seals signing keys and other secrets, `PEPPER` keys the
   password hashes. Both mode 600 or 400, owned by user 65532 in the image, kept apart from backups;
   without them a restored store opens no key and verifies no password.
4. **Authorization code with PKCE `S256` is the only browser flow.** No implicit flow, no password
   grant, no client secret: a client is public (`none`) or signs a `private_key_jwt` with EdDSA or ES256.
5. **Redirect URIs match exactly**, and a code is spent once: a second redemption is refused and
   revokes the refresh family the first one started.
6. **An access token is addressed to one resource** (`aud`), lives five minutes and is never recalled;
   revoking a grant stops it within those five minutes. Check `aud` at every resource server.
7. **`sub` is pairwise per client.** Two applications see different identifiers for the same user; do
   not join users across applications by `sub`.
8. **Behind a proxy, list it in `TRUSTED_PROXIES`.** Otherwise every client is counted as the proxy and
   one client's failed sign-ins hold everybody's.
9. **The admin console needs its own origin** (`ADMIN_URL`, https or a loopback http) and two-factor
   operators; keep its listener off the internet or behind its own TLS.
10. **The store must count requests.** A namespace declared `MULTI MASTER` cannot hold the counters,
    and every counted request is then refused `503`.
11. **Read the refusal.** The token endpoint answers the `error` code alone (`invalid_grant`,
    `invalid_client`, …); the server's JSON log line with its `event` says why.

## Related skills

- `tessaridb` — the store underneath: its users, TLS, snapshots and upgrades.
- `tessaridb-oauth-cluster` — several servers on one store, regions with home-region redirects, and a
  TessariDB cluster under them.
