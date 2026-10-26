---
title: "Generating Kafka ClickHouse pipelines from a JSON sample"
date: 2026-10-22
description: "How we load Kafka topics into ClickHouse through streams, raw and datalake tables, why writing those migrations by hand got old, the shell script that silently mixed up nested fields, and the CLI I built to replace it."
tags: [clickhouse, kafka]
tested_on: ClickHouse 26.9, clickforge 0.7.0
---

This post isn't about ClickHouse internals. It's about a part of my day-to-day work that kept eating my time. You want to build something great, and instead you sit there struggling to understand what is going on. We consume a lot of data straight from Kafka into ClickHouse, using ClickHouse's own Kafka consumer (the `Kafka` table engine) and materialized views. Data is constantly flowing, and the message format keeps changing. Every new topic meant the same job:

1. find a message on the topic and check its fields,
2. write several migrations that have to be applied in a particular order (we use [golang-migrate](https://github.com/golang-migrate/migrate)),
3. apply them and check that data shows up (not on prod, we have a separate environment for that).

For a flat message with a few fields that's fine. When the message has nested objects or arrays, it gets slow and easy to get wrong. At some point I noticed how much time I was spending on it and started looking for a faster way.

## TL;DR

Writing the Kafka → ClickHouse migrations by hand was the slow part, especially for nested messages. A shell script around `clickhouse local` helped, but it needed a 663 MB binary and silently mixed up nested fields. clickforge generates the same five statements in milliseconds with no dependencies. It doesn't make changing a running flow any easier, which is still the hard part.

## The flow: streams, raw, datalake

The `Kafka` table is a consumer, not storage. A plain `SELECT` from it reads messages and moves the consumer group on, so each message can be read only once ([docs](https://clickhouse.com/docs/engines/table-engines/integrations/kafka)). That's why nobody queries `streams` directly. Once a materialized view is attached, ClickHouse reads the topic in the background and pushes each batch of messages through the view into the target table. We want to keep every message as it arrived, so the first view writes into `raw`, and a second view on `raw` fills the typed `datalake` table.

Each topic gets three tables and two materialized views:

```plaintext
Kafka topic
    ↓
streams.video_events     Kafka engine table: reads the topic, stores nothing
    ↓  streams.video_events_mv
raw.video_events         the original message as a string, plus Kafka metadata
    ↓  raw.video_events_mv
datalake.video_events    typed columns, extracted from the message with JSONExtract
```

### The migration, layer by layer

One topic is one up migration with five statements, run in this order. The SQL below is what clickforge generates for `video_events.json`, a sample of video player events (the shell script produced the same five statements). I've cut the column lists down where they repeat.

The first statement creates the consumer. It has a single `message` column, and `kafka_format = 'RawBLOB'` puts the whole Kafka message into it as one string, so nothing is parsed at this stage. `Kafka(kafka)` takes the broker settings from a named collection called `kafka`. I've replaced our internal topic and consumer group names with plain ones.

```sql
CREATE TABLE IF NOT EXISTS `streams`.`video_events` ON CLUSTER clickhouse_datalake
(
	`message` String
)
	ENGINE = Kafka(kafka) SETTINGS kafka_topic_list =
	'video_events', kafka_group_name =
	'clickhouse-video_events', kafka_format = 'RawBLOB';
```

Credentials don't go into the migration. They live in the named collection, which is created once per cluster, either in the server config or with SQL:

```sql
CREATE NAMED COLLECTION kafka AS
    kafka_broker_list = 'kafka1:9092,kafka2:9092',
    kafka_security_protocol = 'sasl_ssl',
    kafka_sasl_mechanism = 'SCRAM-SHA-512',
    kafka_sasl_username = 'clickhouse',
    kafka_sasl_password = '...';
```

This way the migrations can sit in git without passwords, and every topic table just says `Kafka(kafka)`.

The second is `raw`, a normal replicated table that stores the message unchanged, together with where it came from. `_key`, `_offset`, `_partition`, `_timestamp_ms` and `_topic` are virtual columns of the `Kafka` engine, and `_row_created` is the time ClickHouse wrote the row. If the schema changes or the typed table turns out to be wrong, I can rebuild `datalake` from `raw` without reading the topic again.

```sql
CREATE TABLE IF NOT EXISTS `raw`.`video_events` ON CLUSTER clickhouse_datalake
(
	`message`       String,
	`_key`          String,
	`_offset`       UInt64,
	`_partition`    UInt64,
	`_timestamp_ms` DateTime64(3),
	`_topic`        LowCardinality(String),
	`_row_created`  DateTime DEFAULT nowInBlock()
)
	ENGINE = ReplicatedMergeTree('/clickhouse/{cluster}/tables/raw/video_events/{shard}', '{replica}')
	PARTITION BY toYYYYMM(_row_created)
	ORDER BY _row_created
	SETTINGS index_granularity = 8192;
```

The third is `datalake`, the table people query. Each field of the message becomes a typed column, and the Kafka timestamp, topic and write time are carried over from `raw`. It's partitioned by the month of the Kafka timestamp, so a message lands in the month of its Kafka timestamp, not the month it was loaded.

```sql
CREATE TABLE IF NOT EXISTS `datalake`.`video_events` ON CLUSTER clickhouse_datalake
(
	`event_id` String,
	`user_id` Int64,
	...
	`client_ip` Nullable(String),
	`country_code` Nullable(String),
	`platform` String,
	`_timestamp_ms` DateTime64(3),
	`_topic`        LowCardinality(String),
	`_row_created`  DateTime DEFAULT nowInBlock()
)
	ENGINE = ReplicatedMergeTree('/clickhouse/{cluster}/tables/datalake/video_events/{shard}', '{replica}')
	PARTITION BY toYYYYMM(_timestamp_ms)
	ORDER BY _timestamp_ms
	SETTINGS index_granularity = 8192;
```

The fourth connects `raw` to `datalake`. A materialized view works like an insert trigger: every block of rows inserted into `raw` goes through this `SELECT`, and the result is inserted into `datalake`. This is where the message gets parsed, one `JSONExtract` per column.

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS `raw`.`video_events_mv`
	ON CLUSTER clickhouse_datalake TO `datalake`.`video_events` AS
SELECT * FROM (
	SELECT
		JSONExtract(message, 'event_id', 'String') AS `event_id`,
		JSONExtract(message, 'user_id', 'Int64') AS `user_id`,
		...
		JSONExtract(message, 'client_ip', 'Nullable(String)') AS `client_ip`,
		`_timestamp_ms`,
		`_topic`,
		`_row_created`
	FROM `raw`.`video_events`
) SETTINGS cast_keep_nullable = 1;
```

`cast_keep_nullable = 1` keeps `Nullable` when a value is cast to another type. By default it's dropped: on 26.9, `CAST(toNullable(toInt32(0)) AS String)` returns `String`, and with the setting on it returns `Nullable(String)`.

The last statement connects the consumer to `raw`, and the moment it exists, ClickHouse starts reading the topic. `_timestamp_ms` is `Nullable` on the `Kafka` table, so `assumeNotNull` turns it into the plain `DateTime64(3)` that `raw` expects.

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS `streams`.`video_events_mv`
	ON CLUSTER clickhouse_datalake
	TO `raw`.`video_events` (
		`message`        String,
		...
		`_row_created`   DateTime
	) AS
SELECT
	message,
	_key,
	_offset,
	_partition,
	assumeNotNull(_timestamp_ms) AS _timestamp_ms,
	_topic,
	nowInBlock() AS _row_created
FROM `streams`.`video_events`;
```

That's why the order matters. A materialized view only sees rows inserted after it was created, and it doesn't go back for the ones already in the table. 

Changing a running flow is harder than creating it. To change the schema, I drop the `streams` table and its view first so the consumer stops, change the tables, and create everything again in the right order. Get the order wrong, or forget to update a view, and the tables just stay empty. There's no error to tell you why, and you can't simply look at the topic from ClickHouse, because reading the `Kafka` table consumes the messages. clickforge doesn't solve this. It only removes the bottleneck of writing the DDL.

## First attempt: a shell script

My first fix was a [shell script](https://github.com/Maksim-Gr/clickforge/blob/main/create_ddl_for_kafka.sh). It takes a JSON sample of the topic's messages and lets ClickHouse work out the schema:

```bash
./create_ddl_for_kafka.sh video_events.json
```

Inside, it runs `clickhouse local` to create a temporary table from the file with schema inference, prints `SHOW CREATE TABLE`, and then rewrites that output with `sed` and `awk` into the five statements. The column list goes into the `datalake` table, and each column becomes a `JSONExtract(message, 'field', 'Type')` line in the materialized view. It took a heavy session with an LLM to make it work, but I was serious, I wanted my time back.

It worked, but it was never convenient. It needs a ClickHouse binary next to it (`./clickhouse.0`, 663 MB on my laptop), and every column comes out `Nullable`, because the script turns on `schema_inference_make_columns_nullable`. A run took about six seconds. The engine is fixed to `ReplicatedMergeTree`, so there's no way to pick another one, and the `awk` step that rewrites types gets the brackets wrong once a type is nested.

At work, a message can be a hundred lines of loosely structured, nested JSON, and it has to land in a flat, typed table. The bigger problem showed up when I ran it on a message with nested fields for this post:

```json
{"order_id": 1, "customer": {"id": 7, "address": {"city": "Berlin"}}, "items": [{"sku": "A1", "qty": 2}], "tags": {"source": "app", "campaign": "fall"}}
```

`clickhouse local` infers named tuples for the objects, for example `tags Tuple(campaign Nullable(String), source Nullable(String))`. The `awk` step strips everything in backticks from the type, so the names inside the tuple are lost and the view ends up with this:

```sql
JSONExtract(message, 'tags', 'Tuple( Nullable(String), Nullable(String))') AS tags
```

Without names, `JSONExtract` fills the tuple by position. ClickHouse sorted the inferred fields alphabetically (`campaign`, `source`), but the message has them the other way round. Here is what the generated extracts return for the message above on 26.9:

```plaintext
customer: ((NULL),NULL)
items:    [(NULL,'2')]
tags:     ('app','fall')
```

All of `customer` is lost, `qty` landed in the `sku` position, and `tags` has `campaign = 'app'` and `source = 'fall'`. None of these extracts raises an error, so nothing tells you the columns are wrong.

## clickforge

So I wrote a CLI, [clickforge](https://github.com/Maksim-Gr/clickforge). Kind of a weird name, but I like it. It's a single binary with no ClickHouse dependency, and it generates the same flow from the same JSON sample:

```bash
clickforge kafka video_events.json
```

```plaintext
13 columns inferred from video_events

  event_id              String
  user_id               Int64
  ...
  client_ip             String
  country_code          String
  platform              String

Written: ./video_events_up.sql
Written: ./video_events_down.sql
```

That took 7 ms. `video_events_up.sql` holds the five statements in the order above, and `video_events_down.sql` drops them again. A field is `Nullable` only if it's missing or `null` in some message, so in this sample only `client_ip` and `country_code` are `Nullable`, because the last event has neither.

For the nested message, clickforge keeps nested objects as JSON text and turns flat objects into a `Map`:

```plaintext
customer: {"id":7,"address":{"city":"Berlin"}}
items:    [{'sku':'A1','qty':'2'}]
tags:     {'source':'app','campaign':'fall'}
```

Nothing is lost or swapped, but it isn't fully typed either. `qty` is the string `'2'`, and `customer` needs `JSONExtract` at query time.


## Closing words

clickforge is a small CLI, and it doesn't solve everything. Changing a running flow is still manual and still easy to get wrong. What it gives me is the thing I was missing: a fast, correct scaffold for a new topic, so I can apply the migrations and see data in the tables a few seconds later. Not a bad day if it saves me a couple of hours of work. I'm still working on the CLI and trying to make it better.

If you want to try it yourself, the JSON samples and the `JSONExtract` checks are next to this post: [video_events.json](video_events.json), [nested.json](nested.json), [extract-check.sql](extract-check.sql) for the nested test, and [flow-check.sql](flow-check.sql) for the `raw` → `datalake` layers.
