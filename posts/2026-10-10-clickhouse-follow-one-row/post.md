---
title: "Follow one row: what ClickHouse does with your INSERT"
date: 2026-10-10
description: "What happens to a row in ClickHouse from INSERT to merge: blocks, parts, merges and FINAL, traced with real output from 26.9 and the source code."
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

## Preparations

Before we look inside ClickHouse, let's do some preparations. We'll use Docker for simplicity and one small table. Every query here is in [one script](follow-one-row.sql), so you can check any claim yourself as you read.

```bash
docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
docker exec -it ch clickhouse-client
```

Everything happens inside this container. The SQL runs in the `clickhouse-client` session you just opened. Shell commands run through `docker exec ch ...`, and paths like `/var/lib/clickhouse/...` are paths inside the container, not on your machine.

Everything here ran on ClickHouse 26.9. Several defaults changed recently, so on an older version some numbers will differ. I use the non-replicated engines to keep the setup to one container. Everything applies to `ReplicatedReplacingMergeTree` and the other `Replicated*` engines too. The only difference is who decides which parts to merge:

- In a plain `MergeTree`, the server picks the parts and merges them itself.
- In a `Replicated*` table, a replica that is allowed to assign merges (a *leader*) picks the parts and writes a "merge these parts" entry into the replication log in Keeper ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/StorageReplicatedMergeTree.cpp#L4730)). Every replica reads that entry and runs the same merge on its own copy of the data. In some cases, such as very large parts, a replica downloads the finished part from another replica instead ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeFromLogEntryTask.cpp#L101-L112)).

Either way, the merge is the same code with the same engine rules, so what this post shows holds for replicated tables too.

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

Three INSERTs, three parts.

### What is a part, actually?

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

The most important files:

| File | What's inside |
|---|---|
| `data.bin` | The values of all four columns, compressed |
| `primary.cidx` | The primary index: a few `order_id` values that help find rows quickly |
| `data.cmrk4` | Marks: where in `data.bin` each group of rows starts |
| `count.txt` | The number of rows (`1`) |
| `columns.txt` | Column names and types |
| `partition.dat`, `minmax_updated_at.idx` | The partition, and the smallest and largest `updated_at` in the part |
| `checksums.txt` | A checksum of every file, to detect corruption |

So how much space does one order take? The same part gives three different answers:

- **161 bytes** is the size of `data.bin` in the listing above, which holds this part's one row, compressed. It depends on the column types and the compression, so it isn't a fixed cost per row.
- **1,250 bytes** is what `system.parts` reports as `bytes_on_disk`. It adds up the files listed in `checksums.txt` ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataPartChecksum.cpp#L99-L105)), which leaves out `checksums.txt` itself and four small metadata files.
- **56 KiB** is what the filesystem uses. On this container's filesystem, every file takes at least one 4 KiB block, and there are 13 files plus the directory:

```
$ docker exec ch du -k /var/lib/clickhouse/store/621/62173928-.../202610_1_1_1/
56	/var/lib/clickhouse/store/621/62173928-.../202610_1_1_1/
```

Here, one order took 161 bytes of data and 56 KiB of disk. A tiny part is almost all overhead.

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

This part is *Wide*: each column has its own `.bin` file with its own marks. The small files are still there, and they're about the same size as in the one-row part.

| | One order per INSERT | One million orders in one INSERT |
|---|---|---|
| Part type | Compact | Wide |
| Files | 13 | 21 |
| Column data (`.bin` files) | 161 bytes | 12.2 MiB |
| On disk (`du`) | 56 KiB | 12.3 MiB |
| Share that is column data | 0.3% | 99.3% |
| Disk per order | 56 KiB | about 13 bytes |

The overhead of a part is roughly fixed. Spread over a million rows, it disappears. One caveat about my test data: `status` cycles through three values in a fixed order, so it compresses almost to nothing (5 KiB for a million rows). Real data compresses less, but the per-part overhead stays the same.

These parts are small, so all columns share one `data.bin`. A bigger part gets a separate file for each column instead: `order_id.bin`, `status.bin`, `amount.bin`, `updated_at.bin`, each with its own marks file. That's why a query that reads one column of a wide table doesn't touch the others.

Four properties make a part a part:

- **It never changes.** ClickHouse never adds rows to an existing part or edits one in place. New data means a new part. Combining parts means writing a new, bigger part and deleting the old ones later.
- **It's sorted, but only inside itself.** The rows in a part are in `ORDER BY` order. Two parts know nothing about each other, so they can hold overlapping keys, even the same `order_id`.
- **It belongs to exactly one partition.** All rows in `202610_1_1_1` are from October 2026.
- **It's self-contained.** It carries its own index, marks, column list and checksums. To answer a `SELECT`, ClickHouse reads every active part of the table, skipping the ones its indexes rule out, and combines the results.

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

So `202610_1_1_1` is partition `202610`, blocks 1 to 1, level 1.

Hold on. *Block* number?

### What is a block, actually?

The word shows up everywhere in ClickHouse, and I had never stopped to ask whether it always means the same thing:

- in settings: `max_block_size`, `max_insert_block_size`, `min_insert_block_size_rows`
- in the server log: *"Wrote block with 9 rows"*
- in insert deduplication: *"Block with ID … already exists"*
- in compression: `min_compress_block_size`
- and in the part name we just decoded: "block number"

It doesn't. "Block" means three different things:

| Term | What it is | Where you see it |
|---|---|---|
| Block (in memory) | A batch of rows held as columns, the unit every part of ClickHouse processes | Settings like `max_insert_block_size`, *"Wrote block with N rows"* in logs, deduplication block IDs (a hash of an insert block) |
| Block number | A number from a counter, taken each time a new part is committed. One INSERT that creates three parts takes three numbers | Part names: `202610_1_1_1` |
| Compressed block | A chunk of one column file, compressed as a unit (made from 64 KiB to 1 MiB of uncompressed data) | Inside `.bin` files, in marks |

ClickHouse's main execution path works on blocks, not single rows. Parsing an INSERT, filtering in a SELECT and writing a part all work on a `Block` ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Core/Block.h#L25-L40)):

```cpp
/** Container for set of columns for bunch of rows in memory.
  * This is unit of data processing.
  * Also contains metadata - data types of columns and their names
  *  (either original names from a table, or generated names during temporary calculations).
  * Allows to insert, remove columns in arbitrary position, to change order of columns.
  */
class Block
{
private:
    using Container = ColumnsWithTypeAndName;
    // ...
    Container data;
```

Each element of `data` is a column with its type and name ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Core/ColumnWithTypeAndName.h#L20-L24)).

For our `orders` table, a block of three rows looks like this in memory:

```
Block (3 rows)
├── order_id    UInt64                  [1, 2, 3]
├── status      LowCardinality(String)  dictionary ['', 'created'], indexes [1, 1, 1]
├── amount      Decimal(10, 2)          [1000, 1000, 1000]     (stored as integers, scale 2)
└── updated_at  DateTime64(3)           [1791630622330, ...]   (milliseconds since epoch)
```

Each column is a contiguous array of values of one type. That layout lets ClickHouse run [tight loops over thousands of values at once](https://clickhouse.com/docs/concepts/why-clickhouse-is-so-fast#state-of-the-art-query-processing-layer), use SIMD instructions, and [compress columns well](https://clickhouse.com/docs/data-compression/compression-in-clickhouse). Inside the query pipeline the same data travels as a `Chunk`: the same columns, but without names and types, which the pipeline already knows from its header. `MergeTreeSink` turns each incoming `Chunk` back into a `Block` as its first step ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeSink.cpp#L140)).

#### How big is a block?

For a SELECT, blocks hold up to `max_block_size` = 65,409 rows. You can see the block boundaries with `blockNumber` and `blockSize`:

```sql
SELECT min(bs), max(bs), uniqExact(bn) AS blocks
FROM (SELECT blockSize() AS bs, blockNumber() AS bn FROM numbers(1000000));
```

```
┌─min(bs)─┬─max(bs)─┬─blocks─┐
│   18865 │   65409 │     16 │
└─────────┴─────────┴────────┘
```

One million rows travel as 16 blocks: 15 full ones of 65,409 rows and one of 18,865.

For an INSERT, ClickHouse wants much bigger blocks, because every insert block becomes at least one part. How big a block gets depends on how the data arrives:

- **`INSERT ... VALUES`, or a file in CSV, JSON and similar formats:** ClickHouse cuts the data into blocks of up to about 1 million rows (`max_insert_block_size`). A typical INSERT from an application is smaller than that, so it's a single block.
- **`INSERT ... SELECT`:** the SELECT produces small blocks of 65,409 rows. Before they reach the table, ClickHouse glues them together until a block has about 1 million rows (`min_insert_block_size_rows`) or 256 MiB (`min_insert_block_size_bytes`), whichever comes first ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Interpreters/InterpreterInsertQuery.cpp#L634-L665)).
- **Async inserts:** ClickHouse collects many small INSERTs in a buffer on the server and writes each full buffer as one block. So many small INSERTs from different clients end up in a few parts instead of one part each.

One order is far too small to hit these limits, so I used a separate test table. I ran two big `INSERT ... SELECT`s into it with merges switched off:

```sql
INSERT INTO blocks_demo SELECT number, '' FROM numbers(3000000);                      -- small rows
INSERT INTO blocks_demo SELECT number, randomPrintableASCII(1000) FROM numbers(600000); -- 1 KB rows
```

| INSERT | Parts created | Why |
|---|---|---|
| 3 million small rows | 3 | Each block hit the 1-million-row limit, and the last part got the rest |
| 600,000 rows of 1 KB | 2 | The 256 MiB limit came first |

The parts are slightly bigger than the limit (1,111,953 rows, not 1 million) because ClickHouse adds whole 65,409-row blocks until it crosses the limit.

So the full rule is one part per partition per insert block. A big `INSERT ... SELECT` creates several parts even in one partition. That's fine: the parts are large, and merges combine them later.

### Inside one INSERT, step by step

So far every INSERT carried a single order. Real pipelines send batches, and one batch can cover several months. To see the whole path, I sent one INSERT with 20 orders spread over three months and streamed the server log to the client:

```bash
docker exec ch clickhouse-client --send_logs_level=trace --async_insert=0 -q "
  INSERT INTO orders
  SELECT number + 100, 'created', 10,
         toDateTime64('2026-10-05 00:00:00', 3) + number * 86400 * 3
  FROM numbers(20)"
```

Trimmed log (block numbers start at 9 because this ran after the other experiments):

```
Trying to reserve 1.00 MiB using storage policy from min volume index 0
MergedBlockOutputStream: filled checksums 202610_9_9_1 (state Temporary)
Wrote block with 9 rows ...
MergedBlockOutputStream: filled checksums 202611_10_10_1 (state Temporary)
Wrote block with 10 rows ...
Allocated block number 9
Renaming temporary part tmp_insert_202610_9_9_1 to 202610_9_9_1 ...
MergedBlockOutputStream: filled checksums 202612_11_11_1 (state Temporary)
Wrote block with 1 rows ...
Allocated block number 10
Renaming temporary part tmp_insert_202611_10_10_1 to 202611_10_10_1 ...
Allocated block number 11
Renaming temporary part tmp_insert_202612_11_11_1 to 202612_11_11_1 ...
```

One INSERT, three parts: 9 rows for October, 10 for November, 1 for December. Let's go through what produced these log lines, one step at a time, in the order it happens.

All of it is done by `MergeTreeSink`, the code that receives insert blocks for a `MergeTree` table ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeSink.cpp#L135-L290)). Before it writes anything, it checks how many parts the table already has. If there are too many, the INSERT is slowed down or rejected with `Too many parts`. Then the six steps begin.

#### Step 1: split the block by partition

Our INSERT has rows for three months, but a part always belongs to exactly one partition. So first, ClickHouse works out which partition each row belongs to, and cuts the block into one block per partition.

**First, it calculates the partition key for every row.** `PARTITION BY toYYYYMM(updated_at)` is an ordinary expression, and ClickHouse runs it on the whole block the same way a `SELECT` would ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreePartition.cpp#L515-L528)). So you can run it yourself on the same 20 rows and predict the parts before inserting anything:

```sql
SELECT toYYYYMM(updated_at) AS partition, count() AS rows,
       min(updated_at), max(updated_at)
FROM (SELECT toDateTime64('2026-10-05 00:00:00', 3) + number * 86400 * 3 AS updated_at
      FROM numbers(20))
GROUP BY partition ORDER BY partition;
```

```
┌─partition─┬─rows─┬─────────min(updated_at)─┬─────────max(updated_at)─┐
│    202610 │    9 │ 2026-10-05 00:00:00.000 │ 2026-10-29 00:00:00.000 │
│    202611 │   10 │ 2026-11-01 00:00:00.000 │ 2026-11-28 00:00:00.000 │
│    202612 │    1 │ 2026-12-01 00:00:00.000 │ 2026-12-01 00:00:00.000 │
└───────────┴──────┴─────────────────────────┴─────────────────────────┘
```

These are exactly the 9, 10 and 1 rows from the log.

The month is counted in the column's timezone. With `updated_at DateTime64(3, 'America/New_York')`, an order from `2026-11-01 02:00` UTC is `2026-10-31 22:00` in New York, and I checked that it lands in partition `202610`. Without a timezone in the column type, the server's timezone is used.

**Then it groups the rows by that value** ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L498-L580)):

```cpp
// MergeTreeDataWriter::splitBlockIntoParts
if (all_partition_columns_are_equal)
{
    /// A typical case is when there is one partition (you do not need to split anything).
    result.emplace_back(std::make_shared<Block>(std::move(block)), get_partition(0));
    // ...
    return result;
}

buildScatterSelector(partition_columns_raw_ptrs, partition_num_to_first_row, selector, max_parts, context);
// ...
for (size_t col = 0; col < block.columns(); ++col)
{
    auto scattered = block.getByPosition(col).column->scatter(partitions_count, selector);
    for (size_t i = 0; i < partitions_count; ++i)
        result[i].block->getByPosition(col).column = std::move(scattered[i]);
}
```

If all rows have the same partition value, which is the common case, the block passes through without copying. Otherwise `buildScatterSelector` goes through the rows once and gives every new value the next number: `202610` becomes 0, `202611` becomes 1, `202612` becomes 2. Then `scatter` splits each column into one column per partition. Data is columnar even in memory, so the split works column by column, not row by row.

**Then it turns the value into a partition ID**, the string you see at the start of the part name ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreePartition.cpp#L231-L285)). The comment in the code explains the rule:

```cpp
/// In case all partition fields are represented by integral types, try to produce a human-readable ID.
/// Otherwise use a hex-encoded hash.
```

I created a few small tables with different partition keys and inserted one row into each:

| `PARTITION BY` | `partition` (the value) | `partition_id` (in the part name) |
|---|---|---|
| `toYYYYMM(d)` | `202610` | `202610` |
| `d` (a `Date`) | `2026-10-10` | `20261010` |
| `(tenant_id, toYYYYMM(d))` | `(42,202610)` | `42-202610` |
| `region` (a `String`) | `EU` | `01cc1803efc6da56563d1f71ddecd090` |
| no `PARTITION BY` | `tuple()` | `all` |

Numbers and dates give readable IDs. A string gives a hash, so to drop that partition you write the value, `ALTER TABLE ... DROP PARTITION 'EU'`, not the ID. `system.parts` shows both, in the `partition` and `partition_id` columns.

**Finally, it checks the limit.** One insert block may touch at most 100 partitions (`max_partitions_per_insert_block`). I inserted 101 months in one go:

```
Code: 252. DB::Exception: Too many partitions for single INSERT block (more than 100).
The limit is controlled by 'max_partitions_per_insert_block' setting. Large number of partitions
is a common misconception. ... Please note, that partitioning is not intended to speed up SELECT
queries (ORDER BY key is sufficient to make range queries fast). Partitions are intended for
data manipulation (DROP PARTITION, etc).. (TOO_MANY_PARTS)
```

The whole INSERT failed and no parts were created. The message itself is good advice: partition by something coarse, like a month, and let `ORDER BY` do the work for queries.

Every resulting block becomes its own part. That's why a single INSERT spanning three months created three parts. Steps 2 to 5 now run for each of these blocks separately.

#### Step 2: sort, without moving any rows

Rows in a part are always stored in `ORDER BY` order, so next the block is sorted by the sorting key ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L878-L888)):

```cpp
// MergeTreeDataWriter::writeTempPartImpl
if (!isAlreadySorted(block, sort_description))
{
    stableGetPermutation(block, sort_description, perm);
    perm_ptr = &perm;
}
else
    ProfileEvents::increment(ProfileEvents::MergeTreeDataWriterBlocksAlreadySorted);
```

Sorting here means computing a *permutation*, an array that says "row 5 goes first, then row 2, then …". Columns are reordered one at a time later, right before each one is written to disk. Two details matter:

- **The sort is stable.** Rows with equal keys keep their order from the INSERT. That matters in a `ReplacingMergeTree` without a version column: when one INSERT carries several versions of a row, the last one is kept. Between parts, the part committed later wins. Our `orders` table has a version column, `updated_at`, so there the highest version wins in any order.
- **Already-sorted input is detected and skipped.** The check is cheap compared with a sort.

Sorting one order takes no time at all, so to measure it I used a separate table with `ORDER BY id`. I inserted the same million rows twice, once in order and once shuffled, and read the profile counters from `system.query_log`:

```sql
SELECT query_id,
       ProfileEvents['MergeTreeDataWriterBlocksAlreadySorted'] AS already_sorted,
       ProfileEvents['MergeTreeDataWriterSortingBlocksMicroseconds'] / 1000 AS sort_ms
FROM system.query_log
WHERE query_id IN ('blog_sorted', 'blog_shuffled') AND type = 'QueryFinish';
```

| Input | Already sorted? | Time spent sorting |
|---|---|---|
| 1M rows in `ORDER BY` order | yes | 1.3 ms |
| The same rows shuffled | no | 52.2 ms |

These timings are from my laptop (Apple M1 Pro, Docker Desktop), so treat them as an illustration. The shuffled time varies between runs (36 to 52 ms in mine), but sorted input stays roughly 30 to 40 times cheaper. The check is exact: a block must be fully sorted by the whole `ORDER BY` key, and a block that is only mostly sorted gets sorted as usual. So if your pipeline can send each batch already sorted by the key, for example by event time when time leads the key, ClickHouse skips that work.

#### Step 3: merge on insert, and why the level is 1

The official docs say *"A level of 0 indicates this is a new part that has not been merged"*, and so does almost every blog post. That's true for a plain `MergeTree`. For `ReplacingMergeTree`, and for the other engines that apply logic on merge (`Summing`, `Aggregating`, `Collapsing`), ClickHouse runs that same logic on the sorted block before writing it:

```cpp
const bool optimize_on_insert = !isPatchPartitionId(partition_id)
    && global_settings[Setting::optimize_on_insert]
    && data.merging_params.mode != MergeTreeData::MergingParams::Ordinary;
UInt32 new_part_level = optimize_on_insert ? 1 : 0;
// ...
if (optimize_on_insert)
    block = mergeBlock(std::move(block), metadata_snapshot, sort_description, perm_ptr, data.merging_params);
```

[Source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L809-L813)

The setting `optimize_on_insert` is on by default. The merge logic has already run on the new part once, so it starts at level 1. In practice, if you insert two versions of the same order in the same INSERT, only the latest one is written. Duplicates can only exist *between* parts. It also helps `FINAL`: a part with level above 0 whose key range doesn't overlap any other part is read without the merge step ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/QueryPlan/ReadFromMergeTree.cpp#L2516)).

#### Step 4: choose the part format and the granule size

The rows are ready. Before writing them, ClickHouse decides how the part will be laid out on disk, starting with its format ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L992)).

The expected size is the block's size in memory. Below `min_bytes_for_wide_part` (10 MiB) the part is *Compact*: all columns go into one `data.bin`, which keeps tiny inserts from creating a file per column. Above it, the part is *Wide*, with one `.bin` file per column.

Next, ClickHouse decides how many rows go into each *granule*, the unit the primary index points to ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeIndexGranularity.cpp#L115-L160)). A granule holds `min(8192, 10 MiB / average row size)` rows. With narrow rows like ours that's always 8192. With wide rows, for example a 50 KB JSON payload, a granule shrinks to about 200 rows, so reading "one granule" doesn't mean reading hundreds of megabytes.

#### Step 5: write the columns, the marks and the primary index

For a Wide part, the writer goes column by column ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataPartWriterWide.cpp#L366-L460)).

This is where the permutation computed during sorting is finally applied. Only one column at a time is held in sorted order, so memory use stays low even for wide tables.

Each column is compressed in blocks made from 64 KiB to 1 MiB of uncompressed data (`min_compress_block_size`, `max_compress_block_size`). On disk they're usually smaller: in the table below, each 64 KiB block of `id` takes about 32 KiB. At the start of every granule, the writer records a *mark*, the address of that granule inside the column file ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataPartWriterWide.cpp#L487-L520)).

A mark has two numbers: where the compressed block starts in the `.bin` file, and where the granule starts inside that block once it's decompressed. Before recording the mark, the writer closes the current compressed block if it already holds at least 64 KiB, so granules tend to start at block boundaries.

The *primary index* gets one entry per granule: the sorting-key value of the granule's first row ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataPartWriterOnDisk.cpp#L252-L284)).

You can see both structures with the `mergeTreeIndex` table function. Our tiny `orders` parts have just one granule each, so here is a separate table with one million rows `(id UInt64, v String)` and `ORDER BY id`:

```sql
SELECT mark_number, rows_in_granule, id AS index_value,
       (id.mark.offset_in_compressed_file, id.mark.offset_in_decompressed_block) AS id_mark,
       (v.mark.offset_in_compressed_file,  v.mark.offset_in_decompressed_block)  AS v_mark
FROM mergeTreeIndex(currentDatabase(), index_demo, with_marks = true);
```

```
┌─mark_number─┬─rows_in_granule─┬─index_value─┬─id_mark────────┬─v_mark─────────┐
│           0 │            8192 │           0 │ (0,0)          │ (0,0)          │
│           1 │            8192 │        8192 │ (32796,0)      │ (0,31658)      │
│           2 │            8192 │       16384 │ (65610,0)      │ (64347,0)      │
│           3 │            8192 │       24576 │ (98422,0)      │ (64347,40960)  │
│         ... │                 │             │                │                │
│         122 │             576 │      999424 │ (4002578,0)    │ (4083254,0)    │
│         123 │               0 │      999999 │ (4002578,4608) │ (4083254,3456) │
└─────────────┴─────────────────┴─────────────┴────────────────┴────────────────┘
```

How to read it:

- **The whole primary index for a million rows is 124 values.** `system.parts` reports `primary_key_bytes_in_memory` = 992 bytes. That's why a sparse index fits in RAM even for billions of rows.
- **`index_value`** is the key of each granule's first row. To find `id = 20000`, ClickHouse binary-searches these values, sees that it falls in granule 2 (16384–24575), and reads only that granule.
- **`id` starts a new compressed block at every granule**, so its second number is always 0. A granule of `id` is 8192 × 8 bytes = 64 KiB, exactly `min_compress_block_size`.
- **`v` (short strings) is smaller per granule**, so two granules share one compressed block. Mark 1 says: decompress the block at file offset 0, then skip 31,658 bytes.
- **The last granule has 576 rows** (1,000,000 − 122 × 8192). Mark 123 is a final mark with 0 rows that records the end of the data and the last key.

All of this goes into the part's `tmp_insert_...` directory:

- the column values into `data.bin`, or into one `.bin` file per column in a Wide part
- the marks into `data.cmrk4`, or one `.cmrk2` file per column
- the primary index into `primary.cidx`
- the smallest and largest `updated_at` into `minmax_updated_at.idx`, which lets a query skip the whole part
- plus `checksums.txt`, `columns.txt` and `count.txt`

Once a part is fully written, the log says *"Wrote block with 9 rows"*. The part is complete on disk, but nobody can see it yet.

#### Step 6: commit: get a block number and rename

So far the part is invisible: its directory starts with `tmp_insert_`, and queries never look at such directories. If the server crashes now, the directory is just garbage that ClickHouse removes later. Making the part visible happens in `commitPart` ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeSink.cpp#L412-L463)):

```cpp
MergeTreeData::Transaction transaction(storage, context->getCurrentTransaction().get());
{
    auto lock = storage.lockParts();
    auto block_holder = storage.fillNewPartName(part, lock);
    // ... deduplication check ...
    storage.renameTempPartAndAdd(part, transaction, lock, /*rename_in_transaction=*/ false);
    transaction.commit(lock);
}
```

Under the table's parts lock, three things happen:

1. **The block number is assigned now, not when the data was written.** `fillNewPartName` takes the next number from the table's counter and sets the part's name ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/StorageMergeTree.cpp#L4808-L4817)). That's the "Allocated block number 9" log line. Block numbers therefore follow commit order, which is what lets merges reason about "newer" and "older" parts. In a non-replicated table, one counter serves the whole table, so the three parts of our 20-order INSERT got 9, 10 and 11 even though they're in different partitions. `Replicated` tables keep a separate counter for each partition in Keeper ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/StorageReplicatedMergeTree.cpp#L7948-L7988)).
2. **The directory is renamed** from `tmp_insert_202610_9_9_1` to `202610_9_9_1`. A rename within one filesystem is atomic, so readers see either no part or the complete part, never half of one.
3. **The part joins the table's set of active parts.** Queries that start after this point include it.

After the commit, the sink records the new part in `system.part_log` (a `NewPart` event) and wakes up the background merge scheduler ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeSink.cpp#L334)).

Every INSERT asks for a merge, but that doesn't mean one happens. The merge selector decides whether merging is worth it yet.

You can see the counters for any of your own INSERTs:

```sql
SELECT k AS event, v AS value
FROM system.query_log
ARRAY JOIN mapKeys(ProfileEvents) AS k, mapValues(ProfileEvents) AS v
WHERE query_id = '<your insert query id>' AND type = 'QueryFinish'
  AND k LIKE 'MergeTreeDataWriter%';
```

For the 20-row INSERT above: `MergeTreeDataWriterBlocks` = 3 (one per partition), `MergeTreeDataWriterBlocksAlreadySorted` = 3, `MergeTreeDataWriterRows` = 20.

## 2. Too many parts

> "Why are we getting `Too many parts` errors?"

Every part costs files on disk, metadata in memory, and a future merge. If a partition accumulates parts faster than merges can combine them, ClickHouse protects itself:

- At `parts_to_delay_insert` = 1000 active parts in a partition, INSERTs are slowed down artificially.
- At `parts_to_throw_insert` = 3000, INSERTs fail with `Too many parts`.

These are the current defaults. Older posts quote 150/300, which were the defaults before 23.6.

The classic cause is many small INSERTs. To see it, I used a separate test table and sent it 50 single-row INSERTs concurrently, with merges stopped:

```bash
for i in $(seq 1 50); do
  docker exec ch clickhouse-client --async_insert=0 -q "INSERT INTO ins_test (id) VALUES ($i)" &
done; wait
```

| Mode | Parts created | Rows |
|---|---|---|
| `async_insert = 0` | 50 | 50 |
| `async_insert = 1` | 7 | 50 |

With *asynchronous inserts*, the server buffers incoming INSERTs and writes one part per flush. A flush happens after 200 ms (`async_insert_busy_timeout_max_ms`) or 10 MiB (`async_insert_max_data_size`). Since 26.2, `async_insert` is on by default.

Async inserts didn't help our `orders` table, though. The three single-row INSERTs into `orders` at the start ran with `async_insert = 1` and still produced three parts. With `wait_for_async_insert = 1` (the safe default), each INSERT waits until its data is flushed. A client that sends INSERTs one after another therefore never shares a buffer with anyone. Async inserts batch *concurrent* writers, for example many app servers, devices or Lambdas. A single sequential loop still has to batch on the client side.

<!-- TODO(you): add a sentence from your own experience — what's your ingestion pattern? -->

## 3. Merges, and why nothing happened for six minutes

Background merges combine adjacent parts within one partition into a bigger part, using a streaming k-way merge of already-sorted data. Let's turn them back on:

```sql
SYSTEM START MERGES orders;
```

Nothing happened. Thirty seconds later, three parts were still there, and they stayed separate for the next six minutes.

The reason is in [`SimpleMergeSelector.h`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/Compaction/MergeSelectors/SimpleMergeSelector.h#L117). The selector prefers to merge about `base = 5` parts of similar size at once, which keeps write amplification low. With fewer parts it relaxes that rule only gradually, as the parts get older (from 10 seconds up to an hour for small parts) or as their count grows (10 to 50 parts). Three tiny, fresh parts aren't worth a merge yet.

That's how the selector decides in 26.9. It has table settings (`merge_selector_base`, `merge_selector_algorithm` and others), and its rules change between releases: one of its heuristics was switched on by default in 26.7.

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

The first three parts waited almost six minutes. When the fifth part arrived, a merge of exactly five parts started 0.2 ms later. The result, `202610_1_5_2`, covers blocks 1–5 at level 2. The sixth part keeps waiting for company.

<!-- TODO(us): timeline chart from part_log — x = time, one bar per part, merged parts connected -->

The merged-away parts don't disappear immediately. They stay as `active = 0` for `old_parts_lifetime` (8 minutes), so queries already reading them can finish.

Two consequences matter in practice:

- **Merges are eventual.** You can't predict when, or whether, two given rows end up in the same part. The six minutes and the five parts are what I saw in one run, not numbers to plan around.
- **Merges never cross partitions.** Keep that in mind for the next section.

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

Two rows. The old version is in one part and the new one in another, and they haven't been merged yet. There are two correct ways to read it:

```sql
-- Let ClickHouse apply the merge logic at read time
SELECT * FROM orders FINAL WHERE order_id = 1;          -- paid

-- Or deduplicate yourself
SELECT order_id, argMax(status, updated_at) AS status
FROM orders WHERE order_id = 1 GROUP BY order_id;       -- paid
```

`FINAL` used to be slow. Today it runs in parallel and skips parts that can't contain duplicates, which is where those level-1 parts help. It's often the simplest way to get deduplicated results. Its cost still depends on the table layout and the query, so for performance-sensitive queries, measure it against `argMax`.

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

Even after a forced full merge, the duplicate is permanent. The two versions are in different partitions, and merges never cross partitions. `FINAL` still returns the right answer, because by default it deduplicates across partitions at read time, on every query. But turn on the popular optimization for `FINAL`:

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

The result is wrong, and there is no error.

**Rule:** in a `ReplacingMergeTree`, every version of a row must land in the same partition. Partition by something that never changes for a key, such as `toYYYYMM(created_at)`, or don't partition at all.

## Back to the coffee break

Here are the short answers I give now:

- **"Why do I still see the old value?"** The new version is in a different part that hasn't been merged yet. Merges are lazy, so that can last a long time. If the versions are in different partitions, they will never be merged. Read with `FINAL` or `argMax`, and make sure every version of a row lands in the same partition.
- **"Why are we getting `Too many parts`?"** A non-empty INSERT normally creates at least one part per partition per insert block. Many small INSERTs, or a partition key that's too fine, create parts faster than merges can combine them. Batch on the client, or use async inserts if you have many concurrent writers.
- **"Why doesn't my `SELECT` show what I expect?"** In `Summing`, `Aggregating` and `Collapsing` tables, merges change the rows themselves, so the answer depends on which merges have happened. That one gets its own post: [Part 2](/posts/clickhouse-merges-change-results/).

And the longer version, as a checklist:

| Area | Rule |
|---|---|
| Ingestion | A non-empty INSERT normally creates at least one part per partition per insert block. The exceptions are async inserts, which combine INSERTs, and, in `Replicated` tables, retries that ClickHouse drops as duplicates. Batch on the client. |
| Ingestion | Async inserts (on by default since 26.2) only help when many clients insert at the same time. |
| Table design | Merges never cross partitions. Choose a partition key that never changes for a row, especially with `ReplacingMergeTree`. |
| Querying | Duplicates are expected until merged. Use `FINAL` or `argMax`, and don't schedule `OPTIMIZE ... FINAL` to fix them. |
| Querying | Merges save storage. Your queries have to be correct without them. |
| Operations | Merges are lazy by design. The selector waits for about five parts of similar size, so a few small parts sitting around is normal. |
| Operations | `system.parts` and `system.part_log` show everything described here. Look at them before tuning anything. |

## Further reading

- [Supercharging your large ClickHouse data loads](https://clickhouse.com/blog/supercharge-your-clickhouse-data-loads-part1) by Tom Schreiber: how insert block size and parallelism affect bulk loads.
- [The too many parts problem](https://clickhouse.com/docs/tips-and-tricks/too-many-parts) in the official docs.
- [`OPTIMIZE TABLE ... FINAL`: when to use it, when to avoid it](https://clickhouse.com/resources/engineering/clickhouse-optimize-table-final).
- Source: [`MergeTreeDataWriter.cpp`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp) (insert to part), [`SimpleMergeSelector.h`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/Compaction/MergeSelectors/SimpleMergeSelector.h) (which parts merge), [`MergeTreeSettings.cpp`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeSettings.cpp) (all the defaults).

All the SQL from these experiments is in [one script](follow-one-row.sql) you can run against a fresh container.
