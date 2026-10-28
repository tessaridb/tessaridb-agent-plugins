# Regions

A region is its own TessariDB store holding its own companies (namespace `oauth_<region>`), served by
one or more servers with `REGION=<region>`. A company's identity data stays in its home region.

## Wiring two regions

In each region's store, as its owner, declare the account the other regions read with. It reaches the
directory (the companies and the region's `PUBLIC_URL`) and nothing else:

```text
DEFINE USER oauth_peer ON oauth_us.directory ROLE viewer PASSWORD '<password>';
```

`DEFINE USER` takes the password as literal text, not as a parameter, so run it from a file only the
owner can read (`tessaridb --at <store> -f peer.tql`) and delete the file afterwards.

Then start each region's servers with:

| Variable | Value |
|---|---|
| `PEERS` | the other regions, `region=host:port` of their stores, comma-separated |
| `PEER_USER`, `PEER_PASSWORD` | the account above; required with `PEERS` |
| `PEER_AUTHORITY` | the authority the other stores' certificates are checked against |

## What happens (checked on OAuth 0.3.0, TessariDB 0.39.2, two regions)

- A server reads every other region's directory every five seconds. A company created in `us` was
  redirected from `eu` 1.3 s after it was made (measured on OAuth 0.1.0).
- A request for a company another region serves answers `307 Temporary Redirect` to the same path and
  query at that region's `PUBLIC_URL`; a `POST` is redirected `307` too, so its body is sent again.
- A company no region serves is `404`. The admin console is not redirected (another region's company
  answers `404` there).
- With a peer's directory unreadable, a server kept the companies that region last named and logged a
  `WARN` (`a peer region's directory was not read; its last entries are kept`, `peer-directories`,
  `category=Unavailable`).
- A server whose `PEERS` names its own region refused to start, naming the variable.
