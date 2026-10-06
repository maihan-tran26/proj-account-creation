CREATE OR REPLACE TABLE
    EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_ITA AS

WITH ita_visitors AS (
    SELECT DISTINCT person
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_TYPE
    WHERE first_visit_group = 'ITA'
),

-- Pull visitor records used to identify the first visit.
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
    WHERE v2.interaction_date >= '2025-09-01'::DATE
      AND v2.interaction_date <  '2026-10-01'::DATE
      AND v2.visitor_flag = 1
),

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

-- Check all source records on dates after the first visit date.
later_activity AS (
    SELECT
        f.person,

        MAX(IFF(d.soft_submit_flag = 1, 1, 0))
            AS later_soft_submitted,

        MAX(IFF(d.hard_submit_flag = 1, 1, 0))
            AS later_hard_submitted,

        MIN(
            IFF(
                d.soft_submit_flag = 1,
                TO_DATE(d.interaction_date),
                NULL
            )
        ) AS first_later_soft_submit_date,

        MIN(
            IFF(
                d.hard_submit_flag = 1,
                TO_DATE(d.interaction_date),
                NULL
            )
        ) AS first_later_hard_submit_date

    FROM first_visit AS f
    LEFT JOIN BDM_MARKETING.DACR_ACQ_Funnel_combined_PBI_v2 AS d
        ON f.person = d.person
       AND d.interaction_date >=
           DATEADD('day', 1, TO_DATE(f.first_interaction_time))
       AND d.interaction_date < '2026-10-01'::DATE

    GROUP BY f.person
),

customer_type_summary AS (
    SELECT
        person,
        cust_type
    FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_CUST_TYPE_LOOKUP
)

SELECT
    c.*,
    t.cust_type,

    COALESCE(l.later_soft_submitted, 0) AS later_soft_submitted,
    COALESCE(l.later_hard_submitted, 0) AS later_hard_submitted,

    l.first_later_soft_submit_date,
    l.first_later_hard_submit_date,

    DATEDIFF(
        'day',
        TO_DATE(c.first_interaction_time),
        l.first_later_soft_submit_date
    ) AS days_to_later_soft_submit,

    DATEDIFF(
        'day',
        TO_DATE(c.first_interaction_time),
        l.first_later_hard_submit_date
    ) AS days_to_later_hard_submit

FROM categorized_visitors AS c
LEFT JOIN customer_type_summary AS t
    ON c.person = t.person
LEFT JOIN later_activity AS l
    ON c.person = l.person;


SELECT
    first_visit_category,
    COUNT(*) AS total_people,

    SUM(
        IFF(later_hard_submitted = 1, 1, 0)
    ) AS later_hard_submit_people,

    SUM(
        IFF(
            later_soft_submitted = 1
            AND later_hard_submitted = 0,
            1,
            0
        )
    ) AS later_soft_submit_only_people,

    SUM(
        IFF(
            later_soft_submitted = 0
            AND later_hard_submitted = 0,
            1,
            0
        )
    ) AS neither_later_submit_people

FROM EDS.BDM_MARKETING.HT_ACCOUNT_CREATION_REVISED_VISISTOR_FUNNEL_ITA
GROUP BY first_visit_category
ORDER BY first_visit_category;
