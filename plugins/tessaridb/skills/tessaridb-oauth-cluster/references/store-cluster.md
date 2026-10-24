# The OAuth store on a TessariDB cluster

The server's store can be a TessariDB cluster, so the identity data survives a machine. Stand the
cluster up with the `tessaridb-cluster` skill first.

## Before the first start

A cluster refuses a namespace whose replication was never stated, and the server does not declare one.
As the owner, at the current leader:

```text
DEFINE NAMESPACE oauth_eu REPLICATION FACTOR 3;
```

Then declare the server's account as for one node, and start the server.

## `STORE` is one address

- The server connects to the one node `STORE` names and does not follow a redirect. Started against a
  follower it refuses: the store answers that the range is led by another node. Point `STORE` at the
  leader.
- Checked on a three-node cluster (OAuth 0.1.0, TessariDB 0.38.2): after the leadership moved (epoch
  11 to 14) the server went on serving through the same node.
- With the `STORE` node itself down, every counted request (sign-in, token, authorize) answered `503`
  until it returned. Put that node behind your most reliable machine, and alert on `503`s.
- The command line run against a follower says it cannot follow; run administrative statements at the
  leader too.
