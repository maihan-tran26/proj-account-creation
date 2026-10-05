SELECT 
    cust_type
    , COUNT(DISTINCT appl_key) AS app_count 
    , COUNT(DISTINCT cust_id) AS cust_count 
FROM EDS.BDM.APP_LOAN_PRODUCTION
WHERE 
    YEAR(tran_date) IN (2024,2025,2026)
GROUP BY 1 
ORDER BY 1 


CREATE OR REPLACE TABLE EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP AS 
WITH C1 AS (
SELECT 
    cust_id 
    , cust_type 
FROM EDS.BDM.APP_LOAN_PRODUCTION
WHERE 
    YEAR(tran_date) IN (2024,2025,2026)
QUALIFY ROW_NUMBER() OVER(PARTITION BY cust_id ORDER BY appl_entry_dt DESC) =1 
), traffic AS (
    SELECT 
      v.visitor_id
      , v.customer_id
      , cust_id
      , cust_type 
      , MIN(v.created_at) AS visit_Date 
  FROM OM_FRONTEND.LANDABLE_TRAFFIC_VISITS v
  LEFT JOIN c1 
  ON TRY_TO_NUMBER(TO_VARCHAR(v.customer_id)) = TRY_TO_NUMBER(TO_VARCHAR(c1.cust_id))
  WHERE 
       YEAR(v.record_created_timestamp) IN (2024, 2025, 2026) 
  GROUP BY 1,2,3,4
) 

SELECT * 
FROM traffic
WHERE cust_type is not null 
QUALIFY ROW_NUMBER() OVER(PARTITION BY visitor_id ORDER BY visit_date DESC) = 1 
-------------------------------------------------------

SELECT visitor_id, COUNT(DISTINCT cust_type)
FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
GROUP BY 1 
ORDER BY 2 DESC 


SELECT *  FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
WHERE visitor_id = '283228201'

-----------------------------------------------------

SELECT cust_id, COUNT(DISTINCT cust_type)
FROM C1 
GROUP BY 1 
ORDER BY 2 DESC 


SELECT * 
FROM EDS.BDM.APP_LOAN_PRODUCTION
WHERE cust_id = '192257243'


SELECT
    visitor_id,
    visit_id,
    customer_id,
    created_at AS visit_time,
    record_created_timestamp
FROM OM_FRONTEND.LANDABLE_TRAFFIC_VISITS
WHERE visitor_id = 283228201
  AND YEAR(record_created_timestamp) IN (2024, 2025, 2026)
ORDER BY created_at, visit_id;


SELECT * 
FROM EDS.SB_ANALYTICS_PII.DACR_FUNNEL_COOKIE_SUMM_FULL
LIMIT 100 
