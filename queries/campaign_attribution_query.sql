-- Campaign-wise LPV -> Lead Creation conversion, last-touch attribution (PM-confirmed rule):
-- for each customer_id per calendar day, take the UTM tag from their MOST RECENT qualifying LPV row
-- that day, using the `timestamp` column (epoch millis, hour-grain via `datehour` cross-check) --
-- NOT `dl_last_updated`, which is date-grain only and cannot break ties within a day.
-- Substitute {{START_DATE}} / {{END_DATE}} with IST calendar dates (single day or MTD range).
--
-- Gotcha: only Lending_LOC-vertical UTM values count. A customer's cross-vertical UTM tags (e.g. from
-- a FASTag or PL campaign on the same day) are never pulled in, because the `vertical_name = 'Lending_LOC'`
-- filter is applied BEFORE the last-touch ROW_NUMBER, not after.
--
-- Pulse partition lag applies here too -- see pan_prefill_query.sql header. Verify
-- MAX(dl_last_updated) before trusting {{END_DATE}} = "yesterday".

WITH lpv_rows AS (
    SELECT customer_id, utm_source, utm_campaign, utm_medium, timestamp,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY timestamp DESC) AS rn
    FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3
    WHERE vertical_name = 'Lending_LOC'
      AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND (screen_name LIKE '%lead-not-present%' OR screen_name = 'consumer-app/paytm-loc/marketplace/offers-shown-pq')
),
last_touch AS (
    SELECT customer_id, utm_source, utm_campaign, utm_medium
    FROM lpv_rows WHERE rn = 1
),
lead_created AS (
    -- Same lead-creation definition as 01_LEAD_CREATED in open_funnel_query.sql.
    SELECT DISTINCT history_custid AS customer_id
    FROM hive.workflow_nexus.lead_history_snapshot_v3
    WHERE dl_last_updated IS NOT NULL
      AND DATE(history_timestamp + INTERVAL '5' HOUR + INTERVAL '30' MINUTE) BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND history_tostate IN ('BASIC_DETAILS_CAPTURED','LEAD_NOT_PRESENT','BASIC_DETAILS_CAPTURED_MARKETPLACE')
)
SELECT
    lt.utm_campaign,
    lt.utm_source,
    lt.utm_medium,
    COUNT(DISTINCT lt.customer_id) AS lpv_count,
    COUNT(DISTINCT lc.customer_id) AS lead_created_count
FROM last_touch lt
LEFT JOIN lead_created lc ON lt.customer_id = lc.customer_id
GROUP BY lt.utm_campaign, lt.utm_source, lt.utm_medium
ORDER BY lpv_count DESC;
-- Dashboard shows top 20 by lpv_count. Always also compute:
--   SELECT COUNT(DISTINCT utm_campaign) FROM last_touch  -- total distinct campaigns, for the "N shown
--   of M total" disclosure -- never silently truncate without stating the excluded count/volume.

-- ============================================================================
-- Multi-day trend for the top-10 campaigns (added 2026-08-14, PM request for pattern detection).
-- Run the single-day query above FIRST to get the current top-10 campaign names, then substitute them
-- into the IN (...) list below. Last-touch is computed PER CUSTOMER PER DAY (PARTITION BY includes
-- dl_last_updated), matching the single-day query's semantics repeated across days.
--
-- IMPORTANT: filter to the top-10 names in the FINAL SELECT, not in the base lpv_rows CTE -- if you
-- pre-filter before ROW_NUMBER(), a customer whose true last touch that day was a non-top-10 campaign
-- gets incorrectly attributed to a top-10 one (their only remaining row after the pre-filter looks like
-- rn=1 even though it wasn't really their last touch). Compute last-touch across ALL campaigns first.
WITH lpv_rows AS (
    SELECT customer_id, utm_campaign, timestamp, dl_last_updated,
           ROW_NUMBER() OVER (PARTITION BY customer_id, dl_last_updated ORDER BY timestamp DESC) AS rn
    FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3
    WHERE vertical_name = 'Lending_LOC'
      AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND (screen_name LIKE '%lead-not-present%' OR screen_name = 'consumer-app/paytm-loc/marketplace/offers-shown-pq')
),
last_touch AS (
    SELECT customer_id, utm_campaign, dl_last_updated
    FROM lpv_rows WHERE rn = 1
      AND utm_campaign IN ({{TOP_10_CAMPAIGN_NAMES}})
),
lead_created AS (
    SELECT DISTINCT history_custid AS customer_id, DATE(history_timestamp + INTERVAL '5' HOUR + INTERVAL '30' MINUTE) AS lead_date
    FROM hive.workflow_nexus.lead_history_snapshot_v3
    WHERE dl_last_updated IS NOT NULL
      AND DATE(history_timestamp + INTERVAL '5' HOUR + INTERVAL '30' MINUTE) BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND history_tostate IN ('BASIC_DETAILS_CAPTURED','LEAD_NOT_PRESENT','BASIC_DETAILS_CAPTURED_MARKETPLACE')
)
SELECT lt.dl_last_updated, lt.utm_campaign,
    COUNT(DISTINCT lt.customer_id) AS lpv_count,
    COUNT(DISTINCT lc.customer_id) AS lead_created_count
FROM last_touch lt
LEFT JOIN lead_created lc ON lt.customer_id = lc.customer_id AND lc.lead_date = lt.dl_last_updated
GROUP BY lt.dl_last_updated, lt.utm_campaign
ORDER BY lt.dl_last_updated, lt.utm_campaign;
-- A campaign missing from an earlier day's rows means it wasn't in the top 10 (or had zero LPV) that
-- day, not necessarily a data gap -- note this explicitly in the dashboard rather than showing a blank
-- that looks like missing data.
