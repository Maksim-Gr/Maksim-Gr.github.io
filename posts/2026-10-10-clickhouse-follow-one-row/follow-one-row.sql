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
