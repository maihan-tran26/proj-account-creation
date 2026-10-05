WITH C1 AS (
SELECT 
    CASE WHEN gen_url2 ILIKE '%offers%no%ding%lookup%30393%' THEN 'no-ding-email' 
         WHEN gen_url2 ILIKE '%accounts%reapply%' THEN 'account-reapply'
         when gen_url2 ILIKE '%accounts%check%offers%' THEN 'account-check-offers'
         when gen_url2 ILIKE '%accounts%get%started%' THEN 'account-get-started'
         when gen_url2 ILIKE '%application%' THEN 'application'
         when gen_url2 ILIKE '%/affiliate/%' THEN 'affiliate-link'
         when gen_url2 ILIKE '%/apply%' THEN 'apply-page'
         WHEN gen_url2 ILIKE '%accounts%offers' THEN 'account-offers'
         WHEN gen_url2 ILIKE '%/ppc/%' then 'ppc-page'
         WHEN gen_url2 ILIKE '%check%offers%###' THEN 'wizard-check-offer-page'
    ELSE gen_url2 END AS url_maping 
    , COUNT(DISTINCT visitor_id)
FROM
   BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2
GROUP BY 1 
ORDER BY 2 DESC 
) 

SELECT *
FROM C1 
ORDER BY 2 DESC 


SELECT 
    DISTINCT cookie_id 
    , interaction_date
FROM
   BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 v2
WHERE gen_url2 ILIKE '%accounts%offers' and CAST(v2.interaction_date AS DATE) >= DATEADD(DAY, -30, CURRENT_DATE)

/////////////////////////////////////////////////////////

WITH date_range_data AS (
  SELECT
    v2.visitor_id,
    TO_DATE(v2.interaction_date) AS visit_date,
    v2.visit_id
  FROM
    BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS v2
  WHERE
    v2.interaction_date >= '2025-08-01'
    AND v2.interaction_date < '2026-09-01'
    AND NOT v2.visitor_id IS NULL
),
visitor_visits AS (
  SELECT
    visitor_id,
    visit_date,
    COUNT(DISTINCT visit_id) AS visit_id_count
  FROM
    date_range_data
  GROUP BY
    visitor_id,
    visit_date
),
visitor_first_date AS (
  SELECT
    visitor_id,
    MIN(visit_date) AS first_visit_date
  FROM
    visitor_visits
  GROUP BY
    visitor_id
),
visitor_same_day AS (
  SELECT
    vv.visitor_id,
    MAX(vv.visit_id_count) AS max_visit_ids_in_day
  FROM
    visitor_visits AS vv
  GROUP BY
    vv.visitor_id
),
visitor_return_gap AS (
  SELECT
    vv.visitor_id,
    MIN(
      DATEDIFF(DAY, vfd.first_visit_date, vv.visit_date)
    ) AS min_return_gap
  FROM
    visitor_visits AS vv
    INNER JOIN visitor_first_date AS vfd ON vv.visitor_id = vfd.visitor_id
  WHERE
    vv.visit_date > vfd.first_visit_date
  GROUP BY
    vv.visitor_id
),
visitor_category AS (
  SELECT
    vsd.visitor_id,
    vsd.max_visit_ids_in_day,
    vrg.min_return_gap,
    CASE
      WHEN vsd.max_visit_ids_in_day > 1 THEN '1. Same day return'
      WHEN NOT vrg.min_return_gap IS NULL
      AND vrg.min_return_gap BETWEEN 1
      AND 30 THEN '2. Returned within 1-30 days'
      WHEN NOT vrg.min_return_gap IS NULL
      AND vrg.min_return_gap BETWEEN 31
      AND 60 THEN '3. Returned within 31-60 days'
      WHEN NOT vrg.min_return_gap IS NULL
      AND vrg.min_return_gap BETWEEN 61
      AND 90 THEN '4. Returned within 61-90 days'
      WHEN NOT vrg.min_return_gap IS NULL
      AND vrg.min_return_gap BETWEEN 91
      AND 365 THEN '5. Returned within 91-365 days'
      WHEN NOT vrg.min_return_gap IS NULL
      AND vrg.min_return_gap > 365 THEN '6. Returned after more than 1 year'
      ELSE '7. No repeat visits'
    END AS return_bucket
  FROM
    visitor_same_day AS vsd
    LEFT JOIN visitor_return_gap AS vrg ON vsd.visitor_id = vrg.visitor_id
),
bucket_counts AS (
  SELECT
    return_bucket,
    COUNT(DISTINCT visitor_id) AS visitor_count
  FROM
    visitor_category
  GROUP BY
    return_bucket
)

SELECT * 
FROM visitor_category 
WHERE return_bucket NOT ILIKE '%no%repeat%visits%'

/**** final to pull return bucket ***/ 
SELECT
  return_bucket,
  TO_CHAR(visitor_count, '999,999,999') AS visitor_count
FROM
  bucket_counts
UNION ALL
SELECT
  'Total' AS return_bucket,
  TO_CHAR(SUM(visitor_count), '999,999,999') AS visitor_count
FROM
  bucket_counts
ORDER BY
  return_bucket
