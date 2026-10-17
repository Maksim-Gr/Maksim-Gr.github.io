---
title: "Follow one row: what ClickHouse does with your INSERT"
date: 2026-10-10
description: "What happens to a row in ClickHouse from INSERT to merge: parts, merges, duplicates and FINAL, traced with real output from 26.9 and the source code."
tags: [clickhouse]
tested_on: ClickHouse 26.9
series: Inside ClickHouse
part: 1
draft: false
---

I work as a data infrastructure engineer at a company where ClickHouse comes up at almost every coffee break. The questions I get are usually some version of these:

- "Why do I still see the old value? I'm using `ReplicatedReplacingMergeTree`."
- "Why are we getting `Too many parts` errors?"
- "Why doesn't my `SELECT` show the values I expect?"

At some point I noticed that all of them come from the same gap. The people asking had never seen the whole flow, from the moment a row is inserted to the moment it's merged, deduplicated or deleted.

So one day I looked at our ClickHouse cluster and remembered the line from the *Inside Out* trailer:

> Do you ever look at someone and wonder: what is going on inside their head?

So I decided to look inside ClickHouse's head.

I knew the semantics. I'd read the official ClickHouse docs and plenty of blog posts. But something was missing, even for me. I decided it's better to touch it once than to hear about it a hundred times.

I followed one order through its life in ClickHouse: insert, parts, merges, updates and duplicates. I captured real output at each step and looked up in the source code why it behaves that way. Where a single row wasn't enough to show something, I used a bigger batch or a separate test table, and I say so each time.

## TL;DR

- *"Why do I still see the old value?"* The new version sits in a different part that hasn't been merged with the old one yet, and merges are lazy. If the two versions are in different partitions, they will never be merged. Read with `FINAL` or `argMax`, and keep every version of a row in the same partition.
- *"Why are we getting `Too many parts`?"* A non-empty INSERT normally creates at least one part per partition. Many small INSERTs, or a partition key that's too fine, create parts faster than merges can combine them. Batch on the client, or use async inserts when many clients write at once.
- *"Why doesn't my `SELECT` show the values I expect?"* In `Summing`, `Aggregating` and `Collapsing` tables, merges change the rows themselves, so re-aggregate in every query. [Part 2](/posts/clickhouse-merges-change-results/) covers this in detail.

The rest of the post shows where these answers come from.

## Preparations

Before we look inside ClickHouse, let's do some preparations. We'll use Docker for simplicity and one small table. Every query here is in [one script](follow-one-row.sql), so you can check any claim yourself as you read.

```bash
docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
docker exec -it ch clickhouse-client
```

Everything happens inside this container. The SQL runs in the `clickhouse-client` session you just opened. Shell commands run through `docker exec ch ...`, and paths like `/var/lib/clickhouse/...` are paths inside the container, not on your machine.

Everything here ran on ClickHouse 26.9, and several defaults changed recently, so on an older version some numbers will differ. I use the non-replicated engines to keep the setup to one container, but all of it applies to `ReplicatedReplacingMergeTree` too. The only difference is who decides which parts to merge: in a replicated table, a leader replica writes that decision into the replication log in Keeper ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/StorageReplicatedMergeTree.cpp#L4730)), and every replica then runs the same merge on its own copy, or, for very large parts, downloads the result ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeFromLogEntryTask.cpp#L101-L112)).

The table:

```sql
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
```

When it merges parts, `ReplacingMergeTree(updated_at)` keeps the latest version of each `order_id`, because `ORDER BY order_id` defines which rows ClickHouse considers duplicates, while `updated_at` defines which duplicate wins. This partition key is a mistake on purpose. We'll come back to it.

To watch parts pile up, we stop background merges for now:

```sql
SYSTEM STOP MERGES orders;
```

## 1. An INSERT creates a part

```sql
INSERT INTO orders VALUES (1, 'created', 10.00, now64());
INSERT INTO orders VALUES (2, 'created', 10.00, now64());
INSERT INTO orders VALUES (3, 'created', 10.00, now64());

SELECT name, part_type, rows, level
FROM system.parts
WHERE table = 'orders' AND active;
```

```
┌─name─────────┬─part_type─┬─rows─┬─level─┐
│ 202610_1_1_1 │ Compact   │    1 │     1 │
│ 202610_2_2_1 │ Compact   │    1 │     1 │
│ 202610_3_3_1 │ Compact   │    1 │     1 │
└──────────────┴───────────┴──────┴───────┘
```

Three INSERTs gave me three parts.

### What a part is

The [official docs](https://clickhouse.com/docs/parts) describe it like this:

> The data from each table in the ClickHouse MergeTree engine family is organized on disk as a collection of immutable `data parts`.
>
> A data part is created whenever a set of rows is inserted into the table.

So a table is a set of parts, and every INSERT adds new ones. To see which part each row lives in, select the virtual column `_part`:

```sql
SELECT _part, order_id, status FROM orders;
```

```
┌─_part────────┬─order_id─┬─status──┐
│ 202610_1_1_1 │        1 │ created │
│ 202610_2_2_1 │        2 │ created │
│ 202610_3_3_1 │        3 │ created │
└──────────────┴──────────┴─────────┘
```

Each part is a directory on disk. `system.parts` shows where:

```sql
SELECT name, rows, bytes_on_disk, active, path
FROM system.parts
WHERE table = 'orders';
```

```
┌─name─────────┬─rows─┬─bytes_on_disk─┬─active─┬─path─────────────────────────────────────────────────────┐
│ 202610_1_1_1 │    1 │          1250 │      1 │ /var/lib/clickhouse/store/621/62173928-.../202610_1_1_1/ │
│ 202610_2_2_1 │    1 │          1250 │      1 │ /var/lib/clickhouse/store/621/62173928-.../202610_2_2_1/ │
│ 202610_3_3_1 │    1 │          1250 │      1 │ /var/lib/clickhouse/store/621/62173928-.../202610_3_3_1/ │
└──────────────┴──────┴───────────────┴────────┴──────────────────────────────────────────────────────────┘
```

`active = 1` means the part is currently part of the table. Here is what's inside one of these directories:

```
$ docker exec ch ls -l /var/lib/clickhouse/store/621/62173928-.../202610_1_1_1/
total 52
-rw-r----- 1 clickhouse clickhouse 379 Oct 11 12:45 checksums.txt
-rw-r----- 1 clickhouse clickhouse 254 Oct 11 12:45 columns_substreams.txt
-rw-r----- 1 clickhouse clickhouse 138 Oct 11 12:45 columns.txt
-rw-r----- 1 clickhouse clickhouse   1 Oct 11 12:45 count.txt
-rw-r----- 1 clickhouse clickhouse 161 Oct 11 12:45 data.bin
-rw-r----- 1 clickhouse clickhouse  72 Oct 11 12:45 data.cmrk4
-rw-r----- 1 clickhouse clickhouse  10 Oct 11 12:45 default_compression_codec.txt
-rw-r----- 1 clickhouse clickhouse   1 Oct 11 12:45 metadata_version.txt
-rw-r----- 1 clickhouse clickhouse  16 Oct 11 12:45 minmax_updated_at.idx
-rw-r----- 1 clickhouse clickhouse   4 Oct 11 12:45 partition.dat
-rw-r----- 1 clickhouse clickhouse  50 Oct 11 12:45 primary.cidx
-rw-r----- 1 clickhouse clickhouse 410 Oct 11 12:45 serialization.json
-rw-r----- 1 clickhouse clickhouse 536 Oct 11 12:45 statistics.packed
```

`data.bin` holds the values of all four columns, compressed. `primary.cidx` is the primary index and `data.cmrk4` the marks, which help ClickHouse find rows quickly, and the rest is metadata: row count, column types, the partition, the min and max `updated_at`, and checksums of every file.

How much disk does one order cost? My first answer was 1,250 bytes, the `bytes_on_disk` value from `system.parts`, and that's what went into the first draft. Then I added up the sizes from `ls -l`, got 2,032, and went digging: `bytes_on_disk` only counts the files listed in `checksums.txt` ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataPartChecksum.cpp#L99-L105)), which leaves out a few small metadata files. The column data itself, `data.bin`, is 161 bytes. And the filesystem doesn't care about any of these numbers, because on this container every file takes at least one 4 KiB block:

```
$ docker exec ch du -k /var/lib/clickhouse/store/621/62173928-.../202610_1_1_1/
56	/var/lib/clickhouse/store/621/62173928-.../202610_1_1_1/
```

So one order took 161 bytes of data and 56 KiB of disk, which means a tiny part is almost all overhead.

A big INSERT turns this around. Into a copy of the same table, I inserted one million orders with a single INSERT. They all fall in October, so they became one part:

```
$ docker exec ch ls -l /var/lib/clickhouse/store/a7a/a7a4bb8f-.../202610_1_1_1/
total 12600
-rw-r----- 1 clickhouse clickhouse 3787369 Oct 13 07:15 amount.bin
-rw-r----- 1 clickhouse clickhouse     410 Oct 13 07:15 amount.cmrk2
...
-rw-r----- 1 clickhouse clickhouse 4004915 Oct 13 07:15 order_id.bin
-rw-r----- 1 clickhouse clickhouse     415 Oct 13 07:15 order_id.cmrk2
...
-rw-r----- 1 clickhouse clickhouse    5120 Oct 13 07:15 status.bin
-rw-r----- 1 clickhouse clickhouse      59 Oct 13 07:15 status.dict.bin
...
-rw-r----- 1 clickhouse clickhouse 5019580 Oct 13 07:15 updated_at.bin
-rw-r----- 1 clickhouse clickhouse     429 Oct 13 07:15 updated_at.cmrk2

$ docker exec ch du -k /var/lib/clickhouse/store/a7a/a7a4bb8f-.../202610_1_1_1/
12604	/var/lib/clickhouse/store/a7a/a7a4bb8f-.../202610_1_1_1/
```

This part is *Wide*: each column has its own `.bin` file and its own marks file, which is also why a query that reads one column of a wide table never touches the others. The small metadata files are still there, about the same size as in the one-row part.

| | One order per INSERT | One million orders in one INSERT |
|---|---|---|
| Part type | Compact | Wide |
| Files | 13 | 21 |
| Column data (`.bin` files) | 161 bytes | 12.2 MiB |
| On disk (`du`) | 56 KiB | 12.3 MiB |
| Share that is column data | 0.3% | 99.3% |
| Disk per order | 56 KiB | about 13 bytes |

The overhead of a part is roughly fixed, so with a million rows behind it you stop noticing it: about 13 bytes per order. (My test data flatters this a bit, since `status` cycles through three values and compresses to almost nothing, but the per-part overhead is the same either way.)

So a part never changes: new data means a new part, and combining parts means writing a bigger one and deleting the old ones later. Each part is sorted by `ORDER BY`, but only inside itself, so two parts can both hold the same `order_id`, which is exactly how duplicates happen. Each part also belongs to one partition and carries its own index, marks and checksums, and a `SELECT` reads every active part its indexes don't rule out.

The part name `202610_1_1_1` encodes its history. The [official docs for `system.parts`](https://clickhouse.com/docs/operations/system-tables/parts) explain the format:

> The part naming format is the following:
>
> ```text
> <partition_id>_<minimum_block_number>_<maximum_block_number>_<level>_<data_version>
> ```
>
> - `partition_id` - identifies the partition key
> - `minimum_block_number` - identifies the minimum block number in the part. ClickHouse always merges continuous blocks
> - `maximum_block_number` - identifies the maximum block number in the part
> - `level` - incremented by one with each additional merge on the part. A level of 0 indicates this is a new part that has not been merged. It is important to remember that all parts in ClickHouse are always immutable
> - `data_version` - optional value, incremented when a part is mutated (again, mutated data is always only written to a new part, since parts are immutable)

So `202610_1_1_1` is partition `202610`, blocks 1 to 1, level 1. The level surprised me, since the docs say a new part starts at 0. It turns out `ReplacingMergeTree` runs its merge logic on every inserted block before writing it, so its new parts count as merged once already. The block number raised even more questions, because "block" means three different things in ClickHouse.

I followed both rabbit holes, together with everything else the server does inside one INSERT: splitting rows by partition, sorting, writing marks and the primary index, and the commit. That turned into a post of its own, [Inside one INSERT](/posts/clickhouse-inside-one-insert/), which is Part 3 of this series. You don't need it for the rest of this one.

## 2. Too many parts

> "Why are we getting `Too many parts` errors?"

Every part costs files on disk, metadata in memory, and a future merge. If a partition piles up parts faster than merges can combine them, ClickHouse protects itself: at 1000 active parts in a partition (`parts_to_delay_insert`) it starts slowing INSERTs down on purpose, and at 3000 (`parts_to_throw_insert`) it rejects them with `Too many parts`. Those are the current defaults. A lot of older posts still quote 150 and 300, which were the defaults before 23.6.

The classic cause is many small INSERTs. To see it, I used a separate test table and sent it 50 single-row INSERTs concurrently, with merges stopped:

```bash
for i in $(seq 1 50); do
  docker exec ch clickhouse-client --async_insert=0 -q "INSERT INTO ins_test (id) VALUES ($i)" &
done; wait
```

With `async_insert = 0`, the 50 rows became 50 parts. Running the same loop with `async_insert = 1` gave 7 parts for the same 50 rows. With *asynchronous inserts*, the server buffers incoming INSERTs and writes one part per flush. A flush happens after 200 ms (`async_insert_busy_timeout_max_ms`) or 10 MiB (`async_insert_max_data_size`). Since 26.2, `async_insert` is on by default.

Since async inserts are on by default now, I assumed they had already batched my three single-row INSERTs into `orders`. They hadn't. With `wait_for_async_insert = 1` (the safe default) each INSERT waits until its data is flushed, so a client that sends INSERTs one after another never shares a buffer with anyone. Async inserts batch *concurrent* writers, like many app servers or Lambdas; a single sequential loop still has to batch on the client side.

<!-- TODO(you): add a sentence from your own experience — what's your ingestion pattern? -->

## 3. Merges, and why nothing happened for six minutes

Background merges combine adjacent parts within one partition into a bigger part, using a streaming k-way merge of already-sorted data. Let's turn them back on:

```sql
SYSTEM START MERGES orders;
```

I expected a merge within seconds. Nothing happened. Thirty seconds later the three parts were still there, and they stayed separate for the next six minutes while I wondered whether I'd forgotten something.

The reason is in [`SimpleMergeSelector.h`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/Compaction/MergeSelectors/SimpleMergeSelector.h#L117): the selector prefers to merge about five parts of similar size at once (`base = 5`), which keeps write amplification low, and relaxes that only gradually as parts get older or more numerous. Three tiny, fresh parts aren't worth it yet. That's the 26.9 behaviour, at least; the selector has its own table settings, and its rules change between releases.

So I inserted three more orders. ClickHouse records every part event in `system.part_log`:

```sql
SELECT event_time_microseconds AS t, event_type, part_name, merged_from, rows
FROM system.part_log
WHERE table = 'orders'
ORDER BY t;
```

```
┌──────────────────────────t─┬─event_type──────┬─part_name────┬─merged_from──────────────────────────────────────────┬─rows─┐
│ 2026-10-10 11:10:22.332555 │ NewPart         │ 202610_1_1_1 │ []                                                   │    1 │
│ 2026-10-10 11:10:22.489426 │ NewPart         │ 202610_2_2_1 │ []                                                   │    1 │
│ 2026-10-10 11:10:22.654394 │ NewPart         │ 202610_3_3_1 │ []                                                   │    1 │
│ 2026-10-10 11:16:09.673250 │ NewPart         │ 202610_4_4_1 │ []                                                   │    1 │
│ 2026-10-10 11:16:09.829828 │ NewPart         │ 202610_5_5_1 │ []                                                   │    1 │
│ 2026-10-10 11:16:09.830053 │ MergePartsStart │ 202610_1_5_2 │ ['202610_1_1_1','202610_2_2_1',...,'202610_5_5_1']   │    0 │
│ 2026-10-10 11:16:09.832240 │ MergeParts      │ 202610_1_5_2 │ ['202610_1_1_1','202610_2_2_1',...,'202610_5_5_1']   │    5 │
│ 2026-10-10 11:16:09.984342 │ NewPart         │ 202610_6_6_1 │ []                                                   │    1 │
└────────────────────────────┴─────────────────┴──────────────┴──────────────────────────────────────────────────────┴──────┘
```

The first three parts waited almost six minutes, but when the fifth part arrived, a merge of exactly five parts started 0.2 ms later. The result, `202610_1_5_2`, covers blocks 1–5 at level 2, and the sixth part is left waiting for company.

<!-- TODO(us): timeline chart from part_log — x = time, one bar per part, merged parts connected -->

Merged-away parts stay on disk as `active = 0` for another 8 minutes (`old_parts_lifetime`), so queries already reading them can finish.

What I take from this: merges are eventual, and you can't predict when, or even whether, two given rows end up in the same part. The six minutes and the five parts are just what I saw in one run, not numbers to plan around. And merges never cross partitions, which matters a lot in the next section.

## 4. Updating the order: duplicates and FINAL

> "Why do I still see the old value? I'm using `ReplicatedReplacingMergeTree`."

Order 1 gets paid. In a `ReplacingMergeTree`, an update is just another INSERT with a newer version:

```sql
INSERT INTO orders VALUES (1, 'paid', 10.00, now64());

SELECT * FROM orders WHERE order_id = 1;
```

```
┌─order_id─┬─status──┬─amount─┬──────────────updated_at─┐
│        1 │ created │     10 │ 2026-10-10 11:10:22.330 │
│        1 │ paid    │     10 │ 2026-10-10 11:16:26.581 │
└──────────┴─────────┴────────┴─────────────────────────┘
```

Two rows, because the old version is in one part and the new one in another, and nothing has merged them yet. You can read it correctly either way:

```sql
-- Let ClickHouse apply the merge logic at read time
SELECT * FROM orders FINAL WHERE order_id = 1;          -- paid

-- Or deduplicate yourself
SELECT order_id, argMax(status, updated_at) AS status
FROM orders WHERE order_id = 1 GROUP BY order_id;       -- paid
```

`FINAL` has a reputation for being slow, but much of that advice is old: today it runs in parallel and skips parts that can't contain duplicates (that's where those level-1 parts help). Its cost still depends on the table layout and the query, so for anything performance-sensitive I'd measure it against `argMax`.

### The partition trap

Now the order ships, and the shipment is recorded in November:

```sql
INSERT INTO orders VALUES (1, 'shipped', 10.00, '2026-11-02 09:00:00');
OPTIMIZE TABLE orders FINAL;   -- force a merge in every partition

SELECT _partition_id, _part, * FROM orders WHERE order_id = 1;
```

```
┌─_partition_id─┬─_part────────┬─order_id─┬─status──┬──────────────updated_at─┐
│ 202610        │ 202610_1_7_3 │        1 │ paid    │ 2026-10-10 11:16:26.581 │
│ 202611        │ 202611_8_8_2 │        1 │ shipped │ 2026-11-02 09:00:00.000 │
└───────────────┴──────────────┴──────────┴─────────┴─────────────────────────┘
```

Even after a forced full merge the duplicate is still there, and it will stay there forever, because the two versions are in different partitions and merges never cross partitions. `FINAL` still returns the right answer, because by default it deduplicates across partitions at read time, on every query. But turn on the popular optimization for `FINAL`:

```sql
SELECT * FROM orders FINAL WHERE order_id = 1
SETTINGS do_not_merge_across_partitions_select_final = 1;
```

```
┌─order_id─┬─status──┬──────────────updated_at─┐
│        1 │ shipped │ 2026-11-02 09:00:00.000 │
│        1 │ paid    │ 2026-10-10 11:16:26.581 │
└──────────┴─────────┴─────────────────────────┘
```

That's two rows for one order, with no error and no warning. If I had to pick one thing from this whole post to remember, it would be this: in a `ReplacingMergeTree`, every version of a row has to land in the same partition. Partition by something that never changes for a key, such as `toYYYYMM(created_at)`, or don't partition at all.

## Back to the coffee break

The short answers are in the TL;DR at the top. If I had to boil the rest down for a colleague: batch your INSERTs on the client, because async inserts only help with many concurrent writers. Don't panic about a few small parts, since merges are lazy on purpose, and `system.parts` and `system.part_log` will show you what's going on. Pick a partition key that never changes for a row, and read with `FINAL` or `argMax` instead of scheduling `OPTIMIZE ... FINAL` to clean up duplicates. Merges save storage, but your queries have to be correct without them.

## Further reading

If you want to go further, Tom Schreiber's [Supercharging your large ClickHouse data loads](https://clickhouse.com/blog/supercharge-your-clickhouse-data-loads-part1) is the best thing I found on insert block size and parallelism, and the docs have a page on [the too many parts problem](https://clickhouse.com/docs/tips-and-tricks/too-many-parts). For the internals, see [Inside one INSERT](/posts/clickhouse-inside-one-insert/) (Part 3) and [`SimpleMergeSelector.h`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/Compaction/MergeSelectors/SimpleMergeSelector.h).

All the SQL from these experiments is in [one script](follow-one-row.sql) you can run against a fresh container.
