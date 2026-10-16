-- Companion script for "When ClickHouse merges change your query results" (Inside ClickHouse, part 2)
-- Tested on ClickHouse 26.9:
--   docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
--   docker exec -i ch clickhouse-client --multiquery < merges-change-results.sql

-- 1. When merges change the answer -------------------------------------------------------
-- SummingMergeTree: zero rows disappear, non-numeric columns keep the first value
DROP TABLE IF EXISTS page_stats;
CREATE TABLE page_stats (day Date, page String, views Int64, title String)
ENGINE = SummingMergeTree ORDER BY (day, page);
SYSTEM STOP MERGES page_stats;
INSERT INTO page_stats VALUES ('2026-10-10', '/home',  10, 'Home');
INSERT INTO page_stats VALUES ('2026-10-10', '/home',   5, 'Home (new title)');
INSERT INTO page_stats VALUES ('2026-10-10', '/promo',  7, 'Promo');
INSERT INTO page_stats VALUES ('2026-10-10', '/promo', -7, 'Promo');
SELECT _part, page, views, title FROM page_stats ORDER BY _part;          -- four parts, one row each
SELECT * FROM page_stats ORDER BY page, views;                            -- a plain SELECT: all four rows
SELECT page, sum(views) AS total FROM page_stats GROUP BY page ORDER BY page;   -- /home 15, /promo 0
SYSTEM START MERGES page_stats;
OPTIMIZE TABLE page_stats FINAL;
SELECT _part, page, views, title FROM page_stats ORDER BY _part;          -- only /home, title 'Home'
SELECT page, sum(views) AS total FROM page_stats GROUP BY page ORDER BY page;   -- /promo is gone
SELECT page, sum(views) AS total FROM page_stats GROUP BY page HAVING sum(views) != 0 ORDER BY page;   -- same answer before and after

-- AggregatingMergeTree: a plain column changes value after a merge
-- (since 26.7 this CREATE fails without allow_dimensions_outside_sorting_key = 1)
DROP TABLE IF EXISTS daily;
CREATE TABLE daily
(
    day       Date,
    cnt_plain UInt64,
    cnt       SimpleAggregateFunction(sum, UInt64),
    users     AggregateFunction(uniq, UInt64)
)
ENGINE = AggregatingMergeTree ORDER BY day
SETTINGS allow_dimensions_outside_sorting_key = 1;
INSERT INTO daily SELECT '2026-10-10', count(), count(), uniqState(toUInt64(number % 7)) FROM numbers(10);
INSERT INTO daily SELECT '2026-10-10', count(), count(), uniqState(toUInt64(number % 7 + 100)) FROM numbers(5);
SELECT day, sum(cnt_plain), sum(cnt), uniqMerge(users) FROM daily GROUP BY day;   -- 15, 15, 12
OPTIMIZE TABLE daily FINAL;
SELECT day, sum(cnt_plain), sum(cnt), uniqMerge(users) FROM daily GROUP BY day;   -- 10, 15, 12

-- CollapsingMergeTree: a cancel row that arrives first does not collapse
DROP TABLE IF EXISTS user_state;
CREATE TABLE user_state (user_id UInt64, page_views UInt32, sign Int8)
ENGINE = CollapsingMergeTree(sign) ORDER BY user_id;
INSERT INTO user_state VALUES (1, 5, 1);
INSERT INTO user_state VALUES (1, 5, -1), (1, 6, 1);
INSERT INTO user_state VALUES (2, 5, -1);
INSERT INTO user_state VALUES (2, 5, 1);
OPTIMIZE TABLE user_state FINAL;
SELECT _part, * FROM user_state ORDER BY user_id;               -- user 2 keeps both rows
SELECT user_id, sum(toInt64(page_views) * sign) AS page_views
FROM user_state GROUP BY user_id HAVING sum(sign) > 0 ORDER BY user_id;

-- VersionedCollapsingMergeTree: same out-of-order rows collapse
DROP TABLE IF EXISTS user_state_v;
CREATE TABLE user_state_v (user_id UInt64, page_views UInt32, sign Int8, version UInt32)
ENGINE = VersionedCollapsingMergeTree(sign, version) ORDER BY user_id;
INSERT INTO user_state_v VALUES (2, 5, -1, 1);
INSERT INTO user_state_v VALUES (2, 5, 1, 1);
OPTIMIZE TABLE user_state_v FINAL;
SELECT count() FROM user_state_v;                               -- 0

-- 2. Deletes and updates -------------------------------------------------------
DROP TABLE IF EXISTS orders_mt;
CREATE TABLE orders_mt
(
    order_id UInt64,
    status   LowCardinality(String),
    amount   Decimal(10, 2)
)
ENGINE = MergeTree ORDER BY order_id
SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1;

INSERT INTO orders_mt SELECT number, 'created', 10 FROM numbers(1000000);
OPTIMIZE TABLE orders_mt FINAL;

DELETE FROM orders_mt WHERE order_id < 10;
SELECT count() FROM orders_mt;
SELECT name, rows, formatReadableSize(bytes_on_disk) AS size
FROM system.parts WHERE database = currentDatabase() AND table = 'orders_mt' AND active;
SELECT command, is_done FROM system.mutations
WHERE database = currentDatabase() AND table = 'orders_mt';

ALTER TABLE orders_mt DELETE WHERE order_id < 20 SETTINGS mutations_sync = 1;
SELECT name, rows, formatReadableSize(bytes_on_disk) AS size
FROM system.parts WHERE database = currentDatabase() AND table = 'orders_mt' AND active;

UPDATE orders_mt SET status = 'paid' WHERE order_id = 500;
SELECT name, rows, formatReadableSize(bytes_on_disk) AS size
FROM system.parts WHERE database = currentDatabase() AND table = 'orders_mt' AND active
ORDER BY name;
SELECT * FROM orders_mt WHERE order_id = 500;
