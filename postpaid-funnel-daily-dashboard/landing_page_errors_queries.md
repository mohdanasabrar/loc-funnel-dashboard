# Landing-page errors (LPV -> Lead Creation) — query templates

Two sources, combined in the dashboard's `landing_page_errors` section. **They run on different data
freshness** — see the freshness note at the bottom before comparing counts across sources.

## 1. Field-validation errors (Trino)

```sql
-- Substitute {{START_DATE}} / {{END_DATE}} -- single-day only recommended (screen_action_snapshot_v3
-- gotcha #1), though a short range works for a day-by-day breakdown if GROUP BY dl_last_updated is added.
SELECT event_label, COUNT(DISTINCT customer_id) AS distinct_customers, COUNT(*) AS raw_events
FROM hive.paytm_dml_pulse_raw.screen_action_snapshot_v3
WHERE vertical_name = 'Lending_LOC'
  AND dl_last_updated BETWEEN {{START_DATE}} AND {{END_DATE}}
  AND event_action = 'field-validation-error'
GROUP BY event_label
ORDER BY distinct_customers DESC;
```

**37 distinct `event_label` values confirmed live 2026-08-11** (brief's 4-value list — `pan_isValidPan`,
`pan_isRequired`, `locCombinedTnc_isRequired`, `advisorId_patternMatch` — was a partial, illustrative
sample, not exhaustive). Full list is in `knowledge/errors/mapping.md` under "Landing-page / FE
validation errors". Top 2 by distinct-customer volume: `pan_isRequired` (23,442 customers, 6.7% of that
day's LPV) and `pan_isValidPan` (9,029 customers, 60,518 raw events — ~6.7 retries/customer).

## 2. Backend/BFF errors (Elasticsearch)

Index: `lending-postpaid-bff-fe-prod_indexer_{{DATE}}`. **Read `prefill_source_query.md`'s "root-level
fields are NOT indexed" gotcha first** — `operation`, `operation_status`, `state`, `product_type` are
unqueryable on this index; every query below scopes via `message` text + `logger_name` instead, then
inspects `state` from a raw `_source` sample to confirm funnel-stage placement before counting it.

### Confirmed relevant to LPV -> Lead Creation (state = LEAD_NOT_PRESENT or earlier)

**a. FETCH_PAN_INFO failures** (state confirmed = `LEAD_NOT_PRESENT` from `_source` sampling):
```json
{
  "query": { "bool": {
    "must": [ { "match_phrase": { "message": "occured while fetching pan info" } } ],
    "filter": [ { "term": { "logger_name.keyword": "ToolsService" } } ]
  }},
  "aggs": { "distinct_custs": { "cardinality": { "field": "context.customer_id.keyword" } } }
}
```
2026-08-12: 1,531 raw docs, **1,277 distinct customers** (dedup ratio ~1.2:1 — not retry-inflated).

**b. USER_JOURNEY_RESOLVER_CONTROLLER failures** (the resolver call fired on landing-page load, before
any lead exists — confirmed via `_source`: `operation: USER_JOURNEY_RESOLVER_CONTROLLER`, error
`UE-BFFAXIOS-ERROR-NEXUSSERVICE`, HTTP 417 from `nexusService`):
```json
{
  "query": { "bool": {
    "must": [ { "match_phrase": { "message": "Failed to fetch user journey from resolver controller" } } ]
  }},
  "aggs": { "distinct_custs": { "cardinality": { "field": "context.customer_id.keyword" } } }
}
```
2026-08-12: 84 raw docs, **57 distinct customers**.

**c. Lead create/update failures** (closest match to the brief's `NEXUS_CREATE_OR_UPDATE_LEAD`):
```json
{
  "query": { "bool": {
    "must": [ { "match_phrase": { "message": "creating or updating lead from Nexus" } } ],
    "filter": [ { "term": { "level.keyword": "error" } } ]
  }},
  "aggs": { "distinct_custs": { "cardinality": { "field": "context.customer_id.keyword" } } }
}
```
2026-08-12: 9 raw docs, **9 distinct customers** — negligible, reported as noise, not a finding.

### Checked and excluded (wrong funnel stage)

- **`FETCH_LEAD` / `SUBMIT_DATA` / `PRE_SUBMIT_PROCESSING`**: no material failure volume found
  concentrated at `state = LEAD_NOT_PRESENT`. The one large generic error bucket on this index,
  `"Internal Error Occurred at BFF while performing the operation"` (366 raw docs, `operation:
  INTERNAL_ERROR`), sits at `state = MANDATE_SUCCESS` — a late-funnel stage, well past Lead Creation.
  Excluded from this section. It's also a clean illustration of the retry-inflation gotcha already
  documented in `anomaly-methodology.md`: a 3-doc sample of it was one single `lead_id`
  (`69fc385944311226d0d09e97`) retrying an identical stack trace.
- **`"Schema not found in DB for the given product, lender, state combination"`** (75 raw docs / 15
  distinct customers, `operation: FETCH_SCHEMA_FROM_DB`): sampled `_source` shows the embedded `state`
  is `LEAD_FORCEFULLY_CLOSED`, not `LEAD_NOT_PRESENT` — a marketplace-child-lead teardown path, not the
  landing page. Excluded per the brief's own instruction to drop later-stage states from this view.

## Recovery check (mandatory, added 2026-08-13 per PM request)

Every landing-page error finding must state whether affected customers recovered (progressed past the
error) or were blocked (no further funnel progress). A raw "N customers hit this error" count alone
overstates impact if most of them proceeded anyway.

**Method:**
1. Pull the full affected-customer list from ES (not just the `cardinality` count) — a `terms` agg on
   `context.customer_id.keyword`, sized above the expected distinct count so `sum_other_doc_count = 0`
   (confirms the full set was captured, not a truncated sample).
2. Cross-reference that customer list against `hive.workflow_nexus.lead_history_snapshot_v3` via
   `history_custid IN (...)` (join key confirmed: Pulse/ES `customer_id` ↔ `history_custid` — see
   `trino/schema.md` § cross-source join keys). Filter `dl_last_updated` to the error date through
   today (mandatory partition filter, gotcha #3) — a narrower window only tells you about progression
   already logged as of "today," not a full lifetime check.
3. Classify each customer as **progressed** (has any `history_tostate <> '<the error's own state>'` row
   in that window — i.e. moved past the state the error fired at) vs. **no further activity** (zero
   rows in that window).
4. Report both counts and the percentage, alongside the caveat that "no further activity in this
   window" is not proof of permanent drop-off — the customer may return after the window closes, or
   may already have progressed *before* the error window if they're a repeat visitor (not checked
   unless the window is widened).

**Worked example — `FETCH_PAN_INFO` failure, 2026-08-12 (1,277 distinct customers):** cross-referenced
against `lead_history_snapshot_v3` for `dl_last_updated` 2026-08-12–08-13. 847/1,277 (66.3%) had at
least one row with `history_tostate <> 'LEAD_NOT_PRESENT'` — i.e. they created a lead and moved forward
despite the error (recovered, likely via retry-success or manual PAN entry). 430/1,277 (33.7%) had no
`lead_history` row at all in that window — consistent with drop-off, but not confirmed as permanent
(window doesn't extend past "today" at the time of the check, and prior-window activity wasn't
checked). Only 15/1,277 had a row with `history_tostate = 'LEAD_NOT_PRESENT'` itself — this state is
rarely persisted as its own row; most rows for a customer are the state(s) they moved *into*.

**Also cross-check the operation's actual purpose before writing the impact sentence.** `schema.md`'s
`FETCH_PAN_INFO` entry (added 2026-08-14) documents this call as a PAN **validation** lookup, not the
prefill source (`FETCH_PREFILLING`/`PrefillingService` is the real prefill call). A dashboard sentence
like "this blocks PAN prefill entirely" should be verified against which operation actually failed
before publishing — conflating validation and prefill failures overstates a specific error's impact.

## Dedup convention (mandatory)

Always report **raw doc count AND unique-customer count side by side**. `context.customer_id` is used
as the dedup key on this index — `lead_id` is present on some doc shapes (e.g. the
`FETCH_SCHEMA_FROM_DB` docs above) but not others (the `FETCH_PAN_INFO` / resolver docs above have no
`lead_id`), so `customer_id` is the consistent key across all three findings here.

## Daily trend for backend errors (added 2026-08-14, PM request for pattern detection)

Wrap any of the 3 confirmed `cardinality` queries above in a `date_histogram` instead of running them
flat for one day. Pure ES, unaffected by Trino availability — run this even when Trino is down.

```json
{
  "size": 0,
  "query": { "bool": {
    "must": [ { "match_phrase": { "message": "<the signature's message phrase>" } } ],
    "filter": [ /* same logger_name/level filter as the flat version, if any */ ]
  }},
  "aggs": {
    "by_day": {
      "date_histogram": { "field": "@timestamp", "calendar_interval": "day", "time_zone": "Asia/Kolkata" },
      "aggs": { "distinct_custs": { "cardinality": { "field": "context.customer_id.keyword" } } }
    }
  }
}
```

Use a wildcard index (`lending-postpaid-bff-fe-prod_indexer_2026-08-*`) rather than a single date so the
histogram spans the full window in one query.

**Always scan the full trend for outliers before writing up "current day" findings** — the 2026-08-14
backfill found a 167,656-customer spike on 2026-08-03 (baseline ~50-130) purely because the trend was
pulled; no single-day refresh before that had ever surfaced it. See `README.md`'s "Backend-error 12-day
trend + incident detection" section and `dashboard-data.json`'s `backend_errors.incident_finding` for
the full root-cause writeup. Re-scan this trend on every refresh, not just once — a new spike on any
future date should get the same treatment (sample raw docs, check for uniform latency/error code,
rule out retry-inflation, cross-check against that day's LPV/Lead Created in `dod_trend`).

## Freshness note

Trino field-validation numbers above are dated **2026-08-11** (latest available Pulse partition as of
2026-08-13 — see `pan_prefill_query.sql` header on the ~1-day Pulse lag). ES backend-error numbers are
dated **2026-08-12** (ES has no such lag; `2026-08-12` and even a partial `2026-08-13` index already
exist). Do not treat the one-day offset between the two sub-sections as a real trend signal — it's a
pipeline-freshness artifact, not a day-over-day comparison.
