
CREATE OR REPLACE TABLE EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_V1 AS 
WITH date_range_data AS (
    SELECT
        v2.visitor_id,
        v2.interaction_date AS interaction_time,
        TO_DATE(v2.interaction_date) AS visit_date,
        v2.visit_id,
        v2.funnel
    FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS v2
    WHERE v2.interaction_date >= '2025-08-01'
      AND v2.interaction_date <  '2026-09-01'
      AND v2.visitor_id IS NOT NULL
),

visitor_visits AS (
    SELECT
        visitor_id,
        visit_date,
        COUNT(DISTINCT visit_id) AS visit_id_count
    FROM date_range_data
    GROUP BY visitor_id, visit_date
),

visitor_first_date AS (
    SELECT
        visitor_id,
        MIN(visit_date) AS first_visit_date
    FROM visitor_visits
    GROUP BY visitor_id
),

visitor_same_day AS (
    SELECT
        visitor_id,
        MAX(visit_id_count) AS max_visit_ids_in_day
    FROM visitor_visits
    GROUP BY visitor_id
),

visitor_return_gap AS (
    SELECT
        vv.visitor_id,
        MIN(
            DATEDIFF(DAY, vfd.first_visit_date, vv.visit_date)
        ) AS min_return_gap
    FROM visitor_visits AS vv
    INNER JOIN visitor_first_date AS vfd
        ON vv.visitor_id = vfd.visitor_id
    WHERE vv.visit_date > vfd.first_visit_date
    GROUP BY vv.visitor_id
),

visitor_category AS (
    SELECT
        vsd.visitor_id,
        vsd.max_visit_ids_in_day,
        vrg.min_return_gap,
        CASE
            WHEN vsd.max_visit_ids_in_day > 1
                THEN '1. Same day return'
            WHEN vrg.min_return_gap BETWEEN 1 AND 30
                THEN '2. Returned within 1-30 days'
            WHEN vrg.min_return_gap BETWEEN 31 AND 60
                THEN '3. Returned within 31-60 days'
            WHEN vrg.min_return_gap BETWEEN 61 AND 90
                THEN '4. Returned within 61-90 days'
            WHEN vrg.min_return_gap BETWEEN 91 AND 365
                THEN '5. Returned within 91-365 days'
            WHEN vrg.min_return_gap > 365
                THEN '6. Returned after more than 1 year'
            ELSE '7. No repeat visits'
        END AS return_bucket
    FROM visitor_same_day AS vsd
    LEFT JOIN visitor_return_gap AS vrg
        ON vsd.visitor_id = vrg.visitor_id
),

-- Select one earliest record per visitor.
first_visit_funnel AS (
    SELECT
        visitor_id,
        visit_id AS first_visit_id,
        interaction_time AS first_interaction_time,
        COALESCE(NULLIF(TRIM(funnel), ''), 'Unknown')
            AS first_visit_funnel
    FROM date_range_data
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY visitor_id
        ORDER BY
            interaction_time ASC,
            visit_id ASC NULLS LAST,
            NULLIF(TRIM(funnel), '') ASC NULLS LAST
    ) = 1
), 

repeat_visitor_detail AS (
    SELECT
        vc.visitor_id,
        vc.return_bucket,
        f.first_visit_id,
        f.first_interaction_time,
        f.first_visit_funnel,

        CASE
            WHEN f.first_visit_funnel IN (
                'PQ_OMF',
                'PQ_Email',
                'FA_OMF',
                'PQ_OAM',
                'Others'
            ) THEN 'ITA'

            WHEN f.first_visit_funnel IN (
                'Affiliat_API',
                'CK_EA',
                'Affiliate_Remarketing_Multiple',
                'FA_Aff_Link',
                'Direct_Mail',
                'FA_Email',
                'Affiliate_Remarketing_Single',
                'EA_Remarketing',
                'CK_LB',
                'Exp_Act_WH',
                'ND_FA_Email',
                'FA_OAM'
            ) THEN 'PQ'

            ELSE 'Unmapped'
        END AS first_visit_group

    FROM visitor_category AS vc
    INNER JOIN first_visit_funnel AS f
        ON vc.visitor_id = f.visitor_id
    WHERE vc.return_bucket <> '7. No repeat visits'
)

SELECT * 
FROM repeat_visitor_detail

----------------------------------------------------------------------------------
SELECT * FROM  EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_V1  LIMIT 100 

------------------------------------------------------------ Build ITA Audience Logic -----------------------------------------------

CREATE OR REPLACE TABLE EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_ITA AS 
WITH ita_visitors AS (
    SELECT DISTINCT visitor_id
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_V1
    WHERE first_visit_group = 'ITA'
),

-- Pull all source records for the ITA audience.
ita_source_data AS (
    SELECT
        v2.visitor_id,
        v2.visit_id,
        v2.interaction_date AS interaction_time,
        v2.funnel,
        v2.gen_url,
        v2.soft_submit_flag,
        v2.soft_approval_flag,
        v2.hard_submit_flag
    FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS v2
    INNER JOIN ita_visitors AS i
        ON v2.visitor_id = i.visitor_id
    WHERE v2.interaction_date >= '2025-08-01'
      AND v2.interaction_date <  '2026-09-01'
),

-- Identify the first visit using the same ordering as before.
first_visit AS (
    SELECT
        visitor_id,
        visit_id AS first_visit_id,
        interaction_time AS first_interaction_time,
        COALESCE(NULLIF(TRIM(funnel), ''), 'Unknown')
            AS first_visit_funnel
    FROM ita_source_data
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY visitor_id
        ORDER BY
            interaction_time ASC,
            visit_id ASC NULLS LAST,
            NULLIF(TRIM(funnel), '') ASC NULLS LAST
    ) = 1
),

-- Check all records within that first visit.
first_visit_activity AS (
    SELECT
        f.visitor_id,
        f.first_visit_id,
        f.first_interaction_time,
        f.first_visit_funnel,

        MAX(
            IFF(
                   d.gen_url ILIKE '%check%offers%'
                OR d.gen_url ILIKE '%prequalification%start%'
                OR d.gen_url ILIKE '%application%'
                OR d.gen_url ILIKE '/prequalification'
                OR d.gen_url ILIKE '%account%reapply%'
                OR d.gen_url ILIKE '%prequalification%started%'
                OR d.gen_url ILIKE '%account%get%started%'
                OR d.gen_url ILIKE '%apply%',
                1,
                0
            )
        ) AS app_started,

        MAX(IFF(d.soft_submit_flag = 1, 1, 0))
            AS soft_submitted,

        MAX(IFF(d.soft_approval_flag = 1, 1, 0))
            AS soft_approved,

        MAX(IFF(d.hard_submit_flag = 1, 1, 0))
            AS hard_submitted,

        COUNT(d.visitor_id) AS matched_first_visit_rows

    FROM first_visit AS f
    LEFT JOIN ita_source_data AS d
        ON f.visitor_id = d.visitor_id
       AND f.first_visit_id = d.visit_id

    GROUP BY
        f.visitor_id,
        f.first_visit_id,
        f.first_interaction_time,
        f.first_visit_funnel
),

categorized_visitors AS (
    SELECT
        *,
        CASE
            WHEN hard_submitted = 1
                THEN '4. Hard submitted'

            WHEN app_started = 1
             AND (
                    (
                        first_visit_funnel = 'FA_OMF'
                        AND hard_submitted = 0
                    )
                    OR
                    (
                        first_visit_funnel <> 'FA_OMF'
                        AND soft_submitted = 0
                    )
                 )
                THEN '1. App started, no submit'

            WHEN first_visit_funnel <> 'FA_OMF'
             AND app_started = 1
             AND soft_submitted = 1
             AND soft_approved = 1
             AND hard_submitted = 0
                THEN '2. Soft approved, no hard submit'

            WHEN first_visit_funnel <> 'FA_OMF'
             AND app_started = 1
             AND soft_submitted = 1
             AND soft_approved = 0
                THEN '3. Soft submitted, not soft approved'

            ELSE '5. Other'
        END AS first_visit_category

    FROM first_visit_activity
), 

customer_type_summary AS (
    SELECT
        visitor_id,

        COUNT(DISTINCT NULLIF(TRIM(TO_VARCHAR(customer_id)), ''))
            AS customer_id_count,

        COUNT(DISTINCT NULLIF(UPPER(TRIM(cust_type)), ''))
            AS cust_type_count,

        CASE
            WHEN COUNT(
                DISTINCT NULLIF(TRIM(TO_VARCHAR(customer_id)), '')
            ) > 1
                THEN 'Multiple customer IDs'

            WHEN COUNT(
                DISTINCT NULLIF(UPPER(TRIM(cust_type)), '')
            ) > 1
                THEN 'Multiple customer types'

            ELSE COALESCE(
                MAX(NULLIF(UPPER(TRIM(cust_type)), '')),
                'Unknown'
            )
        END AS cust_type

    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
    GROUP BY visitor_id
)

SELECT
    c.*,
    COALESCE(t.cust_type, 'Unknown') AS cust_type,
    COALESCE(t.customer_id_count, 0) AS customer_id_count,
    COALESCE(t.cust_type_count, 0) AS cust_type_count

FROM categorized_visitors AS c
LEFT JOIN customer_type_summary AS t
    ON c.visitor_id = t.visitor_id;

-----------------------------------------------------------------------------------------------

SELECT
    first_visit_category,
    cust_type,
    COUNT(DISTINCT visitor_id) AS visitor_count

FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_ITA

WHERE first_visit_category IN (
    '1. App started, no submit',
    '2. Soft approved, no hard submit'
)

GROUP BY
    first_visit_category,
    cust_type

ORDER BY
    first_visit_category,
    cust_type;




------------------------------------- Final Script  ----------------------------


SELECT
    first_visit_category,
    COUNT(DISTINCT visitor_id) AS visitor_count
FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_ITA
GROUP BY first_visit_category
ORDER BY first_visit_category;


------------------------------------- Troubleshoot ITA audience ----------------------------

SELECT
    first_visit_funnel,

    CASE
        WHEN matched_first_visit_rows = 0
            THEN '1. No source rows matched first visit'

        WHEN app_started = 0
         AND soft_submitted = 1
            THEN '2. Soft submitted, no app-start URL match'

        WHEN app_started = 0
         AND soft_submitted = 0
            THEN '3. No app-start URL match, no submit'

        ELSE '4. Unexpected flag combination'
    END AS other_reason,
COUNT(DISTINCT visitor_id) AS visitor_count

FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_ITA
WHERE first_visit_category = '5. Other'

GROUP BY first_visit_funnel, other_reason
ORDER BY visitor_count DESC;


------------------------------------------------------------ Build PQ Audience Logic -----------------------------------------------
CREATE OR REPLACE TABLE EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_PQ AS 
WITH pq_visitors AS (
    SELECT DISTINCT visitor_id
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_V1
    WHERE first_visit_group = 'PQ'
),

pq_source_data AS (
    SELECT
        v2.visitor_id,
        v2.visit_id,
        v2.interaction_date AS interaction_time,
        v2.funnel,
        v2.hard_submit_flag
    FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS v2
    INNER JOIN pq_visitors AS p
        ON v2.visitor_id = p.visitor_id
    WHERE v2.interaction_date >= '2025-08-01'
      AND v2.interaction_date <  '2026-09-01'
),

-- Use the same first-record selection as your ITA script.
first_visit AS (
    SELECT
        visitor_id,
        visit_id AS first_visit_id,
        interaction_time AS first_interaction_time,
        COALESCE(NULLIF(TRIM(funnel), ''), 'Unknown')
            AS first_visit_funnel
    FROM pq_source_data
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY visitor_id
        ORDER BY
            interaction_time ASC,
            visit_id ASC NULLS LAST,
            NULLIF(TRIM(funnel), '') ASC NULLS LAST
    ) = 1
),

first_visit_activity AS (
    SELECT
        p.visitor_id,
        f.first_visit_id,
        f.first_interaction_time,
        f.first_visit_funnel,

        COUNT(d.visitor_id) AS matched_first_visit_rows,

        MAX(IFF(d.hard_submit_flag = 1, 1, 0))
            AS hard_submitted

    FROM pq_visitors AS p
    LEFT JOIN first_visit AS f
        ON p.visitor_id = f.visitor_id
    LEFT JOIN pq_source_data AS d
        ON p.visitor_id = d.visitor_id
       AND f.first_visit_id = d.visit_id

    GROUP BY
        p.visitor_id,
        f.first_visit_id,
        f.first_interaction_time,
        f.first_visit_funnel
),

categorized_visitors AS (
    SELECT
        *,
        CASE
            WHEN first_interaction_time IS NULL
              OR first_visit_id IS NULL
              OR matched_first_visit_rows = 0
                THEN '3. Other'

            WHEN hard_submitted = 1
                THEN '2. Hard submitted'

            ELSE '1. Prequalified, no hard submit'
        END AS first_visit_category,

        CASE
            WHEN first_interaction_time IS NULL
                THEN 'No source records in date window'
            WHEN first_visit_id IS NULL
                THEN 'Missing first visit ID'
            WHEN matched_first_visit_rows = 0
                THEN 'No matching first-visit records'
            ELSE NULL
        END AS other_reason

    FROM first_visit_activity
), 
customer_type_summary AS (
    SELECT
        visitor_id,

        COUNT(DISTINCT NULLIF(TRIM(TO_VARCHAR(customer_id)), ''))
            AS customer_id_count,

        COUNT(DISTINCT NULLIF(UPPER(TRIM(cust_type)), ''))
            AS cust_type_count,

        CASE
            WHEN COUNT(
                DISTINCT NULLIF(TRIM(TO_VARCHAR(customer_id)), '')
            ) > 1
                THEN 'Multiple customer IDs'

            WHEN COUNT(
                DISTINCT NULLIF(UPPER(TRIM(cust_type)), '')
            ) > 1
                THEN 'Multiple customer types'

            ELSE COALESCE(
                MAX(NULLIF(UPPER(TRIM(cust_type)), '')),
                'Unknown'
            )
        END AS cust_type

    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
    GROUP BY visitor_id
)

SELECT
    c.*,
    COALESCE(t.cust_type, 'Unknown') AS cust_type,
    COALESCE(t.customer_id_count, 0) AS customer_id_count,
    COALESCE(t.cust_type_count, 0) AS cust_type_count

FROM categorized_visitors AS c
LEFT JOIN customer_type_summary AS t
    ON c.visitor_id = t.visitor_id;

-------------------------------------------------------------------------------


SELECT
    first_visit_category,
    cust_type,
    COUNT(DISTINCT visitor_id) AS visitor_count

FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REPEAT_PQ

WHERE first_visit_category IN (
    '1. Prequalified, no hard submit'
)

GROUP BY
    first_visit_category,
    cust_type

ORDER BY
    first_visit_category,
    cust_type;

----------------------------------------------------------------------------------------

    
SELECT
    first_visit_category,
    COUNT(DISTINCT visitor_id) AS visitor_count
FROM categorized_visitors
GROUP BY first_visit_category
ORDER BY first_visit_category;


-----------------------------------------------------------------------------------------------
