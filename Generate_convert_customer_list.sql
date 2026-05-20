/* =========================================================
   PURPOSE
   -------
   Run all 3 debug/result outputs at one time:

   1) pre_launch_order_customer
      Customers who bought the pre-launch PLU before launch.

   2) pre_to_post_launch_population
      Those pre-launch customers who returned during post-launch.

   3) new_plu_order_customer
      Those returned customers who bought the new post-launch PLU.

   BigQuery Studio will show each final SELECT as a separate result set.
========================================================= */


-- =========================================================
-- 1) Parameters
-- =========================================================
WITH
params AS (
  SELECT
    DATE '2026-05-16' AS post_launch_end_date,
    ['2033', '2034', '2032'] AS new_plu_id,
    ['20','3012','3010','104','2010','2011','3011','24','2012','21'] AS old_plu_id,
    DATE '2026-01-01' AS pre_launch_begin_date,
),

  test_store_launch_dates AS (
    SELECT
      '2MWAXy3FzKTvmSgn' AS test_store_id,
      'Lancaster / W Pleasant Run Rd' AS test_store_name,
      DATE '2026-04-27' AS launch_date
    UNION ALL
    SELECT
      '8CCEYO2I92f92Qdc', 'Dallas / N Central Expy (Meadow)', DATE '2026-04-27'
    UNION ALL
    SELECT '8uhY7x53ECiEcan0', 'Melissa / Sam Rayburn Hwy', DATE '2026-04-27'
    UNION ALL
    SELECT 'XIyD5NWrRRBtbUKc', 'Marshall / E End Blvd S', DATE '2026-04-29'
    UNION ALL
    SELECT 'uUUnekPKWHSOi9PQ', 'Fort Worth / E Berry St', DATE '2026-04-28'
    UNION ALL
    SELECT 'b4gu065sNyiZggy7', 'Whitesboro / Highway 377 N', DATE '2026-05-08'
  ),
-- =========================================================
-- 2) Shared transaction base
--    This table is reused by all later steps.
-- =========================================================


transaction_base AS (
  SELECT
   s.test_store_id,
      s.test_store_name,
      s.launch_date,
    t.check_hash,
    t.accountNumberId,
    t.storeId,
    t.business_date,
    t.check
  FROM `migration2220.NormalizedTransactions_StoreTimeZone` t
  JOIN test_store_launch_dates s
      ON t.storeId = s.test_store_id
  JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON t.storeId = sg.storeId
   AND sg.storeGroupId = 'GoldenChick'
  CROSS JOIN params p
  WHERE
    t.transaction_type IN (
      'Pre Auth Request',
      'Pre Auth Complete',
      'Purchase'
    )
    AND t.check IS NOT NULL
    AND t.business_date BETWEEN p.pre_launch_begin_date
                            AND p.post_launch_end_date
),

-- =========================================================
-- 3) Customers who bought the old/pre-launch PLU
-- =========================================================
pre_launch_order AS (
  SELECT
    t.accountNumberId,
    t.check_hash,
    JSON_VALUE(line_item, '$.p') AS plu_id,
    JSON_VALUE(line_item, '$.n') AS item_name
  FROM transaction_base t
  CROSS JOIN UNNEST(JSON_QUERY_ARRAY(t.check, '$.ls')) AS line_item
  CROSS JOIN params p
  WHERE
    t.business_date BETWEEN p.pre_launch_begin_date
                        AND DATE_SUB(t.launch_date, INTERVAL 1 DAY)
    AND JSON_VALUE(line_item, '$.p') IN UNNEST(p.old_plu_id)
    -- AND t.storeId IN UNNEST(p.test_store_id)
    AND SAFE_CAST(JSON_VALUE(line_item, '$.pr') AS NUMERIC) != 0
),
pre_launch_order_customer AS (
  SELECT
    accountNumberId,
    COUNT(DISTINCT check_hash) AS visit_number
  FROM pre_launch_order
  GROUP BY accountNumberId
)

,


-- =========================================================
-- 4) Of those pre-launch customers,
--    find who returned during post-launch window.
-- =========================================================
pre_to_post_launch_population AS (
  SELECT
    t.accountNumberId,
    COUNT(DISTINCT t.check_hash) AS visit_number
  FROM transaction_base t
  JOIN pre_launch_order_customer pre
    ON t.accountNumberId = pre.accountNumberId
  CROSS JOIN params p
  WHERE
    t.business_date BETWEEN t.launch_date
                        AND p.post_launch_end_date
  GROUP BY t.accountNumberId
)
--SELECT * FROM pre_to_post_launch_population ORDER BY visit_number DESC;
,
-- =========================================================
-- 5) Of those returned customers,
--    find who bought the new/post-launch PLU.
-- =========================================================
pre_to_post_new_plu_order AS (
  SELECT
    pop.accountNumberId,t.check_hash,
    JSON_VALUE(line_item, '$.p') AS plu_id,
    JSON_VALUE(line_item, '$.n') AS item_name
  FROM transaction_base t
  JOIN pre_to_post_launch_population pop
    ON t.accountNumberId = pop.accountNumberId
  CROSS JOIN params p
  CROSS JOIN UNNEST(JSON_QUERY_ARRAY(t.check, '$.ls')) AS line_item
  WHERE
    t.business_date BETWEEN t.launch_date
                        AND p.post_launch_end_date
    AND t.check IS NOT NULL
    AND JSON_VALUE(line_item, '$.p') IN UNNEST (p.new_plu_id)
    AND SAFE_CAST(JSON_VALUE(line_item, '$.pr') AS NUMERIC) != 0
),
new_plu_order_customer AS (
  SELECT
    accountNumberId,
    COUNT(DISTINCT check_hash) AS visit_number
  FROM pre_to_post_new_plu_order
  GROUP BY accountNumberId
)


SELECT
  *
FROM new_plu_order_customer
ORDER BY visit_number DESC;

