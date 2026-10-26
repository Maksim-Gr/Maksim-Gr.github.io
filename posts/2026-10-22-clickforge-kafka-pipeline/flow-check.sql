-- Companion script for "Generating Kafka ClickHouse pipelines from a JSON sample"
-- Runs the raw -> datalake part of the migration clickforge 0.7.0 generates for video_events.json,
-- without Kafka: plain MergeTree instead of ReplicatedMergeTree, no ON CLUSTER, rows inserted into raw by hand.
-- Tested on ClickHouse 26.9:
--   docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
--   docker cp video_events.json ch:/var/lib/clickhouse/user_files/
--   docker exec -i ch clickhouse-client --multiquery < flow-check.sql

DROP DATABASE IF EXISTS raw; DROP DATABASE IF EXISTS datalake; CREATE DATABASE raw; CREATE DATABASE datalake;

CREATE TABLE IF NOT EXISTS `raw`.`video_events`
(
	`message`       String,
	`_key`          String,
	`_offset`       UInt64,
	`_partition`    UInt64,
	`_timestamp_ms` DateTime64(3),
	`_topic`        LowCardinality(String),
	`_row_created`  DateTime DEFAULT nowInBlock()
)
	ENGINE = MergeTree
	PARTITION BY toYYYYMM(_row_created)
	ORDER BY _row_created
	SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS `datalake`.`video_events`
(
	`event_id` String,
	`user_id` Int64,
	`session_id` String,
	`video_id` Int64,
	`event_type` String,
	`playback_position_ms` Int64,
	`duration_ms` Int64,
	`quality` String,
	`is_live` Bool,
	`timestamp` DateTime64(3),
	`client_ip` Nullable(String),
	`country_code` Nullable(String),
	`platform` String,
	`_timestamp_ms` DateTime64(3),
	`_topic`        LowCardinality(String),
	`_row_created`  DateTime DEFAULT nowInBlock()
)
	ENGINE = MergeTree
	PARTITION BY toYYYYMM(_timestamp_ms)
	ORDER BY _timestamp_ms
	SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS `raw`.`video_events_mv`  TO `datalake`.`video_events` AS
SELECT * FROM (
	SELECT
		JSONExtract(message, 'event_id', 'String') AS `event_id`,
		JSONExtract(message, 'user_id', 'Int64') AS `user_id`,
		JSONExtract(message, 'session_id', 'String') AS `session_id`,
		JSONExtract(message, 'video_id', 'Int64') AS `video_id`,
		JSONExtract(message, 'event_type', 'String') AS `event_type`,
		JSONExtract(message, 'playback_position_ms', 'Int64') AS `playback_position_ms`,
		JSONExtract(message, 'duration_ms', 'Int64') AS `duration_ms`,
		JSONExtract(message, 'quality', 'String') AS `quality`,
		JSONExtract(message, 'is_live', 'Bool') AS `is_live`,
		JSONExtract(message, 'timestamp', 'DateTime64(3)') AS `timestamp`,
		JSONExtract(message, 'client_ip', 'Nullable(String)') AS `client_ip`,
		JSONExtract(message, 'country_code', 'Nullable(String)') AS `country_code`,
		JSONExtract(message, 'platform', 'String') AS `platform`,
		`_timestamp_ms`,
		`_topic`,
		`_row_created`
	FROM `raw`.`video_events`
) SETTINGS cast_keep_nullable = 1;

INSERT INTO raw.video_events (message, _key, _offset, _partition, _timestamp_ms, _topic)
SELECT line, '', rowNumberInAllBlocks(), 0, now64(3), 'private.dev.video_events.v1'
FROM file('video_events.json', 'LineAsString');
SELECT count() FROM raw.video_events;
SELECT event_id, user_id, event_type, is_live, timestamp, client_ip, platform FROM datalake.video_events ORDER BY timestamp FORMAT PrettyCompactMonoBlock;
DROP DATABASE raw; DROP DATABASE datalake;

-- A materialized view does not backfill: only rows inserted after it exists reach the target
CREATE DATABASE mvtest;
CREATE TABLE mvtest.raw (message String) ENGINE = MergeTree ORDER BY tuple();
CREATE TABLE mvtest.typed (id Int64) ENGINE = MergeTree ORDER BY tuple();
INSERT INTO mvtest.raw VALUES ('{"id": 1}');
CREATE MATERIALIZED VIEW mvtest.raw_mv TO mvtest.typed AS SELECT JSONExtract(message, 'id', 'Int64') AS id FROM mvtest.raw;
INSERT INTO mvtest.raw VALUES ('{"id": 2}');
SELECT (SELECT count() FROM mvtest.raw) AS raw_rows, (SELECT groupArray(id) FROM mvtest.typed) AS typed_ids;   -- 2, [2]
DROP DATABASE mvtest;

-- Credentials live in a named collection, not in the migration. ClickHouse accepts this
-- (the Kafka table only connects once a materialized view is attached, so no broker is needed here)
CREATE DATABASE nctest;
CREATE NAMED COLLECTION nctest_kafka AS
    kafka_broker_list = 'kafka1:9092,kafka2:9092',
    kafka_security_protocol = 'sasl_ssl',
    kafka_sasl_mechanism = 'SCRAM-SHA-512',
    kafka_sasl_username = 'clickhouse',
    kafka_sasl_password = 'secret';
CREATE TABLE nctest.t (message String) ENGINE = Kafka(nctest_kafka)
SETTINGS kafka_topic_list = 'video_events', kafka_group_name = 'clickhouse-video_events', kafka_format = 'RawBLOB';
SELECT name, engine FROM system.tables WHERE database = 'nctest';   -- t, Kafka
DROP DATABASE nctest;
DROP NAMED COLLECTION nctest_kafka;

-- cast_keep_nullable
SELECT toTypeName(CAST(toNullable(toInt32(0)) AS String));                                  -- String
SELECT toTypeName(CAST(toNullable(toInt32(0)) AS String)) SETTINGS cast_keep_nullable = 1;  -- Nullable(String)
