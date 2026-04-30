/*
-- Version: 1.0
-- Author: Tuan Pham
-- Date: 04/30/2026.
-- Description: Caculate median store count over a time period in BigQuery.
*/
-- ============================================================
-- PURPOSE
-- ============================================================
-- Calculate the minimum, maximum, and median store count for the
-- dynamic YoY comparison group.
--
-- A store is included in the comparison group for each anchor_day only if:
--   1. It is active on the current anchor_day
--   2. It is active on the same weekday prior year date: anchor_day - 364 days
--   3. It is active on the historical reference date: anchor_day - 546 days
--
-- "Active" means the store has more than active_store_transaction
-- transactions on that business_day.
--
-- Final output:
--   Max_Store           = highest daily comparison-store count
--   Min_Store           = lowest daily comparison-store count
--   median_store_count  = median daily comparison-store count
--
-- ============================================================
-- LOGIC FLOW
-- ============================================================
-- 1. params
--    Define date range, active-store threshold, and target store group.
--
-- 2. storegroup_dayparts
--    Read daypart JSON from StoreGroups and convert start/duration into minutes.
--
-- 3. storegroup_dayparts_normalized
--    Standardize daypart names such as Breakfast, Lunch, Dinner.
--
-- 4. base_tx
--    Pull raw transaction rows, join store mapping, store group, and timezone.
--
-- 5. final_tx
--    Assign each transaction to the correct daypart and business_day.
--    Handles dayparts that cross midnight.
--
-- 6. anchor_days
--    Build the list of business days to evaluate.
--
-- 7. store_day_activity
--    Aggregate transaction count and sales by store and business_day.
--
-- 8. qualified_store_day
--    Keep only active store-days above the transaction threshold.
--
-- 9. comparison_group
--    For each anchor_day, keep stores active on:
--       current day,
--       current day - 364,
--       current day - 546.
--
-- 10. store_count
--     Count how many stores qualify for each anchor_day.
--
-- 11. Final SELECT
--     Return max, min, and median store count.
-- ============================================================

WITH params AS (
  SELECT
    DATE '2025-01-01' AS start_date,
    DATE '2026-01-01' AS end_date,

    -- Minimum transaction count required for a store to be considered active
    CAST(10 AS INT64) AS active_store_transaction,

    -- Store group to analyze
    CAST('GoldenChick' AS STRING) AS target_store_group
),

/* ------------------------------------------------------------
   1. Read daypart definitions from StoreGroups
------------------------------------------------------------ */
storegroup_dayparts AS (
  SELECT
    g.storeGroupId,
    g.name AS storeGroup_name,
    g.timeZone,

    -- Raw daypart name from JSON, for example Breakfast, Lunch, Dinner
    JSON_VALUE(dp, '$.n') AS raw_daypart_name,

    -- Daypart order from JSON
    SAFE_CAST(JSON_VALUE(dp, '$.do') AS INT64) AS daypart_order,

    -- Daypart start time from JSON
    SAFE_CAST(JSON_VALUE(dp, '$.st.h') AS INT64) AS start_hour,
    SAFE_CAST(JSON_VALUE(dp, '$.st.m') AS INT64) AS start_minute,

    -- Daypart duration from JSON
    SAFE_CAST(JSON_VALUE(dp, '$.d.hs') AS INT64) AS duration_hours,
    SAFE_CAST(JSON_VALUE(dp, '$.d.ms') AS INT64) AS duration_minutes,

    -- Convert start time to minute of day.
    -- Example: 6:30 AM = 6 * 60 + 30 = 390
    SAFE_CAST(JSON_VALUE(dp, '$.st.h') AS INT64) * 60
      + SAFE_CAST(JSON_VALUE(dp, '$.st.m') AS INT64) AS start_minute_of_day,

    -- Convert duration to total minutes.
    -- Example: 4 hours 30 minutes = 270 minutes
    SAFE_CAST(JSON_VALUE(dp, '$.d.hs') AS INT64) * 60
      + SAFE_CAST(JSON_VALUE(dp, '$.d.ms') AS INT64) AS duration_minute_total

  FROM `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoreGroups` g

  -- Expand dayParts ARRAY<JSON> into one row per daypart
  CROSS JOIN UNNEST(g.dayParts) AS dp

  JOIN params p
    ON g.storeGroupId = p.target_store_group

  WHERE JSON_VALUE(dp, '$.n') IS NOT NULL

    -- Exclude All Day because this query assigns transactions to specific dayparts
    AND JSON_VALUE(dp, '$.n') != 'All Day'
),

/* ------------------------------------------------------------
   2. Normalize daypart names
------------------------------------------------------------ */
storegroup_dayparts_normalized AS (
  SELECT
    storeGroupId,
    storeGroup_name,
    timeZone,
    daypart_order,
    start_hour,
    start_minute,
    duration_hours,
    duration_minutes,
    start_minute_of_day,
    duration_minute_total,

    -- Standardize naming so similar labels group together
    CASE
      WHEN LOWER(raw_daypart_name) IN ('breakfast') THEN 'Breakfast'
      WHEN LOWER(raw_daypart_name) IN ('lunch') THEN 'Lunch'
      WHEN LOWER(raw_daypart_name) IN ('midday', 'mid-day', 'mid day') THEN 'Midday'
      WHEN LOWER(raw_daypart_name) IN ('dinner') THEN 'Dinner'
      WHEN LOWER(raw_daypart_name) IN ('late night', 'latenight', 'late-night') THEN 'Late Night'
      ELSE raw_daypart_name
    END AS daypart_name

  FROM storegroup_dayparts
),

/* ------------------------------------------------------------
   3. Pull base transaction rows
------------------------------------------------------------ */
base_tx AS (
  SELECT
    sg.storeGroupId,
    s.name AS store_name,
    m.storeId,
    m.reportGroup,

    c.timestamp,
    c.accountNumberId,
    c.terminalId,
    c.siteIdFrontend,
    c.check,

    -- Convert cents to dollars
    ROUND(c.amount / 100, 2) AS sale_in_dollar,

    c.isNewAtStore,
    d.timeZone,

    -- Convert transaction timestamp into local store-group timezone
    DATETIME(c.timestamp, d.timeZone) AS local_time,
    DATE(c.timestamp, d.timeZone) AS local_date,
    FORMAT_DATE('%A', DATE(c.timestamp, d.timeZone)) AS local_weekday,

    -- Convert transaction local time into minute of day
    EXTRACT(HOUR FROM DATETIME(c.timestamp, d.timeZone)) * 60
      + EXTRACT(MINUTE FROM DATETIME(c.timestamp, d.timeZone)) AS tx_minute_of_day

  FROM `project-3d127dc4-8358-46e9-b7e.backfill_dataset.AuthorizationsClientLine` c

  -- Map merchant/terminal to store
  JOIN `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoresToMerchantIdsAuthorization` m
    ON c.siteIdFrontend = m.merchantId
   AND c.terminalId = m.terminalId

  -- Add store name
  JOIN `project-3d127dc4-8358-46e9-b7e.backfill_dataset.Stores` s
    ON m.storeId = s.storeId

  -- Add store group
  JOIN `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoresToStoreGroups` sg
    ON m.storeId = sg.storeId

  -- Add timezone from the selected store group
  JOIN (
    SELECT DISTINCT storeGroupId, timeZone
    FROM storegroup_dayparts_normalized
  ) d
    ON sg.storeGroupId = d.storeGroupId

  CROSS JOIN params p

  WHERE sg.storeGroupId = p.target_store_group

    -- Pull enough historical data to support:
    --   anchor_day
    --   anchor_day - 364
    --   anchor_day - 546
    AND DATE(c.timestamp, d.timeZone)
        BETWEEN DATE_SUB(p.start_date, INTERVAL 547 DAY) AND p.end_date

    -- Keep only real sale transaction types
    AND c.type IN ('Pre Auth Request', 'Pre Auth Complete', 'Purchase')
),

/* ------------------------------------------------------------
   4. Assign transactions to daypart and business_day
------------------------------------------------------------ */
final_tx AS (
  SELECT
    b.storeGroupId,
    b.store_name,
    b.storeId,
    b.reportGroup,
    b.sale_in_dollar,
    b.accountNumberId,
    b.terminalId,
    b.siteIdFrontend,
    b.check,
    b.timestamp,
    b.timeZone,
    b.local_time,
    b.tx_minute_of_day,
    b.local_date,
    d.start_minute_of_day,
    d.duration_minute_total,
    b.local_weekday,
    b.isNewAtStore,
    d.daypart_name,
    d.daypart_order,
    -- Calculate business_day.
    -- If a daypart crosses midnight and the transaction happens after midnight,
    -- assign it back to the previous business day.
    CASE
      WHEN d.start_minute_of_day + d.duration_minute_total > 1440
           AND b.tx_minute_of_day < MOD(d.start_minute_of_day + d.duration_minute_total, 1440)
      THEN DATE_SUB(b.local_date, INTERVAL 1 DAY)
      ELSE b.local_date
    END AS business_day,

    -- Business weekday based on adjusted business_day
    FORMAT_DATE(
      '%A',
      CASE
        WHEN d.start_minute_of_day + d.duration_minute_total > 1440
             AND b.tx_minute_of_day < MOD(d.start_minute_of_day + d.duration_minute_total, 1440)
        THEN DATE_SUB(b.local_date, INTERVAL 1 DAY)
        ELSE b.local_date
      END
    ) AS business_weekday

  FROM base_tx b

  -- Match each transaction to the daypart where its local time belongs
  JOIN storegroup_dayparts_normalized d
    ON b.storeGroupId = d.storeGroupId
   AND (
        -- Normal daypart: does not cross midnight
        (
          d.start_minute_of_day + d.duration_minute_total <= 1440
          AND b.tx_minute_of_day >= d.start_minute_of_day
          AND b.tx_minute_of_day < d.start_minute_of_day + d.duration_minute_total
        )

        OR

        -- Cross-midnight daypart, for example Late Night
        (
          d.start_minute_of_day + d.duration_minute_total > 1440
          AND (
               b.tx_minute_of_day >= d.start_minute_of_day
               OR b.tx_minute_of_day < MOD(d.start_minute_of_day + d.duration_minute_total, 1440)
          )
        )
      )
),

/* ------------------------------------------------------------
   5. Build anchor days in the target reporting window
------------------------------------------------------------ */
anchor_days AS (
  SELECT DISTINCT
    business_day AS anchor_day
  FROM final_tx
  CROSS JOIN params p
  WHERE business_day BETWEEN p.start_date AND p.end_date
),

/* ------------------------------------------------------------
   6. Aggregate daily activity by store
------------------------------------------------------------ */
store_day_activity AS (
  SELECT
    f.storeGroupId,
    f.storeId,
    f.business_day,

    -- Store-day transaction count
    COUNT(*) AS txn_count,

    -- Store-day sales
    ROUND(SUM(f.sale_in_dollar), 2) AS sales_amount

  FROM final_tx f
  GROUP BY
    f.storeGroupId,
    f.storeId,
    f.business_day
),

/* ------------------------------------------------------------
   7. Keep only active store-days
------------------------------------------------------------ */
qualified_store_day AS (
  SELECT
    sda.storeGroupId,
    sda.storeId,
    sda.business_day,
    sda.txn_count,
    sda.sales_amount

  FROM store_day_activity sda
  CROSS JOIN params p

  -- A store-day is active only when transaction count is above threshold
  WHERE sda.txn_count > p.active_store_transaction
),

/* ------------------------------------------------------------
   8. Build dynamic comparison group per anchor_day
------------------------------------------------------------ */
comparison_group AS (
  SELECT
    a.anchor_day,
    cur.storeGroupId,
    cur.storeId

  FROM anchor_days a

  -- Store must be active on current anchor day
  JOIN qualified_store_day cur
    ON cur.business_day = a.anchor_day

  -- Store must also be active on same weekday prior year
  -- 364 days keeps weekday alignment
  JOIN qualified_store_day d364
    ON d364.storeGroupId = cur.storeGroupId
   AND d364.storeId = cur.storeId
   AND d364.business_day = DATE_SUB(a.anchor_day, INTERVAL 364 DAY)

  -- Store must also be active on historical reference day
  -- 546 days is used as an additional stability requirement
  JOIN qualified_store_day d546
    ON d546.storeGroupId = cur.storeGroupId
   AND d546.storeId = cur.storeId
   AND d546.business_day = DATE_SUB(a.anchor_day, INTERVAL 546 DAY)
),

/* ------------------------------------------------------------
   9. Count qualified comparison stores per anchor_day
------------------------------------------------------------ */
store_count AS (
  SELECT
    anchor_day,

    -- Number of stores that qualified for this anchor_day
    COUNT(1) AS number

  FROM comparison_group
  GROUP BY anchor_day
)

/* ------------------------------------------------------------
   10. Final summary: max, min, and median store count
------------------------------------------------------------ */
SELECT
  -- Highest comparison-store count across all anchor days
  MAX(number) AS Max_Store,

  -- Lowest comparison-store count across all anchor days
  MIN(number) AS Min_Store,

  -- Median daily comparison-store count.
  -- APPROX_QUANTILES(number, 100) splits store counts into 100 percentiles.
  -- OFFSET(50) returns the 50th percentile, which is the median.
  APPROX_QUANTILES(number, 100)[OFFSET(50)] AS median_store_count

FROM store_count;