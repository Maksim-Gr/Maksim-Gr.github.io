-- Companion script for "Generating Kafka ClickHouse pipelines from a JSON sample"
-- Tested on ClickHouse 26.9:
--   docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
--   docker exec -i ch clickhouse-client --multiquery < extract-check.sql
--
-- The JSONExtract calls below are copied from the generated materialized views for nested.json:
-- first from create_ddl_for_kafka.sh, then from clickforge 0.7.0.

-- create_ddl_for_kafka.sh: the column names inside the tuples are gone, so fields are matched by position
WITH '{"order_id": 1, "customer": {"id": 7, "address": {"city": "Berlin"}}, "items": [{"sku": "A1", "qty": 2}], "tags": {"source": "app", "campaign": "fall"}}' AS message
SELECT
    JSONExtract(message, 'customer', 'Tuple( Tuple(city Nullable(String)), Nullable(Int64))') AS customer,
    JSONExtract(message, 'items', 'Array(Tuple( Nullable(Int64), Nullable(String)))') AS items,
    JSONExtract(message, 'tags', 'Tuple( Nullable(String), Nullable(String))') AS tags   -- (campaign, source)
FORMAT Vertical;
-- customer: ((NULL),NULL)
-- items:    [(NULL,'2')]
-- tags:     ('app','fall')

-- clickforge: nested objects stay as JSON text, flat objects become a Map
WITH '{"order_id": 1, "customer": {"id": 7, "address": {"city": "Berlin"}}, "items": [{"sku": "A1", "qty": 2}], "tags": {"source": "app", "campaign": "fall"}}' AS message
SELECT
    JSONExtract(message, 'customer', 'String') AS customer,
    JSONExtract(message, 'items', 'Array(Map(String, String))') AS items,
    JSONExtract(message, 'tags', 'Map(String, String)') AS tags
FORMAT Vertical;
-- customer: {"id":7,"address":{"city":"Berlin"}}
-- items:    [{'sku':'A1','qty':'2'}]
-- tags:     {'source':'app','campaign':'fall'}
