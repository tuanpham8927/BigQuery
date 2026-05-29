/*
====================================================================================
PURPOSE:
Create Raw YoY Sale table per group name by using intermidate table StoreGroupYoYChange with dynamic comparison group 

OUTPUT:
- One row per day of week and customer type: 1 group name x 1 date x 1 store count x 1 customer type x 1 day part x 1 current sale x 1 prior sale
====================================================================================
*/

Create OR replace table `migration2220.RawYoYTransactions` as
WITH params AS (
  SELECT
    DATE '2026-01-01' AS start_date,
    DATE '2026-04-25' AS end_date,
    ['GoldenChick','GCDMAAustin','GCDMADallasFortWorth','GCDMAHouston','GCDMAOklahomaCity','GCDMASanAntonio'] AS target_store_group_id
),

base AS (
  SELECT
    s.storeGroupId as group_name,
    storeCount,
    DATE(s.date) AS business_date, 
    FORMAT_DATE('%A', DATE(s.date)) AS weekday_name,

    SAFE_CAST(JSON_VALUE_ARRAY(change, '$.t')[OFFSET(0)] AS INT64) AS customer_type_tag,
    SAFE_CAST(JSON_VALUE_ARRAY(change, '$.t')[OFFSET(2)] AS INT64) AS daypart_tag,


    SAFE_CAST(JSON_VALUE(change, '$.c.s.d') AS NUMERIC) / 100 AS current_sale,
    SAFE_CAST(JSON_VALUE(change, '$.p.s.d') AS NUMERIC) / 100 AS prior_sale

  FROM `backfill_dataset.StoreGroupsYoYChanges` s
  CROSS JOIN params p
  CROSS JOIN UNNEST(s.changes) AS change

  WHERE s.storeGroupId IN UNNEST(p.target_store_group_id)
    AND DATE(s.date) BETWEEN p.start_date AND p.end_date
)

SELECT
  group_name,
  storeCount as store_count,
  business_date,
  weekday_name,

  CASE customer_type_tag
    WHEN 50 THEN 'New'
    WHEN 51 THEN 'Returning'
  END AS customer_type,

  CASE daypart_tag
    WHEN 70 THEN 'Breakfast'
    WHEN 71 THEN 'Brunch'
    WHEN 72 THEN 'BreakfastBrunch'
    WHEN 73 THEN 'Lunch'
    WHEN 74 THEN 'Midday'
    WHEN 75 THEN 'Dinner'
    WHEN 76 THEN 'LateNight'
  END AS daypart,

  ROUND(SUM(current_sale), 2) AS current_sale,
  ROUND(SUM(prior_sale), 2) AS prior_sale

FROM base

WHERE customer_type_tag IN (50, 51)
  AND daypart_tag IN (70, 71, 72, 73, 74, 75, 76)

GROUP BY
  business_date,
  weekday_name,
  customer_type,
  daypart,
  storecount,
  group_name

ORDER BY
  business_date,
  customer_type,
  daypart;

/*
====================================================================================
PURPOSE:
Create Year to date calulation per weekday and customer type by using dynamic comparison group 

OUTPUT:
- One row per day of week and customer type: 1 group name x 1 median stores x YoY changes x sale contribution x impacts
- Total rows: 7 days of week x 2 customer type 
====================================================================================
*/

WITH base AS (
  SELECT
    group_name,
    APPROX_QUANTILES(store_count, 2)[OFFSET(1)] as median_stores,
    STRING_AGG (CAST(store_count AS STRING)) as store_numbers,
    customer_type,
    weekday_name,
    SUM(current_sale) AS current_sales,
    SUM(prior_sale) AS prior_sales
  FROM `migration2220.RawYoYTransactions`
  Where (business_date not between '2026-01-24' and '2026-01-27') -- Exlude storm days
  and group_name = 'GCDMAAustin' 
  GROUP BY customer_type, weekday_name 
  ,group_name
),

calc AS (
  SELECT
    group_name,
    median_stores,
    store_numbers,
    customer_type,
    weekday_name,
    current_sales,
    prior_sales,
    SAFE_DIVIDE(current_sales - prior_sales, prior_sales) AS yoy_change,
    SAFE_DIVIDE(
      current_sales,
      SUM(current_sales) OVER ()
    ) AS sale_contribution
  FROM base
)

SELECT
  group_name,
  median_stores,
  customer_type,
  store_numbers,
  weekday_name,
  ROUND(current_sales, 2) AS current_sales,
  ROUND(prior_sales, 2) AS prior_sales,
  ROUND(yoy_change, 4) AS yoy_change,
  ROUND(sale_contribution, 4) AS sale_contribution,
  ROUND(yoy_change * sale_contribution, 4) AS impact
FROM calc
ORDER BY
  customer_type,
  CASE weekday_name
    WHEN 'Monday' THEN 1
    WHEN 'Tuesday' THEN 2
    WHEN 'Wednesday' THEN 3
    WHEN 'Thursday' THEN 4
    WHEN 'Friday' THEN 5
    WHEN 'Saturday' THEN 6
    WHEN 'Sunday' THEN 7
  END;

/*
====================================================================================
PURPOSE:
Create Year to date calulation per daypart and customer type by using dynamic comparison group 

OUTPUT:
- One row per day of week and customer type: 1 group name x 1 median stores x YoY changes x sale contribution x impacts
- Total rows: 5 day parts x 2 customer type 
====================================================================================
*/

WITH base AS (
  SELECT
    group_name,
    APPROX_QUANTILES(store_count, 2)[OFFSET(1)] as median_stores,
    STRING_AGG (CAST(store_count AS STRING)) as store_numbers,
    customer_type,daypart,
    SUM(current_sale) AS current_sales,
    SUM(prior_sale) AS prior_sales
  FROM `migration2220.RawYoYTransactions`
  Where (business_date not between '2026-01-24' and '2026-01-27') -- Exlude storm days
  and group_name = 'GCDMAAustin' 
  GROUP BY customer_type, daypart
  ,group_name
),

calc AS (
  SELECT
    group_name,
    median_stores,
    store_numbers,
    customer_type,
    daypart,
    current_sales,
    prior_sales,

    SAFE_DIVIDE(current_sales - prior_sales, prior_sales) AS yoy_change,

    SAFE_DIVIDE(
      current_sales,
      SUM(current_sales) OVER ()
    ) AS sale_contribution
  FROM base
)

SELECT
  group_name,
  median_stores,
  customer_type,
  store_numbers,
  daypart,
  ROUND(current_sales, 2) AS current_sales,
  ROUND(prior_sales, 2) AS prior_sales,
  ROUND(yoy_change, 4) AS yoy_change,
  ROUND(sale_contribution, 4) AS sale_contribution,
  ROUND(yoy_change * sale_contribution, 4) AS impact
FROM calc
ORDER BY
  customer_type,
  CASE daypart
    WHEN 'Breakfast' THEN 1
    WHEN 'Lunch' THEN 2
    WHEN 'Midday' THEN 3
    WHEN 'Dinner' THEN 4
    WHEN 'LateNight' THEN 5
  END;
