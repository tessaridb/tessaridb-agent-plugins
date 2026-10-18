# Regions, bucket replication and region failover

Checked against TessariDB S3 0.2.1-beta (documentation and the server's own route table; not run on
two regions here). Upstream: <https://docs.tessaridb.com/s3/operating/clusters#regions>.

## A region

- A server's region is `TESSARIDB_S3_REGION`, the one requests are signed for.
- Its buckets' objects are kept in the metadata database `<database>_<region>` (`meta_us_east_1` for
  the defaults), beside the global database `meta`.
- A request for another region's bucket answers `301 PermanentRedirect`.
- Each region's nodes set `TESSARIDB_S3_ADVERTISE` to the URL their S3 surface is reached at; it is
  recorded for the region as where replicas are sent.

## Bucket replication

`PutBucketReplication`, the `Filter` form: a prefix, a priority, delete markers, a destination bucket
by ARN. Both buckets must be versioned; tag filters and other options answer `NotImplemented`.

```json
{"Role":"arn:aws:iam::default:role/replicator",
 "Rules":[{"ID":"all","Priority":1,"Status":"Enabled","Filter":{"Prefix":""},
           "DeleteMarkerReplication":{"Status":"Enabled"},
           "Destination":{"Bucket":"arn:aws:s3:::photos-eu"}}]}
```

- Each version a rule covers is queued in its own commit and sent by any node to the destination
  region's advertised endpoint as the Role's user (`arn:aws:iam::<account>:role/<user>`), who must
  administer the destination bucket. It keeps its version id.
- The version answers `x-amz-replication-status`; a failing copy is retried after a growing wait and
  marked `FAILED` after 10 tries. Replicas are never sent on.
- A replicating bucket cannot suspend versioning.
- A version sealed with a customer key (SSE-C) is not replicated (`FAILED` at once).

## Failing a region over

From the console, root fails a region over to another and restores it, each under the next epoch
(`POST /api/v1/regions/failover` with `region` and `promoted`; `POST /api/v1/regions/restore` with
`region`; both with a `reason`). While failed over, the region refuses client writes with
`ServiceUnavailable` and still takes replicas.

Rehearse it before you need it: replicate a test bucket, fail its region over, write through the
promoted region, restore, and read the replication status of what was written meanwhile.
