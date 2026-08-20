-- DoD trend: headline stages only (LPV, Lead Created, Signed Up), per calendar day, Open Funnel basis.
-- day_rows scans the FULL 26-stage tostate set (same as open_funnel_query.sql) so the customer-level
-- marketplace flag is computed identically/consistently across all dashboard queries -- a customer
-- whose marketplace tag only appears on an intermediate stage (e.g. CHILD_LEAD_ACTIVE) must still be
-- flagged correctly at Lead Created. Only 2 UNION ALL branches are kept in `tagged` (not all 26), which
-- keeps the query plan well under Trino's 200-stage limit even with GROUP BY activity_date added.
-- Substitute {{START_DATE}} / {{END_DATE}} with IST calendar dates for the trailing window.
WITH day_rows AS (
    SELECT
        history_custid AS custid,
        history_tostate AS tostate,
        history_solutiontypelevel2 AS soltype,
        CAST(DATE(history_timestamp + INTERVAL '5' HOUR + INTERVAL '30' MINUTE) AS DATE) AS activity_date
    FROM hive.workflow_nexus.lead_history_snapshot_v3
    WHERE dl_last_updated IS NOT NULL
      AND DATE(history_timestamp + INTERVAL '5' HOUR + INTERVAL '30' MINUTE) BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND history_solutiontypelevel2 NOT IN ('LAN_DEACTIVATION','EMI','PO_VKYC','PO_ADD_BANK','LIMIT_UPGRADE','PO_SURPLUS_REFUND')
      AND history_tostate IN (
        'BASIC_DETAILS_CAPTURED','LEAD_NOT_PRESENT','BASIC_DETAILS_CAPTURED_MARKETPLACE',
        'BRE_REQUESTED','BRE_SKIPPED_MARKETPLACE','OFFERS_SHOWN_PQ','BRE_COMPLETED',
        'CHILD_LEAD_ACTIVE','LENDER_PAN_VALIDATION_SUCCESS','AADHAAR_OTP_INITIATED',
        'KYC_VALIDATION_IN_PROGRESS','KYC_VALIDATION_SUCCESS',
        'KYC_PINCODE_SERVICEABILITY_CHECK_SUCCESS',
        'SELFIE_REQUIRED','SELFIE_CAPTURED','SELFIE_CAPTURED_V3',
        'LENDER_FACE_SIMILARITY_CHECK_SUCCESS','ADDITIONAL_DATA_CAPTURED',
        'LENDER_BRE_INITIATED','LENDER_BRE_SUCCESS','LENDER_BRE_APPROVE_SUCCESS',
        'CREDIT_LINE_OFFER_REVIEW','CREDIT_LINE_OFFER_ACCEPTED',
        'EMANDATE_REQUIRED','MANDATE_SUCCESS',
        'REVIEW_OFFER_REQUIRED','REVIEW_OFFER_ACCEPTED',
        'ESIGN_REQUIRED','ESIGN_SUCCESS',
        'LMS_ONBOARDING_COMPLETED','LEAD_SUCCESSFULLY_CLOSED'
      )
),
flagged AS (
    SELECT *,
        MAX(CASE WHEN soltype IN ('CHILD_V1','CHILD_V2')
                   OR tostate IN ('BASIC_DETAILS_CAPTURED_MARKETPLACE','BRE_SKIPPED_MARKETPLACE','OFFERS_SHOWN_PQ','CHILD_LEAD_ACTIVE')
                  THEN 1 ELSE 0 END) OVER (PARTITION BY custid, activity_date) AS is_marketplace
    FROM day_rows
),
tagged AS (
    SELECT custid, is_marketplace, activity_date, '01_LEAD_CREATED' AS funnel_step FROM flagged
    WHERE tostate IN ('BASIC_DETAILS_CAPTURED','LEAD_NOT_PRESENT','BASIC_DETAILS_CAPTURED_MARKETPLACE')
    UNION ALL
    SELECT custid, is_marketplace, activity_date, '26_SIGNED_UP' FROM flagged WHERE tostate='LEAD_SUCCESSFULLY_CLOSED'
),
dedup AS ( SELECT DISTINCT activity_date, funnel_step, is_marketplace, custid FROM tagged ),
lpv_matched AS (
    SELECT sv.dl_last_updated AS activity_date, sv.customer_id AS custid,
        CASE WHEN sv.screen_name LIKE '%marketplace%' THEN 1 ELSE 0 END AS is_marketplace
    FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3 sv
    WHERE sv.vertical_name='Lending_LOC'
      AND sv.dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND (sv.screen_name LIKE '%lead-not-present%' OR sv.screen_name='consumer-app/paytm-loc/marketplace/offers-shown-pq')
)
SELECT activity_date, '00_LPV' AS funnel_step, CASE WHEN is_marketplace=1 THEN 'MARKETPLACE' ELSE 'NON_MARKETPLACE' END AS cohort, COUNT(DISTINCT custid) AS customers
FROM lpv_matched GROUP BY activity_date, is_marketplace
UNION ALL
SELECT activity_date, '00_LPV', 'OVERALL', COUNT(DISTINCT custid)
FROM lpv_matched GROUP BY activity_date
UNION ALL
SELECT activity_date, funnel_step, CASE WHEN is_marketplace=1 THEN 'MARKETPLACE' ELSE 'NON_MARKETPLACE' END AS cohort, COUNT(DISTINCT custid) AS customers
FROM dedup GROUP BY activity_date, funnel_step, is_marketplace
UNION ALL
SELECT activity_date, funnel_step, 'OVERALL', COUNT(DISTINCT custid)
FROM dedup GROUP BY activity_date, funnel_step
ORDER BY activity_date, funnel_step, cohort
