# FDC Tool-Commonality Root-Cause Analyzer

`fdc_commonality_rca.py` is a single-file Python application. It reads wafer-level FDC context files, compares low-yield (BAD) wafers against reference (GOOD) wafers, and ranks the process tools, chambers and recipes most likely to explain the yield loss. The result is one self-contained HTML dashboard plus CSV tables for traceability.

The core question is the classic commonality question:

> Among the wafers with a yield problem, is there a tool, chamber or recipe they all (or disproportionately) passed through that the good wafers did not?

---

## 1. Quick start

```bash
pip install pandas numpy scipy scikit-learn plotly   # plotly is optional; see below

# Default: BAD = wafers starting with M900037, GOOD = wafers starting with M900011
python fdc_commonality_rca.py --input "data/*.txt"

# Explicit prefixes (comma-separated; lot or wafer prefixes both work)
python fdc_commonality_rca.py -i "data/*.txt" --bad M900037 --good M900011,M900015

# Or an explicit label file (columns: wafer,label with label = BAD / GOOD)
python fdc_commonality_rca.py -i "data/*.txt" --labels labels.csv --out RCA_Report.html
```

Plotly is only needed to **embed** the charting library into the HTML. If it is installed, the dashboard works fully offline. If not, the dashboard loads Plotly from the jsDelivr CDN instead.

### Command-line options

| Option | Default | Meaning |
|---|---|---|
| `--input / -i` | `*.txt` | One or more glob patterns for the tab-separated FDC files |
| `--bad` | `M900037` | Lot/wafer prefixes of low-yield wafers |
| `--good` | `M900011` | Lot/wafer prefixes of reference wafers |
| `--labels` | – | CSV `wafer,label`; overrides the prefixes |
| `--out` | `FDC_RCA_Dashboard.html` | Dashboard file |
| `--csv-dir` | `rca_outputs` | Folder for result tables (`''` to skip) |
| `--dcqv-threshold` | `0.97` | DCQV below this value counts as an FDC excursion |
| `--revisit-gap` | `2.0` | Hours between runs of the same stage/operation that count as a re-visit |
| `--top` | `15` | Number of suspects shown in the ranking charts |
| `--bootstrap` | `300` | Stability-selection resamples |
| `--seed` | `42` | Random seed (results are reproducible) |

### Input format

The input is tab-separated, one row per FDC context (wafer × tool module run), with these columns:

`equipment type, EQUIPMENTID, equipment, context id, FDCTYPE, MODULEID, MODULENAME, MOD_TYPE_NAME, RECIPEID, LOT, wafer, operation, DCQV, start time, stop time, ROUTE, STAGE`

---

## 2. Architecture

```
 TXT files ─► [1] Ingest & clean ─► [2] Route classification ─► process-path table
                                                                     │
          ┌──────────────────────┬───────────────────────┬───────────┴──────────┐
          ▼                      ▼                       ▼                      ▼
 [3] Commonality stats   [4] FDC health (DCQV)   [5] Flow anomalies     [6] Machine learning
  Fisher / Δ-coverage /   robust z, MWU,          rework, retest,        de-aliasing, L1
  substitution test /     Cliff's δ, peer-        untracked, revisits,   stability selection,
  AMI / Cramér's V        chamber baseline,       lot splits, Q-time,    Extra-Trees, LOO-CV,
                          excursion rate          confounding checks     decision rules
          └──────────────────────┴───────────┬───────────┴──────────────────────┘
                                             ▼
                              [7] Evidence fusion → ranked suspects + tiers
                                             ▼
                        HTML dashboard (self-contained)  +  CSV tables
```

| Stage | Function(s) | What it does |
|---|---|---|
| 1 Ingest | `load_fdc`, `assign_labels` | Validates columns, trims text, removes exact duplicates, parses DCQV, times and operation numbers, and derives `root_lot`, `family` (LIT/ETC/CMP/…) and `eqp_class` (vendor platform without model suffix). Labels wafers by prefix or label file. |
| 2 Routes | `classify_routes` | The most frequent route is the **main route**. Other rows are classified as REWORK, RETEST, WAT or UNTRACKED (`UNDEFINED`). Commonality runs on the main route only, so rework passes do not pollute the comparison. |
| 3 Commonality | `entity_long`, `commonality_table`, `is_substitution`, `stage_divergence` | Builds the wafer × stage × entity path table at three levels (TOOL, CHAMBER = tool::module, RECIPE = tool::recipe) and tests every entity. |
| 4 DCQV | `dcqv_analysis` | Compares FDC health at each stage/chamber between groups. |
| 5 Flow | `flow_anomalies`, `qtime_analysis`, `confounding_checks` | Profiles off-route activity and queue time, and flags study-design risks. |
| 6 ML | `build_feature_matrix`, `ml_analysis` | Multivariate check on the same evidence. |
| 7 Fusion | `fuse_evidence`, `collapse_siblings` | Produces one score per suspect, a confidence tier and a recommended engineering check. |
| Report | `build_figures`, `render_html` | Builds 13 Plotly charts, 5 tables, KPI cards, the verdict panel and the methodology section. |

---

## 3. Statistical and ML algorithms

### 3.1 Commonality statistics

These are computed for every (stage, entity) pair at the tool, chamber and recipe level.

- **Coverage:** `bad_cov = bad wafers that used it / all bad wafers`, `good_cov` likewise, and **Δ-coverage = bad_cov − good_cov**.
- **Fisher exact test** (one-sided, "bad uses it more"). This is exact for tiny samples, unlike chi-square. Benjamini–Hochberg **FDR q-values** are reported for the multiplicity of more than 3,000 tests.
- **Haldane-corrected odds ratio** and **commonality ratio** (`bad_cov / overall_cov`).
- **Substitution test** (`is_substitution`). An entity used by every bad wafer and no good wafer falls into one of two cases:
  - **SUBSTITUTED (head-to-head):** the good wafers ran the *same kind of process* at that stage (same equipment class, and for chambers the same module type) on a *different* tool or chamber. This is the cleanest evidence.
  - **EXTRA / UNLOGGED:** the good wafers have no equipment of that class at that stage. Either the bad lot had an extra step, or the good lot's records are missing. This is weaker evidence.
- **Categories:** `SUBSTITUTED`, `EXTRA/UNLOGGED`, `ALL-BAD COMMON` (every bad wafer and some good wafers), `BAD-ENRICHED`, `COVERAGE GAP` (stage never recorded on good wafers), and `NEUTRAL / GOOD-ENRICHED`.
- **Commonality score:**
  `100 × Δ-coverage × evidence × category_weight × level_weight`
  - `evidence = log p / log p_min`, where `p_min` is the best Fisher p attainable with this sample size.
  - Category weight: substitution 1.0, extra 0.55, coverage gap 0.35.
  - Level weight: recipe 0.75, because recipe-ID changes are often version bumps.
- **Stage divergence:**
  - **Adjusted mutual information (AMI)** between each wafer's chamber path at a stage and its label. AMI is *chance-corrected*, so track/cluster tools that give every wafer a unique module sequence do not falsely score 1.0, which raw Cramér's V would.
  - **Cramér's V** on the coarser tool-level path is reported alongside.

### 3.2 FDC health (DCQV)

- For each stage/chamber the analysis uses the per-wafer **minimum DCQV**, where DCQV is the FDC data-collection quality / health index and 1.0 is ideal.
- **Robust z** = (bad median − good median) / scale, with `scale = max(MAD, IQR/1.349, 0.005)`. The floor stops quantised DCQV values from producing absurd z-scores.
- **Peer-chamber baseline.** If the good wafers never used a chamber (which is exactly the substitution case), the bad wafers' DCQV is compared with the good wafers' *peer chambers of the same module type at the same stage*. These rows are marked † in the dashboard.
- **Mann-Whitney U** and **Cliff's δ** (non-parametric, small-sample safe).
- A chamber is flagged **Degraded** when z ≤ −3, every bad value is below the good minimum, and at least two bad wafers are affected.
- The **excursion rate** per tool and group counts the share of records with DCQV below the threshold.
- **Wafer-level health:** mean DCQV and excursion rate per wafer, tested with a one-sided Mann-Whitney U.

### 3.3 Process-flow anomalies

- **Event counts:** rework, retest and WAT events are counted as distinct (route, operation) pairs. Untracked runs are distinct (tool, start) pairs on the `UNDEFINED` route.
- **Stage re-visits:** the same stage *and operation* run again more than `--revisit-gap` hours later. This catches litho re-exposure and re-processing.
- **Lot IDs** per wafer reveal split and merge activity.
- **Q-time:** idle hours between the last stop of the previous stage and the first start of the next one. Medians are compared per stage.
- **Confounding checks:** whether all bad wafers come from one lot, whether the processing windows of the two groups overlap, and the minimum attainable p-value (statistical power).

### 3.4 Machine learning

| Step | Method | Why |
|---|---|---|
| Features | Binary pass flags (tool/chamber/recipe), complete-case per-chamber DCQV, flow counts | Same evidence, viewed jointly |
| **De-aliasing** | Columns with identical wafer patterns are merged into *alias groups* | With few wafers, hundreds of features are statistically identical. Reporting this honestly is essential. |
| **Stability selection** | L1-logistic regression over 300 stratified bootstraps × random 50% feature subspace × random C ∈ [0.05, 1] | Finds features selected robustly, not by chance. Randomised-lasso style. |
| **Extra-Trees** | 1,000 trees, class-balanced, impurity importance | Non-linear and interaction-aware ranking |
| **LOO-CV** | Leave-one-out balanced accuracy for both models | Checks that the groups are genuinely separable |
| **Decision rules** | Depth-2 decision tree, printed as text | Human-readable separating rule |

### 3.5 Evidence fusion and confidence tiers

```
RCA score = 100 × ( 0.40 · commonality/100
                  + 0.20 · DCQV degradation  (clip(−z/6, 0, 1))
                  + 0.15 · cross-stage recurrence of the same tool/chamber  (clip((n_stages−1)/3, 0, 1))
                  + 0.15 · stability-selection frequency
                  + 0.10 · normalised Extra-Trees importance )
```

**Tiers:**

- **HIGH:** head-to-head tool or chamber substitution.
- **MEDIUM:** recipe substitution, extra or unlogged step, all-bad common, or strong DCQV degradation.
- **LOW:** everything else.

Sibling chambers or recipes of the same tool with an identical wafer pattern (for example four CMP cleaner modules) are merged into a single finding. Each suspect gets an equipment-family-specific recommended check (litho, etch, CMP, PVD, CVD, wet, implant, furnace).

---

## 4. The dashboard

| Section | Content |
|---|---|
| KPI cards | Wafers, records, entities tested, head-to-head substitutions, separating stages, degraded chambers, off-route moves, wafer DCQV health, ML accuracy |
| Prime-suspect verdict | Rank #1 entity, evidence chips, what the good wafers used, recommended check, five more implicated entities |
| Read before acting | Automatic confounding and statistical-power warnings |
| Root-cause candidate table | Top 20 suspects with tier, category, Fisher p, stability, DCQV z, RCA score and action |
| Head-to-head substitution table | For each stage in route order: bad-wafer path vs good-wafer path |
| Charts 1–13 | Fused ranking · coverage plane · AMI along the flow · wafer × suspect matrix · DCQV boxes · excursion rate · process timeline · flow anomalies · Q-time · path similarity · stability selection · Extra-Trees importance · data coverage |
| Tables | DCQV chamber statistics, decision-tree rules, wafer summary, methodology |

Every chart has a **"What it shows / How to read it / Finding"** panel, and the finding text is generated from the data. All charts are interactive: hover for evidence, zoom, pan and export PNG.

**CSV outputs** (written to `rca_outputs/`):

- `rca_ranking.csv`
- `commonality_all_entities.csv`
- `stage_divergence.csv`
- `dcqv_chamber_stats.csv`
- `dcqv_excursion_by_tool.csv`
- `wafer_flow_anomalies.csv`
- `qtime_by_stage.csv`
- `ml_feature_groups.csv`

---

## 5. Results on the supplied data (2 bad wafers, M900037; 6 good wafers, M900011)

**Data:** 3,693 FDC records, 94 tools and 148 stages. Of these stages, 89 were recorded on both groups, 26 only on bad wafers and 26 only on good wafers.

**Leading hypothesis: PVD barrier/seed tool `ASSBA2` (PVD_AMAT_ENDURA_CGMA_BS), pre-clean chamber D**

- Both bad wafers ran their Cu barrier/seed pre-clean in **chamber D** at three stages: **TMECU1_SPU1, ME3CU1_SPU1 and ME4CU1_SPU1**. All six good wafers used **chamber C** at those stages.
- It is a head-to-head chamber substitution that recurs at three stages.
- At ME2CU1_SPU1, where the bad wafers did use chamber C, the bad-wafer DCQV on `ASSBA2` was clearly worse than the good-wafer baseline (robust z ≈ −4; one bad wafer's pre-clean at 0.958). `ASSBA2` also shows a 5% DCQV excursion rate on bad wafers versus 0% on good wafers.
- A poor pre-clean before barrier/seed leads to high via resistance and opens, which is a plausible yield killer.

**Other head-to-head substitutions (HIGH tier)**

- `PA2CU1_PH2` pad lithography ran on the **i-line** scanner/track (`APILA1`/`APILT1`) instead of **KrF** (`APKRA1`/`APKRT1`). This could be a route or flow change for the bad lot and is worth confirming with process integration.
- `ME2CU1_CMP1` polished on **AMCUE1 POL_C/POL_D** instead of POL_A/POL_B.
- `TSVPA1_ET1` and `PA2CU1_ET3` etched in **AEPAA3 chamber A** instead of chamber B or C.
- `ME1OX2_DP1` and `ME2OX3_DP1` ran on CVD **ACEKA1** instead of ACCRA1.
- `SALI1_DP1` used **ASNIA1 chambers 4/D** instead of 1/C.

**Supporting flow signals**

- **Off-route activity:** the bad wafers had about 27 untracked runs each versus 3 for good wafers, 5 retest moves versus 1, and 8–10 lot IDs (heavy splitting) versus 1.
- **FDC health:** wafer-level mean DCQV was 0.9949 for bad wafers versus 0.9968 for good wafers.

**Read before acting**

- Both bad wafers come from **one lot**, and the two groups were processed in **non-overlapping windows** (bad: June–July 2026; good: April–May 2026).
- With 2 bad vs 6 good wafers the best attainable Fisher p is **0.036**. Many entities are aliased: 3,245 features collapse into 181 distinguishable patterns.
- The ranking is therefore a prioritised list of hypotheses. Confirm it by:
  1. Pulling ASSBA2 chamber-D PM, pre-clean etch-rate and Rs monitors for June–July 2026.
  2. Checking yield on other lots that went through ASSBA2-D versus ASSBA2-C.
  3. Adding more bad and good lots from overlapping time windows and re-running the tool.

---

## 6. Extending the tool

- **Continuous yield:** add a `yield` column to the labels file and replace the Fisher test with ANOVA, Kruskal–Wallis or η² per stage in `commonality_table`. The rest of the pipeline is unchanged.
- **Fusion weights:** `W_COMMONALITY`, `W_DCQV`, `W_RECUR`, `W_STABILITY` and `W_FOREST` at the top of the file.
- **Comparability weights:** `CATEGORY_WEIGHT` and `LEVEL_WEIGHT`.
- **Recommended actions:** `FAMILY_ACTIONS`, keyed by the first token of `equipment type`.
- **Theme:** the `C` dictionary for chart colours and the `CSS` string for page styling.
