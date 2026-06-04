/*
Purpose:
  Create migration2220.chicken_salad_graph.

  This table shows weekly total sales and total check count for customers
  who bought Chicken Salad at least once in the selected six test stores.

Business question:
  After identifying Chicken Salad customers, what is their total transaction
  activity by week?

Logic flow:
  1. Define the analysis start datetime.
  2. Define Chicken Salad target PLUs.
  3. Define the six test stores.
  4. Build a transaction base from authorization data.
  5. Convert UTC timestamp to Chicago local business_date using 6 AM cutoff.
  6. Identify checks that contain Chicken Salad.
  7. Identify customers who bought Chicken Salad at least once.
  8. Pull all transaction history for those Chicken Salad customers.
  9. Aggregate total check count and sales by week.
*/

CREATE OR REPLACE TABLE `migration2220.chicken_salad_roll_call` AS

WITH params AS (
  SELECT
    -- Analysis starts at 6 AM Chicago local time.
    DATETIME '2025-01-01 06:00:00' AS start_datetime
),

target_items AS (
  -- Chicken Salad PLUs to identify Chicken Salad orders.
  SELECT '6020' AS target_plu_id, 'Sgl Chk Sld' AS target_item_name UNION ALL
  SELECT '2035', 'ChkSldSand Cmbo' UNION ALL
  SELECT '5325', 'ChkSldSand' UNION ALL
  SELECT '66015', 'Chk Sld Fam' UNION ALL
  SELECT '5520', 'Chk Sld Sld' UNION ALL
  SELECT '65020', 'Chk Sld Sgl' UNION ALL
  SELECT '70100', 'HP Chk Sld'
),

store_windows AS (
  -- Six selected test stores.
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

transaction_base AS (
  /*
    Build the base transaction set.

    Important:
      - timestamp is stored in UTC.
      - Business day starts at 6 AM Chicago time.
      - Therefore, convert timestamp to Chicago local time,
        subtract 6 hours, then take DATE.
  */
  SELECT
    -- Create a stable check-level hash because raw check data may not have a single natural ID.
    CASE
      WHEN a.check IS NULL THEN NULL
      ELSE TO_HEX(
        SHA256(
          CONCAT(
            COALESCE(CAST(a.accountNumberId AS STRING), 'NULL'),
            TO_JSON_STRING(a.check),
            COALESCE(CAST(a.amount AS STRING), 'NULL'),
            COALESCE(CAST(a.siteIdFrontEnd AS STRING), 'NULL'),
            COALESCE(FORMAT_TIMESTAMP('%F %T%E6S', a.timestamp, 'UTC'), 'NULL')
          )
        )
      )
    END AS check_hash,

    a.accountNumberId AS account_number_id,
    m.storeId AS test_store_id,
    sw.store_name,

    -- Convert cents to dollars.
    ROUND(a.amount / 100, 2) AS sale_in_dollar,

    -- Original UTC timestamp.
    a.timestamp,

    -- Chicago local datetime for audit/debugging.
    DATETIME(a.timestamp, 'America/Chicago') AS local_datetime,

    -- Business date using 6 AM cutoff.
    -- Example:
    --   2025-01-01 05:59 AM Chicago = 2024-12-31 business_date
    --   2025-01-01 06:00 AM Chicago = 2025-01-01 business_date
    DATE(
      DATETIME_SUB(
        DATETIME(a.timestamp, 'America/Chicago'),
        INTERVAL 6 HOUR
      )
    ) AS business_date,

    a.check

  FROM `backfill_dataset.AuthorizationsClientLine` a

  -- Map payment authorization merchant/terminal to store.
  JOIN `backfill_dataset.StoresToMerchantIdsAuthorization` m
    ON a.siteIdFrontend = m.merchantId
   AND a.terminalId = m.terminalId

  -- Keep only the six selected test stores.
  JOIN store_windows sw
    ON m.storeId = sw.storeId

  -- Confirm store belongs to the Golden Chick brand group.
  JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON m.storeId = sg.storeId

  CROSS JOIN params p

  WHERE DATETIME(a.timestamp, 'America/Chicago') >= p.start_datetime

    -- Keep valid sale-like transaction types.
    AND a.type IN (
      'Pre Auth Request',
      'Pre Auth Complete',
      'Purchase'
    )

    -- Require check JSON so line items can be inspected.
    AND a.check IS NOT NULL

    -- Require customer ID so customer history can be built.
    AND a.accountNumberId IS NOT NULL

    -- Keep only Golden Chick stores.
    AND sg.storeGroupId = 'GoldenChick'
),

chicken_salad_orders AS (
  /*
    Identify checks that contain at least one Chicken Salad target PLU.

    Grain:
      1 row per chicken-salad check_hash.
  */
  SELECT
    tb.check_hash,
    tb.account_number_id,
    tb.test_store_id,
    tb.store_name,
    tb.business_date

  FROM transaction_base tb

  -- Unnest line items from check JSON.
  CROSS JOIN UNNEST(JSON_QUERY_ARRAY(tb.check, '$.ls')) AS item

  -- Match line item to Chicken Salad target list.
  JOIN target_items ti
    ON JSON_VALUE(item, '$.p') = ti.target_plu_id
   AND JSON_VALUE(item, '$.n') = ti.target_item_name

  -- Only count positive quantity items.
  WHERE SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64) > 0

  GROUP BY
    tb.check_hash,
    tb.account_number_id,
    tb.test_store_id,
    tb.store_name,
    tb.business_date
),

chicken_salad_customers AS (
  /*
    Identify customers who bought Chicken Salad at least once.

    Grain:
      1 row per Chicken Salad customer.
  */
  SELECT DISTINCT
    account_number_id
  FROM chicken_salad_orders
),

customer_transaction_history AS (
  /*
    Pull all transaction history for Chicken Salad customers.

    Important:
      This includes both:
        - Chicken Salad orders
        - Non-Chicken Salad orders

      This allows the weekly graph to show total activity of customers
      who ever bought Chicken Salad during the analysis period.
  */
  SELECT
    tb.account_number_id,
    tb.check_hash,
    tb.sale_in_dollar,
    tb.timestamp,
    tb.local_datetime,
    tb.business_date

  FROM transaction_base tb

  -- Keep only customers who bought Chicken Salad at least once.
  JOIN chicken_salad_customers csc
    ON tb.account_number_id = csc.account_number_id
)

-- Final weekly aggregation.
SELECT
  DATE_TRUNC(business_date, WEEK(MONDAY)) AS week_start_date,
  DATE_ADD(DATE_TRUNC(business_date, WEEK(MONDAY)), INTERVAL 6 DAY) AS week_end_date,

  COUNT(DISTINCT check_hash) AS total_check_count,
  SUM(sale_in_dollar) AS total_sale

FROM customer_transaction_history

GROUP BY
  week_start_date,
  week_end_date

ORDER BY
  week_start_date;