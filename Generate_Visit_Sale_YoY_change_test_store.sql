/*
================================================================================
Purpose:
Create a daily YoY sales and visit table for the 6 test stores.

Output table:
  migration2220.testStore_YoY_change

Grain:
  1 row = store_id x business_date x customer_type

Main logic:
  1. Define analysis date range.
  2. Define the 6 test stores and launch dates.
  3. Pull valid authorization transactions.
  4. Convert UTC timestamp to business_date using 6 AM business-day rule.
  5. Aggregate daily sales and visits by store and customer type.
  6. Join current business date to same weekday prior-year date using 364-day lag.
  7. Calculate YoY sale and visit delta.
================================================================================
*/

CREATE OR REPLACE TABLE `migration2220.testStore_YoY_change` AS (

WITH params AS (
  -- Analysis parameter dates
  SELECT
    DATE '2026-01-01' AS business_date,              -- Current analysis start date
    DATE '2026-06-07' AS analysis_cutoff_business_date -- Latest complete business date
),

store_windows AS (
  -- Define the 6 test stores and their menu launch dates
  SELECT *
  FROM UNNEST([
    STRUCT('2MWAXy3FzKTvmSgn' AS storeId, 'Lancaster / W Pleasant Run Rd' AS store_name, DATE '2026-04-27' AS launch_date),
    STRUCT('8CCEYO2I92f92Qdc', 'Dallas / N Central Expy (Meadow)', DATE '2026-04-27'),
    STRUCT('8uhY7x53ECiEcan0', 'Melissa / Sam Rayburn Hwy', DATE '2026-04-27'),
    STRUCT('XIyD5NWrRRBtbUKc', 'Marshall / E End Blvd S', DATE '2026-04-29'),
    STRUCT('uUUnekPKWHSOi9PQ', 'Fort Worth / E Berry St', DATE '2026-04-28'),
    STRUCT('b4gu065sNyiZggy7', 'Whitesboro / Highway 377 N', DATE '2026-05-08')
  ])
),

base_transactions AS (
  -- Pull transaction-level records for the 6 test stores
  SELECT
    -- Create a synthetic check hash to identify a unique transaction/check
    TO_HEX(SHA256(CONCAT(
      COALESCE(CAST(a.accountNumberId AS STRING), 'NULL'), '|',
      TO_JSON_STRING(a.check), '|',
      COALESCE(CAST(a.amount AS STRING), 'NULL'), '|',
      COALESCE(CAST(a.siteIdFrontend AS STRING), 'NULL'), '|',
      COALESCE(CAST(a.terminalId AS STRING), 'NULL'), '|',
      COALESCE(FORMAT_TIMESTAMP('%F %T%E6S', a.timestamp, 'UTC'), 'NULL')
    ))) AS check_hash,

    a.accountNumberId AS account_number_id,
    m.storeId AS store_id,
    sw.store_name,
    sw.launch_date,

    -- Convert isnewatStore boolean into readable customer type
    CASE
      WHEN a.isnewatStore = TRUE THEN 'New'
      WHEN a.isnewatStore = FALSE THEN 'Returning'
      ELSE 'Unknown'
    END AS customer_type,

    -- Convert cents to dollars
    ROUND(a.amount / 100, 2) AS sale_in_dollar,

    -- Convert UTC timestamp to store business date.
    -- Business day starts at 6 AM local time, so subtract 6 hours.
    DATE(
      DATETIME_SUB(
        DATETIME(a.timestamp, 'America/Chicago'),
        INTERVAL 6 HOUR
      )
    ) AS business_date

  FROM `backfill_dataset.AuthorizationsClientLine` a

  -- Map authorization merchant/terminal to store_id
  JOIN `backfill_dataset.StoresToMerchantIdsAuthorization` m
    ON a.siteIdFrontend = m.merchantId
   AND a.terminalId = m.terminalId

  -- Keep only the 6 test stores
  JOIN store_windows sw
    ON m.storeId = sw.storeId

  CROSS JOIN params p

  WHERE DATE(
      DATETIME_SUB(
        DATETIME(a.timestamp, 'America/Chicago'),
        INTERVAL 6 HOUR
      )
    ) BETWEEN DATE_SUB(p.business_date, INTERVAL 364 DAY)
        AND p.analysis_cutoff_business_date

    -- Keep valid authorization/payment transaction types
    AND a.type IN (
      'Pre Auth Request',
      'Pre Auth Complete',
      'Purchase'
    )
),

daily_store_customer AS (
  -- Aggregate transaction-level records into daily store/customer-type metrics
  SELECT
    store_id,
    store_name,
    business_date,
    customer_type,
    SUM(sale_in_dollar) AS sale,
    COUNT(DISTINCT check_hash) AS visit
  FROM base_transactions
  GROUP BY
    business_date,
    store_id,
    store_name,
    customer_type
),

current_period AS (
  -- Keep only current analysis period dates
  SELECT d.*
  FROM daily_store_customer d
  CROSS JOIN params p
  WHERE d.business_date BETWEEN p.business_date
                            AND p.analysis_cutoff_business_date
)

-- Final YoY output: current date joined to prior-year comparable date
SELECT
  c.store_id,
  c.store_name,
  c.customer_type AS isnewatStore,
  c.business_date,

  c.sale AS current_sale,
  p.sale AS prior_sale,
  SAFE_DIVIDE(c.sale - p.sale, p.sale) AS yoy_sale_delta,

  c.visit AS current_visit,
  p.visit AS prior_visit,
  SAFE_DIVIDE(c.visit - p.visit, p.visit) AS yoy_visit_delta,

  -- 364-day lag keeps weekday alignment
  DATE_SUB(c.business_date, INTERVAL 364 DAY) AS prior_business_date

FROM current_period c

LEFT JOIN daily_store_customer p
  ON p.store_id = c.store_id
 AND p.customer_type = c.customer_type
 AND p.business_date = DATE_SUB(c.business_date, INTERVAL 364 DAY)

ORDER BY
  c.business_date,
  c.store_id,
  c.customer_type
);


/*
================================================================================
Purpose:
Display daily Sale YoY change for all 6 test stores combined.

Grain:
  1 row = business_date

Use case:
  Check whether total test-store sales improved or declined versus prior year.
================================================================================
*/

SELECT
  business_date,
  SUM(current_sale) AS current_sale,
  SUM(prior_sale) AS prior_sale,
  SAFE_DIVIDE(SUM(current_sale), SUM(prior_sale)) - 1 AS YoY_change
FROM `migration2220.testStore_YoY_change`
GROUP BY business_date
ORDER BY business_date;


/*
================================================================================
Purpose:
Display daily Visit YoY change for one selected test store.

Grain:
  1 row = store_id x customer_type x business_date

Use case:
  Review visit performance for one store and one customer segment.
================================================================================
*/

SELECT
  store_id,
  store_name,
  isnewatStore,
  business_date,
  SUM(current_visit) AS current_visit,
  SUM(prior_visit) AS prior_visit,
  SAFE_DIVIDE(SUM(current_visit), SUM(prior_visit)) - 1 AS YoY_change
FROM `migration2220.testStore_YoY_change`
WHERE store_id = 'b4gu065sNyiZggy7' -- Whitesboro / Highway 377 N
  AND isnewatStore = 'Returning'
GROUP BY
  store_id,
  store_name,
  business_date,
  isnewatStore
ORDER BY business_date;


/*
================================================================================
Purpose:
Display daily Visit YoY change for all 6 test stores combined.

Grain:
  1 row = customer_type x business_date

Use case:
  Review combined visit performance by customer segment.
================================================================================
*/

SELECT
  isnewatStore,
  business_date,
  SUM(current_visit) AS current_visit,
  SUM(prior_visit) AS prior_visit,
  SAFE_DIVIDE(SUM(current_visit), SUM(prior_visit)) - 1 AS YoY_change
FROM `migration2220.testStore_YoY_change`
WHERE isnewatStore = 'Returning'
GROUP BY
  business_date,
  isnewatStore
ORDER BY business_date;