---
name: tessaridb-oauth-cluster
description: Run TessariDB OAuth on more than one server. Use when putting several servers in front of one TessariDB store (a code issued by one redeemed at another, shared sessions and keys), splitting companies across regions so each company's identity data stays in its home region and requests for it are redirected there with PEERS, or putting the OAuth store on a TessariDB cluster and starting the server against it. For one server, its variables, applications and tokens use the tessaridb-oauth skill; for the TessariDB cluster itself use tessaridb-cluster.
---

# TessariDB OAuth on several servers

A TessariDB OAuth server keeps nothing of its own: companies, codes, sessions, refresh families, sealed
keys and request counters are records in its TessariDB store. So every server pointed at the same store
is the same authorization server, and scaling out is starting another one. A **region** is a separate
store with its own companies; servers of one region learn the other regions through `PEERS` and
redirect a request for a company that lives elsewhere.

Checked against **TessariDB OAuth 0.1.0** (alpha, image `tessaridb/oauth:0.1.0`) on **TessariDB 0.38.2**,
in Docker: two servers on one store, two regions on two stores with `PEERS`, and a three-node TessariDB
cluster under one server.

## Pick the reference for the task

| Task | Read |
|---|---|
| Several servers on one store, behind one public address | [references/several-servers.md](references/several-servers.md) |
| Regions: home-region data, `PEERS`, the peer account, redirects | [references/regions.md](references/regions.md) |
| The OAuth store on a TessariDB cluster | [references/store-cluster.md](references/store-cluster.md) |

## Rules that prevent quiet mistakes

1. **Every server of one region gets the same `STORE`, `REGION`, `KEK`, `PEPPER` and `PUBLIC_URL`.** The
   KEK opens the sealed signing keys and the pepper keys the password hashes; a server holding other
   files cannot use the keys or passwords the others wrote.
2. **One `PUBLIC_URL` per region, behind one load balancer.** The issuer is `<PUBLIC_URL>/<company>`; two
   servers advertising different URLs are two issuers to every application.
3. **`PEERS` names the other regions only**, as `region=host:port` of their stores. A server whose
   `PEERS` names its own region refuses to start and names the variable.
4. **The peer account reaches the directory and nothing else**: `ROLE viewer` on
   `oauth_<region>.directory`, declared in each region's store.
5. **A request for another region's company is `307`** to the same path and query at that region's
   `PUBLIC_URL`; the method and body are sent again. A company no region serves is `404`. The admin
   console is never redirected.
6. **A region that stops answering keeps the companies it last named**, with a `WARN` naming
   `peer-directories`, and requests for those companies are still sent to it. Nothing moves by itself.
7. **On a TessariDB cluster, declare the namespace with its replication first, at the leader**
   (`DEFINE NAMESPACE oauth_<region> REPLICATION FACTOR 3`); the cluster refuses an undeclared one.
8. **`STORE` is one address and the server does not follow a redirect.** Start it against the current
   leader; it keeps serving after the leadership moves, but if its `STORE` node goes down every counted
   request answers `503` until that node returns.

## Related skills

- `tessaridb-oauth` - one server: variables, operators, companies, applications, tokens, refusals.
- `tessaridb-cluster` - standing up and operating the TessariDB cluster under it.
