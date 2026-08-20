# Postpaid LOC Funnel Dashboard — daily refresh

Produces the LPV → Signed Up funnel (27 stages), split Marketplace / Non-Marketplace / Overall,
as both an **Open Funnel** (all stage activity in the window) and **Closed Funnel** (activity AND
lead creation both in the window) view — plus a 14-day DoD (day-on-day) trend of headline stages
and an MTD (month-to-date) full-stage rollup.

Extended 2026-08-13 with 4 additional sections (see "The 4 extension sections" below): PAN Prefill
Rate, Prefill Source Breakdown, Campaign-wise LPV → Lead Creation, and Landing-Page Errors.

**Redesigned 2026-08-14** from a single long-scroll page into a left-sidebar app: four nav items
(Overview, PAN Prefill, Campaign Traffic, Landing-Page Errors), each its own `.app-page` div, toggled
by `initNav()` — no page reload, no data re-fetch, purely a `display` toggle keyed on
`.app-nav-item`'s `data-page` attribute. The meta-row (latest day / MTD / generated) moved into the
sidebar footer so it's visible regardless of which page is active; the refresh-note footer stays
outside all `.app-page` divs for the same reason. When adding a 5th section in the future: add one
`<button class="app-nav-item" data-page="X">` to the sidebar nav, wrap the section's markup in
`<div class="app-page" id="page-X">...</div>`, and nothing else needs to change — `initNav()` picks up
new nav items/pages automatically via `querySelectorAll`.

This bundles every correction found during the 2026-08-10/11 session (see
`knowledge/data-sources/trino/gotchas.md` #4, #10, #11):

- **Scope convention:** `history_solutiontypelevel2 NOT IN ('LAN_DEACTIVATION','EMI','PO_VKYC','PO_ADD_BANK','LIMIT_UPGRADE','PO_SURPLUS_REFUND')`
- **Marketplace cohort:** customer-level flag — `MAX(...)` of (`history_solutiontypelevel2 IN ('CHILD_V1','CHILD_V2')` OR `history_tostate` in the marketplace-only set), never a per-row flag.
- **LPV:** identical figure in both Open and Closed views (no lead exists yet at that stage, so the closed-cohort restriction is inapplicable). Marketplace LPV is a known floor (gotcha #11) — the screen_name whitelist inherited from `dod_funnel.sql` doesn't cover all marketplace entry screens.
  - **2026-08-12 fix:** a refresh on 08-11 left Closed's `00_LPV` unset (missing key) for the latest day and MTD sections, which `dashboard.html` then silently skipped rendering. `dashboard.html` / `dashboard-local.html` now enforce this invariant at render time — Closed's LPV is always copied from Open's LPV for the selected period, regardless of what the data pull wrote — so this can't recur as a silent blank row. Still copy LPV from Open into Closed explicitly when assembling `dashboard-data.json` on each refresh; the render-time copy is a backstop, not a substitute.

## Files

- `open_funnel_query.sql` — full 27-stage Open Funnel, parameterized by `{{START_DATE}}` / `{{END_DATE}}` (inclusive, IST calendar dates). Use the same date for both params for a single day.
- `closed_funnel_query.sql` — same, plus the `createdtime` same-window restriction.
- `dod_trend_query.sql` — per-day trend of headline stages only (LPV, Lead Created, Signed Up) over a date range, Open Funnel basis. Use for the 14-day trend view, not full-stage detail (avoids Trino's 200-stage query-plan limit when combined with a GROUP BY activity_date).
- `pan_prefill_query.sql` — PAN prefill rate (day + MTD), Trino. See "PAN Prefill Rate" below.
- `pan_source_query.sql` — PAN prefill source breakdown (CIF/KYB), Trino. See "Prefill Source Breakdown" below.
- `prefill_source_query.md` — superseded 2026-08-17; old Elasticsearch approach, kept for historical reference only.
- `campaign_attribution_query.sql` — last-touch campaign attribution, LPV → Lead Creation, Trino. See "Campaign-wise LPV → Lead Creation" below.
- `landing_page_errors_queries.md` — Trino field-validation query + ES backend-error query templates. See "Landing-Page Errors" below.

Run each via the `mcp__trino__trino_query` tool (SQL files) or `mcp__elasticsearch-mcp-prod__search` (query bodies in the `.md` files), substituting the date placeholders.

## The 4 extension sections (added 2026-08-13)

### PAN Prefill Rate

Daily + MTD rate of `pan-card-pan-prefilled` events as % of same-day LPV. Source:
`pan_prefill_query.sql` (Trino, `screen_action_snapshot_v3` + `screenviewagg_snapshot_v3`).

**Pulse partition lag — check before every refresh:** `screen_action_snapshot_v3` and
`screenviewagg_snapshot_v3` can lag `hive.workflow_nexus` (the rest of the dashboard's source) by
~1 day. Confirmed live 2026-08-13: `hive.workflow_nexus` had a full 2026-08-12 partition while the
Pulse tables' `MAX(dl_last_updated)` was still 2026-08-11. Run
`SELECT MAX(dl_last_updated) FROM hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3 WHERE vertical_name = 'Lending_LOC'`
first and use whatever date comes back as "latest day" for this section and the two below it — do not
report a false zero/empty result for a partition that hasn't landed yet.

### Prefill Source Breakdown

Where PAN prefill data actually came from (`CIF` vs. `KYB`, or not prefilled at all), as % of same-day
LPV. Source: `pan_source_query.sql` (Trino, `screen_action_snapshot_v3` — the same table as "PAN Prefill
Rate" above).

**Two prior corrections here both turned out to be fixing the wrong tracking system, not the right one.**
Full history, in case a similar bug resurfaces:

1. **2026-08-14** — originally read `FETCH_PAN_INFO`/`ToolsService` and reported `CACHE`/`SIGNZY`. PM
   flagged that as PAN *validation* sourcing, not prefill sourcing. Corrected to Elasticsearch
   `PrefillingService`'s `panSource` field.
2. **2026-08-17, first attempt** — PM flagged that percentages were computed against `total_attempts`
   (a raw, undeduplicated Elasticsearch doc count), not LPV. Fixed to `COUNT(DISTINCT customer_id)` /
   LPV — but this was still wrong: Elasticsearch's `PrefillingService` call population only covers
   ~20-34% of same-day LPV, a fundamentally different (far less complete) tracking system than the FE
   product event already used for the correct ~44-46% "PAN Prefill Rate" above. Dividing that
   incomplete ES numerator by the correct LPV denominator produced CIF shares of 5-14% against the PM's
   correct read of the business (~39-40% CIF, ~45% overall).
3. **2026-08-17, final fix** — PM pointed directly at the right field: `screen_action_snapshot_v3`,
   `event_action = 'pan_source'` (underscore, not the camelCase `panSource` guessed earlier),
   `event_label6` = `CIF`/`KYB`. Same table, same tracking system as `pan_prefill_query.sql`'s
   `prefilled` bucket — cross-checked on 2026-08-15: CIF+KYB (126,154) vs. that day's `prefilled` count
   (125,857), a 99.8% match. Elasticsearch is no longer used for this section at all; see
   `pan_source_query.sql`. `prefill_source_query.md` (the old ES approach) is kept for historical
   reference only, marked superseded at the top.

**Resulting numbers (2026-08-06 to 2026-08-16):** CIF runs a tight 37.2%-39.0% of LPV, KYB 6.7%-7.7%,
Not-prefilled 43.2%-45.1% — CIF+KYB+Not-prefilled together account for ~89% of LPV, with the remaining
~11% matching the "no_pan_event" ceiling already shown in the Prefill Rate section above (LPV customers
who fired neither event that day). No day-over-day anomaly in this window — the range is far tighter
than either of the two earlier (wrong) methodologies produced, which in hindsight was itself a signal
something was off with those approaches rather than a genuinely noisy metric.

### Campaign-wise LPV → Lead Creation

Top 20 campaigns (of the day's total distinct campaigns — the excluded count/volume is always shown,
never silently dropped) ranked by LPV volume, with Lead Creation conversion per campaign. Source:
`campaign_attribution_query.sql` (Trino).

**Attribution rule (PM-confirmed): last-touch** — for each customer per calendar day, the UTM tag from
their most recent qualifying LPV row that day, ordered by the `timestamp` column (epoch millis;
`dl_last_updated` alone is date-grain only and can't break same-day ties). Only `Lending_LOC`-vertical
UTM values count.

Subject to the same Pulse partition lag as PAN Prefill Rate above — same latest-day check applies.

**Pattern Findings + 13-Day Trend (added 2026-08-14, PM request).** The single-day top-20 table alone
can't show a campaign's volume collapsing and recovering over several days — added `top_campaigns_trend`
(daily LPV + Lead Created for the day's top 10 campaigns, backfilled across `dod_range`) plus
`pattern_findings` (narrative call-outs when a campaign's trend shows a real pattern, not just noise).
**Query:** same last-touch methodology as the base table, but with `dl_last_updated` added to the
`PARTITION BY` in the last-touch `ROW_NUMBER()` (so last-touch is computed per customer *per day*, not
once across the whole range) and `GROUP BY` extended to include the day — see the query block at the
bottom of `campaign_attribution_query.sql`. Restrict the final `WHERE utm_campaign IN (...)` to the
already-known top-10 names (from the latest day's own top-20 pull) — don't pre-filter the base CTE to
those names before computing `ROW_NUMBER()`, or a customer's true last touch (if it was a non-top-10
campaign) gets silently misattributed to a top-10 one.

First backfill (2026-08-14, 08-01 to 08-13) found two real patterns purely from having the history:
`postpaid_acq_Dailypush` collapsed to <2% of its normal LPV volume on 4 separate days (looks like
intermittent campaign pausing), and `pp_acq_postpaymentscreen` (the single highest-volume campaign when
active) dropped and stayed low for 5+ days across two separate windows. Neither was visible in any
single-day snapshot — this is the entire reason day-over-day history was worth building.

### Landing-Page Errors

Two sub-sections: Trino field-validation errors (`event_action = 'field-validation-error'`, broken down
by `event_label` — 37 distinct values confirmed, not just the 4 originally documented) and
Elasticsearch backend/BFF errors (scoped via the same `message`+`logger_name` workaround as Prefill
Source Breakdown). Source: `landing_page_errors_queries.md`.

**Dedup convention (mandatory on every refresh):** always report raw doc/event count AND unique
customer count side by side. One stuck customer/lead retrying can look like mass impact on raw count
alone (see `anomaly-methodology.md`'s retry-inflation gotcha) — confirmed again live 2026-08-12, where
a 3-doc sample of the `INTERNAL_ERROR` bucket was a single `lead_id` retrying an identical stack trace.

**Stage-scoping discipline:** not every error with a landing-page-sounding message actually occurs at
`LEAD_NOT_PRESENT`. Always check the embedded `state` from a raw `_source` sample before including an
error in this section — `Schema not found in DB...` and `Internal Error Occurred at BFF...` both looked
plausible but sampled at `LEAD_FORCEFULLY_CLOSED` and `MANDATE_SUCCESS` respectively (later/terminal
stages) and were excluded. Give each error a one-line recommendation only if unique-customer impact is
material — call out 1-2-customer errors as noise, not findings.

**Backend-error 12-day trend + incident detection (added 2026-08-14, PM request).** Each of the 3
confirmed backend-error signatures (PAN-fetch failures, resolver-controller failures, lead
create/update failures) now has a `date_histogram` (`time_zone: Asia/Kolkata`, `cardinality` agg on
`context.customer_id.keyword`) run back to 2026-08-03 — see the query pattern already in
`landing_page_errors_queries.md`'s ES section, just wrapped in a `date_histogram` instead of a flat
`cardinality` agg. This is pure ES, unaffected by Trino availability.

**Major finding from the first backfill:** resolver-controller failures spiked to 167,656 distinct
customers on 2026-08-03 (baseline ~50-130/day) with a corroborating spike in lead create/update
failures the same day (1,876 vs. a 3-21 baseline) — a smaller recurrence hit both signatures on
2026-08-06. The PAN-fetch signature stayed flat on both days, narrowing the root cause to the
resolver/lead-creation path. Raw `_source` samples from 08-03 show `error_code: LOS-BFF-WF-00020`,
HTTP 500, `refCode: UE-BFFAXIOS-ERROR-NEXUSSERVICE`, and a uniform ~30-second latency across different
customers/devices — consistent with `workflow-nexus` itself being unavailable, not a client or
retry-inflation artifact (ruled out per the usual dedup check). This was invisible in every prior
single-day refresh and only surfaced once the 12-day trend existed — file as a P1 incident-review with
the workflow-nexus team. Full writeup in `dashboard-data.json`'s
`landing_page_errors.backend_errors.incident_finding`.

## Daily refresh procedure

Ask (any of): "refresh the funnel dashboard", "update the funnel dashboard", "pull today's funnel dashboard".

Each refresh:
1. Run `open_funnel_query.sql` and `closed_funnel_query.sql` with `{{START_DATE}}={{END_DATE}}` = yesterday (IST).
2. Run `dod_trend_query.sql` with a 14-day trailing window ending yesterday.
3. Run `open_funnel_query.sql` and `closed_funnel_query.sql` again with `{{START_DATE}}` = first of the current month, `{{END_DATE}}` = yesterday, for the MTD rollup.
4. Check `MAX(dl_last_updated)` on `hive.paytm_dml_pulse_raw.screenviewagg_snapshot_v3` (Lending_LOC) — if it lags "yesterday" (confirmed possible, see "Pulse partition lag" above), use that latest-available date for steps 5-7 instead, and note the lag in the dashboard.
5. Run `pan_prefill_query.sql` (day + MTD) for the PAN Prefill Rate section.
6. Run the ES queries in `prefill_source_query.md` for the Prefill Source Breakdown section (day, plus keep the prior day's numbers for the 2-way comparison until enough history accumulates for real baseline alerting).
7. Run `campaign_attribution_query.sql` for the Campaign-wise LPV → Lead Creation section, and the Trino + ES queries in `landing_page_errors_queries.md` for the Landing-Page Errors section.
8. Update `artifacts/data/postpaid-funnel-dashboard-live/dashboard-data.json` (single rolling file, overwritten each refresh — not a dated pull, since it's a live dashboard feed, not a point-in-time analysis artifact). Update all 8 top-level keys from the original funnel plus the 4 extension keys (`pan_prefill`, `prefill_source`, `campaign_traffic`, `landing_page_errors`).
9. Regenerate `dashboard.html` from the template in this folder and republish via the Artifact tool to the primary URL (recorded below). Copy the same file to `dashboard-v2.html` and republish that too, to keep the backup URL in sync.

**Dashboard URL (primary as of 2026-08-14):** https://claude.ai/code/artifact/2919d225-651c-403d-afdc-807e941f900a (`dashboard-v2.html`) — private by default, share from the page's share menu if the PM wants to hand it to others.

**Backup URL (`dashboard-v3.html`, kept in sync on every refresh):** https://claude.ai/code/artifact/ff69aee3-c090-4ba1-935c-4d2041b6619e — republish here too if the primary ever hits the "blank after many republishes" failure mode.

**Superseded URLs (do not reuse):**
- https://claude.ai/code/artifact/07bc3521-15c2-4175-8432-b7e5f4838a0e (`dashboard.html`, the ORIGINAL primary) — after many republishes across 2026-08-13/14 this URL started rendering blank while the byte-identical content on a fresh URL rendered fine after the same wait. Demoted to backup-of-a-backup; `dashboard.html` itself is still the canonical local working file (all edits happen here first, then get copied to `dashboard-v2.html`/`dashboard-v3.html` before publishing) — only the *published URL* was rotated, not the file.
- https://claude.ai/code/artifact/484cb833-7328-4476-9e22-c00c1d686045 — same failure mode, retired 2026-08-13.

**Important nuance learned 2026-08-14 — don't confuse "still loading" with "actually broken":** this page can take 25-30+ seconds to render now that it's grown (4 sections, ~170KB). A blank screenshot at 10-15 seconds is very likely just slow load, not the republish-blank bug. Before concluding a URL has hit the platform quirk: (a) wait at least 25-30 seconds, (b) check the console for zero output (the real quirk shows no console activity at all, whereas slow-load still eventually paints), (c) ideally compare against a fresh test URL with the same content — if the fresh one also takes a while but eventually renders, the original probably would too with more patience. Rotating to a new URL is for confirmed-blank-after-lots-of-republishes cases, not a first resort.

**Refresh procedure note:** copy the verified `dashboard.html` to BOTH `dashboard-v2.html` and `dashboard-v3.html` and publish to both URLs above on every refresh (not just one) — there is no single "the" backup anymore, there are two, and both should stay current.

**Note on `dashboard.html`:** it ends with a `try/catch` around the boot sequence and a `window.onerror` handler that render any exception as a visible on-page banner. Keep this wrapper on every future edit — the Artifact viewer's sandboxed iframe was observed to render a fully blank page (not even static markup) on an uncaught JS exception during initial script execution, with no way to inspect its console from outside. The banner is the only way to see what broke without that access. Note this banner does NOT catch the "blank after many republishes" failure mode above -- that one produces no banner either, which is itself the tell that it's platform-side, not a script error.

**Incident (2026-08-13): the 4-extension-section build silently dropped the entire core render engine.** When `dashboard.html` was regenerated to add the 4 extension sections, the edit kept `DATA`, the 4 new render functions, and the boot sequence's call list, but dropped everything in between — `fmt`, `pctFmt`, `computePct`, `renderMeta`, `renderKpis`, `niceMax`, `abbrev`, `renderTrendChart`, `renderCharts`, `state`, `emptySection`, `sectionFor`, `currentSection`, `monthLabel`, `initPeriodControls`, `renderFunnelTable`, `wireToggle`, `renderLimitations`, `renderAnomalies`, `renderRecommendations` — roughly 400 lines, gone. The boot sequence still called all of them, so every refresh after that build published a page whose first line (`renderMeta()`) threw `ReferenceError: renderMeta is not defined`, caught by the error banner. Recovered by publishing the last known-good version's URL as a fresh artifact via `Artifact({url: ...})`... no — via **`Duplicate` on that version in the artifact's own version-history menu**, then `WebFetch`-ing the duplicate's `claude.ai/code/artifact/<id>` URL, which returns the full raw HTML (WebFetch documents this as special-cased for artifact URLs) — that gave back the exact original source to copy the missing block from, rather than reconstructing it from guesswork.

**Lesson for any future edit to this file:** before publishing, grep the file for the full expected function list above (`grep -c "^function "` should be ~19, not ~5) — a large diff that only *adds* functions without touching existing ones can still net-delete code if the edit tool replaced a range instead of inserting into it. This class of bug produces no diff-review red flag if you only look at what changed, only at what's now missing.

**Also fixed in the same incident:** `renderKpis` and `renderTrendChart` didn't guard against a `null` value (e.g. this month's LPV-partition-lag gap) — `null` was silently coerced to `0` in arithmetic, producing a fabricated "▼100.0% drop" KPI and a chart line that plunged to zero instead of just stopping. Both now treat `null` as "no data" (renders `—`, chart line breaks instead of dropping to zero) rather than a real zero.

**Incident (2026-08-14): a resolved data lag didn't propagate to the day-level table.** When the LPV-partition lag on `screenviewagg_snapshot_v3` finally resolved, the refresh correctly backfilled `dod_trend`'s `00_LPV` array (used by the 14-Day Trend charts) for 2026-08-12 — but `daily_open['2026-08-12']` and `daily_closed['2026-08-12']` (used by the Full Funnel Detail table's Day selector) were never touched, since they're a **separate data structure** populated by a separate query step. The PM checked the Day-selector table specifically, saw the LPV row still missing for 08-12, and correctly called it out — the dashboard's own trend chart looked fine, so this was easy to miss. Fixed by pulling the missing day's LPV split (all 3 cohorts) and inserting it directly into both `daily_open`/`daily_closed`, reusing the cohort-level figures already sitting in `dod_trend` for that exact date rather than re-querying Trino (which was saturated at the time — see below). **Lesson: when a historical data gap gets backfilled, check ALL structures that could contain that date — `dod_trend`, `daily_open`, `daily_closed` — not just the one most visibly broken.** A `grep` for the affected date across the whole `dashboard-data.json` (or a small script checking every `daily_open`/`daily_closed` entry for a missing `00_LPV` key, as done during this fix) is cheap insurance against this recurring for a different date or a different field.

**Same-day infra note:** the Trino cluster (`cdp-trino-query.platform.mypaytm.com`) was persistently saturated for over 30 minutes during the 2026-08-14 refresh (every query, including trivial probes, rejected with "Too many queued queries"). This stale-blocked `pan_prefill.mtd`, `campaign_traffic`, and `landing_page_errors.field_validation` for that refresh — each was left showing its last-known values with an explicit staleness note rather than fabricated numbers, and should self-correct on the next refresh once the cluster clears. If this recurs, don't retry in a tight loop — space out attempts or defer non-critical sections to the next scheduled refresh.

**Incident (2026-08-18): a pre-existing data/render-code schema mismatch crashed the whole page, undetected by the function-count check alone.** The 2026-08-18 refresh republished cleanly (function count intact, valid JS syntax) but the PM immediately hit a blank page with a red `DASHBOARD RENDER ERROR: Cannot read properties of undefined (reading 'toFixed')` banner from `renderPrefillSource`. Root cause: every entry in `prefill_source.days[*]` was missing an `accounted_for_pct` field that `renderPrefillSource`'s per-day table reads unguarded (`r.accounted_for_pct.toFixed(1)`, no `== null` check like the rest of the codebase uses via `fmt()`/`pctFmt()`) — this predated the 2026-08-18 refresh (that refresh never touched `prefill_source.days` values, only added a `stale_note`), so the section had likely been broken since whenever the table-row code was added without the data pipeline ever computing that field. Fixed by backfilling `accounted_for_pct = CIF_pct + KYB_pct + NOT_PREFILLED_pct` for every day + MTD. Also surfaced a **separate, deeper issue**: those CIF/KYB/NOT_PREFILLED percentages sum to ~100%, meaning the historical days are still on the old "% of `total_attempts`" methodology, not the "% of same-day LPV" method documented as the final fix in `pan_source_query.sql` (see the "Prefill Source Breakdown" section above) — flagged via a `prefill_source.methodology_caveat` field in the data rather than silently treated as correct; needs a proper Trino backfill once available, not another patch.

**Lesson — verify the render, not just the diff, before calling a refresh done.** A syntax-valid, function-count-intact `dashboard.html` can still crash at runtime if the data doesn't satisfy every field the render functions assume, and a quick visual load can look "still loading" or hit an unrelated platform/tooling issue that makes a real bug hard to distinguish from a false alarm. Before telling the PM a refresh is complete, run the page through a real DOM (e.g. `node` + `jsdom`, `npm install jsdom` into the scratchpad if not already present) and check for the on-page error banner (`div[style*="position: fixed"]` with the red `#d03b3b`/`208, 59, 59` background) rather than relying on a text search of `body.innerHTML` (which also matches the banner's own source code string and gives false confidence) — and spot-check that every major section's container (`kpi-grid`, `prefill-source-table`, `campaign-table`, etc.) actually populated with non-empty content, not just that no error fired.

**Incident (2026-08-19): Trino saturation hit two consecutive refreshes, and the resolver-controller outage recurred a third time.** The 2026-08-18 refresh (run 2026-08-18, "yesterday"=08-17) had already hit "Too many queued queries" on `pan_prefill`, `prefill_source`, `campaign_traffic`, and `landing_page_errors.field_validation` (per the stale_notes it left behind). The very next refresh (run 2026-08-19, "yesterday"=08-18) hit the SAME failure mode again — Trino accepted the single-day Open Funnel query for 2026-08-18 but then rejected every subsequent query (Closed Funnel, MTD, dod_trend, and all 4 extension sections' Trino halves) with "Too many queued queries," including trivial `SELECT 1` probes, across several spaced-out retries over ~10+ minutes. Per the 2026-08-14 precedent, did not retry in a tight loop; core funnel `latest_day` was deliberately NOT advanced to 2026-08-18 this refresh (kept at 2026-08-17) rather than write Open-only data and risk the same Open/Closed-LPV-invariant gap as the 2026-08-12 incident. **This is now the second consecutive stale-Trino refresh — worth escalating as a recurring cluster-capacity issue, not a one-off.** Separately, the pure-ES `landing_page_errors.backend_errors` section (unaffected by Trino) surfaced a THIRD occurrence of the resolver-controller outage pattern first found on 2026-08-03: 20,662 distinct customers hit `Failed to fetch user journey from resolver controller` on 2026-08-18 (vs. a ~26-130/day baseline), corroborated by a same-day spike in lead create/update failures (3,764 vs. a 3-97/day baseline) — same signature as before (`UE-BFFAXIOS-ERROR-NEXUSSERVICE`, ~30,000ms timeout). Notably, 2026-08-18's own funnel numbers (LPV 346,421, LPV→Lead-Created 25.03%) show no aggregate conversion degradation despite this — the customer-level recovery-check (cross-referencing affected customer_ids against `lead_history_snapshot_v3`) could not be run this refresh since it needs Trino; flagged as the top follow-up for next refresh. Full detail in `dashboard-data.json`'s `landing_page_errors.backend_errors.incident_finding`.

## AI Funnel Trend section (added 2026-08-17)

Added to the Overview page, directly under Full Funnel Detail and above Stage Anomalies: a 3-line
trend chart (LPV→Lead Created %, Lead Created→BRE1 Success %, BRE1 Success→KYC In Progress %) plus 3
AI-insight cards, one per series. **Scope: OVERALL cohort only, Open Funnel basis, 2026-08-10 to
2026-08-16 (7 days)** — does not cover Marketplace/Non-Marketplace splits or the Closed Funnel view.
Data lives in `dashboard-data.json`'s `ai_funnel_trend` key (mirrored into `dashboard.html`'s `DATA`
literal, same as every other section) and is rendered by `renderAiFunnelTrend()`. New CSS tokens
`--series-lpv-lc` / `--series-lc-bre1` / `--series-bre1-kyc` were added (all 3 `:root` blocks) to keep
this chart's colors distinct from the existing Marketplace/Non-Marketplace series tokens.

**Known limitations carried into every refresh:**
- Marketplace LPV is a floor, not a true count (gotcha #11).
- Marketplace-Closed ratios can look noisy at low-volume stages (small base).
- `PO_SURPLUS_REFUND` and the 5 servicing states are excluded from all counts — if a new unlisted `history_solutiontypelevel2` value appears, it will silently be INCLUDED (exclusion-list behavior) until gotchas.md is re-reconciled.
- **(added 2026-08-13)** PAN Prefill Rate, Prefill Source Breakdown, Campaign-wise LPV → Lead Creation, and the Trino half of Landing-Page Errors all read from `hive.paytm_dml_pulse_raw.*`, which can lag `hive.workflow_nexus` by ~1 day — these 4 sections' "latest day" may legitimately differ from the main funnel sections' latest day. Always check and state which date each section is actually showing.
- Prefill Source Breakdown's worst-day alerting has no usable baseline yet (only 2 days of history as of 2026-08-13) — re-evaluate once ≥5 days accumulate, same as the main anomaly detector needed ~8-10 days.
- Elasticsearch's `lending-postpaid-bff-fe-prod_indexer_*` has several root-level fields (`operation`, `operation_status`, `product_type`, `state`) that are present in `_source` but not queryable (gotcha #9 in `data-sources/elasticsearch/gotchas.md`) — all 3 new ES-backed sections work around this via `message`+`logger_name` text matching, which is more brittle to upstream message-copy changes than a field filter would be. If a section suddenly returns 0 after a service deploy, check whether the message text changed before assuming the underlying event stopped.
