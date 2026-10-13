-- Companion script for "Follow one row: what ClickHouse does with your INSERT" (Inside ClickHouse, part 1)
-- Tested on ClickHouse 26.9:
--   docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
--   docker exec -i ch clickhouse-client --multiquery < follow-one-row.sql
-- Timing-dependent steps (merges) are marked; results may differ slightly between runs.

-- 1. An INSERT creates a part --------------------------------------------------
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

-- What is a part: which part each row lives in, and where parts are on disk
SELECT _part, order_id, status FROM orders ORDER BY order_id;

SELECT name, rows, bytes_on_disk, active, path FROM system.parts
WHERE database = currentDatabase() AND table = 'orders'
ORDER BY name;   -- then: docker exec ch ls -l <path>  and  docker exec ch du -k <path>

-- A big part for comparison: one million orders in one INSERT -> one Wide part
DROP TABLE IF EXISTS orders_big;
CREATE TABLE orders_big AS orders;
SYSTEM STOP MERGES orders_big;
INSERT INTO orders_big
SELECT number, ['created', 'paid', 'shipped'][number % 3 + 1], (number % 10000) / 100,
       toDateTime64('2026-10-01 00:00:00', 3) + number % 2000000
FROM numbers(1000000) SETTINGS async_insert = 0;
SELECT name, part_type, rows, formatReadableSize(bytes_on_disk) AS size, path FROM system.parts
WHERE database = currentDatabase() AND table = 'orders_big' AND active;   -- then: docker exec ch ls -l <path>  and  docker exec ch du -k <path>

-- 1a. What is a block? ----------------------------------------------------------
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

-- 1b. Inside one INSERT ---------------------------------------------------------
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

-- 2. Too many parts: run the shell loop from the post against this table -----
DROP TABLE IF EXISTS ins_test;
CREATE TABLE ins_test (id UInt64, ts DateTime DEFAULT now()) ENGINE = MergeTree ORDER BY id;
SYSTEM STOP MERGES ins_test;
-- for i in $(seq 1 50); do docker exec ch clickhouse-client --async_insert=0 -q "INSERT INTO ins_test (id) VALUES ($i)" & done; wait
-- SELECT count() AS parts FROM system.parts WHERE table = 'ins_test' AND active;
-- TRUNCATE TABLE ins_test;  then repeat the loop without --async_insert=0

-- 3. Merges (timing-dependent) -------------------------------------------------
SYSTEM START MERGES orders;
-- the three parts usually stay unmerged for a while; two more inserts trigger a 5-part merge
INSERT INTO orders VALUES (4, 'created', 10.00, now64());
INSERT INTO orders VALUES (5, 'created', 10.00, now64());
INSERT INTO orders VALUES (6, 'created', 10.00, now64());

SELECT sleep(3) FORMAT Null;
SELECT name, rows, level, active
FROM system.parts WHERE database = currentDatabase() AND table = 'orders'
ORDER BY name;

SYSTEM FLUSH LOGS;
SELECT event_time_microseconds AS t, event_type, part_name, merged_from, rows
FROM system.part_log
WHERE database = currentDatabase() AND table = 'orders'
ORDER BY t;

-- 4. Updates, duplicates and FINAL --------------------------------------------
INSERT INTO orders VALUES (1, 'paid', 10.00, now64());

SELECT * FROM orders WHERE order_id = 1 ORDER BY updated_at;
SELECT * FROM orders FINAL WHERE order_id = 1;
SELECT order_id, argMax(status, updated_at) AS status
FROM orders WHERE order_id = 1 GROUP BY order_id;

-- the partition trap: the next version lands in another month
INSERT INTO orders VALUES (1, 'shipped', 10.00, '2026-11-02 09:00:00');
OPTIMIZE TABLE orders FINAL;

SELECT _partition_id, _part, * FROM orders WHERE order_id = 1 ORDER BY updated_at;
SELECT * FROM orders FINAL WHERE order_id = 1;
SELECT * FROM orders FINAL WHERE order_id = 1
SETTINGS do_not_merge_across_partitions_select_final = 1;   -- returns 2 rows
