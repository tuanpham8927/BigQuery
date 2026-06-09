/*
====================================================================================
PURPOSE:
Create Raw YoY Sale table per group name by using intermidate table StoreGroupYoYChange with dynamic comparison group

OUTPUT:
- One row per day of week and customer type: 1 group name x 1 date x 1 store count x 1 customer type x 1 day part x 1 current sale x 1 prior sale
====================================================================================
*/

CREATE OR REPLACE TABLE `migration2220.RawYoYTransactions`
AS
WITH
  params AS (
    SELECT
      DATE '2026-01-01' AS start_date,
      DATE '2026-06-07' AS end_date,
      [
        'GoldenChick', 'GCDMAAustin', 'GCDMADallasFortWorth', 'GCDMAHouston',
        'GCDMAOklahomaCity', 'GCDMASanAntonio'] AS target_store_group_id
  ),
  base AS (
    SELECT
      s.storeGroupId AS group_name,
      storeCount,
      DATE(s.date) AS business_date,
      FORMAT_DATE('%A', DATE(s.date)) AS weekday_name,
      SAFE_CAST(JSON_VALUE_ARRAY(change, '$.t')[OFFSET(0)] AS INT64)
        AS customer_type_tag,
      SAFE_CAST(JSON_VALUE_ARRAY(change, '$.t')[OFFSET(2)] AS INT64)
        AS daypart_tag,
      SAFE_CAST(JSON_VALUE(change, '$.c.s.d') AS NUMERIC) / 100 AS current_sale,
      SAFE_CAST(JSON_VALUE(change, '$.p.s.d') AS NUMERIC) / 100 AS prior_sale,
      SAFE_CAST(JSON_VALUE(change, '$.c.t.d') AS NUMERIC) AS current_transaction,
      SAFE_CAST(JSON_VALUE(change, '$.p.t.d') AS NUMERIC) AS prior_transaction
    FROM `backfill_dataset.StoreGroupsYoYChanges` s
    CROSS JOIN params p
    CROSS JOIN UNNEST(s.changes) AS change
    WHERE
      s.storeGroupId IN UNNEST(p.target_store_group_id)
      AND DATE(s.date) BETWEEN p.start_date AND p.end_date
  )
SELECT
  group_name,
  storeCount AS store_count,
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
  ROUND(SUM(prior_sale), 2) AS prior_sale,
  SUM(current_transaction) AS current_visit,
  SUM(prior_transaction) AS prior_visit
FROM base
WHERE
  customer_type_tag IN (50, 51)
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
===================================================================================
The purpose: Pivot visit_YoY result by weekly for 5 DMAs and Brand
====================================================================================
*/

WITH base AS (
  SELECT
    group_name,
    business_date,

    SUM(current_visit) AS current_visit,
    SUM(prior_visit) AS prior_visit

  FROM `migration2220.RawYoYTransactions`

  WHERE business_date NOT BETWEEN DATE '2026-01-24'
                              AND DATE '2026-01-27'
    --AND customer_type = 'Returning' -- 'New'

  GROUP BY
    group_name,
    business_date
),

yoy AS (
  SELECT
    group_name,
    business_date,

    current_visit,
    prior_visit,

    SAFE_DIVIDE(
      current_visit - prior_visit,
      prior_visit
    ) AS yoy_visit_change

  FROM base
)

SELECT
  business_date,

  -- Brand
  MAX(CASE WHEN group_name = 'GoldenChick' THEN prior_visit END) AS brand_prior_visit,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN current_visit END) AS brand_current_visit,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN yoy_visit_change END) AS brand_yoy_visit_change,

  -- Austin
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN prior_visit END) AS austin_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN current_visit END) AS austin_current_visit,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN yoy_visit_change END) AS austin_yoy_visit_change,

  -- Dallas / Fort Worth
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN prior_visit END) AS dfw_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN current_visit END) AS dfw_current_visit,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN yoy_visit_change END) AS dfw_yoy_visit_change,

  -- Houston
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN prior_visit END) AS houston_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN current_visit END) AS houston_current_visit,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN yoy_visit_change END) AS houston_yoy_visit_change,

  -- Oklahoma City
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN prior_visit END) AS okc_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN current_visit END) AS okc_current_visit,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN yoy_visit_change END) AS okc_yoy_visit_change,

  -- San Antonio
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN prior_visit END) AS san_antonio_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN current_visit END) AS san_antonio_current_visit,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN yoy_visit_change END) AS san_antonio_yoy_visit_change

FROM yoy

GROUP BY
  business_date

ORDER BY
  business_date;


/*
===================================================================================
The purpose: Pivot sale_YoY result by daily for 5 DMAs and Brand
====================================================================================

*/

WITH base AS (
  SELECT
    group_name,
    business_date,

    SUM(current_sale) AS current_sale,
    SUM(prior_sale) AS prior_sale

  FROM `migration2220.RawYoYTransactions`

  WHERE business_date NOT BETWEEN DATE '2026-01-24'
                              AND DATE '2026-01-27'
   -- AND customer_type = 'New'

  GROUP BY
    group_name,
    business_date
),

yoy AS (
  SELECT
    group_name,
    business_date,
    current_sale,
    prior_sale,

    SAFE_DIVIDE(
      current_sale - prior_sale,
      prior_sale
    ) AS yoy_sale_change

  FROM base
)

SELECT
  business_date,

  -- Brand
  MAX(CASE WHEN group_name = 'GoldenChick' THEN prior_sale END) AS brand_prior_sale,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN current_sale END) AS brand_current_sale,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN yoy_sale_change END) AS brand_yoy_sale_change,

  -- Austin
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN prior_sale END) AS austin_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN current_sale END) AS austin_current_sale,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN yoy_sale_change END) AS austin_yoy_sale_change,

  -- Dallas / Fort Worth
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN prior_sale END) AS dfw_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN current_sale END) AS dfw_current_sale,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN yoy_sale_change END) AS dfw_yoy_sale_change,

  -- Houston
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN prior_sale END) AS houston_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN current_sale END) AS houston_current_sale,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN yoy_sale_change END) AS houston_yoy_sale_change,

  -- Oklahoma City
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN prior_sale END) AS okc_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN current_sale END) AS okc_current_sale,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN yoy_sale_change END) AS okc_yoy_sale_change,

  -- San Antonio
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN prior_sale END) AS san_antonio_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN current_sale END) AS san_antonio_current_sale,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN yoy_sale_change END) AS san_antonio_yoy_sale_change

FROM yoy

GROUP BY
  business_date

ORDER BY
  business_date;


/*
===================================================================================
The purpose: Pivot sale_YoY result by weekly for 5 DMAs and Brand
====================================================================================
*/
WITH base AS (
  SELECT
    group_name,
    DATE_TRUNC(business_date, WEEK(MONDAY)) AS week_start_date,
    SUM(current_sale) AS current_sale,
    SUM(prior_sale) AS prior_sale

  FROM `migration2220.RawYoYTransactions`

  WHERE business_date NOT BETWEEN DATE '2026-01-24'
                              AND DATE '2026-01-27'
    AND customer_type = 'Returning'

  GROUP BY
    group_name,
    week_start_date
),

yoy AS (
  SELECT
    group_name,
    week_start_date,
    current_sale,
    prior_sale,

    SAFE_DIVIDE(
      current_sale - prior_sale,
      prior_sale
    ) AS yoy_sale_change

  FROM base
)

SELECT
  week_start_date,

  -- Brand
  MAX(CASE WHEN group_name = 'GoldenChick' THEN prior_sale END) AS brand_prior_sale,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN current_sale END) AS brand_current_sale,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN yoy_sale_change END) AS brand_yoy_sale_change,

  -- Austin
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN prior_sale END) AS austin_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN current_sale END) AS austin_current_sale,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN yoy_sale_change END) AS austin_yoy_sale_change,

  -- Dallas / Fort Worth
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN prior_sale END) AS dfw_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN current_sale END) AS dfw_current_sale,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN yoy_sale_change END) AS dfw_yoy_sale_change,

  -- Houston
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN prior_sale END) AS houston_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN current_sale END) AS houston_current_sale,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN yoy_sale_change END) AS houston_yoy_sale_change,

  -- Oklahoma City
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN prior_sale END) AS okc_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN current_sale END) AS okc_current_sale,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN yoy_sale_change END) AS okc_yoy_sale_change,

  -- San Antonio
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN prior_sale END) AS san_antonio_prior_sale,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN current_sale END) AS san_antonio_current_sale,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN yoy_sale_change END) AS san_antonio_yoy_sale_change

FROM yoy

GROUP BY
  week_start_date

ORDER BY
  week_start_date;


/*
===================================================================================
The purpose: Pivot visit_YoY result by weekly for 5 DMAs and Brand
====================================================================================
*/
WITH base AS (
  SELECT
    group_name,

    DATE_TRUNC(business_date, WEEK(MONDAY)) AS week_start_date,

    SUM(current_visit) AS current_visit,
    SUM(prior_visit) AS prior_visit

  FROM `migration2220.RawYoYTransactions`

  WHERE business_date NOT BETWEEN DATE '2026-01-24'
                              AND DATE '2026-01-27'
     --AND customer_type = 'Returning'
    AND customer_type = 'New'

  GROUP BY
    group_name,
    week_start_date
),

yoy AS (
  SELECT
    group_name,
    week_start_date,

    current_visit,
    prior_visit,

    SAFE_DIVIDE(
      current_visit - prior_visit,
      prior_visit
    ) AS yoy_visit_change

  FROM base
)

SELECT
  week_start_date,

  -- Brand
  MAX(CASE WHEN group_name = 'GoldenChick' THEN prior_visit END) AS brand_prior_visit,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN current_visit END) AS brand_current_visit,
  MAX(CASE WHEN group_name = 'GoldenChick' THEN yoy_visit_change END) AS brand_yoy_visit_change,

  -- Austin
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN prior_visit END) AS austin_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN current_visit END) AS austin_current_visit,
  MAX(CASE WHEN group_name = 'GCDMAAustin' THEN yoy_visit_change END) AS austin_yoy_visit_change,

  -- Dallas / Fort Worth
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN prior_visit END) AS dfw_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN current_visit END) AS dfw_current_visit,
  MAX(CASE WHEN group_name = 'GCDMADallasFortWorth' THEN yoy_visit_change END) AS dfw_yoy_visit_change,

  -- Houston
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN prior_visit END) AS houston_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN current_visit END) AS houston_current_visit,
  MAX(CASE WHEN group_name = 'GCDMAHouston' THEN yoy_visit_change END) AS houston_yoy_visit_change,

  -- Oklahoma City
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN prior_visit END) AS okc_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN current_visit END) AS okc_current_visit,
  MAX(CASE WHEN group_name = 'GCDMAOklahomaCity' THEN yoy_visit_change END) AS okc_yoy_visit_change,

  -- San Antonio
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN prior_visit END) AS san_antonio_prior_visit,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN current_visit END) AS san_antonio_current_visit,
  MAX(CASE WHEN group_name = 'GCDMASanAntonio' THEN yoy_visit_change END) AS san_antonio_yoy_visit_change

FROM yoy

GROUP BY
  week_start_date

ORDER BY
  week_start_date;
