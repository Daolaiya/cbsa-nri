# NRI TBML / Anomaly - Pending Follow-ups

Working notes for deferred work. Not part of the deliverable notebooks.

## 1. REQ_VERS_NBR de-duplication (highest priority)
- Re-transmitted declarations repeat all their lines under the same `CLNT_SPLY_REQ_ID` with a higher `REQ_VERS_NBR`, so summing across versions double-counts value and inflates `LINE_CNT` / counts.
- Belongs in **Notebook 1 (NRI_2) foundation** - the `base` CTE of `TXN_TABLE` and the source scans for features / IND_SRC. Both notebooks inherit the fix; then re-run NRI_2 (REBUILD) and NRI_3.
- Netezza-safe approach (no correlated subquery): build a `latest` CTE = `MAX(REQ_VERS_NBR)` per key, then `JOIN ... AND s.REQ_VERS_NBR = l.MAX_VERS`.
- Verify BEFORE implementing:
  - **Key scope:** is the version per `CLNT_SPLY_REQ_ID` or per `DRV_REQ_NBR`?
  - **Dtype:** numeric vs zero-padded string vs `'NULL'`/empty (need NULLIF/TRIM/cast guard).
  - **Magnitude:** count of keys with >1 distinct version. If tiny, low priority.
  - Confirm a higher version fully replaces the prior (standard amendment semantics).

## 2. Data window + re-tune thresholds (NRI_3)
- **Confirmed:** dominant arrival window is **2025**; avg tenure ~178 days (~single-year slice).
- Consequence: two anomaly rules are structurally near-dead until thresholds change:
  - `A_REACTIVATION` = 0 because `REACTIVATION_DAYS = 365` exceeds the window. Lower to ~120.
  - `A_VOLUME_SPIKE` ~ 0 because monthly z is capped at ~sqrt(11) ~ 3.32 with <=12 months; threshold 3.0 is at the ceiling. Lower to ~2.5 or use a ratio metric (peak month / median month).
  - `NOVELTY_GRACE_DAYS = 180` ~ avg tenure, so ~half of entities can never trigger novelty. Lower to ~90.

## 3. Combined TBML + anomaly view (capstone)
- Join `OADM.TBML_T_NRI_RISK_MATRIX_M` (TBML) with `OADM.TBML_T_NRI_ANOM_PROFILE_M` (anomaly) on `BN_9`.
- Entities high on both typology indicators and behavioral anomalies are the strongest referrals.
- ML/rule overlap is already in NRI_3 (~60 of 75 ML outliers also RULE_SCORE>=2; varies run to run).

## 4. I11 Inconsistent Lines of Trade - threshold vs FATF definition
- FATF document defines this indicator as trading in **more than one** HS section (i.e. `DISTINCT_SECTIONS >= 2`).
- Current code flags at `DISTINCT_SECTIONS >= SECTIONS_FLAG_MIN` with `SECTIONS_FLAG_MIN = 3` - a deliberate noise-reduction choice, stricter than the document.
- This run: **34.6%** flag rate at >=3 sections.
- Decide later whether to (a) keep 3 (fewer, higher-confidence flags) or (b) set it to 2 to match the document literally; possibly expose both and compare flag rates.
- Lives in NRI_2: `SECTIONS_FLAG_MIN` in the indicator-settings cell, used in the `I11_LINES_OF_TRADE` assignment.

## 5. Add omitted FATF indicators where feasible
- **I6 One-to-One Relationship** - feasible from this data (count distinct vendor-importer relationships each side; flag pairs that trade almost exclusively with each other). No quantity/UOM needed. Best near-term add to NRI_2.
- **I12 Vague Descriptions** - needs goods-description text analysis (char/token counts, bottom 25%). Requires a clean description field; assess availability/noise first.
- **I1 Miscalculations / I2 Inconsistent Prices** - blocked: need reliable per-unit quantity/UOM, which this dataset lacks. Revisit only if a cargo/quantity source is joined in.
- **I13-I15 (non-scalable)** - need company-registry data (addresses, directors/agents, owner info); out of scope unless that data is sourced.

## 6. Benford on declared currency — done (NRI_2)
- I4/I5 Benford use **transaction-level declared value** (`TXN_VALUE_DECL`) for official flags; CAD Benford kept as reference (`BENFORD*_MAD_CAD`, `I4_BENFORD1_CAD`, `I5_BENFORD2_CAD`).
- `TXN_TABLE` stores `TXN_VALUE_DECL`, `DECL_CCY`, `IS_MIXED_CCY_TXN`. Declared total is summed only when all lines in a transaction share one currency; mixed-currency transactions are excluded from official Benford.
- **Verified** in full NB1 re-run: declared flagged **3,386** / **3,202**; CAD reference **3,408** / **3,168**; ~25,220 mixed-ccy txns excluded from declared Benford.
- **Optional refinements later:**
  - Per-currency Benford within entity if mixed-currency pooling is still too noisy.
  - Tune MAD thresholds if declared flag rate shifts materially on a new data slice.
  - When `DECL_CCY='CAD'`, declared and CAD test the same currency; residual differences are from FX conversion on multi-line totals, not currency mismatch.

## 7. Flag combination analysis — done (NRI_2)
- Subsection below "Save the risk matrix": single flags and k-flag co-occurrences (k = 2 … 8), ranked by count.
- **Verified** in full NB1 re-run: max `FLAG_COUNT` = 6; k = 7 and k = 8 tables all zeros; top pair I4+I5 (3,100 importers).
- Lift/association deferred.

## 8. Smaller items
- Reconcile entity counts across steps: **19,366** (txn table) vs **19,367** (consolidator source scan) vs **~19,355** (NRI_3 baselines — re-run NB3 after NB1 rebuild). Different grains; ~11-entity spread is negligible but confirm none are dropped unexpectedly (e.g. null BN_9 / below `MIN_TXNS_BASELINE`).
- **Basel unmatched vendor countries — done:** UM, TK, JE, FO, AS, NC (**14 lines** total); absent from Basel file, default low-risk.
- **754** source lines with null/blank/`'NULL'` `PRICE_VAL_TOTAL` — negligible; documented in NB1 source-QA cells.
- Novelty may over-fire for naturally diverse/generalist importers (high HS-chapter counts); consider normalizing by diversity rather than raw counts.
- Tiny-value transactions ($0.01-$1.40) dominate the negative value-z tail; likely data-quality artifacts - eyeball before treating as signal.
- Optional: replace the single global `REBUILD` boolean with a set/dict of build targets + `should_build(key)` for selective rebuilds.
- ML layer now active (scikit-learn installed); robust median/MAD variant of `VALUE_Z` is a possible refinement.
- NRI_3 ML overlap count is run-to-run variable (IsolationForest randomized); consider setting `random_state` for reproducibility before quoting exact figures. (Note: `random_state=42` is already set; the small variation is from `contamination="auto"` / data, not the seed - confirm.)
- **I9 Rounded - cents dropped before MOD test (NRI_2):** the check does `MOD(CAST(ROUND(value) AS BIGINT), 1000)=0`, so `ROUND` discards cents and e.g. `$1,000.37 -> 1000` is counted as round-1000 (over-counts roundness). For strict exact-multiple semantics, test cents-inclusive, e.g. `MOD(CAST(ROUND(value*100) AS BIGINT), 100000)=0` for round-1000, or require the decimal part to be `.00`. The `DOUBLE -> ROUND -> BIGINT` chain itself is required because `PRICE_VAL_TOTAL` is text and Netezza `MOD` needs integer operands.
