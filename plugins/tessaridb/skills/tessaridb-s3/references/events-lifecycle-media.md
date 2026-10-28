# Notifications, lifecycle rules and media renditions

Checked against TessariDB S3 0.8.0 (the notification and lifecycle configurations below were
accepted by a running server, an upload under `2026/…jpg` appeared in the topic, and the media rules
below made the three image renditions of an upload). Upstream: <https://docs.tessaridb.com/s3/data-and-access/events-lifecycle-media>.

All three run through TessariDB: events through a topic, lifecycle and media through queues that hand
each piece of work to one node at a time.

## Notifications

`PutBucketNotificationConfiguration` accepts **queue configurations**.

- The default destination needs no setting: `arn:tessaridb:sqs:::tessaridb` is the metadata store's
  own `s3_notifications` topic, in the **region's** database (`<database>_<region>`, so
  `s3.meta_us_east_1` by default). Read it with a TessariDB topic consumer (see the `tessaridb` skill,
  topics), in the same transaction as the work it triggers:

<!-- not run: needs a TessariDB S3 metadata store; ran against one -->
```tessariql
USE NAMESPACE s3 DATABASE meta_us_east_1;
READ FROM s3_notifications LIMIT 10;
-- 'n-1': { position: 1, value: { Records: [{ eventName: 'ObjectCreated:Put', eventSource: 'tessaridb:s3',
--   s3: { bucket: { name: 'first' }, configurationId: 'new-photos', object: { key: '2026/cat.jpg', … } } }] } }
```
- An operator can declare alternatives in `TESSARIDB_S3_NOTIFY_TARGETS`
  (`<id>=kafka:<host:port>[,…]/<topic>` with an existing topic, or `<id>=webhook:<http(s) URL>`,
  `;`-separated). A bucket names one only as `arn:tessaridb:sqs:::<id>`, never by address, so a bucket
  administrator cannot point the server at a host of their choosing.

```json
{"QueueConfigurations":[{"Id":"new-photos","QueueArn":"arn:tessaridb:sqs:::tessaridb",
  "Events":["s3:ObjectCreated:*"],
  "Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"2026/"},{"Name":"suffix","Value":".jpg"}]}}}]}
```

```bash
aws s3api put-bucket-notification-configuration --bucket first --notification-configuration file://notify.json
```

- Events: `s3:ObjectCreated:*` (Put, Copy, CompleteMultipartUpload), `s3:ObjectRemoved:*` (Delete,
  DeleteMarkerCreated), `s3:LifecycleExpiration:*` (Delete, DeleteMarkerCreated); prefix and suffix
  filters.
- Each change is recorded in TessariDB **in the change's own commit** and delivered as an S3 event
  record; the sequencer is its position.
- Into the topic: once per event. To Kafka (keyed by `bucket/key`) or a webhook: at least once, from
  any node, so a receiver must tolerate a repeat.
- A refused delivery is retried after a growing wait and moved to a dead-letter topic after 8 tries.
- An undeclared destination, an unsupported event or overlapping rules → `InvalidArgument`; topic,
  function and event-bus configurations → `NotImplemented`.

## Lifecycle

Rules by prefix: `Expiration` (days, date, `ExpiredObjectDeleteMarker`),
`NoncurrentVersionExpiration` with `NewerNoncurrentVersions`, `AbortIncompleteMultipartUpload`.
Transitions and tag or size filters → `NotImplemented`.

```json
{"Rules":[{"ID":"tmp","Status":"Enabled","Filter":{"Prefix":"tmp/"},"Expiration":{"Days":7}},
          {"ID":"old","Status":"Enabled","Filter":{"Prefix":""},
           "NoncurrentVersionExpiration":{"NoncurrentDays":30},
           "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":2}}]}
```

- A background pass on every node; each bucket with rules is handed to one node at a time and is due
  again an hour after each pass.
- A period runs to the next midnight UTC after its days are up.
- A current object is expired only while it is still the write that was judged; in a versioned bucket
  that leaves a delete marker.
- A version under Object Lock is never removed by lifecycle.

## Media renditions

A bucket's **media rules** (set in the console, `GET/PUT /api/v1/buckets/{bucket}/media`) say which
content types under which prefix get which renditions. Each output is spelled `kind/size/format`:

```json
{"rules":[{"id":"pics","content_types":["image/*"],"prefix":"pics/",
           "outputs":["image/1280/webp","image/400x400-cover/avif@60","image/300x200-exact/jpeg@80"]},
          {"id":"clips","content_types":["video/*"],"prefix":"clips/",
           "outputs":["poster/640/jpeg","video/360p+720p/hls"]}],
 "version":1}
```

- `image` and `poster` (a video's frame): a side of 16–7680 px, or a box `WxH` the picture is fitted
  inside (`-fit`, the default), covers from the middle (`-cover`) or is stretched to (`-exact`);
  JPEG, PNG, WebP or AVIF, with `@<1-100>` quality on the lossy ones. Never enlarged. A photo is
  turned upright by its EXIF orientation first, and no rendition carries the original's metadata.
- `video/<height>p/mp4|webm`: MP4 (H.264 High, AAC) or WebM (VP9, Opus), the shorter side at 360p,
  480p, 720p, 1080p, 1440p or 2160p, never enlarged.
- `video/360p+720p/hls`: one H.264 rendition per height in six-second segments under a master
  playlist, each file an object beside the original.
- An output a rule's content types can't all make, or a size out of range, is refused
  `invalid_media` with the reason. A save carries the `version` it read; one made over someone
  else's change is refused `412 stale_media` and changes nothing.
- Renditions are ordinary objects under `<key>.renditions/` (`image-400x400-cover-q60.avif`); a
  rendition never gets renditions.
- Objects already in the bucket get renditions by a sweep (`POST /api/v1/buckets/{bucket}/media/sweep`,
  progress at `GET` of the same route; the console's button), which skips a rendition made since its
  original.
- Workers per node: `TESSARIDB_S3_MEDIA_WORKERS` (2). Video needs `TESSARIDB_S3_FFMPEG` on that node
  (the image carries none); a video task is stopped after 50 minutes.
- A failed task is retried after a growing wait and listed in the console after five tries
  (`GET /api/v1/media/failed`).
