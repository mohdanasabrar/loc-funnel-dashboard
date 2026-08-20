-- PAN Prefill Rate = distinct customers with 'pan-card-pan-prefilled' / LPV count, same day.
-- Source: hive.paytm_dml_pulse_raw.screen_action_snapshot_v3 (prefill events) +
--         hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3 (LPV denominator, same definition as 00_LPV
--         in open_funnel_query.sql -- reused here, not reinvented).
-- Substitute {{START_DATE}} / {{END_DATE}} with IST calendar dates. Use the same date for both params
-- for a single day; use a month-start/yesterday range for MTD.
--
-- IMPORTANT -- Pulse partition lag: screen_action_snapshot_v3 / screenviewagg_snapshot_v3 land on a
-- ~1-day delay versus hive.workflow_nexus (the funnel-stage source). Before running for "yesterday",
-- confirm the partition actually exists:
--   SELECT MAX(dl_last_updated) FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3
--   WHERE vertical_name = 'Lending_LOC'
-- If the partition for the target date is missing, fall back to the latest available date and note
-- the lag explicitly in the dashboard refresh -- do not silently report a 0%/empty rate.
--
-- Gotcha: screen_action_snapshot_v3 is documented "single-day queries only" (see gotchas.md #1) due to
-- its 46-column width and self-join risk -- a plain GROUP BY (no self-join) over an 11-day MTD range has
-- been verified to complete without issue, but keep an eye on runtime as the month grows past ~20 days.

WITH prefill_events AS (
    SELECT event_action, customer_id
    FROM hive.paytm_dml_pulse_raw.screen_action_snapshot_v3
    WHERE vertical_name = 'Lending_LOC'
      AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND event_action IN ('pan-card-pan-prefilled', 'pan-card-pan-not-prefilled')
),
lpv AS (
    SELECT customer_id
    FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3
    WHERE vertical_name = 'Lending_LOC'
      AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
      AND (screen_name LIKE '%lead-not-present%' OR screen_name = 'consumer-app/paytm-loc/marketplace/offers-shown-pq')
)
SELECT
    'prefilled' AS bucket, COUNT(DISTINCT customer_id) AS distinct_customers
FROM prefill_events WHERE event_action = 'pan-card-pan-prefilled'
UNION ALL
SELECT
    'not_prefilled', COUNT(DISTINCT customer_id)
FROM prefill_events WHERE event_action = 'pan-card-pan-not-prefilled'
UNION ALL
SELECT
    'lpv_denominator', COUNT(DISTINCT customer_id)
FROM lpv;

-- Rate = prefilled / lpv_denominator. Report both prefilled and not_prefilled counts alongside LPV so
-- the "PAN screen not reached at all" gap (LPV minus prefilled minus not_prefilled) is visible too --
-- do not silently drop it.
