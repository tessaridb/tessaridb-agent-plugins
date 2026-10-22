# Kafka and RESP clients

Checked against TessariDB 0.37.1. A node can speak two protocols that existing applications already
use: the **Kafka protocol** and **RESP**, the protocol key-value servers and their client libraries
speak. An application keeps its client library and its code and changes the address it connects to.
Full detail: <https://docs.tessaridb.com/integrations/switching-a-client>,
<https://docs.tessaridb.com/integrations/kafka-clients>,
<https://docs.tessaridb.com/integrations/resp-clients>.

Neither protocol is on by default. A node serves one only when it is given an address for it:

```sh
tessaridb ./data --serve 0.0.0.0:9080 --http 0.0.0.0:8000 \
  --kafka 0.0.0.0:9092 --kafka-database shop.orders \
  --resp 0.0.0.0:6379 --resp-space shop.orders.cache
```

The container image takes the same settings as `TESSARIDB_KAFKA`, `TESSARIDB_KAFKA_DATABASE`,
`TESSARIDB_KAFKA_ADVERTISE`, `TESSARIDB_RESP` and `TESSARIDB_RESP_SPACE`. Given `--tls-cert` and
`--tls-key`, both ports speak TLS 1.3 with the node's certificate, and `--require-client-tls` refuses
to start a node whose Kafka or RESP port would be in the clear. `INFO FOR NODE` lists every port the
node serves under `clients.listeners`.

## Rules that prevent quiet mistakes

1. **Sign in as a store user.** Kafka clients use SASL `PLAIN` (`SASL_SSL` with a certificate); RESP
   clients use `AUTH user password` or `HELLO 3 AUTH user password`. Each command runs under that
   user's grants. SCRAM is refused at the handshake, because the store keeps Argon2id hashes only.
   A store with no users is open on these ports too.
2. **Declare the topic first.** Producing to a topic that does not exist does not create it; the
   client reports it unknown until it times out. Declare it, or create it with an admin client.
3. **Name topics the store's way.** A Kafka topic name is `<namespace>.<database>.<topic>`, or a bare
   name read in the database `--kafka-database` names.
4. **Behind a port mapping or a load balancer, set `--kafka-advertise`** to the address clients can
   reach. Without it a client connects once, is told the node's own address, and fails.
5. **Match the partitioner when both sides write.** The store places an append by murmur2 of the
   `BY` field, the hash the Java client uses by default. Clients on librdkafka (Python, Go, .NET, C)
   default to another hash: set `partitioner: murmur2_random` there, or one key's records land in
   two partitions and per-key order breaks without an error.
6. **A RESP connection works on one space.** `--resp-space ns.db.space` names the one every
   connection starts in; `TESSARIDB.USE <ns> <db> <space>` (sent as a raw command) switches it.
   `SELECT 0` is accepted and any other number is refused.
7. **Know what is refused rather than emulated.** Kafka transactions (`transactional.id`), Lua
   scripting (`EVAL`, `FUNCTION`), administration commands (`FLUSHALL`, `CONFIG`, `ACL`, …), bit
   fields, probabilistic keys, geo commands, and on streams a client-chosen ID, `XDEL` and `XSETID`.
   An unknown RESP command answers `ERR unknown command`, and inside `MULTI` it discards the
   transaction at `EXEC`.

## Topics with partitions

A Kafka record is stored as one message of a store topic, with `key`, `value`, `headers` and the
producer's `timestamp`. A Kafka offset is the message's position minus one. A message appended in
TessariQL, or by a RESP `XADD`, is fetched by a Kafka consumer as JSON.

```tessariql
DEFINE TOPIC orders PARTITIONS 3 BY customer;
CREATE orders = { customer: 'c-42', total: 19.99 } RETURN POSITION;
READ FROM orders PARTITION 0 LIMIT 10;
INFO FOR TOPIC orders;
```

A read of a split topic names its partition; without one it is refused as `PartitionNotNamed`:

```tessariql
-- refused: PartitionNotNamed
READ FROM orders;
```

A Kafka group's committed offset is a named reader position, `kafka:<group>`, on each partition, so
`READ FROM orders PARTITION p FOR CONSUMER 'kafka:billing'` continues where the Kafka group stopped,
and `INFO FOR TOPIC` reports it with its lag. A store an older build created refuses `PARTITIONS` as
`FormatNotFinalized` until `ALTER STORE FINALIZE FORMAT`.

## Keys, containers and a cache's space

A RESP value is stored by what it holds: a canonical decimal integer as an integer (so `INCR` is the
store's own atomic increment), other UTF-8 text as a string, anything else as bytes. `GET` answers
the bytes that were sent. A hash, list, set or sorted set is one key whose value is the container,
changed by one atomic statement per command; TessariQL writes the same containers:

```tessariql
DEFINE SPACE data;
LIST PUSH data:'jobs' BACK 'a', 'b';
HASH SET data:'cart:u1' 'apples' = 3, 'pears' = 1;
HASH INCR data:'cart:u1' 'apples' BY 2;
MEMBERS ADD data:'tags:post:7' 'rust', 'db';
SCORES ADD data:'board' 'ada' = 10, 'bob' = 7;
GET data:'cart:u1';
```

A statement on a key holding another kind is refused, as RESP's `WRONGTYPE`:

```tessariql
-- refused: KeyHoldsAnotherKind
LIST PUSH data:'cart:u1' BACK 'x';
```

For the data a cache server would hold, keep the space in memory. Its keys take no log record and no
disk sync, no follower or backup carries them, a restart empties it, and `MAX` is required:

```tessariql
DEFINE SPACE hot IN MEMORY MAX 100000;
SET hot:'session:ada' = 'signed-in' EXPIRE 30m;
INCR hot:'hits';
```

One transaction cannot write a held space and anything durable together:

```tessariql
-- refused: InMemoryBesideDurable
BEGIN;
SET hot:'k' = 1;
SET data:'k' = 1;
COMMIT;
```

## Streams, transactions and pub/sub over RESP

- A stream key names a topic in the space's database; `XADD` appends, `XREADGROUP` reads through the
  topic's group and holds until `XACK`. An ID is `<milliseconds appended>-<position>`. A stream on a
  split topic is refused.
- `MULTI … EXEC` is one store transaction; `WATCH` makes `EXEC` refuse when a watched key changed.
- `PUBLISH` reaches this node's subscribers only, in memory; a channel belongs to the space's
  database. Subscribing needs `read` on the space, publishing `write`, re-checked while subscribed.
- Blocking pops (`BLPOP`, `BZPOPMIN`, …) wake on the store's commits, including a TessariQL write.

## On a cluster

Either client may connect to any node. A write sent to a node that does not lead the range is
carried to the leader. Each member advertises its Kafka port with
`DEFINE REPLICA … KAFKA AT 'host:port'` and `Metadata` lists every member as a broker. An `IN MEMORY`
space lives on its range leader: one copy for every client, emptied by a failover.
