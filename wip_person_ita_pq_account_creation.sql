CREATE OR REPLACE TABLE EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP AS 
WITH C1 AS (
SELECT 
    appl_key
    , cust_type 
FROM EDS.BDM.APP_LOAN_PRODUCTION
WHERE 
    YEAR(tran_date) IN (2024,2025,2026)
QUALIFY ROW_NUMBER() OVER(PARTITION BY appl_key ORDER BY appl_entry_dt DESC) =1 
), traffic AS (
    SELECT 
      v.appl_key
      , v.person AS person
      , c1.cust_type 
      , MIN(v.interaction_date) AS visit_Date 
  FROM  BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 v
  LEFT JOIN c1 
  ON v.appl_key = c1.appl_key 
  WHERE 
       YEAR(v.interaction_date) IN (2024, 2025, 2026) 
  GROUP BY 1,2,3
) 

SELECT * 
FROM traffic
WHERE cust_type is not null 
QUALIFY ROW_NUMBER() OVER(PARTITION BY person ORDER BY visit_date DESC) = 1 


SELECT 
    person, COUNT(DISTINCT cust_type)
FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
GROUP BY 1 
ORDER BY 2 DESC 

---------------------------------------------------------------------------------
CREATE OR REPLACE TABLE
    EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_TYPE AS
WITH returning_population AS (
    -- Your September population who visited before September.
    SELECT DISTINCT
        person,
        return_bucket
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_BASE1
    WHERE return_bucket NOT ILIKE '%no%repeat%identified%'
),


first_interaction AS (
    -- Find the earliest recorded visit for these visitors.
    SELECT
        v.person,
        v.interaction_date AS first_interaction_time,
        v.funnel AS first_visit_funnel
    FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 v 
    WHERE v.visitor_flag = 1
         AND v.interaction_date >= '2025-09-01'::DATE
         AND v.interaction_date <  '2026-10-01'::DATE
      AND EXISTS (
          SELECT 1
          FROM returning_population r
          WHERE r.person = v.person
      )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY v.person
        ORDER BY
            v.interaction_date ASC,
            v.visit_id ASC NULLS LAST,
            v.funnel ASC NULLS LAST
    ) = 1
),

classified_population AS (
    SELECT
        r.person,
        r.return_bucket,
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

    FROM returning_population r
    LEFT JOIN first_interaction f
        ON r.person = f.person
)

SELECT * FROM classified_population


/************************************ITA + Cust Code ************************************************/

CREATE OR REPLACE TABLE EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_ITA AS
WITH ita_visitors AS (
    SELECT DISTINCT person
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_TYPE
    WHERE first_visit_group = 'ITA'
),

-- Pull all source records for the ITA audience.
ita_source_data AS (
    SELECT
        v2.person,
        v2.visit_id,
        v2.interaction_date AS interaction_time,
        v2.funnel,
        v2.gen_url,
        v2.soft_submit_flag,
        v2.soft_approval_flag,
        v2.hard_submit_flag
    FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS v2
    INNER JOIN ita_visitors AS i
        ON v2.person = i.person
    WHERE (v2.interaction_date >= '2025-09-01'::DATE
         AND v2.interaction_date < '2026-10-01'::DATE)
         and v2.visitor_flag = 1 
), 

-- Identify the first visit using the same ordering as before.
first_visit AS (
    SELECT
        person,
        visit_id AS first_visit_id,
        interaction_time AS first_interaction_time,
        COALESCE(NULLIF(TRIM(funnel), ''), 'Unknown')
            AS first_visit_funnel
    FROM ita_source_data
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY person
        ORDER BY
            interaction_time ASC,
            visit_id ASC NULLS LAST,
            NULLIF(TRIM(funnel), '') ASC NULLS LAST
    ) = 1
),

-- Check all records within that first visit.
first_visit_activity AS (
    SELECT
        f.person,
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

        COUNT(d.person) AS matched_first_visit_rows

    FROM first_visit AS f
    LEFT JOIN ita_source_data AS d
        ON f.person = d.person
       AND f.first_visit_id = d.visit_id

    GROUP BY
        f.person,
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
    -- Script #1 already selects one cust_type per person.
    SELECT
        person,
        cust_type
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
)


SELECT
    c.*,
    cust_type

FROM categorized_visitors AS c
LEFT JOIN customer_type_summary AS t
    ON c.person = t.person;

    
----------------------- Separate data pull on ITA audience ------------------- 


SELECT
    first_visit_category,
    cust_type,
    COUNT(DISTINCT person) AS visitor_count

FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_ITA
GROUP BY
    first_visit_category,
    cust_type

ORDER BY
    first_visit_category,
    cust_type;


/************** Return bucket check by ITA & FA ***************************/ 

SELECT
    return_bucket,
    first_visit_group,
    COUNT(DISTINCT person) AS returning_visitors
FROM classified_population
GROUP BY
    return_bucket,
    first_visit_group
ORDER BY
    return_bucket,
    first_visit_group;


SELECT *
FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2
WHERE person = '740072757'


/************************************ PQ + Cust Code ************************************************/

CREATE OR REPLACE TABLE
    EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_PQ AS

WITH pq_visitors AS (
    SELECT DISTINCT person
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_TYPE
    WHERE first_visit_group = 'PQ'
),

pq_source_data AS (
    SELECT
        v2.person,
        v2.visit_id,
        v2.interaction_date AS interaction_time,
        v2.funnel,
        v2.hard_submit_flag
    FROM BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS v2
    INNER JOIN pq_visitors AS p
        ON v2.person = p.person
    WHERE v2.interaction_date >= '2025-09-01'::DATE
      AND v2.interaction_date <  '2026-10-01'::DATE
      AND v2.visitor_flag = 1
),

-- Use the same first-record selection as your ITA script.
first_visit AS (
    SELECT
        person,
        visit_id AS first_visit_id,
        interaction_time AS first_interaction_time,
        COALESCE(NULLIF(TRIM(funnel), ''), 'Unknown')
            AS first_visit_funnel
    FROM pq_source_data
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY person
        ORDER BY
            interaction_time ASC,
            visit_id ASC NULLS LAST,
            NULLIF(TRIM(funnel), '') ASC NULLS LAST
    ) = 1
),

first_visit_activity AS (
    SELECT
        p.person,
        f.first_visit_id,
        f.first_interaction_time,
        f.first_visit_funnel,

        COUNT(d.person) AS matched_first_visit_rows,

        MAX(IFF(d.hard_submit_flag = 1, 1, 0))
            AS hard_submitted

    FROM pq_visitors AS p
    LEFT JOIN first_visit AS f
        ON p.person = f.person
    LEFT JOIN pq_source_data AS d
        ON p.person = d.person
       AND f.first_visit_id = d.visit_id

    GROUP BY
        p.person,
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
        person,
        cust_type
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
)

SELECT
    c.*,
    COALESCE(t.cust_type, 'Unknown') AS cust_type,
    IFF(t.person IS NOT NULL, 1, 0) AS cust_type_matched

FROM categorized_visitors AS c
LEFT JOIN customer_type_summary AS t
    ON c.person = t.person;



    
SELECT
    first_visit_category,
    cust_type,
    COUNT(DISTINCT person) AS visitor_count

FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_pQ
GROUP BY
    first_visit_category,
    cust_type

ORDER BY
    first_visit_category,
    cust_type;
