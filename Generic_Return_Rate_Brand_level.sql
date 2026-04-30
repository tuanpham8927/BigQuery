-- version: v1.1
-- change: add Saturday filter logic
-- author: Tuan Pham
-- date: 2026-04-30
WITH params AS (
  SELECT
    DATE '2025-01-01' AS period_1_start,
    DATE '2025-03-31' AS period_1_end,
    DATE '2026-01-01' AS period_2_start,
    DATE '2026-03-31' AS period_2_end,

    1 AS start_visit_min,
    9 AS start_visit_max,
    10 AS max_visit_number,

    'GoldenChick' AS target_store_group,
    'all' AS target_store_id
),

/* ================= BASE TRANSACTIONS ================= */
final_tx AS (
  SELECT
    b.*
  FROM `migration2220.BasedTransactions` b
  JOIN `backfill_dataset.StoresToStoreGroups` sg
    ON b.storeId = sg.storeId
  CROSS JOIN params p
  WHERE sg.storeGroupId = p.target_store_group
    AND (p.target_store_id = 'all' OR b.storeId = p.target_store_id)
    AND b.accountNumberId IS NOT NULL
),

/* ================= LIFETIME VISIT RANK PER STORE ================= */
/*
  Important:
    This ranks visits by accountNumberId + storeId.

  Meaning:
    The same customer can have:
      - visit #1 at Store A
      - visit #1 at Store B

    This is store-level lifecycle, not brand-level lifecycle.
*/
ranked_visits AS (
  SELECT
    accountNumberId,
    storeId,
    timestamp,
    local_time,
    business_day,
    local_weekday,

    ROW_NUMBER() OVER (
      PARTITION BY accountNumberId, storeId
      ORDER BY local_time
    ) AS visit_number

  FROM final_tx
),

/* ================= SATURDAY-FIRST CUSTOMER-STORE COHORT ================= */
/*
  Keep only accountNumberId + storeId combinations where
  the first lifetime visit at that specific store was Saturday.
*/
first_visit_saturday_customers AS (
  SELECT
    accountNumberId,
    storeId
  FROM ranked_visits
  WHERE visit_number = 1
    AND local_weekday = 'Saturday'
),

/* ================= GENERIC VISIT PAIRS ================= */
visit_pairs AS (
  SELECT
    start_visit_number,
    start_visit_number + 1 AS next_visit_number
  FROM params,
  UNNEST(
    GENERATE_ARRAY(
      start_visit_min,
      LEAST(start_visit_max, max_visit_number - 1)
    )
  ) AS start_visit_number
),

/* ================= BUILD CUSTOMER-STORE VISIT PAIRS ================= */
customer_pair_visits AS (
  SELECT
    r.storeId,
    vp.start_visit_number,
    vp.next_visit_number,
    r.accountNumberId,

    MAX(
      CASE
        WHEN r.visit_number = vp.start_visit_number
        THEN r.business_day
      END
    ) AS start_visit_business_day,

    MAX(
      CASE
        WHEN r.visit_number = vp.next_visit_number
        THEN r.business_day
      END
    ) AS next_visit_business_day

  FROM ranked_visits r

  JOIN first_visit_saturday_customers f
    ON r.accountNumberId = f.accountNumberId
   AND r.storeId = f.storeId

  JOIN visit_pairs vp
    ON r.visit_number IN (
      vp.start_visit_number,
      vp.next_visit_number
    )

  GROUP BY
    r.storeId,
    vp.start_visit_number,
    vp.next_visit_number,
    r.accountNumberId
),

/* ================= FINAL RETURN RATE FOR WHOLE BRAND ================= */
final AS (
  SELECT
    CONCAT(
      CAST(cpv.start_visit_number AS STRING),
      '->',
      CAST(cpv.next_visit_number AS STRING)
    ) AS Visit_Pair,

    cpv.start_visit_number,

    ROUND(
      SAFE_DIVIDE(
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
          AND cpv.next_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
        ),
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
        )
      ),
      4
    ) AS Return_Rate_Q1_2025,

    ROUND(
      SAFE_DIVIDE(
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
          AND cpv.next_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
        ),
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
        )
      ),
      4
    ) AS Return_Rate_Q1_2026,

    ROUND(
      SAFE_DIVIDE(
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
          AND cpv.next_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
        ),
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
        )
      )
      -
      SAFE_DIVIDE(
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
          AND cpv.next_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
        ),
        COUNTIF(
          cpv.start_visit_business_day BETWEEN p.period_1_start AND p.period_1_end
        )
      ),
      4
    ) AS Return_Rate_Change,

    COUNTIF(
      cpv.start_visit_business_day BETWEEN p.period_2_start AND p.period_2_end
    ) AS `2026 Base Customer`

  FROM customer_pair_visits cpv
  CROSS JOIN params p
  GROUP BY
    Visit_Pair,
    cpv.start_visit_number
)

SELECT
  Visit_Pair,
  Return_Rate_Q1_2025,
  Return_Rate_Q1_2026,
  Return_Rate_Change,
  `2026 Base Customer`
FROM final
ORDER BY start_visit_number;