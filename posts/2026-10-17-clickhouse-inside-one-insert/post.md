---
title: "Inside one INSERT: what the ClickHouse server does, step by step"
date: 2026-10-17
description: "Three things ClickHouse calls a block, how big an insert block gets, and the six steps from INSERT to a committed part: partition split, sort, merge on insert, granules, marks and the commit. Real output from 26.9 and the source code."
tags: [clickhouse]
tested_on: ClickHouse 26.9
series: Inside ClickHouse
part: 3
draft: false
---

In [Part 1](/posts/clickhouse-follow-one-row/) I followed one order from INSERT to merge, and I skipped what happens inside the server in between. This post is that in-between. It's the most source-code-heavy part of the series, and you don't need it to use ClickHouse well. I wrote it because I kept running into questions that only the source could answer: why a brand-new part already has level 1, why "block" seems to mean something different every time I see it, and what exactly the server writes before an INSERT returns.

The setup is the same as in Part 1: one container running ClickHouse 26.9 and the `orders` table.

```bash
docker run -d --name ch --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.9
docker exec -it ch clickhouse-client
```

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

In Part 1, three single-row INSERTs into this table created three parts, the first one named `202610_1_1_1`: partition `202610`, blocks 1 to 1, level 1. Let's start with that word, *block*.

## Three things called a block

The word shows up everywhere in ClickHouse, and I had never stopped to ask whether it always means the same thing:

- in settings: `max_block_size`, `max_insert_block_size`, `min_insert_block_size_rows`
- in the server log: *"Wrote block with 9 rows"*
- in insert deduplication: *"Block with ID … already exists"*
- in compression: `min_compress_block_size`
- and in part names like `202610_1_1_1`, which contain block numbers

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

### How big is a block?

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

For an INSERT, ClickHouse wants much bigger blocks, because every insert block becomes at least one part. How big a block gets depends on how the data arrives. With `INSERT ... VALUES`, or a file in CSV, JSON and similar formats, ClickHouse cuts the data into blocks of up to about 1 million rows (`max_insert_block_size`), and since a typical INSERT from an application is much smaller than that, it ends up as a single block. `INSERT ... SELECT` is different: the SELECT produces small blocks of 65,409 rows, and before they reach the table ClickHouse glues them together until a block has about 1 million rows (`min_insert_block_size_rows`) or 256 MiB (`min_insert_block_size_bytes`), whichever comes first ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Interpreters/InterpreterInsertQuery.cpp#L634-L665)). And with async inserts, ClickHouse collects many small INSERTs in a buffer on the server and writes each full buffer as one block, so lots of small INSERTs from different clients end up in a few parts instead of one part each.

One order is far too small to hit these limits, so I used a separate test table. I ran two big `INSERT ... SELECT`s into it with merges switched off:

```sql
INSERT INTO blocks_demo SELECT number, '' FROM numbers(3000000);                      -- small rows
INSERT INTO blocks_demo SELECT number, randomPrintableASCII(1000) FROM numbers(600000); -- 1 KB rows
```

The 3 million small rows became 3 parts: each block hit the 1-million-row limit, and the last part got whatever was left. The 600,000 rows of 1 KB each became 2 parts, because there the 256 MiB limit came first. The parts are a bit bigger than the limit (1,111,953 rows rather than 1 million), since ClickHouse keeps adding whole 65,409-row blocks until it crosses it.

So the full rule is one part per partition per insert block, and a big `INSERT ... SELECT` creates several parts even within one partition. I don't think that's worth worrying about, though: those parts are large, and merges will combine them later anyway.

## Inside one INSERT, step by step

In Part 1 every INSERT carried a single order. Real pipelines send batches, and one batch can cover several months. To see the whole path, I sent one INSERT with 20 orders spread over three months and streamed the server log to the client:

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

### Step 1: split the block by partition

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

### Step 2: sort, without moving any rows

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

Sorting here means computing a *permutation*, an array that says "row 5 goes first, then row 2, then …". Columns are reordered one at a time later, right before each one is written to disk.

The sort is stable, so rows with equal keys keep their order from the INSERT. That sounds like trivia until you use a `ReplacingMergeTree` without a version column: when one INSERT carries several versions of a row, the last one is the one that's kept, and between parts the part committed later wins. Our `orders` table has a version column, `updated_at`, so for us the highest version wins no matter the order. The other detail is that input which is already sorted gets detected and skipped, and the check is cheap compared with an actual sort.

Sorting one order takes no time at all, so to measure it I used a separate table with `ORDER BY id`. I inserted the same million rows twice, once in order and once shuffled, and read the profile counters from `system.query_log`:

```sql
SELECT query_id,
       ProfileEvents['MergeTreeDataWriterBlocksAlreadySorted'] AS already_sorted,
       ProfileEvents['MergeTreeDataWriterSortingBlocksMicroseconds'] / 1000 AS sort_ms
FROM system.query_log
WHERE query_id IN ('blog_sorted', 'blog_shuffled') AND type = 'QueryFinish';
```

The sorted million rows were recognised as already sorted and took 1.3 ms. The shuffled copy wasn't, and sorting it took 52.2 ms. That's on my laptop (Apple M1 Pro, Docker Desktop), so take it as an illustration rather than a benchmark: the shuffled number jumped around between 36 and 52 ms across my runs, but the sorted input always stayed 30 to 40 times cheaper. The check is exact: a block must be fully sorted by the whole `ORDER BY` key, and a block that is only mostly sorted gets sorted as usual. So if your pipeline can send each batch already sorted by the key, for example by event time when time leads the key, ClickHouse skips that work.

### Step 3: merge on insert, and why the level is 1

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

### Step 4: choose the part format and the granule size

The rows are ready. Before writing them, ClickHouse decides how the part will be laid out on disk, starting with its format ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L992)).

The expected size is the block's size in memory. Below `min_bytes_for_wide_part` (10 MiB) the part is *Compact*: all columns go into one `data.bin`, which keeps tiny inserts from creating a file per column. Above it, the part is *Wide*, with one `.bin` file per column.

Next, ClickHouse decides how many rows go into each *granule*, the unit the primary index points to ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeIndexGranularity.cpp#L115-L160)). A granule holds `min(8192, 10 MiB / average row size)` rows. With narrow rows like ours that's always 8192. With wide rows, for example a 50 KB JSON payload, a granule shrinks to about 200 rows, so reading "one granule" doesn't mean reading hundreds of megabytes.

### Step 5: write the columns, the marks and the primary index

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

The thing that surprised me most is how small this is. The whole primary index for a million rows is 124 values, and `system.parts` reports `primary_key_bytes_in_memory` = 992 bytes, which is why a sparse index fits in RAM even for billions of rows. `index_value` is the key of each granule's first row: to find `id = 20000`, ClickHouse binary-searches these values, sees that it falls in granule 2 (16384–24575), and reads only that granule.

The marks take a bit more squinting. For `id`, the second number is always 0, because `id` starts a new compressed block at every granule: a granule of `id` is 8192 × 8 bytes = 64 KiB, exactly `min_compress_block_size`. `v` holds short strings, so its granules are smaller and two of them share one compressed block. Mark 1 for `v` says: decompress the block at file offset 0, then skip 31,658 bytes. At the end, the last real granule has 576 rows (1,000,000 − 122 × 8192), and mark 123 is a final mark with 0 rows that only records where the data ends and what the last key is.

All of this goes into the part's `tmp_insert_...` directory:

- the column values into `data.bin`, or into one `.bin` file per column in a Wide part
- the marks into `data.cmrk4`, or one `.cmrk2` file per column
- the primary index into `primary.cidx`
- the smallest and largest `updated_at` into `minmax_updated_at.idx`, which lets a query skip the whole part
- plus `checksums.txt`, `columns.txt` and `count.txt`

Once a part is fully written, the log says *"Wrote block with 9 rows"*. The part is complete on disk, but nobody can see it yet.

### Step 6: commit: get a block number and rename

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

All of this happens under the table's parts lock. First, the part gets its block number, and only now, not when the data was written: `fillNewPartName` takes the next number from the table's counter and sets the part's name ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/StorageMergeTree.cpp#L4808-L4817)). That's the "Allocated block number 9" line in the log. Block numbers therefore follow commit order, which is what lets merges reason about "newer" and "older" parts.

I got this counter wrong in my first draft. I wrote that it goes up once per INSERT, and a reader pointed out that one INSERT here produced three block numbers. The source is clearer than either of us was: in a non-replicated table one counter serves the whole table and is taken once per part, so the three parts of our 20-order INSERT got 9, 10 and 11 even though they're in different partitions. `Replicated` tables keep a separate counter for each partition in Keeper ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/StorageReplicatedMergeTree.cpp#L7948-L7988)).

Then the directory is renamed from `tmp_insert_202610_9_9_1` to `202610_9_9_1`. A rename within one filesystem is atomic, so readers see either no part or the whole part, never half of one, and from this moment the part is in the table's set of active parts and queries that start afterwards include it.

After the commit, the sink records the new part in `system.part_log` (a `NewPart` event) and wakes up the background merge scheduler ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeSink.cpp#L334)).

Every INSERT asks for a merge, but that doesn't mean one happens; the merge selector decides whether merging is worth it yet, and as we'll see in a moment, it's quite picky.

You can see the counters for any of your own INSERTs:

```sql
SELECT k AS event, v AS value
FROM system.query_log
ARRAY JOIN mapKeys(ProfileEvents) AS k, mapValues(ProfileEvents) AS v
WHERE query_id = '<your insert query id>' AND type = 'QueryFinish'
  AND k LIKE 'MergeTreeDataWriter%';
```

For the 20-row INSERT above: `MergeTreeDataWriterBlocks` = 3 (one per partition), `MergeTreeDataWriterBlocksAlreadySorted` = 3, `MergeTreeDataWriterRows` = 20.

## What I took from it

Most of what an INSERT does happens before anything is visible: the rows are split by partition, sorted, possibly merged with each other, cut into granules and written with their marks and index into a temporary directory. Only the very last step, the commit, gives the part its block number and makes it part of the table, and that's the moment everything in [Part 1](/posts/clickhouse-follow-one-row/) and [Part 2](/posts/clickhouse-merges-change-results/) builds on.

All the SQL from these experiments is in [one script](inside-one-insert.sql) you can run against a fresh container.
