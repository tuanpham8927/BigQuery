/*
-- Version 1.2
-- Author: Tuan Pham
-- Date: 04/30/2026.
-- Add danymic param for Any day.
-- Adjust day filter at anchor condition for n th visit.
--    Required denominator/numerator object:
--    same-store visit #n happened on Saturday.
--    We use business_day, not local_weekday, because business_day is the already-normalized business-date field used by the visit spine.
--  The version 1.1 excludes customer which has the n visit on Saturday as below sample.
      A customer-store pair has:
        visit #1 = Monday
        visit #2 = Saturday
        visit #3 = Tuesday
      Then the pair SHOULD be included in the denominator for 2->3,
      because visit #2 happened on Saturday.
    The version 1.2 handle the above case.
*/

-- ============================================================
-- Change logic filter 
-- VISIT PAIR RETURN RATE QUERY
-- Supports:
--   [7]                 = Saturday only
--   [1,2,3,4,5,6]       = Non-Saturday
--   [1,2,3,4,5,6,7]     = All days
--
-- BigQuery DAYOFWEEK meaning:
--   1 = Sunday
--   2 = Monday
--   3 = Tuesday
--   4 = Wednesday
--   5 = Thursday
--   6 = Friday
--   7 = Saturday
--
-- Business logic:
--   1. Get all customer-store transactions for the selected store group.
--   2. Rank each customer’s visits per store across lifetime.
--   3. Dynamically create visit pairs: 1->2, 2->3, ... 9->10.
--   4. For each visit pair, count:
--        denominator = customers whose start visit #n is inside period
--        numerator   = customers whose start visit #n and next visit #(n+1)
--                      are both inside the same period
--   5. Apply day filter only to the start visit date.
--      Example:
--        For Saturday mode, visit #n must happen on Saturday.
--        The return visit #(n+1) can happen on any day.
-- ============================================================

WITH params AS (
  SELECT
    -- Comparison periods
    DATE '2025-01-01' AS period_1_start,
    DATE '2025-03-31' AS period_1_end,
    DATE '2026-01-01' AS period_2_start,
    DATE '2026-03-31' AS period_2_end,

    -- Visit pair range
    -- 1 to 9 means:
    --   1->2, 2->3, 3->4, ... 9->10
    1 AS start_visit_min,
    9 AS start_visit_max,
    10 AS max_visit_number,

    -- Store scope
    'GoldenChick' AS target_store_group,
    'all' AS target_store_id,

    -- ========================================================
    -- DAY FILTER PARAMETER
    -- Change this one line only.
    --
    -- Saturday only:
    --   [7]
    --
    -- Non-Saturday:
    --   [1,2,3,4,5,6]
    --
    -- All days:
    --   [1,2,3,4,5,6,7]
    -- ========================================================
    [1,2,3,4,5,6,7] AS target_days
),

/* ================= BASE TRANSACTIONS ================= */
/*
  Pull all transactions for the selected StoreGroup.

  Important:
    Do NOT filter to period dates here.

  Why:
    Visit rank is lifetime-based.
    If we filtered only Q1 2025 or Q1 2026 here, visit #1, #2, #3, etc.
    would be incorrectly recalculated inside that limited period.
*/
final_tx AS (
  SELECT
    b.*
  FROM `migration2220.BasedTransactions` b
  JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON b.storeId = sg.storeId
  CROSS JOIN params p
  WHERE sg.storeGroupId = p.target_store_group
    AND (p.target_store_id = 'all' OR b.storeId = p.target_store_id)
    AND b.accountNumberId IS NOT NULL
),

/* ================= LIFETIME VISIT RANK PER CUSTOMER + STORE ================= */
/*
  Rank visits by accountNumberId + storeId.

  Meaning:
    Same customer visiting different stores has separate lifecycle ranks.

  Example:
    Customer A at Store 1:
      visit #1, visit #2, visit #3

    Customer A at Store 2:
      visit #1, visit #2

  This keeps the query as same-store return behavior.
*/
ranked_visits AS (
  SELECT
    accountNumberId,
    storeId,
    timestamp,
    local_time,
    business_day,
    business_weekday,

    ROW_NUMBER() OVER (
      PARTITION BY accountNumberId, storeId
      ORDER BY local_time
    ) AS visit_number

  FROM final_tx
),

/* ================= DYNAMIC VISIT PAIRS ================= */
/*
  Creates reusable visit-pair list.

  With current params:
    start_visit_min = 1
    start_visit_max = 9
    max_visit_number = 10

  Output:
    1 -> 2
    2 -> 3
    3 -> 4
    ...
    9 -> 10
*/
visit_pairs AS (
  SELECT
    start_visit_number,
    start_visit_number + 1 AS next_visit_number
  FROM params,
  UNNEST(
    GENERATE_ARRAY(
      start_visit_min,
      LEAST(start_visit_max, max_visit_number - 1)
    )
  ) AS start_visit_number
),

/* ================= BUILD CUSTOMER-STORE VISIT PAIRS ================= */
/*
  For each customer-store pair, find the business date of:
    - start visit #n
    - next visit #(n+1)

  Example:
    For 2->3:
      start_visit_business_day = business day of visit #2
      next_visit_business_day  = business day of visit #3
*/
customer_pair_visits AS (
  SELECT
    r.storeId,
    vp.start_visit_number,
    vp.next_visit_number,
    r.accountNumberId,

    MAX(
      CASE
        WHEN r.visit_number = vp.start_visit_number
        THEN r.business_day
      END
    ) AS start_visit_business_day,

    MAX(
      CASE
        WHEN r.visit_number = vp.next_visit_number
        THEN r.business_day
      END
    ) AS next_visit_business_day

  FROM ranked_visits r
  JOIN visit_pairs vp
    ON r.visit_number IN (
      vp.start_visit_number,
      vp.next_visit_number
    )

  GROUP BY
    r.storeId,
    vp.start_visit_number,
    vp.next_visit_number,
    r.accountNumberId
),

/* ================= FINAL RETURN RATE ================= */
/*
  Day filter logic:

    EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
    IN UNNEST(p.target_days)

  This means the day filter applies to the START visit only.

  Example:
    If target_days = [7], then visit #n must be Saturday.
    The next visit #(n+1) can happen on any weekday, as long as it is
    inside the same comparison period.
*/
final AS (
  SELECT
    CONCAT(
      CAST(cpv.start_visit_number AS STRING),
      '->',
      CAST(cpv.next_visit_number AS STRING)
    ) AS Visit_Pair,

    cpv.start_visit_number,

    -- ========================================================
    -- PERIOD 1 RETURN RATE
    -- Example: Q1 2025
    -- ========================================================
    ROUND(
      SAFE_DIVIDE(
        -- Numerator:
        -- start visit is inside period 1
        -- start visit matches target day filter
        -- next visit is also inside period 1
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
          AND cpv.next_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
        ),

        -- Denominator:
        -- start visit is inside period 1
        -- start visit matches target day filter
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
        )
      ),
      4
    ) AS Return_Rate_Q1_2025,

    -- ========================================================
    -- PERIOD 2 RETURN RATE
    -- Example: Q1 2026
    -- ========================================================
    ROUND(
      SAFE_DIVIDE(
        -- Numerator:
        -- start visit is inside period 2
        -- start visit matches target day filter
        -- next visit is also inside period 2
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
          AND cpv.next_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
        ),

        -- Denominator:
        -- start visit is inside period 2
        -- start visit matches target day filter
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
        )
      ),
      4
    ) AS Return_Rate_Q1_2026,

    -- ========================================================
    -- RETURN RATE CHANGE
    -- Period 2 return rate minus Period 1 return rate
    -- ========================================================
    ROUND(
      SAFE_DIVIDE(
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
          AND cpv.next_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
        ),
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
        )
      )
      -
      SAFE_DIVIDE(
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
          AND cpv.next_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
        ),
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
          AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
              IN UNNEST(p.target_days)
        )
      ),
      4
    ) AS Return_Rate_Change,

    -- ========================================================
    -- PERIOD 2 BASE CUSTOMER
    -- This is the denominator for Q1 2026.
    -- It counts customer-store start-visit opportunities.
    -- ========================================================
    COUNTIF(
      cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
      AND EXTRACT(DAYOFWEEK FROM cpv.start_visit_business_day)
          IN UNNEST(p.target_days)
    ) AS `2026 Base Customer`

  FROM customer_pair_visits cpv
  CROSS JOIN params p
  GROUP BY
    Visit_Pair,
    cpv.start_visit_number
)

SELECT
  Visit_Pair,
  Return_Rate_Q1_2025,
  Return_Rate_Q1_2026,
  Return_Rate_Change,
  `2026 Base Customer`
FROM final
ORDER BY start_visit_number;