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
CREATE TEMP TABLE params AS
SELECT
  DATE '2026-04-28' AS post_launch_begin_date,
  DATE '2026-05-10' AS post_launch_end_date,

  -- New menu / post-launch PLU
  '2033' AS post_launch_plu_id,

  -- Old menu / pre-launch PLU
  '2011' AS pre_launch_plu_id,

  -- Test store list
  ['2MWAXy3FzKTvmSgn'] AS test_store_id,

  DATE '2026-01-01' AS pre_launch_begin_date,
  DATE '2026-04-26' AS pre_launch_end_date;


-- =========================================================
-- 2) Shared transaction base
--    This table is reused by all later steps.
-- =========================================================
CREATE TEMP TABLE transaction_base AS
SELECT
  t.check_hash,
  t.accountNumberId,
  t.storeId,
  t.business_date,
  t.check
FROM `migration2220.NormalizedTransactions_StoreTimeZone` t
JOIN `backfill_dataset.StoresToStoreGroups` s
  ON t.storeId = s.storeId
 AND s.storeGroupId = 'GoldenChick'
CROSS JOIN params p
WHERE t.transaction_type IN (
    'Pre Auth Request',
    'Pre Auth Complete',
    'Purchase'
  )
  AND t.storeId IN UNNEST(p.test_store_id)

  -- Pull all transactions from pre-launch through post-launch.
  AND t.business_date BETWEEN p.pre_launch_begin_date
                          AND p.post_launch_end_date;


-- =========================================================
-- 3) Customers who bought the old/pre-launch PLU
-- =========================================================
CREATE TEMP TABLE pre_launch_order AS
SELECT
  t.accountNumberId,
  JSON_VALUE(line_item, '$.p') AS plu_id,
  JSON_VALUE(line_item, '$.n') AS item_name
FROM transaction_base t
CROSS JOIN UNNEST(JSON_QUERY_ARRAY(t.check, '$.ls')) AS line_item
CROSS JOIN params p
WHERE t.business_date BETWEEN p.pre_launch_begin_date
                          AND p.pre_launch_end_date
  AND JSON_VALUE(line_item, '$.p') = p.pre_launch_plu_id

  -- Exclude zero-price modifiers or free items.
  AND SAFE_CAST(JSON_VALUE(line_item, '$.pr') AS NUMERIC) != 0;


CREATE TEMP TABLE pre_launch_order_customer AS
SELECT
  accountNumberId,
  COUNT(plu_id) AS visit_number
FROM pre_launch_order
GROUP BY accountNumberId;


-- =========================================================
-- 4) Of those pre-launch customers,
--    find who returned during post-launch window.
-- =========================================================
CREATE TEMP TABLE pre_to_post_launch_population AS
SELECT
  t.accountNumberId,
  COUNT(DISTINCT t.check_hash) AS visit_number
FROM transaction_base t
JOIN pre_launch_order_customer pre
  ON t.accountNumberId = pre.accountNumberId
CROSS JOIN params p
WHERE t.business_date BETWEEN p.post_launch_begin_date
                          AND p.post_launch_end_date
GROUP BY t.accountNumberId;


-- =========================================================
-- 5) Of those returned customers,
--    find who bought the new/post-launch PLU.
-- =========================================================
CREATE TEMP TABLE pre_to_post_new_plu_order AS
SELECT
  pop.accountNumberId,
  JSON_VALUE(line_item, '$.p') AS plu_id,
  JSON_VALUE(line_item, '$.n') AS item_name
FROM transaction_base t
JOIN pre_to_post_launch_population pop
  ON t.accountNumberId = pop.accountNumberId
CROSS JOIN params p
CROSS JOIN UNNEST(JSON_QUERY_ARRAY(t.check, '$.ls')) AS line_item
WHERE t.business_date BETWEEN p.post_launch_begin_date
                          AND p.post_launch_end_date
  AND t.check IS NOT NULL
  AND JSON_VALUE(line_item, '$.p') = p.post_launch_plu_id

  -- Exclude zero-price modifiers or free items.
  AND SAFE_CAST(JSON_VALUE(line_item, '$.pr') AS NUMERIC) != 0;


CREATE TEMP TABLE new_plu_order_customer AS
SELECT
  accountNumberId,
  COUNT(plu_id) AS visit_number
FROM pre_to_post_new_plu_order
GROUP BY accountNumberId;


-- =========================================================
-- Final Output 1
-- Customers who bought old/pre-launch PLU
-- =========================================================
SELECT
  *
FROM pre_launch_order_customer
ORDER BY visit_number DESC;


-- =========================================================
-- Final Output 2
-- Pre-launch PLU customers who returned post-launch
-- =========================================================
SELECT
  *
FROM pre_to_post_launch_population
ORDER BY visit_number DESC;


-- =========================================================
-- Final Output 3
-- Returned customers who bought new/post-launch PLU
-- =========================================================
SELECT
  *
FROM new_plu_order_customer
ORDER BY visit_number DESC;