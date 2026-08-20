-- Open Funnel: all stage transitions in the window, regardless of lead creation date.
-- Substitute {{START_DATE}} / {{END_DATE}} with IST calendar dates, e.g. DATE '2026-08-10'.
-- Use START_DATE = END_DATE for a single day. Corrected per gotchas.md #4, #10, #11.
WITH day_rows AS (
    SELECT
        history_custid AS custid,
        history_tostate AS tostate,
        history_solutiontypelevel2 AS soltype
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
                  THEN 1 ELSE 0 END) OVER (PARTITION BY custid) AS is_marketplace
    FROM day_rows
),
tagged AS (
    SELECT custid, is_marketplace, '01_LEAD_CREATED' AS funnel_step FROM flagged
    WHERE tostate IN ('BASIC_DETAILS_CAPTURED','LEAD_NOT_PRESENT','BASIC_DETAILS_CAPTURED_MARKETPLACE')
    UNION ALL SELECT custid, is_marketplace, '02_BRE1_REQUESTED' FROM flagged WHERE tostate IN ('BRE_REQUESTED','BRE_SKIPPED_MARKETPLACE','OFFERS_SHOWN_PQ')
    UNION ALL SELECT custid, is_marketplace, '03_BRE1_SUCCESS' FROM flagged WHERE tostate IN ('BRE_COMPLETED','BRE_SKIPPED_MARKETPLACE','OFFERS_SHOWN_PQ')
    UNION ALL SELECT custid, is_marketplace, '04_MARKETPLACE_OFFER_SELECTED' FROM flagged WHERE tostate IN ('CHILD_LEAD_ACTIVE','BRE_COMPLETED')
    UNION ALL SELECT custid, is_marketplace, '05_LENDER_PAN_VALIDATION_SUCCESS' FROM flagged WHERE tostate='LENDER_PAN_VALIDATION_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '06_AADHAAR_OTP' FROM flagged WHERE tostate='AADHAAR_OTP_INITIATED'
    UNION ALL SELECT custid, is_marketplace, '07_KYC_IN_PROGRESS' FROM flagged WHERE tostate='KYC_VALIDATION_IN_PROGRESS'
    UNION ALL SELECT custid, is_marketplace, '08_KYC_SUCCESS' FROM flagged WHERE tostate='KYC_VALIDATION_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '09_KYC_PINCODE_SUCCESS' FROM flagged WHERE tostate='KYC_PINCODE_SERVICEABILITY_CHECK_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '10_SELFIE_REQUIRED' FROM flagged WHERE tostate='SELFIE_REQUIRED'
    UNION ALL SELECT custid, is_marketplace, '11_SELFIE_UPLOADED' FROM flagged WHERE tostate IN ('SELFIE_CAPTURED','SELFIE_CAPTURED_V3')
    UNION ALL SELECT custid, is_marketplace, '12_LENDER_FACE_SIMILARITY_CHECK_SUCCESS' FROM flagged WHERE tostate='LENDER_FACE_SIMILARITY_CHECK_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '13_ADDITIONAL_DATA_CAPTURED' FROM flagged WHERE tostate='ADDITIONAL_DATA_CAPTURED'
    UNION ALL SELECT custid, is_marketplace, '14_LENDER_BRE_REQUIRED' FROM flagged WHERE tostate='LENDER_BRE_INITIATED'
    UNION ALL SELECT custid, is_marketplace, '15_LENDER_BRE_SUCCESS' FROM flagged WHERE tostate='LENDER_BRE_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '16_LENDER_BRE_APPROVED' FROM flagged WHERE tostate='LENDER_BRE_APPROVE_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '17_CREDIT_LINE_OFFER_REVIEW' FROM flagged WHERE tostate='CREDIT_LINE_OFFER_REVIEW'
    UNION ALL SELECT custid, is_marketplace, '18_CREDIT_LINE_OFFER_ACCEPTED' FROM flagged WHERE tostate='CREDIT_LINE_OFFER_ACCEPTED'
    UNION ALL SELECT custid, is_marketplace, '19_EMANDATE_REQUIRED' FROM flagged WHERE tostate='EMANDATE_REQUIRED'
    UNION ALL SELECT custid, is_marketplace, '20_MANDATE_SUCCESS' FROM flagged WHERE tostate='MANDATE_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '21_REVIEW_OFFER_REQUIRED' FROM flagged WHERE tostate='REVIEW_OFFER_REQUIRED'
    UNION ALL SELECT custid, is_marketplace, '22_REVIEW_OFFER_ACCEPTED' FROM flagged WHERE tostate='REVIEW_OFFER_ACCEPTED'
    UNION ALL SELECT custid, is_marketplace, '23_ESIGN_REQUIRED' FROM flagged WHERE tostate='ESIGN_REQUIRED'
    UNION ALL SELECT custid, is_marketplace, '24_ESIGN_SUCCESS' FROM flagged WHERE tostate='ESIGN_SUCCESS'
    UNION ALL SELECT custid, is_marketplace, '25_LMS_ONBOARDING_COMPLETED' FROM flagged WHERE tostate='LMS_ONBOARDING_COMPLETED'
    UNION ALL SELECT custid, is_marketplace, '26_SIGNED_UP' FROM flagged WHERE tostate='LEAD_SUCCESSFULLY_CLOSED'
),
dedup AS ( SELECT DISTINCT funnel_step, is_marketplace, custid FROM tagged ),
lpv_matched AS (
    SELECT sv.customer_id AS custid,
        CASE WHEN sv.screen_name LIKE '%marketplace%' THEN 1 ELSE 0 END AS is_marketplace
    FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3 sv
    WHERE sv.vertical_name='Lending_LOC'
      AND sv.dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND (sv.screen_name LIKE '%lead-not-present%' OR sv.screen_name='consumer-app/paytm-loc/marketplace/offers-shown-pq')
)
SELECT '00_LPV' AS funnel_step, CASE WHEN is_marketplace=1 THEN 'MARKETPLACE' ELSE 'NON_MARKETPLACE' END AS cohort, COUNT(DISTINCT custid) AS customers
FROM lpv_matched GROUP BY is_marketplace
UNION ALL
SELECT '00_LPV' AS funnel_step, 'OVERALL' AS cohort, COUNT(DISTINCT custid) AS customers
FROM lpv_matched
UNION ALL
SELECT funnel_step, CASE WHEN is_marketplace=1 THEN 'MARKETPLACE' ELSE 'NON_MARKETPLACE' END AS cohort, COUNT(DISTINCT custid) AS customers
FROM dedup GROUP BY funnel_step, is_marketplace
UNION ALL
SELECT funnel_step, 'OVERALL' AS cohort, COUNT(DISTINCT custid) AS customers
FROM dedup GROUP BY funnel_step
ORDER BY cohort, funnel_step
