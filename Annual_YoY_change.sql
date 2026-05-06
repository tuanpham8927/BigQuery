/* ============================================================
   BUSINESS PURPOSE
   ============================================================

   This query produces a DMA-level YoY comparison table with:

   - Saturday metrics
   - Non-Saturday metrics
   - Sales
   - Transactions
   - Average check
   - Customer YoY %
   - Fixed cohort store count

   FINAL OUTPUT GRAIN:
     1 row = 1 DMA x 1 year

   CORE BUSINESS LOGIC:

   1. Start with valid BasedTransactions only:
      - In-store and Online
      - positive sales
      - valid storeId
      - valid business_day

   2. Build a fixed cohort per DMA:
      A store must pass all rules:
        - baseline maturity rule
        - monthly continuity rule
        - Saturday coverage rule
        - Non-Saturday coverage rule

   3. After fixed cohort is created:
      Build YoY date pairs using BasedTransactions business dates.

   4. Symmetric YoY date-pair rule:
      A current business date is included only if the aligned prior date
      also exists for the same DMA fixed cohort.

      current_business_day compares to:
        DATE_SUB(current_business_day, INTERVAL 364 DAY)

   5. Final result pivots:
      - Saturday columns
      - Non-Saturday columns

   IMPORTANT:
   This query does NOT use the calendar table for final YoY totals.
   The calendar table is used only for cohort qualification rules.

============================================================ */

--CREATE OR REPLACE TABLE `migration2220.B_Annual_YoY_Change` AS

WITH params AS (
  SELECT
    DATE '2022-01-01' AS start_date,
    DATE '2026-04-30' AS cutoff_date,

    -- Baseline maturity rule:
    -- store must reach its 50th qualified transaction
    -- on or before this date.
    50 AS maturity_txn_rank,
    DATE '2021-10-01' AS maturity_cutoff_date,

    -- Monthly continuity rule:
    -- store must have at least 100 transactions every month.
    100 AS monthly_min_txn,

    -- Daily coverage rule:
    -- a store-date is considered covered only if it has >= 10 transactions.
    10 AS daily_min_txn,

    -- Saturday coverage rule thresholds.
    -- Full years require at least 40 covered Saturdays.
    -- 2026 YTD requires at least 13 covered Saturdays.
    40 AS min_saturdays_full_year,
    13 AS min_saturdays_2026_ytd,

    -- Non-Saturday coverage rule:
    -- store must cover at least 75% of expected Non-Saturday dates.
    0.75 AS min_non_saturday_coverage_pct,

    -- Input multiple DMA groups here.
    -- Empty ARRAY is take all stores of GoldenChick.
    ARRAY<STRING>[] AS target_store_groups,
    -- ARRAY<STRING>[
    --   'GCDMADallasFortWorth',
    --   'GCDMAHouston',
    --   'GCDMAAustin',
    --   'GCDMAOklahomaCity',
    --   'GCDMASanAntonio'
    -- ] AS target_store_groups,
        

    -- Storm Saturday exclusion.
    ARRAY<DATE>[DATE '2026-01-24'] AS excluded_saturdays,

    -- Storm Non-Saturday exclusions.
    ARRAY<DATE>[
      DATE '2026-01-25',
      DATE '2026-01-26',
      DATE '2026-01-27'
    ] AS excluded_non_saturdays
),

/* ============================================================
   1. CALENDAR BACKBONE

   Used for cohort qualification only:
   - expected months
   - expected Saturdays
   - expected Non-Saturdays

   Not used for final YoY transaction/sales totals.
============================================================ */
calendar AS (
  SELECT
    d AS business_day,
    EXTRACT(YEAR FROM d) AS business_year,
    FORMAT_DATE('%Y-%m', d) AS business_month,
    FORMAT_DATE('%A', d) AS business_weekday
  FROM params p,
  UNNEST(GENERATE_DATE_ARRAY(p.start_date, p.cutoff_date)) AS d
),

/* ============================================================
   2. VALID TRANSACTION BASE

   This is the raw transaction source used for:
   - fixed cohort rules
   - final current/prior sales and transaction totals
============================================================ */
Based_data AS (
  SELECT
    b.storeId AS store_id,
    b.store_name,
    b.accountNumberId,
    b.business_day,
    b.business_weekday,
    b.sale_in_dollar
  FROM `migration2220.BasedTransactions` b
  CROSS JOIN params p
  WHERE b.business_day <= p.cutoff_date
    AND b.reportGroup IN ('In-store', 'Online')
    AND b.storeId IS NOT NULL
    AND b.business_day IS NOT NULL
    AND COALESCE(b.sale_in_dollar, 0) > 0
)
,

/* ============================================================
   3. STORE-DAY TRANSACTION COUNT

   One row = 1 store x 1 business date.

   Used to decide whether a store covered a date.
============================================================ */
store_day_txn AS (
  SELECT
    store_id,
    store_name,
    business_day,
    business_weekday,
    COUNT(*) AS qualified_txn_count
  FROM Based_data
  CROSS JOIN params p
  WHERE business_day BETWEEN p.start_date AND p.cutoff_date
  GROUP BY store_id, store_name, business_day, business_weekday
),

/* ============================================================
   4. TARGET DMA STORE LIST

   Finds stores that belong to the selected DMA groups.
============================================================ */
store_list AS (
  SELECT DISTINCT
    ssg.storeGroupId AS dma_store_group_id,
    sg.name AS dma_name,
    sdt.store_id,
    sdt.store_name
  FROM store_day_txn sdt
  LEFT JOIN `backfill_dataset.StoresToStoreGroups` ssg
    ON sdt.store_id = ssg.storeId --AND ssg.storeGroupId like 'GCDMA%'
  JOIN `backfill_dataset.StoreGroups` sg ON ssg.storeGroupId = sg.storeGroupId
  CROSS JOIN params p
  WHERE ARRAY_LENGTH(p.target_store_groups) = 0 OR ssg.storeGroupId IN UNNEST(p.target_store_groups)
),

/* ============================================================
   5. BASELINE MATURITY RULE

   Rank each store's transactions by business date.
   Store passes if its 50th transaction happened on/before cutoff.
============================================================ */
ranked_store_txn AS (
  SELECT
    store_id,
    business_day,
    ROW_NUMBER() OVER (
      PARTITION BY store_id
      ORDER BY business_day
    ) AS qualified_txn_rank
  FROM Based_data
),

maturity_audit AS (
  SELECT
    s.dma_store_group_id,
    s.store_id,

    CASE
      WHEN MIN(
        CASE
          WHEN r.qualified_txn_rank = p.maturity_txn_rank
          THEN r.business_day
        END
      ) <= p.maturity_cutoff_date
      THEN TRUE ELSE FALSE
    END AS baseline_maturity_pass_flag

  FROM store_list s
  CROSS JOIN params p
  LEFT JOIN ranked_store_txn r
    ON s.store_id = r.store_id
  GROUP BY s.dma_store_group_id, s.store_id, p.maturity_cutoff_date
)
,

/* ============================================================
   6. MONTHLY CONTINUITY RULE

   Store must have at least 100 transactions in every expected month.
============================================================ */
expected_months AS (
  SELECT DISTINCT business_month
  FROM calendar
),

store_month_txn AS (
  SELECT
    store_id,
    FORMAT_DATE('%Y-%m', business_day) AS business_month,
    SUM(qualified_txn_count) AS monthly_qualified_transaction_count
  FROM store_day_txn
  GROUP BY store_id, business_month
),

monthly_audit AS (
  SELECT
    s.dma_store_group_id,
    s.store_id,

    -- If any expected month has fewer than 100 transactions,
    -- the store fails monthly continuity.
    CASE
      WHEN COUNTIF(
        COALESCE(m.monthly_qualified_transaction_count, 0) < p.monthly_min_txn
      ) = 0
      THEN TRUE ELSE FALSE
    END AS monthly_continuity_pass_flag

  FROM store_list s
  CROSS JOIN expected_months em
  CROSS JOIN params p
  LEFT JOIN store_month_txn m
    ON s.store_id = m.store_id
   AND em.business_month = m.business_month
  GROUP BY s.dma_store_group_id, s.store_id
),

/* ============================================================
   7. SATURDAY COVERAGE RULE
============================================================ */
expected_saturdays AS (
  SELECT business_year, business_day
  FROM calendar
  CROSS JOIN params p
  WHERE business_weekday = 'Saturday'
    AND business_day NOT IN UNNEST(p.excluded_saturdays)
),

store_saturday_coverage AS (
  SELECT
    s.dma_store_group_id,
    s.store_id,
    e.business_year,

    -- Count covered Saturdays where store had at least daily_min_txn.
    COUNTIF(
      COALESCE(d.qualified_txn_count, 0) >= p.daily_min_txn
    ) AS covered_saturday_dates

  FROM store_list s
  CROSS JOIN expected_saturdays e
  CROSS JOIN params p
  LEFT JOIN store_day_txn d
    ON s.store_id = d.store_id
   AND e.business_day = d.business_day
  GROUP BY s.dma_store_group_id, s.store_id, e.business_year
),

saturday_audit AS (
  SELECT
    dma_store_group_id,
    store_id,

    -- Full years need >= 40 covered Saturdays.
    -- 2026 YTD needs >= 13 covered Saturdays.
    CASE
      WHEN COUNTIF(
        CASE
          WHEN business_year BETWEEN 2022 AND 2025
            THEN covered_saturday_dates < p.min_saturdays_full_year
          WHEN business_year = 2026
            THEN covered_saturday_dates < p.min_saturdays_2026_ytd
          ELSE FALSE
        END
      ) = 0
      THEN TRUE ELSE FALSE
    END AS saturday_coverage_pass_flag

  FROM store_saturday_coverage
  CROSS JOIN params p
  WHERE business_year BETWEEN 2022 AND 2026
  GROUP BY dma_store_group_id, store_id
),

/* ============================================================
   8. NON-SATURDAY COVERAGE RULE
============================================================ */
expected_non_saturdays AS (
  SELECT business_year, business_day
  FROM calendar
  CROSS JOIN params p
  WHERE business_weekday <> 'Saturday'
    AND business_day NOT IN UNNEST(p.excluded_non_saturdays)
),

store_non_saturday_coverage AS (
  SELECT
    s.dma_store_group_id,
    s.store_id,
    e.business_year,

    -- Coverage rate = covered Non-Saturday dates / expected Non-Saturday dates.
    SAFE_DIVIDE(
      COUNTIF(COALESCE(d.qualified_txn_count, 0) >= p.daily_min_txn),
      COUNT(*)
    ) AS non_saturday_coverage_rate

  FROM store_list s
  CROSS JOIN expected_non_saturdays e
  CROSS JOIN params p
  LEFT JOIN store_day_txn d
    ON s.store_id = d.store_id
   AND e.business_day = d.business_day
  GROUP BY s.dma_store_group_id, s.store_id, e.business_year
),

non_saturday_audit AS (
  SELECT
    dma_store_group_id,
    store_id,

    -- Store passes only if every year has coverage >= 75%.
    CASE
      WHEN COUNTIF(
        non_saturday_coverage_rate < p.min_non_saturday_coverage_pct
      ) = 0
      THEN TRUE ELSE FALSE
    END AS non_saturday_coverage_pass_flag

  FROM store_non_saturday_coverage
  CROSS JOIN params p
  WHERE business_year BETWEEN 2022 AND 2026
  GROUP BY dma_store_group_id, store_id
),

/* ============================================================
   9. FIXED COHORT

   Store enters final cohort only if it passes all rules.
============================================================ */
fixed_cohort AS (
  SELECT
    s.dma_store_group_id,
    s.dma_name,
    s.store_id,
    s.store_name
  FROM store_list s
  JOIN maturity_audit ma
    ON s.dma_store_group_id = ma.dma_store_group_id
   AND s.store_id = ma.store_id
  JOIN monthly_audit mo
    ON s.dma_store_group_id = mo.dma_store_group_id
   AND s.store_id = mo.store_id
  JOIN saturday_audit sa
    ON s.dma_store_group_id = sa.dma_store_group_id
   AND s.store_id = sa.store_id
  JOIN non_saturday_audit na
    ON s.dma_store_group_id = na.dma_store_group_id
   AND s.store_id = na.store_id
  WHERE ma.baseline_maturity_pass_flag = TRUE
    AND mo.monthly_continuity_pass_flag = TRUE
    AND sa.saturday_coverage_pass_flag = TRUE
    AND na.non_saturday_coverage_pass_flag = TRUE
),

fixed_cohort_count AS (
  SELECT
    dma_store_group_id,
    COUNT(DISTINCT store_id) AS fixed_dma_store_count, STRING_AGG(DISTINCT store_name,', ' ORDER BY store_name) AS fixed_cohort_store_names
  FROM fixed_cohort
  GROUP BY dma_store_group_id
),

/* ============================================================
   10. ACTUAL DMA BUSINESS DATES

   Gets actual transaction dates after fixed cohort is created.

   This keeps the final YoY calculation based on BasedTransactions,
   not calendar-only dates.
============================================================ */
actual_dma_business_dates AS (
  SELECT DISTINCT
    fc.dma_store_group_id,
    fc.dma_name,
    b.business_day,
    b.business_weekday
  FROM Based_data b
  JOIN fixed_cohort fc
    ON b.store_id = fc.store_id
),

/* ============================================================
   11. SYMMETRIC YoY DATE PAIRS

   This is the key reconciliation logic.

   A current date is included only if its 364-day prior date also exists
   for the same DMA fixed cohort.

   This avoids:
     - current/prior using different date lists
     - same business day count but mismatched actual dates
============================================================ */
current_period_dates AS (
  SELECT DISTINCT
    cur.dma_store_group_id,
    cur.dma_name,
    cur.business_day AS current_business_day,
    DATE_SUB(cur.business_day, INTERVAL 364 DAY) AS prior_business_day,
    EXTRACT(YEAR FROM cur.business_day) AS year,
    CASE
      WHEN EXTRACT(YEAR FROM cur.business_day) BETWEEN 2023 AND 2025 THEN 'Full Year'
      WHEN EXTRACT(YEAR FROM cur.business_day) = 2026 THEN 'YTD'
    END AS output_period_type,
    CASE
      WHEN cur.business_weekday = 'Saturday' THEN 'Saturday'
      ELSE 'Non-Saturday'
    END AS weekday_group
  FROM actual_dma_business_dates cur
  JOIN actual_dma_business_dates prior
    ON cur.dma_store_group_id = prior.dma_store_group_id
   AND DATE_SUB(cur.business_day, INTERVAL 364 DAY) = prior.business_day -- Current date is included only if its 364-day prior date also exists. 
  CROSS JOIN params p
  WHERE EXTRACT(YEAR FROM cur.business_day) BETWEEN 2023 AND 2026
    AND NOT (
      cur.business_weekday = 'Saturday'
      AND cur.business_day IN UNNEST(p.excluded_saturdays)
    )
    AND NOT (
      cur.business_weekday <> 'Saturday'
      AND cur.business_day IN UNNEST(p.excluded_non_saturdays)
    )
),

/* ============================================================
   12. CURRENT TOTALS
============================================================ */
current_totals AS (
  SELECT
    d.dma_store_group_id,
    d.dma_name,
    d.year,
    d.output_period_type,
    d.weekday_group,    
    COUNT(DISTINCT d.current_business_day) AS current_business_date_count,
    SUM(COALESCE(b.sale_in_dollar, 0)) AS current_sales,
    COUNT(DISTINCT b.accountNumberId) AS current_customers,
    COUNTIF(b.store_id IS NOT NULL AND COALESCE(b.sale_in_dollar, 0) > 0)
      AS current_transaction_count
  FROM current_period_dates d
  JOIN fixed_cohort fc
    ON d.dma_store_group_id = fc.dma_store_group_id
  LEFT JOIN Based_data b
    ON b.store_id = fc.store_id
   AND b.business_day = d.current_business_day
  GROUP BY d.dma_store_group_id, d.dma_name, d.year, d.output_period_type, d.weekday_group
),

/* ============================================================
   13. PRIOR TOTALS
============================================================ */
prior_totals AS (
  SELECT
    d.dma_store_group_id,
    d.dma_name,
    d.year,
    d.output_period_type,
    d.weekday_group,

    COUNT(DISTINCT b.business_day) AS prior_business_date_count,
    SUM(COALESCE(b.sale_in_dollar, 0)) AS prior_sales,
    COUNT(DISTINCT b.accountNumberId) AS prior_customers,
    COUNTIF(b.store_id IS NOT NULL AND COALESCE(b.sale_in_dollar, 0) > 0)
      AS prior_transaction_count

  FROM current_period_dates d
  JOIN fixed_cohort fc
    ON d.dma_store_group_id = fc.dma_store_group_id
  LEFT JOIN Based_data b
    ON b.store_id = fc.store_id
   AND b.business_day = d.prior_business_day
  GROUP BY d.dma_store_group_id, d.dma_name, d.year, d.output_period_type, d.weekday_group
),

/* ============================================================
   14. CALCULATE YOY BY WEEKDAY GROUP

   Grain:
     1 row = 1 DMA x 1 year x 1 weekday group
============================================================ */
final_by_weekday AS (
  SELECT
    c.dma_store_group_id,
    c.dma_name,
    c.year,
    c.output_period_type,
    fcc.fixed_dma_store_count,
    fcc.fixed_cohort_store_names,
    c.weekday_group,

    c.current_business_date_count,
    p.prior_business_date_count,

    ROUND(c.current_sales, 2) AS current_sales,
    ROUND(p.prior_sales, 2) AS prior_sales,

    c.current_transaction_count,
    p.prior_transaction_count,

    c.current_customers,
    p.prior_customers,

    ROUND(SAFE_DIVIDE(c.current_sales, c.current_transaction_count), 2)
      AS current_average_check,

    ROUND(SAFE_DIVIDE(p.prior_sales, p.prior_transaction_count), 2)
      AS prior_average_check,

    ROUND(SAFE_DIVIDE(c.current_sales, p.prior_sales) - 1, 4)
      AS sales_yoy_pct,

    ROUND(SAFE_DIVIDE(c.current_transaction_count, p.prior_transaction_count) - 1, 4)
      AS transaction_yoy_pct,

    ROUND(
      SAFE_DIVIDE(
        SAFE_DIVIDE(c.current_sales, c.current_transaction_count),
        SAFE_DIVIDE(p.prior_sales, p.prior_transaction_count)
      ) - 1,
      4
    ) AS average_check_yoy_pct,

    ROUND(SAFE_DIVIDE(c.current_customers, p.prior_customers) - 1, 4)
      AS customer_yoy_pct

  FROM current_totals c
  JOIN prior_totals p
    ON c.dma_store_group_id = p.dma_store_group_id
   AND c.year = p.year
   AND c.output_period_type = p.output_period_type
   AND c.weekday_group = p.weekday_group
  JOIN fixed_cohort_count fcc
    ON c.dma_store_group_id = fcc.dma_store_group_id
)

SELECT * FROM final_by_weekday --where dma_store_group_id like 'GoldenChick%'

/* ============================================================
   15. FINAL PIVOT OUTPUT

   Converts:
     DMA x year x weekday group

   Into:
     DMA x year

   With Saturday and Non-Saturday side by side.
============================================================ */
-- SELECT
--   dma_store_group_id,
--   dma_name,
--   year,
--   output_period_type,
--   fixed_dma_store_count,

--   MAX(IF(weekday_group = 'Non-Saturday', current_business_date_count, NULL))
--     AS non_saturday_current_business_date_count,

--   MAX(IF(weekday_group = 'Non-Saturday', current_sales, NULL))
--     AS non_saturday_current_sales,

--   MAX(IF(weekday_group = 'Non-Saturday', prior_sales, NULL))
--     AS non_saturday_prior_sales,

--   MAX(IF(weekday_group = 'Non-Saturday', current_transaction_count, NULL))
--     AS non_saturday_current_transaction_count,

--   MAX(IF(weekday_group = 'Non-Saturday', prior_transaction_count, NULL))
--     AS non_saturday_prior_transaction_count,

--   MAX(IF(weekday_group = 'Non-Saturday', sales_yoy_pct, NULL))
--     AS non_saturday_sales_yoy_pct,

--   MAX(IF(weekday_group = 'Non-Saturday', transaction_yoy_pct, NULL))
--     AS non_saturday_transaction_yoy_pct,

--   MAX(IF(weekday_group = 'Non-Saturday', average_check_yoy_pct, NULL))
--     AS non_saturday_average_check_yoy_pct,

--   MAX(IF(weekday_group = 'Non-Saturday', customer_yoy_pct, NULL))
--     AS non_saturday_customer_yoy_pct,

--   MAX(IF(weekday_group = 'Saturday', current_business_date_count, NULL))
--     AS saturday_current_business_date_count,

--   MAX(IF(weekday_group = 'Saturday', current_sales, NULL))
--     AS saturday_current_sales,

--   MAX(IF(weekday_group = 'Saturday', prior_sales, NULL))
--     AS saturday_prior_sales,

--   MAX(IF(weekday_group = 'Saturday', current_transaction_count, NULL))
--     AS saturday_current_transaction_count,

--   MAX(IF(weekday_group = 'Saturday', prior_transaction_count, NULL))
--     AS saturday_prior_transaction_count,

--   MAX(IF(weekday_group = 'Saturday', sales_yoy_pct, NULL))
--     AS saturday_sales_yoy_pct,

--   MAX(IF(weekday_group = 'Saturday', transaction_yoy_pct, NULL))
--     AS saturday_transaction_yoy_pct,

--   MAX(IF(weekday_group = 'Saturday', average_check_yoy_pct, NULL))
--     AS saturday_average_check_yoy_pct,

--   MAX(IF(weekday_group = 'Saturday', customer_yoy_pct, NULL))
--     AS saturday_customer_yoy_pct

-- FROM final_by_weekday
-- GROUP BY
--   dma_store_group_id,
--   dma_name,
--   year,
--   output_period_type,
--   fixed_dma_store_count
-- ORDER BY
--   dma_name,
--   year;