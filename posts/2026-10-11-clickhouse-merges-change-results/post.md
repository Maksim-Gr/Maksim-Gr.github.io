---
title: "When ClickHouse merges change your query results"
date: 2026-10-11
description: "Summing, Aggregating and Collapsing tables give different answers before and after a merge. Real output from 26.9, the rules from the source, and query patterns that stay correct either way."
tags: [clickhouse]
tested_on: ClickHouse 26.9
series: Inside ClickHouse
part: 2
draft: true
---

<!-- TODO(you): rewrite this intro in your own words -->

In [Part 1](/posts/clickhouse-follow-one-row/) I followed one order from INSERT to merge. That answered two of the coffee-break questions from work. This post is about the third one:

> "Why doesn't my `SELECT` show the values I expect?"

I usually hear it from someone using a `SummingMergeTree`, an `AggregatingMergeTree` or a `CollapsingMergeTree`. In these engines a merge also changes the rows themselves: it sums them, collapses them or deletes them. So the same query can return a different answer depending on how many merges have happened.

You need three facts from Part 1:

- Every INSERT writes at least one new part. ClickHouse never changes a part. A merge writes a new, bigger part and deletes the old ones later.
- Merges run in the background, whenever the merge selector decides they're worth it. You can't predict when two rows end up in the same part.
- Merges never cross partitions.

Everything here ran on ClickHouse 26.9.

## 1. When merges change the answer

In Part 1, `ReplacingMergeTree` kept the latest version of each order. It's one of several engines that do extra work when rows with the same key meet, and they all follow the same pattern: `ORDER BY` defines which rows belong together, and the engine defines what happens to them.

| Engine | Rows with the same `ORDER BY` key become… |
|---|---|
| `ReplacingMergeTree(ver)` | the row with the highest `ver` (or the last inserted) |
| `SummingMergeTree` | one row with numeric columns summed |
| `AggregatingMergeTree` | one row with aggregate states merged |
| `CollapsingMergeTree(sign)` | nothing, if a `+1` row is cancelled by a `-1` row |
| `VersionedCollapsingMergeTree(sign, ver)` | the same, matched by version, in any order |
| `CoalescingMergeTree` (25.6+) | one row with the latest non-NULL value of each column |

The important part is *when* "become" happens. The engine logic runs at exactly three moments, and all three use the same algorithm classes:

1. **On insert**, inside one insert block. This is why new parts of these engines start at level 1. `MergeTreeDataWriter::mergeBlock` picks the algorithm ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTreeDataWriter.cpp#L596-L660)):

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

2. **In a background merge**, but only for the parts that merge picked, inside one partition ([`MergeTask.cpp`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Storages/MergeTree/MergeTask.cpp#L2929)).
3. **With `FINAL`**, at read time, for the parts the query reads ([`MergeTreeFinalMerge.cpp`](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/QueryPlan/MergeTreeFinalMerge.cpp#L63)).

Between those moments, the rows of one key sit in different parts, unprocessed. A plain `SELECT` sees whatever state the merges have reached so far. Here is what that means for each engine. Every experiment uses one INSERT per row, so each row starts in its own part, and then forces a full merge with `OPTIMIZE TABLE ... FINAL`.

### SummingMergeTree: zero rows disappear

```sql
CREATE TABLE page_stats (day Date, page String, views Int64, title String)
ENGINE = SummingMergeTree ORDER BY (day, page);

INSERT INTO page_stats VALUES ('2026-10-10', '/home',  10, 'Home');
INSERT INTO page_stats VALUES ('2026-10-10', '/home',   5, 'Home (new title)');
INSERT INTO page_stats VALUES ('2026-10-10', '/promo',  7, 'Promo');
INSERT INTO page_stats VALUES ('2026-10-10', '/promo', -7, 'Promo');   -- a correction
```

Before the merge there are four rows, one per part, and `sum(views) ... GROUP BY page` gives `/home` = 15 and `/promo` = 0. After `OPTIMIZE TABLE page_stats FINAL`:

```
┌─_part─────┬────────day─┬─page──┬─views─┬─title─┐
│ all_1_4_2 │ 2026-10-10 │ /home │    15 │ Home  │
└───────────┴────────────┴───────┴───────┴───────┘
```

Two surprises, both written down in the algorithm's header ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/SummingSortedAlgorithm.h#L11-L15)):

```cpp
/** Merges several sorted inputs into one.
  * For each group of consecutive identical values of the primary key (the columns by which the data is sorted),
  *  collapses them into one row, summing all the numeric columns except the primary key.
  * If in all numeric columns, except for the primary key, the result is zero, it deletes the row.
  */
```

- **`/promo` is gone.** Its views summed to 0, so the row was deleted. That's fine for page views, but if the table holds account balances, a balance of exactly zero makes the account vanish from the table.
- **`title` kept `'Home'`, the first value**, and `'Home (new title)'` was lost. Non-numeric columns outside the key are not summed. One value survives, and you don't choose which.

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

On 26.9 this `CREATE TABLE` fails:

```
Column(s) cnt_plain of the AggregatingMergeTree table are neither part of the sorting key nor
aggregate measures (AggregateFunction or SimpleAggregateFunction). During background merges, rows
with the same value of the sorting key are collapsed into one, so these columns keep an arbitrary
value, which silently produces wrong results ...
```

This check is new in 26.7. Older versions accepted the table silently. To see what it protects against, I created the table again with `SETTINGS allow_dimensions_outside_sorting_key = 1`, the old behavior, and inserted two batches of 10 and 5 events:

| Query | Before merge | After merge |
|---|---|---|
| `sum(cnt_plain)` | 15 | 10 |
| `sum(cnt)` | 15 | 15 |
| `uniqMerge(users)` | 12 | 12 |

The same query returns a different number depending on whether a merge has happened. `cnt_plain` keeps the first row's value, as the algorithm's header says ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/AggregatingSortedAlgorithm.h#L14-L19)): *"For columns that are not part of the primary key and which do not have the AggregateFunction type, when merged, the first value is selected."* `SimpleAggregateFunction(sum, ...)` and `AggregateFunction(...)` columns combine correctly in every state.

The same rule applies to querying: always re-aggregate (`sum(cnt)`, `uniqMerge(users)`, `GROUP BY` the key). Some rows are merged and some aren't, and only a re-aggregation gives the same answer either way.

### CollapsingMergeTree: the order of parts matters

Collapsing models changing state as a log. To update a row, you insert a copy of the old row with `sign = -1` to cancel it, plus the new row with `sign = 1`:

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

User 1 collapsed correctly. User 2's pair survived a full merge. The reason is in the rules at the top of the algorithm ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/CollapsingSortedAlgorithm.h#L14-L25)):

```cpp
/** ...
  * If the number of positive and negative rows is the same, and the last row is positive, then the first negative and last positive rows are written.
  * If the number of positive and negative rows is the same, and the last line is negative, it writes nothing.
  * ...
  */
```

Within one key, rows are merged in part order, which is block-number order, which is commit order: a part gets its block number when it's committed. For user 2, the `-1` was committed first, so the group ends with a positive row and both rows are kept. With parallel writers, retries or Kafka partitions, "cancel before state" happens in real pipelines.

Two ways to stay correct:

- **Query with `sign`**, which gives the right answer whether or not the rows collapsed:

  ```sql
  SELECT user_id, sum(page_views * sign) AS page_views
  FROM user_state
  GROUP BY user_id
  HAVING sum(sign) > 0;
  ```

  This returns only user 1 with 6 page views. User 2's rows cancel out in the sums.

- **Use `VersionedCollapsingMergeTree(sign, version)`.** It matches a `-1` and a `+1` with the same version regardless of order ([source](https://github.com/ClickHouse/ClickHouse/blob/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms/VersionedCollapsingAlgorithm.h#L11-L15)). The same out-of-order inserts for user 2, with `version = 1` on both rows, left 0 rows after `OPTIMIZE TABLE ... FINAL`.

### The rule for all of them

**Write every query so it returns the same answer whether zero, some or all merges have happened.** In practice:

| Engine | Query pattern that's always correct |
|---|---|
| `ReplacingMergeTree` | `FINAL`, or `argMax(col, ver) ... GROUP BY key` |
| `SummingMergeTree` | `sum(col) ... GROUP BY key` |
| `AggregatingMergeTree` | `-Merge` combinators and `sum`/`max`/… for `SimpleAggregateFunction`, `GROUP BY key` |
| `CollapsingMergeTree` | `sum(col * sign) ... GROUP BY key HAVING sum(sign) > 0` |
| `VersionedCollapsingMergeTree` | Same as Collapsing |

And remember the limits: merges never cross partitions, and they run only when the merge selector decides it's worth it. Treat merges as a storage optimization, and keep your query results independent of them.

## 2. Deleting and updating in place

Parts are immutable, so how do `DELETE` and `UPDATE` work? To see the effect on a part of realistic size, I used a `MergeTree` table with one million orders in a single part, `all_1_1_1`.

**Lightweight `DELETE`:**

```sql
DELETE FROM orders_mt WHERE order_id < 10;
```

```
┌─name────────┬────rows─┬─size─────┐
│ all_1_1_1_2 │ 1000000 │ 3.94 MiB │
└─────────────┴─────────┴──────────┘
```

`count()` now returns 999,990, but the part still physically holds 1,000,000 rows. The name gained a fifth field, `_2`, the *mutation version*. `system.mutations` shows what ran: `UPDATE _row_exists = 0 WHERE order_id < 10`. A lightweight delete writes a hidden mask column and leaves the data alone. The rows are physically dropped during later merges.

**`ALTER TABLE ... DELETE`** (a classic mutation):

```sql
ALTER TABLE orders_mt DELETE WHERE order_id < 20 SETTINGS mutations_sync = 1;
```

```
┌─name────────┬───rows─┬─size─────┐
│ all_1_1_1_3 │ 999980 │ 3.94 MiB │
└─────────────┴────────┴──────────┘
```

The part was rewritten, and now 999,980 rows are physically present. On a real table this rewrites every affected part, which costs a lot of I/O.

**Lightweight `UPDATE`** (new, needs `enable_block_number_column = 1` and `enable_block_offset_column = 1` on the table):

```sql
UPDATE orders_mt SET status = 'paid' WHERE order_id = 500;
```

```
┌─name───────────────────────────────────────────────┬───rows─┬─size─────┐
│ all_1_1_1_3                                        │ 999980 │ 3.94 MiB │
│ patch-ca8f64b62d9505701c71c81624162ef0-all_5_5_0_4 │      1 │ 1.05 KiB │
└────────────────────────────────────────────────────┴────────┴──────────┘
```

Instead of rewriting a 4 MiB part to change one value, ClickHouse wrote a 1 KiB patch part with one row. Reads apply the patch on the fly, and merges eventually fold it into the main part.

| Operation | What it writes | Data physically removed or changed |
|---|---|---|
| `DELETE FROM` | A row mask (`_row_exists`) | On later merges |
| `ALTER ... DELETE` / `UPDATE` | Full rewrite of affected parts | Immediately (asynchronously) |
| `UPDATE ... SET` | A small patch part | On later merges |
| `ALTER ... DROP PARTITION` | Nothing, removes directories | Instantly |

## Back to the coffee break

- **"Why doesn't my `SELECT` show what I expect?"** In `Summing`, `Aggregating` and `Collapsing` tables, the raw rows depend on which merges have happened. Write every query so it gives the same answer whether zero, some or all merges have happened. In practice that means re-aggregating in every query.

The checklist:

| Area | Rule |
|---|---|
| Table design | In an `AggregatingMergeTree`, every column is either in `ORDER BY` or an aggregate (`SimpleAggregateFunction` or `AggregateFunction`). Since 26.7, ClickHouse rejects other schemas. |
| Table design | In a `SummingMergeTree`, a row whose sums reach zero is deleted on merge. Keep that in mind for values where zero means something, like balances. |
| Table design | Prefer `VersionedCollapsingMergeTree` when cancel rows can arrive before the rows they cancel. |
| Querying | In `Summing`, `Aggregating` and `Collapsing` tables, always re-aggregate: `sum`, `-Merge` combinators, `sum(col * sign)`, with `GROUP BY` the key. |
| Querying | Merges save storage. Your queries have to be correct without them. |
| Operations | Prefer lightweight `DELETE`/`UPDATE` and `DROP PARTITION` over `ALTER ... DELETE/UPDATE` mutations. |

## Further reading

- The official docs for [`SummingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/summingmergetree), [`AggregatingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/aggregatingmergetree), [`CollapsingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/collapsingmergetree) and [`VersionedCollapsingMergeTree`](https://clickhouse.com/docs/engines/table-engines/mergetree-family/versionedcollapsingmergetree).
- [Lightweight `DELETE`](https://clickhouse.com/docs/guides/developer/lightweight-delete) and [lightweight `UPDATE`](https://clickhouse.com/docs/sql-reference/statements/update) in the official docs.
- Source: [`src/Processors/Merges/Algorithms/`](https://github.com/ClickHouse/ClickHouse/tree/ca8dd5528a09eddfa1b0be2a987c0c8c77c7d5a7/src/Processors/Merges/Algorithms), where every engine's merge rules live.

All the SQL from these experiments is in [one script](merges-change-results.sql) you can run against a fresh container.
