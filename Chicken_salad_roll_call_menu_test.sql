/*
Purpose:
  Create migration2220.chicken_salad_roll_call_control_store.

  This table shows weekly total sales and total check count for customers
  who bought Chicken Salad at least once before the borrowed comparison date
  in the selected matched control stores.

Business question:
  Did prior Chicken Salad buyers in the matched control stores show the same
  weekly sales/check-count pattern as prior Chicken Salad buyers in the test stores?

Important:
  Control stores did not remove Chicken Salad.
  launch_date below is a borrowed comparison date from the matched test store, so we can simulate the pre-launch chicken salad in comparision with its test store.
*/

CREATE OR REPLACE TABLE `migration2220.chicken_salad_roll_call_control_store` AS

WITH params AS (
  SELECT
    DATE '2025-01-01' AS start_datetime,
    DATE '2026-05-31' AS analysis_cutoff_business_date
),

target_items AS (
  SELECT '6020' AS target_plu_id, 'Sgl Chk Sld' AS target_item_name UNION ALL
  SELECT '2035', 'ChkSldSand Cmbo' UNION ALL
  SELECT '5325', 'ChkSldSand' UNION ALL
  SELECT '66015', 'Chk Sld Fam' UNION ALL
  SELECT '5520', 'Chk Sld Sld' UNION ALL
  SELECT '65020', 'Chk Sld Sgl' UNION ALL
  SELECT '70100', 'HP Chk Sld'
),

store_windows AS (
  SELECT *
  FROM UNNEST([
    STRUCT('ZsfnR6Po4t2wjNxs' AS storeId, 'Ovilla / W Ovilla Rd' AS store_name, DATE '2026-04-27' AS launch_date),
    STRUCT('nRjxg7Az1k8ak3rx', 'Richardson / W Arapaho Rd', DATE '2026-04-27'),
    STRUCT('xjtjMLilSu8ctIP6', 'Plano / Independence Pkwy', DATE '2026-04-27'),
    STRUCT('NfiXL8fjfNMusZZH', 'Garland / Lavon Dr', DATE '2026-04-29'),
    STRUCT('KR36AiwhORwWrUun', 'Addison / Marsh Ln', DATE '2026-04-28'),
    STRUCT('SCGMk8mZxgcOxrHU', 'Mckinney / S Lake Forest Dr', DATE '2026-05-08')
  ])
),

transaction_base AS (
  SELECT
    CASE
      WHEN a.check IS NULL THEN NULL
      ELSE TO_HEX(
        SHA256(
          CONCAT(
            COALESCE(CAST(a.accountNumberId AS STRING), 'NULL'), '|',
            TO_JSON_STRING(a.check), '|',
            COALESCE(CAST(a.amount AS STRING), 'NULL'), '|',
            COALESCE(CAST(a.siteIdFrontend AS STRING), 'NULL'), '|',
            COALESCE(CAST(a.terminalId AS STRING), 'NULL'), '|',
            COALESCE(FORMAT_TIMESTAMP('%F %T%E6S', a.timestamp, 'UTC'), 'NULL')
          )
        )
      )
    END AS check_hash,

    a.accountNumberId AS account_number_id,

    m.storeId AS store_id,
    sw.store_name,
    sw.launch_date,

    ROUND(a.amount / 100, 2) AS sale_in_dollar,

    a.timestamp,
    DATETIME(a.timestamp, 'America/Chicago') AS local_datetime,

    DATE(
      DATETIME_SUB(
        DATETIME(a.timestamp, 'America/Chicago'),
        INTERVAL 6 HOUR
      )
    ) AS business_date,

    a.check

  FROM `backfill_dataset.AuthorizationsClientLine` a

  JOIN `backfill_dataset.StoresToMerchantIdsAuthorization` m
    ON a.siteIdFrontend = m.merchantId
   AND a.terminalId = m.terminalId

  JOIN store_windows sw
    ON m.storeId = sw.storeId

  JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON m.storeId = sg.storeId
   AND sg.storeGroupId = 'GoldenChick'

  CROSS JOIN params p

  WHERE DATE(
      DATETIME_SUB(
        DATETIME(a.timestamp, 'America/Chicago'),
        INTERVAL 6 HOUR
      )
    ) between p.start_datetime and p.analysis_cutoff_business_date

    AND a.type IN (
      'Pre Auth Request',
      'Pre Auth Complete',
      'Purchase'
    )

    AND a.check IS NOT NULL
    AND a.accountNumberId IS NOT NULL
),

prelaunch_transaction_base AS (
  SELECT *
  FROM transaction_base
  WHERE business_date < launch_date
),

chicken_salad_orders AS (
  SELECT
    tb.check_hash,
    tb.account_number_id,
    tb.store_id,
    tb.store_name,
    tb.launch_date,
    tb.business_date

  FROM prelaunch_transaction_base tb

  CROSS JOIN UNNEST(JSON_QUERY_ARRAY(tb.check, '$.ls')) AS item

  JOIN target_items ti
    ON JSON_VALUE(item, '$.p') = ti.target_plu_id
   AND JSON_VALUE(item, '$.n') = ti.target_item_name

  WHERE SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64) > 0

  GROUP BY
    tb.check_hash,
    tb.account_number_id,
    tb.store_id,
    tb.store_name,
    tb.launch_date,
    tb.business_date
),

chicken_salad_customers AS (
  SELECT DISTINCT
    account_number_id,
    store_id,
    store_name,
    launch_date
  FROM chicken_salad_orders
),

customer_transaction_history AS (
  SELECT
    tb.account_number_id,
    tb.store_id,
    tb.store_name,
    tb.launch_date,
    tb.check_hash,
    tb.sale_in_dollar,
    tb.timestamp,
    tb.local_datetime,
    tb.business_date,

    CASE
      WHEN tb.business_date < tb.launch_date THEN 'PRE_COMPARISON'
      ELSE 'POST_COMPARISON'
    END AS comparison_period

  FROM transaction_base tb

  JOIN chicken_salad_customers csc
    ON tb.account_number_id = csc.account_number_id
   AND tb.store_id = csc.store_id
)

SELECT
  DATE_TRUNC(business_date, WEEK(MONDAY)) AS week_start_date,
  DATE_ADD(DATE_TRUNC(business_date, WEEK(MONDAY)), INTERVAL 6 DAY) AS week_end_date,

  COUNT(DISTINCT CONCAT(store_id, '|', account_number_id)) AS prior_chicken_salad_customer_count,
  COUNT(DISTINCT CONCAT(store_id, '|', check_hash)) AS total_check_count,
  SUM(sale_in_dollar) AS total_sale

FROM customer_transaction_history

GROUP BY
  week_start_date,
  week_end_date

ORDER BY
  week_start_date;