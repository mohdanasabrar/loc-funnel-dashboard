# Stage-level anomaly detection — methodology

Added 2026-08-11 per PM request: flag day-level drops/gains at the individual funnel-stage level,
then root-cause via Elasticsearch where possible, then recommend.

## Detection rule (transparent, not a black box)

For each stage *s* (02..26 — stage 01 has no "previous stage" to convert from) and each day *d* in
the available window, compute the stage-over-previous-stage conversion % (Overall cohort, Open Funnel
basis — the least noisy of the four table/cohort combinations):

```
conv(s, d) = customers(s, d) / customers(s-1, d) * 100
```

Compute the median of `conv(s, d)` across all OTHER available days for that same stage — call it
`baseline(s)`. Flag day *d* for stage *s* as an anomaly if:

```
abs(conv(s, d) - baseline(s)) >= 15 percentage points
   AND
abs(conv(s, d) - baseline(s)) / baseline(s) >= 0.20   -- i.e. also a >=20% relative move
```

Both conditions must hold — this avoids flagging small-percentage-point moves on already-low-conversion
stages (e.g. a 2pp move on a 5% stage is a 40% relative move and IS worth flagging) while also avoiding
flagging trivial relative moves on high-conversion stages (e.g. 100.0% -> 100.6% is a 0.6% relative move
and should NOT be flagged even though every basis point is "different").

With only 8-10 days of history available (grows daily), this is a threshold rule, not a statistical
model (z-scores need more history than we have to be meaningful) -- re-evaluate once 30+ days of
history accumulate.

## Root-cause attempt (per flagged anomaly)

1. Identify which backend API / lender call the stage's `history_tostate` transition depends on
   (see `knowledge/errors/mapping.md`).
2. Query Elasticsearch (`lending-postpaid-workflow-nexus-prod_indexer_<date>` and
   `lending-postpaid-bff-fe-prod_indexer_<date>`) for `level: error` docs on that exact date, filtered
   to error codes/messages known to affect that dependency (from the mapping doc), NOT a raw
   highest-volume-error-code scan -- the highest-volume codes are dominated by unrelated servicing/
   scheduler-retry noise (confirmed 2026-08-11: `LOS-NEXUS-EXT-11070` and `LOS-NEXUS-VAL-11120`, the
   two largest error codes by volume across Aug 1-10, are SSFB account-summary/statement timeout and
   a scheduler retrying an already-failed lead -- both servicing-side, unrelated to onboarding-stage
   drops).
3. Cross-check unique `leadId`/`custId` count for the matched error, not just raw doc count (gotcha #5
   — one stuck lead can retry hundreds of times and look like mass impact).
4. Only report a root cause if the affected-lead volume from the error is a plausible match for the
   size of the funnel drop, AND the error's date/time distribution concentrates around the drop (not
   spread evenly across the whole window, which would suggest a baseline nuisance rather than a cause).
5. If no matching signal is found, report **"cause not identified"** explicitly. Do not infer a cause
   from correlation-by-date-only without a matching error signature and volume.

## Known non-causes (checked, ruled out, don't re-investigate every refresh)

- `LOS-NEXUS-EXT-11070` (SSFB `GetAccountSummary`/`GetLatestStatementSummary` timeout) -- servicing/
  status-polling only, not an onboarding funnel gate.
- `LOS-NEXUS-VAL-11120` (`TM account ID is empty`) -- post-activation scheduler job, not onboarding.
- `LOS-NEXUS-EXT-00111` (`callCreateOrUpdateAPI: stateUpdate` on already-`INITIATE_KYC_VALIDATION_FAILED`
  leads) -- scheduler retry noise on leads that already failed; downstream of the real cause, not the
  cause itself.
