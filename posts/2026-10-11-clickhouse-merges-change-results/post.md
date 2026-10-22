---
title: "When ClickHouse merges change your query results"
date: 2026-10-11
description: "Summing, Aggregating, and Collapsing tables can return different results before and after a merge. This post shows real output from ClickHouse 26.9, explains the rules in the source code, and presents query patterns that remain correct either way."
tags: [clickhouse]
tested_on: ClickHouse 26.9
series: Inside ClickHouse
part: 2
draft: false
---

In [Part 1](/posts/clickhouse-follow-one-row/), I followed an order from INSERT through a merge. That answered two questions that came up during coffee breaks at work. This post tackles the third:

> "Why doesn't my `SELECT` show the values I expect?"

I usually hear this question from people using `SummingMergeTree`, `AggregatingMergeTree`, or `CollapsingMergeTree`. In these engines, a merge can change the rows themselves: it sums them, collapses them, or removes them. As a result, the same query can return different results depending on how many merges have occurred.

If you skipped Part 1, three things from it matter here. Each inserted block typically creates one or more new parts, and ClickHouse never modifies a part in place; a merge writes a new, larger part and removes the old ones later. Merges run in the background whenever the merge selector decides they're worthwhile, so you can't predict when two rows will end up in the same part. And merges never cross partition boundaries.

Everything here ran on ClickHouse 26.9.

## 1. When merges change the answer

In Part 1, `ReplacingMergeTree` kept the latest version of each order. It's one of several engines that apply special handling when rows with the same sorting key meet. `ORDER BY` determines which rows belong together; the engine determines what happens to them.

| Engine | Rows with the same `ORDER BY` key become… |
|---|---|
| `ReplacingMergeTree(ver)` | the row with the highest `ver` (or the last inserted) |
| `SummingMergeTree` | one row with numeric columns summed |
| `AggregatingMergeTree` | one row with aggregate states merged |
| `CollapsingMergeTree(sign)` | nothing, if a `+1` row is cancelled by a `-1` row |
| `VersionedCollapsingMergeTree(sign, ver)` | the same, matched by version, in any order |
| `CoalescingMergeTree` (25.6+) | one row with the latest non-NULL value of each column |

The important question is *when* that transformation happens. The engine's merge logic is applied at three points, using the same algorithm classes:

1. On insert, within a single insert block. This is why newly inserted parts for these engines start at level 1. `MergeTreeDataWriter::mergeBlock` selects the algorithm ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L596-L660)):

   ```cpp
   switch (merging_params.mode)
   {
       /// There is nothing to merge in single block in ordinary MergeTree
       case MergeTreeData::MergingParams::Ordinary:
           return nullptr;
       case MergeTreeData::MergingParams::Replacing:
           return std::make_shared<ReplacingSortedAlgorithm>(/* ... */);
       case MergeTreeData::MergingParams::Collapsing:
           return std::make_shared<CollapsingSortedAlgorithm>(/* ... */);
       case MergeTreeData::MergingParams::Summing:
           return std::make_shared<SummingSortedAlgorithm>(/* ... */);
       // ... Aggregating, VersionedCollapsing, Graphite, Coalescing
   }
   ```

2. During a background merge, for the selected parts within a single partition ([`MergeTask.cpp`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTask.cpp#L2929)).
3. At query time, when `FINAL` is used, for the parts read by the query ([`MergeTreeFinalMerge.cpp`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/QueryPlan/MergeTreeFinalMerge.cpp#L63)).

Between these stages, rows with the same key can remain in separate parts, unprocessed. A plain `SELECT` sees whatever state the background merges have reached so far. Here's what that means for each engine. In the `SummingMergeTree` and `CollapsingMergeTree` examples, each INSERT starts its own part, and I then force a full merge with `OPTIMIZE TABLE ... FINAL`. The `AggregatingMergeTree` example uses batches instead.

### SummingMergeTree: zero rows disappear

`SummingMergeTree` is a table of counters. The [official documentation](https://clickhouse.com/docs/engines/table-engines/mergetree-family/summingmergetree) describes it as follows:

> The difference is that when merging data parts for `SummingMergeTree` tables ClickHouse replaces all the rows with the same primary key (or more accurately, with the same sorting key) with one row which contains summed values for the columns with the numeric data type.

Instead of keeping one row per event, the table combines values for each key as parts merge. A typical use case is daily statistics, such as page views per page per day, often populated by a materialized view. The documentation also recommends retaining the raw events in a plain `MergeTree` table alongside it, so a mistake in the sorting key doesn't result in data loss.

Here's the table I played with:

```sql
CREATE TABLE page_stats (day Date, page String, views Int64, title String)
ENGINE = SummingMergeTree ORDER BY (day, page);
```

- `ORDER BY (day, page)` defines the sorting key: one counter per page per day.
- `views` is numeric, so merges sum it.
- `title` is a string, so it can't be summed. It's included to show what happens to non-numeric columns.

I stopped merges and ran four `INSERT` statements. The last one is a correction that cancels out the views for `/promo`:

```sql
SYSTEM STOP MERGES page_stats;

INSERT INTO page_stats VALUES ('2026-10-10', '/home',  10, 'Home');
INSERT INTO page_stats VALUES ('2026-10-10', '/home',   5, 'Home (new title)');
INSERT INTO page_stats VALUES ('2026-10-10', '/promo',  7, 'Promo');
INSERT INTO page_stats VALUES ('2026-10-10', '/promo', -7, 'Promo');   -- a correction
```

Before the merge, each INSERT is its own part, and nothing has been summed yet:

```sql
SELECT _part, page, views, title FROM page_stats ORDER BY _part;
```

```
┌─_part─────┬─page───┬─views─┬─title────────────┐
│ all_1_1_1 │ /home  │    10 │ Home             │
│ all_2_2_1 │ /home  │     5 │ Home (new title) │
│ all_3_3_1 │ /promo │     7 │ Promo            │
│ all_4_4_1 │ /promo │    -7 │ Promo            │
└───────────┴────────┴───────┴──────────────────┘
```

A plain `SELECT` doesn't sum anything, either. It returns all four rows, with two rows per page:

```sql
SELECT * FROM page_stats ORDER BY page, views;
```

```
┌────────day─┬─page───┬─views─┬─title────────────┐
│ 2026-10-10 │ /home  │     5 │ Home (new title) │
│ 2026-10-10 │ /home  │    10 │ Home             │
│ 2026-10-10 │ /promo │    -7 │ Promo            │
│ 2026-10-10 │ /promo │     7 │ Promo            │
└────────────┴────────┴───────┴──────────────────┘
```

To get the totals, the query has to sum them itself:

```sql
SELECT page, sum(views) AS total FROM page_stats GROUP BY page ORDER BY page;
```

```
┌─page───┬─total─┐
│ /home  │    15 │
│ /promo │     0 │
└────────┴───────┘
```

Next, I switched merges back on and forced a merge:

```sql
SYSTEM START MERGES page_stats;
OPTIMIZE TABLE page_stats FINAL;

SELECT _part, page, views, title FROM page_stats ORDER BY _part;
```

```
┌─_part─────┬─page──┬─views─┬─title─┐
│ all_1_4_2 │ /home │    15 │ Home  │
└───────────┴───────┴───────┴───────┘
```

The four parts became one part, `all_1_4_2`: blocks 1 through 4, merged at level 2. The two `/home` rows became a single row with 15 views, while the `/promo` rows disappeared.

Both behaviors are documented in the algorithm's header ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/SummingSortedAlgorithm.h#L11-L15)):

```cpp
/** Merges several sorted inputs into one.
  * For each group of consecutive identical values of the primary key (the columns by which the data is sorted),
  *  collapses them into one row, summing all the numeric columns except the primary key.
  * If in all numeric columns, except for the primary key, the result is zero, it deletes the row.
  */
```

The first thing that bit me is the obvious one: a key whose numeric values all sum to 0 can disappear. The `/promo` views summed to 0, so the merge deleted the row. For page-view counts that's fine, but if the table stores account balances, an account with a zero balance quietly vanishes from it.

The second one I didn't expect at all. I assumed that a query which sums the rows itself is safe no matter what the merges do, and it mostly is, but not about which rows come back. Before the merge, the `GROUP BY` query above returned `/promo` with a total of 0; after the merge, the same query returns only `/home`. To keep the output the same either way, add `HAVING sum(views) != 0`, which hides zero totals before a merge too. (My first version of that query failed with `ILLEGAL_AGGREGATION`, because I'd named the result `views`, the same as the column, and ClickHouse then read `sum(views)` in `HAVING` as a sum of the sum. Hence `total`.)

The third is the `title` column, which kept `'Home'` and threw away `'Home (new title)'`. Non-numeric columns outside the sorting key aren't summed, and the merge keeps the value from the first row, which is the row from the part with the lowest block number. Insert the two rows in reverse order and `'Home (new title)'` wins instead. (Thanks to a reader in the comments for suggesting that test.) The docs call this value arbitrary, and with concurrent inserts "first" means first to commit, not first sent, so I wouldn't rely on it. If you care which title you get, store an `updated_at` timestamp with each row and query `argMax(title, updated_at)`: the newest title wins, however the parts were merged.

### AggregatingMergeTree: a plain column changes its value after a merge

```sql
CREATE TABLE daily
(
    day       Date,
    cnt_plain UInt64,                                -- the mistake
    cnt       SimpleAggregateFunction(sum, UInt64),  -- the fix
    users     AggregateFunction(uniq, UInt64)
)
ENGINE = AggregatingMergeTree ORDER BY day;
```

This is where 26.9 surprised me: the `CREATE TABLE` statement fails before I can even insert anything.

```
Column(s) cnt_plain of the AggregatingMergeTree table are neither part of the sorting key nor
aggregate measures (AggregateFunction or SimpleAggregateFunction). During background merges, rows
with the same value of the sorting key are collapsed into one, so these columns keep an arbitrary
value, which silently produces wrong results ...
```

The check was added in 26.7, and older versions accepted this schema without a word. I only found out because my experiment script, written the old way, failed on 26.9. To show what the check prevents, I recreated the table with `SETTINGS allow_dimensions_outside_sorting_key = 1` (the old behavior) and inserted two batches containing 10 and 5 events:

| Query | Before merge | After merge |
|---|---|---|
| `sum(cnt_plain)` | 15 | 10 |
| `sum(cnt)` | 15 | 15 |
| `uniqMerge(users)` | 12 | 12 |

So the same query gives 15 before the merge and 10 after it. `cnt_plain` retains the first row's value, as the algorithm's header explains ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/AggregatingSortedAlgorithm.h#L14-L19)): *"For columns that are not part of the primary key and which do not have the AggregateFunction type, when merged, the first value is selected."* `SimpleAggregateFunction(sum, ...)` and `AggregateFunction(...)` columns combine correctly across merge states.

The same principle applies when querying: always re-aggregate with functions such as `sum(cnt)` and `uniqMerge(users)`, grouped by the sorting key. Some rows may already have been merged while others haven't; re-aggregation makes the result independent of that state.

### CollapsingMergeTree: the order of parts matters

`CollapsingMergeTree` models state changes as a log. To update a row, insert a copy of the old state with `sign = -1` to cancel it, followed by the new state with `sign = 1`:

```sql
CREATE TABLE user_state (user_id UInt64, page_views UInt32, sign Int8)
ENGINE = CollapsingMergeTree(sign) ORDER BY user_id;

-- user 1: state, then cancel + new state (the documented pattern)
INSERT INTO user_state VALUES (1, 5, 1);
INSERT INTO user_state VALUES (1, 5, -1), (1, 6, 1);

-- user 2: the cancel row arrives BEFORE the state it cancels
INSERT INTO user_state VALUES (2, 5, -1);
INSERT INTO user_state VALUES (2, 5, 1);

OPTIMIZE TABLE user_state FINAL;
```

```
┌─_part─────┬─user_id─┬─page_views─┬─sign─┐
│ all_1_4_2 │       1 │          6 │    1 │
│ all_1_4_2 │       2 │          5 │   -1 │
│ all_1_4_2 │       2 │          5 │    1 │
└───────────┴─────────┴────────────┴──────┘
```

User 1 collapsed as expected. User 2's pair survived a full merge. The reason is explained in the algorithm's rules ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/CollapsingSortedAlgorithm.h#L14-L25)):

```cpp
/** ...
  * If the number of positive and negative rows is the same, and the last row is positive, then the first negative and last positive rows are written.
  * If the number of positive and negative rows is the same, and the last line is negative, it writes nothing.
  * ...
  */
```

Within each sorting key, rows are processed in part order (by block number). In this example, user 2's `-1` part came first, so the group ended with a positive row and both rows survived. With parallel writers, retries, or Kafka partitions, cancellation rows can arrive before the states they cancel.

You can keep the query correct in two ways. The first is to let `sign` do the work in the query, which gives the right answer whether or not the rows have collapsed yet:

```sql
SELECT user_id, sum(toInt64(page_views) * sign) AS page_views
FROM user_state
GROUP BY user_id
HAVING sum(sign) > 0;
```

This returns only user 1, with 6 page views, because user 2's rows cancel each other out in the sums.

The second is to switch to `VersionedCollapsingMergeTree(sign, version)`, which I'd honestly prefer whenever the writers aren't strictly ordered. It matches a `-1` row with a `+1` row of the same version, regardless of their order ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/VersionedCollapsingAlgorithm.h#L11-L15)). Repeating the out-of-order inserts for user 2 with `version = 1` on both rows left no rows after `OPTIMIZE TABLE ... FINAL`.

### The rule for all of them

**Write every query so it returns the same result whether no merges, some merges, or all possible merges have occurred.** In practice:

| Engine | Query pattern that's always correct |
|---|---|
| `ReplacingMergeTree` | `FINAL`, or `argMax(col, ver) ... GROUP BY key` |
| `SummingMergeTree` | `sum(a), sum(b) ... GROUP BY key HAVING sum(a) != 0 OR sum(b) != 0` (a row is deleted only when all its numeric columns sum to 0) |
| `AggregatingMergeTree` | `-Merge` combinators and `sum`/`max`/… for `SimpleAggregateFunction`, `GROUP BY key` |
| `CollapsingMergeTree` | `sum(col * sign) ... GROUP BY key HAVING sum(sign) > 0` |
| `VersionedCollapsingMergeTree` | Same as Collapsing |

Remember the limits: merges never cross partition boundaries, and they run only when the merge selector decides they're worthwhile. Treat merges as a storage optimization, and make your query results independent of merge state.

## 2. Deleting and updating in place

Parts are immutable, so how do `DELETE` and `UPDATE` work? To demonstrate the effect on a realistically sized part, I used a `MergeTree` table containing one million orders in a single part, `all_1_1_1`.

**Lightweight `DELETE`:**

```sql
DELETE FROM orders_mt WHERE order_id < 10;
```

```
┌─name────────┬────rows─┬─size─────┐
│ all_1_1_1_2 │ 1000000 │ 3.94 MiB │
└─────────────┴─────────┴──────────┘
```

`count()` now returns 999,990, but the part still physically contains 1,000,000 rows. The part name gained a fifth field, `_2`, which is the *mutation version*. `system.mutations` shows the operation that ran: `UPDATE _row_exists = 0 WHERE order_id < 10`. A lightweight `DELETE` marks rows in the hidden `_row_exists` column but leaves their data in place. The rows are physically removed during later merges.

**`ALTER TABLE ... DELETE`** (a classic mutation):

```sql
ALTER TABLE orders_mt DELETE WHERE order_id < 20 SETTINGS mutations_sync = 1;
```

```
┌─name────────┬───rows─┬─size─────┐
│ all_1_1_1_3 │ 999980 │ 3.94 MiB │
└─────────────┴────────┴──────────┘
```

The part was rewritten, and 999,980 rows are now physically present. On a real table, this rewrites every affected part and can generate substantial I/O.

**Lightweight `UPDATE`** (requires `enable_block_number_column = 1` and `enable_block_offset_column = 1` on the table):

```sql
UPDATE orders_mt SET status = 'paid' WHERE order_id = 500;
```

```
┌─name───────────────────────────────────────────────┬───rows─┬─size─────┐
│ all_1_1_1_3                                        │ 999980 │ 3.94 MiB │
│ patch-ca8f64b62d9505701c71c81624162ef0-all_5_5_0_4 │      1 │ 1.05 KiB │
└────────────────────────────────────────────────────┴────────┴──────────┘
```

Instead of rewriting a 4 MiB part to change one value, ClickHouse wrote a 1 KiB patch part containing one row. Reads apply the patch on the fly, and later merges fold it into the main part.

| Operation | What it writes | Data physically removed or changed |
|---|---|---|
| `DELETE FROM` | A row mask (`_row_exists`) | On later merges |
| `ALTER ... DELETE` / `UPDATE` | Full rewrite of affected parts | When the mutation completes (asynchronously by default) |
| `UPDATE ... SET` | A small patch part | On later merges |
| `ALTER ... DROP PARTITION` | Removes the partition's data parts | Immediately at the table level; physical cleanup may follow |

## Back to the coffee break

So, *"Why doesn't my `SELECT` show what I expect?"* In `SummingMergeTree`, `AggregatingMergeTree` and `CollapsingMergeTree` tables, the raw rows depend on which merges have happened, so every query should give the same result whether no merges, some merges or all of them have run. In practice that means re-aggregating at query time.

A few more things I'd tell a colleague. In an `AggregatingMergeTree`, put every column either in `ORDER BY` or into an aggregate (`SimpleAggregateFunction` or `AggregateFunction`); since 26.7 ClickHouse won't let you do anything else, which I think is a good call. In a `SummingMergeTree`, remember that a row disappears on merge when all its numeric columns sum to zero, so think twice before storing anything where zero is a meaningful value, like balances. If cancel rows can arrive before the rows they cancel, use `VersionedCollapsingMergeTree`. And for deletes, use lightweight `DELETE`/`UPDATE` for targeted changes, `DROP PARTITION` when a whole partition goes, and classic mutations only when you actually want the full rewrite.

## Further reading

The official docs for [`SummingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/summingmergetree), [`AggregatingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/aggregatingmergetree), [`CollapsingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/collapsingmergetree) and [`VersionedCollapsingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/versionedcollapsingmergetree) are worth reading after this, along with the pages on [lightweight `DELETE`](https://clickhouse.com/docs/guides/developer/lightweight-delete) and [lightweight `UPDATE`](https://clickhouse.com/docs/sql-reference/statements/update). And if you want the actual rules, they live in [`src/Processors/Merges/Algorithms/`](https://github.com/ClickHouse/ClickHouse/tree/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms); the comments at the top of each file are surprisingly readable.

All SQL used in these experiments is available in [a single script](merges-change-results.sql) that you can run against a fresh container.
