# Declared topology, pooled tenants, cross-region replication

Three declarations that turned the cluster from a set of nodes into an
infrastructure: where nodes stand, who shares a node, and how data crosses
between clusters. All three are statements — scriptable, reviewable, and
visible in `INFO FOR NODE` the moment they land.

## Where nodes stand: realms and domains

`DEFINE TOPOLOGY` groups nodes into **realms** (independent failure
environments) and **domains** (locations inside a realm). The declaration is
how the store answers "what survives what" without a human holding the map.

```tessariql
-- Two realms, one with two domains; the survival claim is last and optional.
DEFINE TOPOLOGY prod REALM 'eu' DOMAIN 'west', 'east' REALM 'us' DOMAIN 'central', 'east' SURVIVES REALM LOSS;
-- Amend it as the deployment grows; the change rides the log like everything else.
ALTER TOPOLOGY prod ADD REALM 'ap' DOMAIN 'southeast';
```

The name is a bare word; realm and domain names are text — the same text a
member row names with `REGION`, because a realm is a label, not an
identifier.

A failover policy states its five periods; the store checks the policy
against the declared topology — a policy whose periods cannot hold the
claimed survival refuses at declaration time, not during the outage.

```tessariql
DEFINE FAILOVER AWARENESS 30s COLLECTION 25s ROUND 2s CAMPAIGN 3s LEASE 10s;
```

`AWARENESS` is how often a node refreshes what it knows about its peers;
`LEASE` is how long a leadership stands without renewal; `COLLECTION`,
`ROUND` and `CAMPAIGN` pace the readings and any re-election.

## Who shares a node: pooled tenants

On a pooled node, one process serves many customers. `RESTRICT TO` pins a
database to a node so a tenant's data never lands where they were not
placed, and `INFO FOR NODE` shows the placement as part of the topology
answer.

<!-- not run: placement names a node only a multi-node cluster holds -->
```tessariql
-- The tenant's database lives on the node that declares it.
DEFINE DATABASE acme ON NODE 'pool-7-eu-west';
```

Reads and writes behave exactly as on a dedicated cluster — the pooling is
placement, not a different product. The one rule a pooled cluster lives by:
declare every peer in one transaction, so no node ever counts a membership
the others have not heard.

## Data across clusters: replication links

`DEFINE REPLICATION` streams one database to another cluster. The receiving
copy is read-only by declaration; the link is at-least-once with idempotent
application, so a replayed batch lands the same records once.

<!-- not run: needs a second cluster at the far endpoint -->
```tessariql
-- Outbound: this cluster sends prod.orders to the endpoint.
DEFINE REPLICATION dr TO 'tls://cluster-b.example:9080' FOR DATABASE prod.orders AS 'orders_copy';
```

<!-- not run: needs a second cluster at the far endpoint -->
```tessariql
-- Inbound: accept a stream the other side declared.
DEFINE REPLICATION mirror FROM 'tls://cluster-a.example:9080' FOR DATABASE prod.orders;
-- The link's own row is cluster-local — it never crosses the seam.
INFO FOR REPLICATION dr;
-- Hold and resume without dropping the stream position.
ALTER REPLICATION dr PAUSED;
ALTER REPLICATION dr RESUMED;
```

The receiving side answers writes with the store's own refusal
(`WritesToAReplica`); `COMMIT` on the sender never waits for the far
cluster. A one-time token opens a link without a shared passphrase:

<!-- not run: needs a second cluster at the far endpoint -->
```tessariql
CREATE LINK TOKEN FOR REPLICATION 'dr' EXPIRES 1 HOUR;
```

## Reading the declared shape back

```tessariql
INFO FOR NODE;
```

`topology` names the declared realms and domains and marks a verdict on the
rows the node can check — a realm that would not survive its own loss is
named, not hidden.
