# LOC Daily Funnel Dashboard

Postpaid (Line of Credit) daily funnel dashboard — hosted via Netlify from this repo's root `index.html`.

## Layout

- **`index.html`** — the live dashboard Netlify serves. Canonical source is `postpaid-funnel-daily-dashboard/dashboard.html`; keep them in sync on every update.
- **`postpaid-funnel-daily-dashboard/`** — full working folder: the dashboard HTML (`dashboard.html` plus `-v2`/`-v3` republish mirrors and an older `-local` variant), every Trino/Elasticsearch query used to build each section, and `README.md` with the full daily-refresh runbook (data sources, known gotchas, incident history, refresh procedure).
- **`data/dashboard-data.json`** — the live data snapshot embedded into `index.html`'s `DATA` literal on each refresh. Rolling file, overwritten each refresh, not a dated point-in-time pull.

## For contributors

Read `postpaid-funnel-daily-dashboard/README.md` first — it documents the query methodology, several past incidents (data/render bugs and how they were caught), and the exact refresh procedure. Anomaly-detection methodology is in `postpaid-funnel-daily-dashboard/anomaly-methodology.md`.
