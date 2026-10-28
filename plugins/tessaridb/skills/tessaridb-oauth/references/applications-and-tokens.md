# Applications, flows and tokens

Every endpoint below hangs off a company's issuer, `<issuer>` = `<PUBLIC_URL>/<company>`. Discovery
(`<issuer>/.well-known/openid-configuration`) and the key set are generated from the running
configuration; read them rather than hard-coding a URL.

## Registering an application

An operator holding `clients` registers it in the console or with
`POST <ADMIN_URL>/admin/<company>/api/clients` (JSON, from the console's origin, with an
`Idempotency-Key` header):

```json
{
  "client_id": "reports",
  "redirect_uris": ["https://reports.example.com/callback"],
  "scope_ceiling": ["openid", "profile", "groups"],
  "resources": ["https://api.example.com"],
  "auth_method": "private_key_jwt",
  "assertion_alg": "EdDSA",
  "jwks": [ { "kty": "OKP", "crv": "Ed25519", "x": "..." } ],
  "grant_types": ["authorization_code", "refresh_token"],
  "dpop_bound_access_tokens": false,
  "post_logout_redirect_uris": ["https://reports.example.com/"],
  "backchannel_logout_uri": "https://reports.example.com/backchannel-logout",
  "sector": "reports-suite",
  "reason": "reports goes live"
}
```

- `auth_method` is `none` (a public client, always with PKCE) or `private_key_jwt` with `assertion_alg`
  `EdDSA` or `ES256` and its public keys in `jwks`, a list of JWKs. No client secret exists.
- A client redeems only the grant types it registered. `client_credentials` needs a confidential client.
- `resources` are the audiences its access tokens may name. A client that calls UserInfo lists
  `<issuer>/oauth2/userinfo` among them and asks for it as `resource`.
- `sector` (from 0.2.0, optional): clients registered with the same sector see a person as one `sub`,
  so the applications of one product agree on who a user is; a client without one keeps a `sub` of
  its own. Measured: two clients of one sector got the same `sub` for a user, a third without a
  sector got another.
- Changing a client is not in the console yet: remove it and register it again.

## The browser flow: authorization code with PKCE

1. Send the browser to `GET <issuer>/oauth2/authorize` with `response_type=code`, `client_id`,
   `redirect_uri` (exactly as registered), `scope`, `state`, `nonce` (when `openid`), `resource`,
   `code_challenge` and `code_challenge_method=S256`. Or push those parameters first to
   `POST <issuer>/oauth2/par` (authenticated as at the token endpoint) and send only `client_id` and the
   returned `request_uri`, valid sixty seconds.
2. Until the client and its redirect URI are known, a refusal is shown on a page at the server and sent
   nowhere; later refusals go back to the redirect URI with `error`, `state` and `iss`.
3. The user signs in on the server's own pages and consents to what is not granted yet. The answer at the
   redirect URI carries `code`, `state` and `iss`: compare `state` and `iss` before using the code.
4. Redeem at `POST <issuer>/oauth2/token` with `grant_type=authorization_code`, the code, the same
   `redirect_uri`, `code_verifier` and the client's authentication. The code is spent first and checked
   after, so it redeems once whatever the outcome.

`prompt=none` asks for no page and answers `login_required`, `consent_required` or `interaction_required`
when one would be needed; `max_age` and `prompt=login` force a fresh sign-in. Where the company requires two
factors and the account has none, no code is issued until one is added.

## Client authentication

A `private_key_jwt` assertion is signed by the client's registered key, addressed to the issuer alone,
valid at most five minutes, with a `jti` accepted once (a second presentation is a replay). Its subject
names the client, so `client_id` may be left out beside it.

## What comes back

| Token | Carries | Lifetime |
|---|---|---|
| access token | an RFC 9068 JWT (`typ` `at+jwt`, EdDSA) with only `iss`, `aud` (one resource), `sub` (pairwise per client), `client_id`, `scope`, `iat`, `exp`, `jti`; `cnf.jkt` when DPoP-bound | 5 minutes, never recalled |
| ID token | with `openid`: `auth_time`, `acr`, `amr`, `sid`, `nonce`, `at_hash`, the same pairwise `sub`; no profile or contact data | 5 minutes |
| refresh token | random, stored as a digest; rotates on every use | 14 days unused, 30 days in all |

`acr` and `amr` come only from the methods verified in that sign-in: `urn:tessaridb:acr:sf` for one
factor, `urn:tessaridb:acr:mfa` for two categories, `urn:tessaridb:acr:phr` for a passkey that verified
its user. The server reads no `acr_values`.

A refresh is judged on the family's grant before rotating, so a refused refresh leaves the token usable;
it may narrow scopes or pick one of the grant's resources, never widen. A rotated token presented again
revokes its whole family. `client_credentials` gives a token whose `sub` is the client, never `openid`,
and no refresh token.

## DPoP

Send one `DPoP` header (RFC 9449, `typ` `dpop+jwt`, bound to the method and URI, at most a minute old,
spent once). The token is then `DPoP`, bound to the key's thumbprint; a client registered with
`dpop_bound_access_tokens` is refused without a proof. Bind the code too with `dpop_jkt` on the
authorization request, or by sending the proof with the pushed request.

## UserInfo, revocation and logout

- `GET|POST <issuer>/oauth2/userinfo` answers an access token addressed to that URL and carrying `openid`:
  `sub`, with `profile` the names the user set, with `groups` the user's groups and their `roles`, each
  read at that moment. A bound token must come as `DPoP` with a proof over it. Bad token `401`
  (`invalid_token`), no `openid` `403` (`insufficient_scope`).
- `POST <issuer>/oauth2/revoke` revokes a refresh token with its family; an access token is refused
  `unsupported_token_type` (it simply expires).
- `GET <issuer>/oauth2/logout` with `id_token_hint` (and the registered `post_logout_redirect_uri`, matched
  exactly, with `state`) ends the session the hint names. Use a `GET` redirect: a cross-site `POST`
  carries no session cookie.
- Back-channel logout: when a session ends, each client that got tokens in it and registered a
  `backchannel_logout_uri` (https) receives a `logout+jwt` as the form field `logout_token`; answer `200`
  or `204`. It is retried with backoff up to ten times. A session that simply expires tells nobody.

## Refusals worth knowing

| Answer | Means |
|---|---|
| page at the server, nothing at the redirect URI | unknown client or a redirect URI it did not register |
| `invalid_grant` at the token endpoint | a code spent, expired, for another client or redirect URI, or a PKCE verifier that does not match; a replayed code also revokes its family |
| `invalid_client` | the assertion did not verify, was replayed, or named another audience |
| `401 invalid_token` at UserInfo | the token is not this issuer's, expired, or addressed elsewhere |
| `429` with `Retry-After` | a per-address limit (`X-RateLimit-Class` says which) |
| `503` on a counted request | the store could not count it; the request is refused rather than served |
| `404` for a whole issuer | the company is suspended or unknown (with regions, one another region serves is a `307` there instead) |
