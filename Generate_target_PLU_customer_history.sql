/*
Purpose:
  Create a customer transaction-history table for customers who purchased
  one or more target 8-piece Dark Meat PLUs at the 6 test stores.

Business Objective:
  Track the full check-level history of target-product buyers to understand:
    1. Which customers purchased the target PLUs.
    2. What other items those customers purchased.
    3. Whether each historical check contained a target product.
    4. The full basket/check composition for each customer transaction.

Output Table:
  migration2220.Target_PLU_customer_history

Output Grain:
  1 row = 1 customer x store x transaction/check

Business Rules:
  - Analysis period: 2026-01-01 through 2026-06-07.
  - Business day starts at 6:00 AM Central Time.
  - Only the 6 test stores are included.
  - Only valid authorization/payment transaction types are included:
      Pre Auth Request, Pre Auth Complete, Purchase.
  - A customer is included if they purchased at least one target PLU
    at the same store during the analysis period.
  - All transactions for those customers at the same store are returned,
    not only target-product transactions.
*/

CREATE OR REPLACE TABLE `migration2220.Target_PLU_customer_history` AS

WITH params AS (
  -- Define the analysis date range using business_date.
  SELECT
    DATE '2026-01-01' AS start_business_date,
    DATE '2026-06-07' AS analysis_cutoff_business_date
),

target_items AS (
  -- Define target 8-piece Dark Meat PLUs included in the study.
  SELECT '3534' AS target_plu_id, '8 DK Frd' AS target_item_name UNION ALL
  SELECT '3535', '8 DK H&H' UNION ALL
  SELECT '4032', '8 DK ML Frd' UNION ALL
  SELECT '4033', '8 DK ML H&H' UNION ALL
  SELECT '83015', '8 DK ML Rst' UNION ALL
  SELECT '3533', '8 DK Rst'
),

store_windows AS (
  -- Define the 6 test stores and their menu launch dates.
  -- Launch date is retained for context and future filtering if needed.
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
  -- Pull transaction-level records for the 6 test stores.
  SELECT
    -- Create a synthetic check hash to identify a unique transaction/check.
    -- This is needed because the raw authorization data may not have one
    -- reliable check-level primary key.
    TO_HEX(SHA256(CONCAT(
      COALESCE(CAST(a.accountNumberId AS STRING), 'NULL'), '|',
      TO_JSON_STRING(a.check), '|',
      COALESCE(CAST(a.amount AS STRING), 'NULL'), '|',
      COALESCE(CAST(a.siteIdFrontend AS STRING), 'NULL'), '|',
      COALESCE(CAST(a.terminalId AS STRING), 'NULL'), '|',
      COALESCE(FORMAT_TIMESTAMP('%F %T%E6S', a.timestamp, 'UTC'), 'NULL')
    ))) AS check_hash,

    -- Customer and store identifiers.
    a.accountNumberId AS account_number_id,
    m.storeId AS store_id,
    sw.store_name,
    sw.launch_date,

    -- Raw POS check JSON. Line items are stored under $.ls.
    a.check,

    -- Original UTC timestamp from the authorization source.
    a.timestamp,

    -- Local Central Time timestamp for easier business review.
    DATETIME(a.timestamp, 'America/Chicago') AS local_timestamp,

    -- Convert isnewatStore boolean into readable customer type.
    CASE
      WHEN a.isnewatStore = TRUE THEN 'New'
      WHEN a.isnewatStore = FALSE THEN 'Returning'
      ELSE 'Unknown'
    END AS customer_type,

    -- Convert transaction amount from cents to dollars.
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

  -- Map authorization merchant/terminal identifiers to store_id.
  JOIN `backfill_dataset.StoresToMerchantIdsAuthorization` m
    ON a.siteIdFrontend = m.merchantId
   AND a.terminalId = m.terminalId

  -- Restrict the analysis to the 6 test stores only.
  JOIN store_windows sw
    ON m.storeId = sw.storeId

  CROSS JOIN params p

  WHERE DATE(
      DATETIME_SUB(
        DATETIME(a.timestamp, 'America/Chicago'),
        INTERVAL 6 HOUR
      )
    ) BETWEEN p.start_business_date
        AND p.analysis_cutoff_business_date

    -- Keep valid authorization/payment transaction types.
    AND a.type IN (
      'Pre Auth Request',
      'Pre Auth Complete',
      'Purchase'
    )

    -- Keep only records with check JSON and account id needed for this analysis.
    AND a.check IS NOT NULL
    AND a.accountNumberId IS NOT NULL
),

target_transactions AS (
  -- Identify transactions/checks that contain at least one target PLU.
  SELECT
    tb.check_hash,
    tb.account_number_id,
    tb.store_id,
    tb.business_date,

    -- Build readable target-item details found in the check.
    -- Format:
    -- item name | PLU id | item price in dollars | quantity
    STRING_AGG(
      FORMAT(
        '%s | %s | %.2f | %g',
        JSON_VALUE(item, '$.n'),
        JSON_VALUE(item, '$.p'),
        SAFE_CAST(JSON_VALUE(item, '$.pr') AS FLOAT64) / 100,
        SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64)
      ),
      ', '
    ) AS item_details

  FROM base_transactions tb

  -- Expand POS check line-item JSON array into one row per item.
  CROSS JOIN UNNEST(JSON_QUERY_ARRAY(tb.check, '$.ls')) AS item

  -- Keep only exact target PLU and target item-name matches.
  JOIN target_items ti
    ON JSON_VALUE(item, '$.p') = ti.target_plu_id
   AND JSON_VALUE(item, '$.n') = ti.target_item_name

  -- Exclude voided/zero-quantity line items.
  WHERE SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64) > 0

  GROUP BY
    tb.check_hash,
    tb.account_number_id,
    tb.store_id,
    tb.business_date
),

target_customers AS (
  -- Build the customer universe:
  -- customers who purchased at least one target PLU at a given store.
  --
  -- Output grain:
  -- 1 row = account_number_id x store_id
  SELECT DISTINCT
    account_number_id,
    store_id
  FROM target_transactions
),

customer_inventory_history AS (
  -- Return the complete transaction history for target-product buyers.
  -- This includes both:
  --   1. Checks that contain target products.
  --   2. Checks that do not contain target products.
  SELECT
    bt.store_name,
    bt.account_number_id AS accountNumberId,
    bt.customer_type,
    bt.check_hash,
    bt.timestamp,
    bt.local_timestamp,
    bt.sale_in_dollar AS amount,

    -- TRUE if this transaction/check contains at least one target PLU.
    -- FALSE if it is another transaction from a target-product buyer.
    CASE
      WHEN tt.check_hash IS NOT NULL THEN TRUE
      ELSE FALSE
    END AS check_contains_target_products_flag,

    -- Target-product details only.
    -- NULL when the check does not contain a target PLU.
    tt.item_details AS target_item_details,

    -- Full item-level detail for the entire check.
    -- Format:
    -- item name | PLU id | q=quantity | pr=price in source value
    (
      SELECT STRING_AGG(
        FORMAT(
          '%s | %s | q=%g | pr=%g',
          JSON_VALUE(item, '$.n'),
          JSON_VALUE(item, '$.p'),
          SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64),
          SAFE_CAST(JSON_VALUE(item, '$.pr') AS FLOAT64)
        ),
        '\n'
      )
      FROM UNNEST(JSON_QUERY_ARRAY(bt.check, '$.ls')) AS item
      WHERE SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64) > 0
    ) AS check_details,

    -- Basket composition using item names only.
    -- DISTINCT removes duplicate item names within the same check.
    -- ORDER BY makes the composition stable and easier to compare.
    (
      SELECT STRING_AGG(
        DISTINCT JSON_VALUE(item, '$.n'),
        ', '
        ORDER BY JSON_VALUE(item, '$.n')
      )
      FROM UNNEST(JSON_QUERY_ARRAY(bt.check, '$.ls')) AS item
      WHERE SAFE_CAST(JSON_VALUE(item, '$.q') AS FLOAT64) > 0
    ) AS check_composition

  FROM base_transactions bt

  -- Keep only customers who ever bought target PLUs at the same store.
  JOIN target_customers tc
    ON bt.account_number_id = tc.account_number_id
   AND bt.store_id = tc.store_id

  -- Left join so non-target transactions are still retained.
  -- If tt.check_hash is NULL, the transaction did not contain a target PLU.
  LEFT JOIN target_transactions tt
    ON bt.check_hash = tt.check_hash
)

SELECT
  -- Final reporting-friendly column names.
  store_name AS `Store Name`,
  accountNumberId,
  customer_type AS `isNewAtStore`,
  check_hash AS `Check Number`,
  timestamp AS `Timestamp`,
  local_timestamp AS `Local Timestamp`,
  amount AS `Amount`,
  check_contains_target_products_flag AS `Check Contains Target Products Flag`,
  check_composition AS `Check Composition`,
  check_details AS `Check Details`

FROM customer_inventory_history

ORDER BY
  -- Sort output for spreadsheet review:
  -- store -> customer -> transaction time.
  store_name,
  accountNumberId,
  timestamp;