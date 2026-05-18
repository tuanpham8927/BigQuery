/* =====================================================================
   PURPOSE
   =====================================================================

   BUSINESS QUESTION
   -----------------
   "From what products do people come from to the new item?"

   This analysis identifies the historical menu combinations
   purchased BEFORE customers adopted a new item.

   Example:
   - Customer buys NEW ITEM PLU 2033 during launch period
   - We look back at all historical checks BEFORE launch
   - We build check compositions from those historical checks
   - We count the most common historical combinations

   Business value:
   - Identify migration source products
   - Understand customer behavior before adoption
   - Detect cannibalization patterns
   - Build pie chart of top historical menu compositions

   ---------------------------------------------------------------------
   FINAL OUTPUT
   ---------------------------------------------------------------------

   Top 10 historical check compositions
   + "Others"

   One row =
     1 pie chart slice

===================================================================== */

/* =====================================================================
   STEP 1 — PARAMETERS
   =====================================================================

   begin_date / end_date
     = launch analysis window

   new_plu_ids
     = new menu item

   test_store_id
     = participating test stores

   Lookback_begin_date / Lookback_end_date
     = historical customer behavior window BEFORE launch

===================================================================== */
CREATE TEMP TABLE params
AS
SELECT
  DATE '2026-04-28' AS begin_date,
  DATE '2026-05-10' AS end_date,
  '2033' AS new_plu_ids,
  ['2MWAXy3FzKTvmSgn'] AS test_store_id,
  DATE '2026-01-01' AS Lookback_begin_date,
  DATE '2026-04-26' AS Lookback_end_date;

/* =====================================================================
   STEP 2 — BASE TRANSACTION TABLE
   =====================================================================

   Pull all transactions needed for:
   - launch-period new item detection
   - historical lookback analysis

   Keep only:
   - valid purchase-related transaction types
   - target stores
   - checks with valid check JSON

   One row =
     1 raw transaction row

===================================================================== */
CREATE TEMP TABLE transaction_base
AS
SELECT
  t.check_hash,
  t.accountNumberId,
  t.storeId,
  t.store_name,
  t.sale_in_dollar,
  t.timestamp,
  t.business_date,
  t.channel_group,
  t.check,
  t.transaction_type,
  t.siteIdFrontend
FROM `migration2220.NormalizedTransactions_StoreTimeZone` t
CROSS JOIN params p
WHERE
  t.transaction_type IN (
    'Pre Auth Request',
    'Pre Auth Complete',
    'Purchase')
  AND t.storeId IN UNNEST(p.test_store_id)
  AND t.check IS NOT NULL
  AND t.business_date
    BETWEEN p.Lookback_begin_date
    AND p.end_date;

/* =====================================================================
   STEP 3 — FIND NEW ITEM PURCHASES
   =====================================================================

   Expand line items from check JSON array.

   One row =
     1 PLU line item inside a check

===================================================================== */
CREATE TEMP TABLE new_plu_orders
AS
SELECT
  t.accountNumberId,
  t.storeId,
  t.store_name,
  t.timestamp,
  t.business_date,
  t.channel_group,
  t.check,

  /* Extract PLU ID */
  JSON_VALUE(line_item, '$.p') AS plu_id,

  /* Item name */
  JSON_VALUE(line_item, '$.n') AS item_name,

  /* Item price */
  JSON_VALUE(line_item, '$.pr') AS price
FROM transaction_base t
CROSS JOIN params p

/* Expand line items from check.ls */
CROSS JOIN
  UNNEST(
    JSON_QUERY_ARRAY(t.check, '$.ls')) AS line_item
WHERE
  t.business_date
    BETWEEN p.begin_date
    AND p.end_date

  /* Keep only the new menu item */
  AND JSON_VALUE(line_item, '$.p') = p.new_plu_ids
  AND t.storeId IN UNNEST(p.test_store_id);

/* =====================================================================
   STEP 4 — UNIQUE CUSTOMERS WHO ORDERED NEW ITEM
   =====================================================================

   One row =
     1 customer who adopted the new item

===================================================================== */
CREATE TEMP TABLE new_plu_customer
AS
SELECT DISTINCT
  accountNumberId
FROM new_plu_orders;

/* =====================================================================
   STEP 5 — LOOKBACK CUSTOMERS
   =====================================================================

   Keep customers who:
   - purchased the new item
   - AND existed historically BEFORE launch

===================================================================== */
CREATE TEMP TABLE lookback_customers
AS
SELECT DISTINCT
  accountNumberId
FROM transaction_base
CROSS JOIN params p
WHERE
  business_date
    BETWEEN p.Lookback_begin_date
    AND p.Lookback_end_date
  AND accountNumberId IN (
    SELECT accountNumberId
    FROM new_plu_customer
  );

/* =====================================================================
   STEP 6 — HISTORICAL TRANSACTIONS
   =====================================================================

   Pull ALL historical transactions BEFORE launch
   for customers who later adopted the new item.

   One row =
     1 historical transaction/check

===================================================================== */
CREATE TEMP TABLE lookback_transactions
AS
SELECT
  *
FROM transaction_base
CROSS JOIN params p
WHERE
  business_date
    BETWEEN p.Lookback_begin_date
    AND p.Lookback_end_date
  AND accountNumberId IN (
    SELECT accountNumberId
    FROM lookback_customers
  );

/* =====================================================================
   STEP 7 — EXTRACT NON-ZERO PRICED PLUs
   =====================================================================

   Purpose:
   Build meaningful check compositions.

   Exclude:
   - free sauces
   - modifiers
   - zero-priced add-ons

   One row =
     1 paid PLU inside a historical check

===================================================================== */
CREATE TEMP TABLE check_non_zero_plu
AS
SELECT
  t.check_hash,
  t.check,

  /* PLU ID */
  JSON_VALUE(line_item, '$.p') AS plu_id,

  /* Item price */
  SAFE_CAST(
    JSON_VALUE(line_item, '$.pr') AS NUMERIC) AS item_price_cents
FROM lookback_transactions t

/* Expand check line items */
CROSS JOIN
  UNNEST(
    JSON_QUERY_ARRAY(t.check, '$.ls')) AS line_item
WHERE
  t.check IS NOT NULL
  AND JSON_VALUE(line_item, '$.p') IS NOT NULL

  /* Keep only non-zero priced items */
  AND SAFE_CAST(
    JSON_VALUE(line_item, '$.pr') AS NUMERIC)
    != 0;

/* =====================================================================
   STEP 8 — BUILD CHECK COMPOSITION ID
   =====================================================================

   Check composition logic:
   1. Keep unique PLUs
   2. Sort alphabetically
   3. Concatenate with '-'

   Example:
     2006-3001-65012

   One row =
     1 historical check

===================================================================== */
CREATE TEMP TABLE check_compositions
AS
SELECT
  ARRAY_TO_STRING(
    ARRAY_AGG(
      DISTINCT plu_id
      ORDER BY plu_id),
    '-') AS check_composition_id
FROM check_non_zero_plu
GROUP BY check_hash;

/* =====================================================================
   STEP 9 — COUNT CHECK COMPOSITIONS
   =====================================================================

   One row =
     1 unique check composition

===================================================================== */
CREATE TEMP TABLE check_composition_with_count
AS
SELECT
  check_composition_id,
  COUNT(*) AS check_count
FROM check_compositions
GROUP BY check_composition_id;

/* =====================================================================
   STEP 10 — RANK CHECK COMPOSITIONS
   =====================================================================

   Highest frequency compositions ranked first.

===================================================================== */
CREATE TEMP TABLE ranked_check_compositions
AS
SELECT
  check_composition_id,
  check_count,
  ROW_NUMBER()
    OVER (
      ORDER BY
        check_count DESC,
        check_composition_id
    ) AS composition_rank
FROM check_composition_with_count;

/* =====================================================================
   STEP 11 — TOP 10 + OTHERS
   =====================================================================

   Pie chart readability optimization.

   Keep:
     Top 10 compositions

   Collapse:
     Remaining compositions into "Others"

===================================================================== */
CREATE TEMP TABLE top_10_plus_others
AS
SELECT
  CASE
    WHEN composition_rank <= 10
      THEN check_composition_id
    ELSE 'Others'
    END AS pie_slice_name,
  SUM(check_count) AS check_count
FROM ranked_check_compositions
GROUP BY pie_slice_name;

/* =====================================================================
   OUTPUT 1: A list of accountNumberIds who purchased the new item in Post Launch period
   ===================================================================== */
SELECT * FROM new_plu_customer ORDER BY accountNumberId;

/* =====================================================================
   OUTPUT 2: A list of accountNumberIds who purchased the new item in Post Launch period AND
   historically ordered Golden menu BEFORE launch
   ===================================================================== */
SELECT * FROM lookback_customers ORDER BY accountNumberId;

/* =====================================================================
   OUTPUT 3: get all transactions during the lookback window for customers in output 2.
   ===================================================================== */
SELECT check_hash,accountNumberId,sale_in_dollar,	timestamp,check FROM lookback_transactions;

/* =====================================================================
   OUTPUT 4: create a list of all check compositions from OutPut 3
   ===================================================================== */
SELECT distinct check_composition_id FROM check_compositions;

/* =====================================================================
   OUTPUT 5: Count the number of checks for each check composition from Output 4
   ===================================================================== */
SELECT * FROM check_composition_with_count order by check_count desc;

/* =====================================================================
   OUTPUT 6: Get top 10 check composition slices and group the remaining slices into a slice called “Others”
   ===================================================================== */
SELECT pie_slice_name AS check_composition_id, check_count FROM top_10_plus_others
ORDER BY
  CASE
    WHEN check_composition_id = 'Others'
      THEN 2
    ELSE 1
    END,
  check_count DESC;
