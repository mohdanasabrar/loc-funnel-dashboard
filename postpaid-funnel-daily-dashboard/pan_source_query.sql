-- Prefill Source Breakdown = CIF vs. KYB vs. Not-prefilled, as % of same-day LPV.
-- Source: hive.paytm_dml_pulse_raw.screen_action_snapshot_v3 -- the SAME table as
--         pan_prefill_query.sql's 'prefilled' bucket, not Elasticsearch. See the
--         2026-08-17 correction note in prefill_source_query.md for why an earlier
--         Elasticsearch-based version of this section was wrong (different tracking
--         system, incomplete population vs. LPV).
--
-- Field: event_action = 'pan_source' (underscore -- confirmed live 2026-08-17; 'panSource'
-- camelCase returns zero rows). event_label6 carries the source value: 'CIF' or 'KYB'.
-- Confirmed distinct values as of 2026-08-17: CIF, KYB. No 'NOT_PREFILLED' or 'OTHER' value
-- exists on this event -- failures are a separate, explicit event (see below).
--
-- Cross-check performed 2026-08-17: COUNT(DISTINCT customer_id) for event_action='pan_source'
-- (CIF + KYB combined) on 2026-08-15 = 126,154, vs. pan_prefill_query.sql's 'prefilled' count
-- for the same day = 125,857 -- 99.8% match. Confirms this event and 'pan-card-pan-prefilled'
-- track the same underlying customers; use pan-card-pan-prefilled's Prefill Rate as the
-- authoritative total and this query only for the CIF/KYB split.
--
-- Same partition-lag and single-day-query caveats as pan_prefill_query.sql apply (this is the
-- same 46-column table -- see gotchas.md #1). Substitute {{START_DATE}} / {{END_DATE}} with IST
-- calendar dates; use the same date for both for a single day.

WITH source_events AS (
    SELECT event_label6 AS pan_source, customer_id
    FROM hive.paytm_dml_pulse_raw.screen_action_snapshot_v3
    WHERE vertical_name = 'Lending_LOC'
      AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND event_action = 'pan_source'
),
not_prefilled_events AS (
    SELECT customer_id
    FROM hive.paytm_dml_pulse_raw.screen_action_snapshot_v3
    WHERE vertical_name = 'Lending_LOC'
      AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND event_action = 'pan-card-pan-not-prefilled'
)
SELECT pan_source AS bucket, COUNT(DISTINCT customer_id) AS distinct_customers
FROM source_events
GROUP BY pan_source
UNION ALL
SELECT 'NOT_PREFILLED', COUNT(DISTINCT customer_id)
FROM not_prefilled_events;

-- Divide each bucket by same-day LPV (screenviewagg_snapshot_v3, same definition as
-- pan_prefill_query.sql's lpv_denominator / 00_LPV) to get CIF_pct / KYB_pct / NOT_PREFILLED_pct.
-- For a day-by-day breakdown (not just a single day/range total), GROUP BY dl_last_updated
-- as well -- verified to run without a self-join, same as the parent query.
