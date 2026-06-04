CREATE OR REPLACE TABLE `migration2220.chicken_salad_histogram_brand` AS

WITH params AS (
  SELECT
    DATE '2025-01-01' AS start_date,
    DATE '2026-04-15' AS end_date
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
    m.storeId, 
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

  -- Confirm store belongs to the Golden Chick brand group.
  JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON m.storeId = sg.storeId

  CROSS JOIN params p

  WHERE DATE (DATETIME_SUB(DATETIME(a.timestamp, 'America/Chicago'), INTERVAL 6 HOUR)) BETWEEN p.start_date AND p.end_date

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
  SELECT
    tb.check_hash,
    tb.account_number_id,
    tb.storeid,
    tb.business_date
  FROM transaction_base tb
  CROSS JOIN UNNEST(JSON_QUERY_ARRAY(tb.check, '$.ls')) AS item
  JOIN target_items ti
    ON JSON_VALUE(item, '$.p') = ti.target_plu_id
   AND JSON_VALUE(item, '$.n') = ti.target_item_name
  WHERE SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64) > 0
  GROUP BY
    tb.check_hash,
    tb.account_number_id,
    tb.storeid,
    tb.business_date
),

chicken_salad_customers AS (
  SELECT DISTINCT
    account_number_id
  FROM chicken_salad_orders
)
,

customer_transaction_history AS (
  SELECT
    tb.account_number_id,
    tb.check_hash,
    CASE
      WHEN cso.check_hash IS NOT NULL THEN 1
      ELSE 0
    END AS has_chicken_salad_order
  FROM transaction_base tb
  JOIN chicken_salad_customers csc
    ON tb.account_number_id = csc.account_number_id
  LEFT JOIN chicken_salad_orders cso
    ON tb.check_hash = cso.check_hash
),

customer_summary AS (
  SELECT
    account_number_id,

    COUNT(DISTINCT check_hash) AS total_order_count,

    COUNT(DISTINCT CASE
      WHEN has_chicken_salad_order = 1 THEN check_hash
    END) AS chicken_salad_order_count,

    SAFE_DIVIDE(
      COUNT(DISTINCT CASE WHEN has_chicken_salad_order = 1 THEN check_hash END),
      COUNT(DISTINCT check_hash)
    ) AS chicken_salad_order_percent

  FROM customer_transaction_history
  GROUP BY account_number_id
  HAVING COUNT(DISTINCT check_hash) >= 5
)
/*
====================================================================================================================================================
Validate the query to see if if correctly produce the customer list who used to order at least one chick salad and visits the store at least 5 times
====================================================================================================================================================

    select * from customer_summary

====================================================================================================================================================
Sanity checck each chicken salad customer of the list
====================================================================================================================================================

    SELECT a.timestamp, siteIdFrontend, a.terminalId, m.storeId, sg.storeGroupId, a.accountNumberId,  JSON_VALUE(li_json, '$.p') AS plu,
        JSON_VALUE(li_json, '$.n') AS item_name,
        SAFE_CAST(JSON_VALUE(li_json, '$.q') AS INT64) AS quantity,
        SAFE_CAST(JSON_VALUE(li_json, '$.pr') AS INT64) AS price_cents from `backfill_dataset.AuthorizationsClientLine` a
        JOIN `backfill_dataset.StoresToMerchantIdsAuthorization` m on a.siteIdFrontend = m.merchantId
        AND a.terminalId = m.terminalId
        JOIN `backfill_dataset.StoresToStoreGroups` sg
        on m.storeId = sg.storeId
        CROSS JOIN UNNEST(JSON_QUERY_ARRAY(a.check, '$.ls')) AS li_json   
        where 
        sg.storeGroupId = 'GoldenChick' AND
        accountNumberId = 'b&#F8!loKx' and JSON_VALUE(li_json, '$.n') like '%Chk%'
    AND DATE (DATETIME_SUB(DATETIME(a.timestamp, 'America/Chicago'), INTERVAL 6 HOUR)) BETWEEN '2025-01-01' AND '2026-04-15'

*/
,

customer_bucket AS (
  SELECT
    account_number_id,
    total_order_count,
    chicken_salad_order_count,
    chicken_salad_order_percent,

    CASE
      WHEN chicken_salad_order_percent >= 0.90 THEN '90% - <=100%'
      WHEN chicken_salad_order_percent >= 0.80 THEN '80% - <90%'
      WHEN chicken_salad_order_percent >= 0.70 THEN '70% - <80%'
      WHEN chicken_salad_order_percent >= 0.60 THEN '60% - <70%'
      WHEN chicken_salad_order_percent >= 0.50 THEN '50% - <60%'
      WHEN chicken_salad_order_percent >= 0.40 THEN '40% - <50%'
      WHEN chicken_salad_order_percent >= 0.30 THEN '30% - <40%'
      WHEN chicken_salad_order_percent >= 0.20 THEN '20% - <30%'
      WHEN chicken_salad_order_percent >= 0.10 THEN '10% - <20%'
      ELSE '0% - <10%'
    END AS chicken_salad_percent_bucket,

    CASE
      WHEN chicken_salad_order_percent >= 0.90 THEN 10
      WHEN chicken_salad_order_percent >= 0.80 THEN 9
      WHEN chicken_salad_order_percent >= 0.70 THEN 8
      WHEN chicken_salad_order_percent >= 0.60 THEN 7
      WHEN chicken_salad_order_percent >= 0.50 THEN 6
      WHEN chicken_salad_order_percent >= 0.40 THEN 5
      WHEN chicken_salad_order_percent >= 0.30 THEN 4
      WHEN chicken_salad_order_percent >= 0.20 THEN 3
      WHEN chicken_salad_order_percent >= 0.10 THEN 2
      ELSE 1
    END AS bucket_sort

  FROM customer_summary
)

SELECT
  'BRAND_ALL_STORES' AS store_group,
  chicken_salad_percent_bucket,
  bucket_sort,

  COUNT(DISTINCT account_number_id) AS customer_count,
  SUM(total_order_count) AS total_order_count,
  SUM(chicken_salad_order_count) AS chicken_salad_order_count,

  SAFE_DIVIDE(
    COUNT(DISTINCT account_number_id),
    SUM(COUNT(DISTINCT account_number_id)) OVER ()
  ) AS customer_percent_of_total,

  SAFE_DIVIDE(
    SUM(chicken_salad_order_count),
    SUM(total_order_count)
  ) AS bucket_chicken_salad_order_percent

FROM customer_bucket
GROUP BY
  chicken_salad_percent_bucket,
  bucket_sort
ORDER BY
  bucket_sort;