/*
========================================================
Raw data with full daypart and local business date information and some essential fields, composite field in table AuthorizationsClientLine
Output:
-- One row per raw transaction from AuthorizationsClientLine
-- Filter Golden Chick Stores
-- Essential AuthorizationsClientLine fields
-- Full daypart and business date information, day part may be null due to Store Daypart Configuration misconfiguration.
-- Create a new Transaction_composite_key from primary keys siteIdFrontend,timestamp,accountNumberId,type,amount in table AuthorizationsClientLine
-- Create a new Check_hash from siteIdFrontend,timestamp,accountNumberId,check,amount in table table AuthorizationsClientLine. The new Check_hash may be duplication due to multiple (two) transaction types 'Pre Auth Request', 'Pre Auth Complete' in the same check number.   
========================================================
*/
CREATE OR REPLACE TABLE `migration2220.NormalizedTransactions_StoreTimeZone`
AS

/* ---------------------------------------------
   Daypart definition from StoreGroups
---------------------------------------------- */
WITH
  store_dayparts AS (
    SELECT
      g.storeId,
      g.name AS store_name,
      g.timeZone,
      JSON_VALUE(dp, '$.n') AS raw_daypart_name,
      SAFE_CAST(JSON_VALUE(dp, '$.do') AS INT64) AS daypart_order,
      SAFE_CAST(JSON_VALUE(dp, '$.st.h') AS INT64) AS start_hour,
      SAFE_CAST(JSON_VALUE(dp, '$.st.m') AS INT64) AS start_minute,
      SAFE_CAST(JSON_VALUE(dp, '$.d.hs') AS INT64) AS duration_hours,
      SAFE_CAST(JSON_VALUE(dp, '$.d.ms') AS INT64) AS duration_minutes,
      SAFE_CAST(JSON_VALUE(dp, '$.st.h') AS INT64) * 60
        + SAFE_CAST(JSON_VALUE(dp, '$.st.m') AS INT64) AS start_minute_of_day,
      SAFE_CAST(JSON_VALUE(dp, '$.d.hs') AS INT64) * 60
        + SAFE_CAST(JSON_VALUE(dp, '$.d.ms') AS INT64) AS duration_minute_total
    FROM `project-3d127dc4-8358-46e9-b7e.backfill_dataset.Stores` g
    CROSS JOIN UNNEST(g.dayParts) AS dp
    WHERE
      JSON_VALUE(dp, '$.n') IS NOT NULL
      AND JSON_VALUE(dp, '$.n') != 'All Day'
  ),

  /* ---------------------------------------------

     Normalize daypart labels

  ---------------------------------------------- */
  store_dayparts_normalized AS (
    SELECT
      storeId,
      store_name,
      timeZone,
      daypart_order,
      start_hour,
      start_minute,
      duration_hours,
      duration_minutes,
      start_minute_of_day,
      duration_minute_total,
      CASE
        WHEN LOWER(raw_daypart_name) IN ('breakfast') THEN 'Breakfast'
        WHEN LOWER(raw_daypart_name) IN ('lunch') THEN 'Lunch'
        WHEN LOWER(raw_daypart_name) IN ('midday', 'mid-day', 'mid day')
          THEN 'Midday'
        WHEN LOWER(raw_daypart_name) IN ('dinner') THEN 'Dinner'
        WHEN
          LOWER(raw_daypart_name)
          IN ('late night', 'latenight', 'late-night')
          THEN 'Late Night'
        ELSE raw_daypart_name
        END AS daypart_name
    FROM store_dayparts
  ),

  /* ---------------------------------------------

     Base transaction rows

  ---------------------------------------------- */
  base_tx AS (
    SELECT
      TO_HEX(
        SHA256(
          CONCAT(
            COALESCE(CAST(accountNumberId AS STRING), 'NULL'),
            COALESCE(TO_JSON_STRING(type), 'NULL'),
            COALESCE(CAST(amount AS STRING), 'NULL'),
            COALESCE(CAST(siteIdFrontEnd AS STRING), 'NULL'),
            COALESCE(FORMAT_TIMESTAMP('%F %T%E6S', timestamp, 'UTC'), 'NULL'))))
        AS transaction_composite_key,
      m.storeId,
      s.name AS store_name,
      c.accountNumberId,
      c.terminalId,
      c.authCode,
      c.siteIdFrontend,
      TO_HEX(
        SHA256(
          CONCAT(
            COALESCE(CAST(accountNumberId AS STRING), 'NULL'),
            COALESCE(TO_JSON_STRING(check), 'NULL'),
            COALESCE(CAST(amount AS STRING), 'NULL'),
            COALESCE(CAST(siteIdFrontEnd AS STRING), 'NULL'),
            COALESCE(FORMAT_TIMESTAMP('%F %T%E6S', timestamp, 'UTC'), 'NULL'))))
        AS check_hash,
      c.check,
      c.type AS transaction_type,
      m.reportGroup,
      c.timestamp,
      ROUND(c.amount / 100, 2) AS sale_in_dollar,
      c.isNewAtStore,
      s.timeZone,
      DATETIME(c.timestamp, s.timeZone) AS local_time,
      DATE(c.timestamp, s.timeZone) AS local_date,
      FORMAT_DATE('%A', DATE(c.timestamp, s.timeZone)) AS local_weekday,
      EXTRACT(HOUR FROM DATETIME(c.timestamp, s.timeZone)) * 60
        + EXTRACT(MINUTE FROM DATETIME(c.timestamp, s.timeZone))
        AS tx_minute_of_day
    FROM
      `project-3d127dc4-8358-46e9-b7e.backfill_dataset.AuthorizationsClientLine`
        c
    JOIN
      `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoresToMerchantIdsAuthorization`
        m
      ON
        c.siteIdFrontend = m.merchantId
        AND c.terminalId = m.terminalId
    JOIN `backfill_dataset.Stores` s
      ON
        m.storeId = s.storeId
  )
-- Select count(*) from   base_tx
,

/* ---------------------------------------------

         Assign txn to correct daypart and business_day

      ---------------------------------------------- */
final_tx AS (
  SELECT
    b.transaction_composite_key,
    b.storeId,
    b.store_name,
    b.accountNumberId,
    b.authCode,
    b.terminalId,
    b.siteIdFrontend,
    CASE
      WHEN b.isNewAtStore = TRUE THEN 'New'
      WHEN b.isNewAtStore = FALSE THEN 'Return'
      ELSE 'Unknown'
      END AS customer_type,
    b.transaction_type,
    b.reportGroup AS channel_group,
    b.timestamp,
    b.timeZone,
    b.local_time,
    b.check_hash,
    b.check,
    b.sale_in_dollar,
    d.duration_minute_total,
    d.daypart_name,
    d.daypart_order,
    CASE
      WHEN
        d.start_minute_of_day + d.duration_minute_total > 1440
        AND b.tx_minute_of_day < MOD(
          d.start_minute_of_day + d.duration_minute_total, 1440)
        THEN DATE_SUB(b.local_date, INTERVAL 1 DAY)
      ELSE b.local_date
      END AS business_date,
    FORMAT_DATE(
      '%A',
      CASE
        WHEN
          d.start_minute_of_day + d.duration_minute_total > 1440
          AND b.tx_minute_of_day < MOD(
            d.start_minute_of_day + d.duration_minute_total, 1440)
          THEN DATE_SUB(b.local_date, INTERVAL 1 DAY)
        ELSE b.local_date
        END) AS business_weekday
  FROM base_tx b
  LEFT JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON b.storeId = sg.storeId AND sg.storeGroupId LIKE 'GCDMA%'
  LEFT JOIN store_dayparts_normalized d
    ON
      b.storeId = d.storeId
      AND (
        (
          d.start_minute_of_day + d.duration_minute_total <= 1440
          AND b.tx_minute_of_day >= d.start_minute_of_day
          AND b.tx_minute_of_day
            < d.start_minute_of_day + d.duration_minute_total)
        OR (
          d.start_minute_of_day + d.duration_minute_total > 1440
          AND (
            b.tx_minute_of_day >= d.start_minute_of_day
            OR b.tx_minute_of_day < MOD(
              d.start_minute_of_day + d.duration_minute_total,
              1440))))
)

/* ---------------------------------------------

           --Raw transactions with business day and datepart information .

        ---------------------------------------------- */
SELECT
  *,
  FORMAT_DATE('%m_%Y', business_date) AS business_month_year,
  FORMAT_DATE('%Y', business_date) AS business_year
FROM final_tx
