-- Companion script for "Inside one INSERT: what the ClickHouse server does, step by step" (Inside ClickHouse, part 3)
-- Tested on ClickHouse 26.9:
--   docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
--   docker exec -i ch clickhouse-client --multiquery < inside-one-insert.sql

-- The orders table from part 1, with its first three parts
DROP TABLE IF EXISTS orders;
CREATE TABLE orders
(
    order_id   UInt64,
    status     LowCardinality(String),
    amount     Decimal(10, 2),
    updated_at DateTime64(3)
)
ENGINE = ReplacingMergeTree(updated_at)
PARTITION BY toYYYYMM(updated_at)
ORDER BY order_id;

SYSTEM STOP MERGES orders;

INSERT INTO orders VALUES (1, 'created', 10.00, now64());
INSERT INTO orders VALUES (2, 'created', 10.00, now64());
INSERT INTO orders VALUES (3, 'created', 10.00, now64());

SELECT name, part_type, rows, level
FROM system.parts WHERE database = currentDatabase() AND table = 'orders' AND active
ORDER BY name;

-- 1. Three things called a block ----------------------------------------------------------
-- SELECT blocks: up to max_block_size (65,409) rows
SELECT min(bs), max(bs), uniqExact(bn) AS blocks
FROM (SELECT blockSize() AS bs, blockNumber() AS bn FROM numbers(1000000));

-- INSERT ... SELECT squashing: one part per insert block (merges stopped)
DROP TABLE IF EXISTS blocks_demo;
CREATE TABLE blocks_demo (id UInt64, payload String) ENGINE = MergeTree ORDER BY id;
SYSTEM STOP MERGES blocks_demo;
INSERT INTO blocks_demo SELECT number, '' FROM numbers(3000000) SETTINGS async_insert = 0;
SELECT name, rows FROM system.parts
WHERE database = currentDatabase() AND table = 'blocks_demo' AND active ORDER BY name;   -- 3 parts: rows threshold
TRUNCATE TABLE blocks_demo;
INSERT INTO blocks_demo SELECT number, randomPrintableASCII(1000) FROM numbers(600000) SETTINGS async_insert = 0;
SELECT name, rows, formatReadableSize(data_uncompressed_bytes) AS uncompressed FROM system.parts
WHERE database = currentDatabase() AND table = 'blocks_demo' AND active ORDER BY name;   -- 2 parts: 256 MiB threshold

-- 2. Inside one INSERT, step by step ---------------------------------------------------------
-- Run this one from the shell to see the server log (one INSERT -> three parts):
--   docker exec ch clickhouse-client --send_logs_level=trace --async_insert=0 -q "INSERT INTO orders SELECT number + 100, 'created', 10, toDateTime64('2026-10-05 00:00:00', 3) + number * 86400 * 3 FROM numbers(20)"

-- Step 1: which partition does each row land in? Evaluate the partition key yourself
SELECT toYYYYMM(updated_at) AS partition, count() AS rows, min(updated_at), max(updated_at)
FROM (SELECT toDateTime64('2026-10-05 00:00:00', 3) + number * 86400 * 3 AS updated_at FROM numbers(20))
GROUP BY partition ORDER BY partition;   -- 9 / 10 / 1 rows

-- The month is counted in the column's timezone
DROP TABLE IF EXISTS tz_ny;
CREATE TABLE tz_ny (updated_at DateTime64(3, 'America/New_York')) ENGINE = MergeTree PARTITION BY toYYYYMM(updated_at) ORDER BY tuple();
INSERT INTO tz_ny SELECT toDateTime64('2026-11-01 02:00:00', 3, 'UTC');
SELECT _partition_id, toTimeZone(updated_at, 'UTC') AS utc, updated_at AS new_york FROM tz_ny;   -- 202610

-- Partition IDs for different partition keys
DROP TABLE IF EXISTS p_month; DROP TABLE IF EXISTS p_date; DROP TABLE IF EXISTS p_tuple; DROP TABLE IF EXISTS p_string; DROP TABLE IF EXISTS p_none;
CREATE TABLE p_month  (d Date, tenant_id UInt32, region String) ENGINE = MergeTree PARTITION BY toYYYYMM(d) ORDER BY tuple();
CREATE TABLE p_date   (d Date, tenant_id UInt32, region String) ENGINE = MergeTree PARTITION BY d ORDER BY tuple();
CREATE TABLE p_tuple  (d Date, tenant_id UInt32, region String) ENGINE = MergeTree PARTITION BY (tenant_id, toYYYYMM(d)) ORDER BY tuple();
CREATE TABLE p_string (d Date, tenant_id UInt32, region String) ENGINE = MergeTree PARTITION BY region ORDER BY tuple();
CREATE TABLE p_none   (d Date, tenant_id UInt32, region String) ENGINE = MergeTree ORDER BY tuple();
INSERT INTO p_month  VALUES ('2026-10-10', 42, 'EU');
INSERT INTO p_date   VALUES ('2026-10-10', 42, 'EU');
INSERT INTO p_tuple  VALUES ('2026-10-10', 42, 'EU');
INSERT INTO p_string VALUES ('2026-10-10', 42, 'EU');
INSERT INTO p_none   VALUES ('2026-10-10', 42, 'EU');
SELECT table, partition, partition_id FROM system.parts
WHERE database = currentDatabase() AND table LIKE 'p\\_%' ORDER BY table;

-- More than 100 partitions in one insert block fails with TOO_MANY_PARTS
DROP TABLE IF EXISTS lim;
CREATE TABLE lim (updated_at DateTime64(3)) ENGINE = MergeTree PARTITION BY toYYYYMM(updated_at) ORDER BY tuple();
-- Uncomment to see the error (it stops the script):
-- INSERT INTO lim SELECT toDateTime64('2020-01-01 00:00:00', 3) + toIntervalMonth(number) FROM numbers(101) SETTINGS async_insert = 0;

-- Sorting cost: already-sorted vs shuffled input
DROP TABLE IF EXISTS sort_test;
CREATE TABLE sort_test (id UInt64, v String) ENGINE = MergeTree ORDER BY id;
INSERT INTO sort_test SELECT number, toString(number) FROM numbers(1000000) SETTINGS async_insert = 0, log_comment = 'blog_sorted';
INSERT INTO sort_test SELECT number, toString(number) FROM numbers(1000000) ORDER BY rand() SETTINGS async_insert = 0, log_comment = 'blog_shuffled';
SYSTEM FLUSH LOGS;
SELECT log_comment,
       ProfileEvents['MergeTreeDataWriterBlocksAlreadySorted'] AS already_sorted,
       round(ProfileEvents['MergeTreeDataWriterSortingBlocksMicroseconds'] / 1000, 1) AS sort_ms
FROM system.query_log
WHERE log_comment IN ('blog_sorted', 'blog_shuffled') AND type = 'QueryFinish' AND current_database = currentDatabase()
ORDER BY event_time_microseconds;

-- Primary index and marks of one part
DROP TABLE IF EXISTS index_demo;
CREATE TABLE index_demo (id UInt64, v String) ENGINE = MergeTree ORDER BY id;
INSERT INTO index_demo SELECT number, toString(number) FROM numbers(1000000) SETTINGS async_insert = 0;
SELECT name, part_type, rows, marks, formatReadableSize(primary_key_bytes_in_memory) AS pk_in_memory
FROM system.parts WHERE database = currentDatabase() AND table = 'index_demo' AND active;
SELECT mark_number, rows_in_granule, id AS index_value,
       (id.mark.offset_in_compressed_file, id.mark.offset_in_decompressed_block) AS id_mark,
       (v.mark.offset_in_compressed_file, v.mark.offset_in_decompressed_block) AS v_mark
FROM mergeTreeIndex(currentDatabase(), index_demo, with_marks = true)
WHERE mark_number IN (0, 1, 2, 3, 122, 123)
ORDER BY mark_number;

