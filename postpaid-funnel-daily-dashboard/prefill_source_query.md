# Prefill Source query template (Elasticsearch) — SUPERSEDED 2026-08-17

**This file is no longer used by the dashboard.** The "Prefill Source Breakdown" section now runs
entirely on Trino — see `pan_source_query.sql` (`hive.paytm_dml_pulse_raw.screen_action_snapshot_v3`,
`event_action='pan_source'`, `event_label6`='CIF'/'KYB'). That table is the SAME source as
`pan_prefill_query.sql`'s "prefilled" bucket, and a same-day cross-check (2026-08-15) showed it matches
that bucket to 99.8% — this Elasticsearch `PrefillingService` approach, by contrast, only ever covered
~20-34% of same-day LPV, a materially different (and far less complete) population. Two independent
correction rounds on this file (2026-08-14 fixing which ES operation to read, 2026-08-17 fixing the
percentage denominator) both turned out to be fixing the wrong tracking system rather than the wrong
detail within it. Kept below for historical/investigative reference only — do not point the dashboard
back at this without first re-establishing why Trino's `pan_source` event isn't sufficient.

---

Index: `lending-postpaid-bff-fe-prod_indexer_{{DATE}}` (one index per approximately-UTC date — see the
day-boundary gotcha below, this is NOT an IST-aligned partition and must not be queried alone for a
single IST calendar day).

## Correction (2026-08-14) — this file previously pointed at the wrong operation entirely

The original version of this file scoped to `FETCH_PAN_INFO` / `ToolsService`, returning a `source`
value of `CACHE` or `SIGNZY`. The PM who owns this product flagged that as wrong: CACHE/SIGNZY is a
**PAN validation lookup** (checking a PAN's status via a cache hit or the Signzy KYC vendor), not
**prefill sourcing** (where the PAN value that pre-populated the form field actually came from).

The correct operation is `FETCH_PREFILLING`, logged by `PrefillingService`, message `"Prefilling data
fetched successfully"`. Its payload carries **per-field** source attribution directly:

```json
{"dob":"2002-06-14","pan":"OGTPS1372G","panSource":"KYB","dobSource":"CIF","nameSource":"KYB","emailSource":"CIF","pincodeSource":"LDPS", ...}
```

`panSource` is the field this dashboard section reports on. Confirmed values as of 2026-08-14: `CIF`,
`KYB`. When PAN wasn't prefilled at all, the `pan` field is empty and `panSource` is absent from the
payload entirely — bucket this as `NOT_PREFILLED`, not as a data gap.

Do not use `FETCH_PAN_INFO`/`ToolsService`/`CACHE`/`SIGNZY` for this section again — that data still
exists and is real, it just answers a different question (PAN validation vendor split, not prefill
source). If a future ask wants that split too, it deserves its own section, not a merge into this one.

## Critical gotcha #1 — root-level fields are NOT indexed on this index

`operation`, `operation_status`, `product_type`, `state`, `product_id` appear at the **document root**
in `_source` (retrievable), but are **not queryable** via `term`/`exists`/`terms`-agg — confirmed live
2026-08-13, reconfirmed 2026-08-14 (`FETCH_PREFILLING` as a `term`/`match`-on-keyword filter also
returns empty; only `logger_name` and `message` reliably filter). Do not build a query around
`{"term": {"operation": "..."}}` — it silently returns zero hits, not an error.

What IS reliably queryable:
- `message` (analyzed text) — `match_phrase` works
- `logger_name` / `logger_name.keyword`
- `@timestamp` (for date_histogram / range — see gotcha #2, this is the one to use for day-boundaries,
  NOT the per-day index name)
- `context.customer_id` / `context.customer_id.keyword`
- `context.domain.postpaid-bff.details` — a JSON-encoded **string**, not a nested object. Not
  practically filterable field-by-field via term queries, but a **scripted terms aggregation** with a
  regex extraction works reliably (see query below) — this is more precise than the old
  match_phrase-on-two-adjacent-tokens trick used for the CACHE/SIGNZY version of this file, because it
  extracts the actual field value rather than approximating a phrase match.

## Critical gotcha #2 — the per-day index name is NOT IST-aligned

Confirmed live 2026-08-14: querying `lending-postpaid-bff-fe-prod_indexer_2026-08-12` alone for the
`PrefillingService` message returned 64,062 matching docs. Running the same query as a
`date_histogram` with `time_zone: "Asia/Kolkata"` across the **wildcard** index pattern
(`lending-postpaid-bff-fe-prod_indexer_2026-08-*`) for the true IST calendar day 2026-08-12 returned
136,527 — more than double. The per-day index boundary is evidently UTC-based (or some other
non-IST cutover), not the IST calendar day this dashboard reports everything else on.

**Always query the wildcard pattern with an explicit `@timestamp` range or `date_histogram` +
`time_zone: Asia/Kolkata`, never a single day's index by name, for this section.**

## Query — panSource distribution, single IST day

```json
GET lending-postpaid-bff-fe-prod_indexer_2026-08-*/_search
{
  "size": 0,
  "query": {
    "bool": {
      "must": [ { "match_phrase": { "message": "Prefilling data fetched successfully" } } ],
      "filter": [ { "range": { "@timestamp": { "gte": "{{DAY}}T00:00:00+05:30", "lt": "{{NEXT_DAY}}T00:00:00+05:30" } } } ]
    }
  },
  "aggs": {
    "pan_source": {
      "terms": {
        "script": {
          "lang": "painless",
          "source": "def s = params._source.context.domain['postpaid-bff'].details; def m = /\"panSource\":\"([A-Za-z]+)\"/.matcher(s); if (m.find()) { return m.group(1) } else if (s.indexOf('\"pan\":\"\"') >= 0) { return 'NOT_PREFILLED' } else { return 'OTHER' }"
        },
        "size": 10
      }
    }
  }
}
```

## Query — 7-day trend (date_histogram, IST-aligned)

```json
GET lending-postpaid-bff-fe-prod_indexer_2026-08-*/_search
{
  "size": 0,
  "query": {
    "bool": {
      "must": [ { "match_phrase": { "message": "Prefilling data fetched successfully" } } ],
      "filter": [ { "range": { "@timestamp": { "gte": "{{START_DATE}}T00:00:00Z", "lte": "{{END_DATE}}T23:59:59Z" } } } ]
    }
  },
  "aggs": {
    "by_day": {
      "date_histogram": { "field": "@timestamp", "calendar_interval": "day", "time_zone": "Asia/Kolkata" },
      "aggs": {
        "pan_source": {
          "terms": {
            "script": {
              "lang": "painless",
              "source": "def s = params._source.context.domain['postpaid-bff'].details; def m = /\"panSource\":\"([A-Za-z]+)\"/.matcher(s); if (m.find()) { return m.group(1) } else if (s.indexOf('\"pan\":\"\"') >= 0) { return 'NOT_PREFILLED' } else { return 'OTHER' }"
            },
            "size": 10
          }
        }
      }
    }
  }
}
```

MTD uses the same shape as the single-day query, with the range widened to the month-to-date window
(no `date_histogram` needed if only the aggregate total is wanted — the edge-day imprecision from
gotcha #2 is proportionally small across a multi-week range and can be left as-is for MTD, but always
use the IST-corrected day_histogram version for the single "latest day" headline number, since that's
the figure most likely to be scrutinized).

## Correction (2026-08-17) — percentages were denominated on raw attempts, not LPV

The PM flagged that CIF_pct/KYB_pct/NOT_PREFILLED_pct on the dashboard were `source_doc_count /
total_attempts_doc_count` — i.e. a raw ES event count as both numerator and denominator. Two problems
with that: (1) `total_attempts` is a doc count, not distinct customers, so a customer who retries the
call gets counted multiple times; (2) it's not tied to LPV, so the split answers "of the times this API
was called, what fraction resolved via CIF/KYB" rather than "of everyone who landed, what fraction got
PAN via CIF/KYB" — which is what the dashboard's own labeling implied and what the sibling "PAN Prefill
Rate" section above it already does correctly (`prefilled / LPV`).

Fixed by adding a `cardinality` sub-aggregation on `context.customer_id.keyword` inside each `pan_source`
terms bucket, then dividing that distinct-customer count by same-day LPV (from
`daily_open.OVERALL.00_LPV` in `dashboard-data.json`, the same figure the main funnel table uses) instead
of by `total_attempts`:

```json
"aggs": {
  "pan_source": {
    "terms": { "script": { /* same panSource extraction script as below */ }, "size": 10 },
    "aggs": {
      "distinct_customers": { "cardinality": { "field": "context.customer_id.keyword" } }
    }
  }
}
```

Read `distinct_customers.value` per bucket as the numerator; `doc_count` per bucket is retained as
`*_events` for retry-volume visibility but must not feed a percentage. For MTD, run this as ONE query
over the full range rather than summing daily distinct-customer counts — summing per-day cardinalities
double-counts a customer active on more than one day.

Net effect on the numbers: percentages dropped roughly 5x (e.g. 2026-08-12 CIF share went from 40.4% of
attempts to 8.54% of LPV) because most LPV traffic never reaches the PrefillingService call at all — see
`coverage_pct` in the dashboard data (CIF + KYB + NOT_PREFILLED distinct customers, as a share of LPV).
That ties out against the main funnel: 2026-08-16 coverage (33.8%) tracks its LPV→Lead Created conversion
(24.65%), consistent with this event firing around the Lead Creation step, not at LPV.

## `OTHER` bucket

Watch the `OTHER` bucket (payload didn't match the regex and wasn't an empty-PAN case) on every
refresh — if it's more than a rounding error, the regex or the empty-PAN check needs revisiting, not
silently absorbed into one of the two known sources.

## Worst-day alerting

Same rule as `anomaly-methodology.md` (>=15pp AND >=20% relative move vs. baseline median of other
available days). As of 2026-08-14, 7 days of history are available (08-06 to 08-12) — still short of
the 8-10 day minimum the main funnel anomaly detector required before trusting a baseline. Re-enable
once more days accumulate. The 7-day read so far: CIF share has drifted down (45.3% -> 40.4%) while
NOT_PREFILLED has risen correspondingly (46.5% -> 52.2%); KYB has stayed flat. Looks like a gradual
trend worth watching, not a single-day anomaly.
