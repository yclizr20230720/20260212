#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FDC Tool-Commonality Root-Cause Analyzer
=========================================

Finds the process tool / chamber / recipe that low-yield ("bad") wafers share
and high-yield ("good") wafers do not, by combining four independent lines of
evidence:

    1. Commonality statistics   - coverage, delta-coverage, Fisher exact test,
                                  odds ratio, BH-FDR, stage-level Cramer's V
    2. FDC health (DCQV)        - per-chamber robust z-score, Mann-Whitney U,
                                  Cliff's delta, excursion-rate comparison
    3. Process-flow anomalies   - rework / retest / untracked runs, stage
                                  re-visits, lot splits, Q-time between stages
    4. Machine learning         - feature de-aliasing, L1-logistic stability
                                  selection, Extra-Trees importance, LOO-CV,
                                  shallow decision-tree rules

The four are blended into one ranked suspect list and written to a single,
self-contained HTML dashboard (plus CSV tables for traceability).

Input: tab-separated FDC context files with the columns
    equipment type, EQUIPMENTID, equipment, context id, FDCTYPE, MODULEID,
    MODULENAME, MOD_TYPE_NAME, RECIPEID, LOT, wafer, operation, DCQV,
    start time, stop time, ROUTE, STAGE

Usage:
    python fdc_commonality_rca.py --input "data/*.txt" --bad M900037 --good M900011
    python fdc_commonality_rca.py --input "data/*.txt" --labels labels.csv

Author : FDC Yield Engineering toolkit
License: internal use
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import html
import json
import math
import os
import sys
import warnings
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd
from scipy import stats

warnings.filterwarnings("ignore")

try:  # ML layer is optional - the statistical engine runs without it
    from sklearn.ensemble import ExtraTreesClassifier
    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import LeaveOneOut
    from sklearn.preprocessing import StandardScaler
    from sklearn.tree import DecisionTreeClassifier, export_text
    HAS_SKLEARN = True
except Exception:  # pragma: no cover
    HAS_SKLEARN = False

__version__ = "1.0.0"

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
COLMAP = {
    "equipment type": "eqp_type", "EQUIPMENTID": "eqp_id", "equipment": "tool",
    "context id": "ctx_id", "FDCTYPE": "fdc_type", "MODULEID": "module_id",
    "MODULENAME": "module", "MOD_TYPE_NAME": "module_type", "RECIPEID": "recipe",
    "LOT": "lot", "wafer": "wafer", "operation": "operation", "DCQV": "dcqv",
    "start time": "start", "stop time": "stop", "ROUTE": "route", "STAGE": "stage",
}
REQUIRED = ["equipment", "MODULENAME", "RECIPEID", "wafer", "STAGE", "ROUTE", "start time"]

LEVELS = ["TOOL", "CHAMBER", "RECIPE"]

# Evidence weights used to blend the four lines of evidence into one score
W_COMMONALITY, W_STABILITY, W_FOREST, W_DCQV, W_RECUR = 0.40, 0.15, 0.10, 0.20, 0.15

# Equipment-family hints used to write the recommended action for a suspect
FAMILY_ACTIONS = {
    "LIT": "Pull scanner/track logs for this pass: focus/dose, overlay and CD-SEM results; "
           "compare the resist/coat-develop modules against the tool the good wafers used.",
    "ETC": "Review chamber FDC traces (RF power, pressure, endpoint time, ESC He leak) and the "
           "last PM / wet-clean date; check etch-rate and particle monitor for this chamber.",
    "CMP": "Check head/platen pad life, slurry flow and endpoint traces; compare dishing/erosion "
           "and post-CMP defect scans against the good-wafer polish heads.",
    "PVD": "Check target life, pre-clean etch amount, degas temperature and Rs uniformity; "
           "look for arcing counts in the chamber FDC trace.",
    "CVD": "Check film thickness/RI/stress monitors, showerhead clean counter and chamber "
           "seasoning after the last PM.",
    "WET": "Check bath life / chemical concentration, megasonic power and particle adders for "
           "this tank or spin chamber.",
    "IMP": "Verify dose/energy logs, beam-current stability and Rs/TW monitors for the run; "
           "check for implant species cross-contamination.",
    "FNC": "Check boat slot position, temperature profile and ramp logs; review particle and "
           "thickness monitors of this furnace run.",
}
DEFAULT_ACTION = "Review FDC traces, PM history and inline monitors for this entity."

# Dark "fab control room" theme (validated dark-surface steps of the reference palette)
C = {
    "surface": "#1a1a19", "page": "#0d0d0d", "ink": "#ffffff", "ink2": "#c3c2b7",
    "muted": "#898781", "grid": "#2c2c2a", "axis": "#383835",
    "good": "#3987e5", "bad": "#d95926",
    "aqua": "#199e70", "violet": "#9085e9", "magenta": "#d55181", "yellow": "#c98500",
    "red": "#e66767", "green": "#008300",
    "crit": "#d03b3b", "warn": "#fab219", "serious": "#ec835a", "ok": "#0ca30c",
}
LEVEL_COLOR = {"TOOL": C["aqua"], "CHAMBER": C["violet"], "RECIPE": C["magenta"]}
CAT_SUB, CAT_EXTRA = "BAD-EXCLUSIVE · SUBSTITUTED", "BAD-EXCLUSIVE · EXTRA/UNLOGGED"
CATEGORY_COLOR = {
    CAT_SUB: C["red"], CAT_EXTRA: C["yellow"], "ALL-BAD COMMON": C["violet"], "BAD-ENRICHED": C["magenta"],
    "COVERAGE GAP": C["muted"], "NEUTRAL / GOOD-ENRICHED": C["good"],
}
# comparability weight (how fair the bad-vs-good comparison is) and granularity weight
CATEGORY_WEIGHT = {CAT_SUB: 1.0, CAT_EXTRA: 0.55, "ALL-BAD COMMON": 1.0, "BAD-ENRICHED": 1.0,
                   "COVERAGE GAP": 0.35, "NEUTRAL / GOOD-ENRICHED": 0.0}
LEVEL_WEIGHT = {"TOOL": 1.0, "CHAMBER": 1.0, "RECIPE": 0.75}   # recipe-ID changes are often just version bumps


@dataclass
class Config:
    inputs: List[str]
    bad_keys: List[str]
    good_keys: List[str]
    labels_csv: Optional[str] = None
    out_html: str = "FDC_RCA_Dashboard.html"
    csv_dir: Optional[str] = "rca_outputs"
    dcqv_threshold: float = 0.97
    revisit_gap_hours: float = 2.0
    top_n: int = 15
    n_bootstrap: int = 300
    seed: int = 42
    title: str = "FDC Tool-Commonality Root-Cause Analysis"


# ----------------------------------------------------------------------------
# 1. Ingestion & cleaning
# ----------------------------------------------------------------------------
def load_fdc(paths: List[str]) -> Tuple[pd.DataFrame, Dict]:
    frames, info = [], {"files": [], "dup_rows": 0, "bad_dcqv": 0}
    for p in paths:
        d = pd.read_csv(p, sep="\t", dtype=str, keep_default_na=False, encoding_errors="replace")
        d.columns = [c.strip() for c in d.columns]
        missing = [c for c in REQUIRED if c not in d.columns]
        if missing:
            raise ValueError(f"{p}: missing required columns {missing}")
        d["src_file"] = os.path.basename(p)
        frames.append(d)
        info["files"].append({"file": os.path.basename(p), "rows": len(d)})
    df = pd.concat(frames, ignore_index=True).rename(columns=COLMAP)
    for c in df.columns:
        if df[c].dtype == object:
            df[c] = df[c].astype(str).str.strip()
    n0 = len(df)
    df = df.drop_duplicates(subset=[c for c in df.columns if c != "src_file"])
    info["dup_rows"] = n0 - len(df)
    df["dcqv"] = pd.to_numeric(df.get("dcqv"), errors="coerce")
    info["bad_dcqv"] = int(df["dcqv"].isna().sum())
    df["op_num"] = pd.to_numeric(df["operation"], errors="coerce")
    df["start"] = pd.to_datetime(df["start"], errors="coerce")
    df["stop"] = pd.to_datetime(df.get("stop"), errors="coerce").fillna(df["start"])
    df["module"] = df["module"].replace("", "NA")
    df["root_lot"] = df["wafer"].str.split(".").str[0]
    df["family"] = df["eqp_type"].str.split("_").str[0].str.upper()
    # equipment class = vendor platform without model suffix (LIT_ASML_SCANNER_XT400 -> LIT_ASML_SCANNER)
    df["eqp_class"] = df["eqp_type"].str.split("_").str[:3].str.join("_")
    return df.reset_index(drop=True), info


def assign_labels(df: pd.DataFrame, cfg: Config) -> pd.DataFrame:
    """Label each wafer BAD / GOOD from a labels CSV or from lot/wafer prefixes."""
    lab = {}
    if cfg.labels_csv:
        l = pd.read_csv(cfg.labels_csv)
        l.columns = [c.strip().lower() for c in l.columns]
        for w, y in zip(l["wafer"].astype(str), l["label"].astype(str).str.upper()):
            lab[w.strip()] = "BAD" if y.startswith(("B", "1", "F", "L")) else "GOOD"
    for w in df["wafer"].unique():
        if w in lab:
            continue
        if any(w.startswith(k) for k in cfg.bad_keys):
            lab[w] = "BAD"
        elif any(w.startswith(k) for k in cfg.good_keys):
            lab[w] = "GOOD"
    df = df.copy()
    df["label"] = df["wafer"].map(lab)
    dropped = df["label"].isna().sum()
    if dropped:
        print(f"[warn] {df.loc[df.label.isna(), 'wafer'].nunique()} wafers unlabeled - excluded ({dropped} rows)")
    df = df[df["label"].notna()].copy()
    if df.loc[df.label == "BAD", "wafer"].nunique() == 0 or df.loc[df.label == "GOOD", "wafer"].nunique() == 0:
        raise SystemExit("Need at least one BAD and one GOOD wafer - check --bad/--good/--labels.")
    return df


def classify_routes(df: pd.DataFrame) -> Tuple[pd.DataFrame, str]:
    main_route = df["route"].value_counts().idxmax()

    def cls(route: str, stage: str) -> str:
        r, s = route.upper(), stage.upper()
        if route == main_route:
            return "MAIN"
        if r == "UNDEFINED" or s == "UNDEFINED":
            return "UNTRACKED"
        if "RWK" in r or s.startswith("RWK"):
            return "REWORK"
        if r.startswith("RT") or "RT-STG" in s:
            return "RETEST"
        if "WAT" in r or "WAT" in s:
            return "WAT"
        return "OTHER"

    df = df.copy()
    df["route_class"] = [cls(r, s) for r, s in zip(df["route"], df["stage"])]
    return df, main_route


# ----------------------------------------------------------------------------
# 2. Commonality engine
# ----------------------------------------------------------------------------
def entity_long(main: pd.DataFrame) -> pd.DataFrame:
    """One row per (wafer, stage, level, entity) - the 'process path' table."""
    base = main[["wafer", "label", "stage", "tool", "module", "module_type", "recipe",
                 "eqp_type", "eqp_class", "family"]].copy()
    parts = []
    for lvl in LEVELS:
        b = base.copy()
        b["level"] = lvl
        if lvl == "TOOL":
            b["entity"] = b["tool"]
        elif lvl == "CHAMBER":
            b["entity"] = b["tool"] + " :: " + b["module"]
        else:
            b["entity"] = b["tool"] + " :: R" + b["recipe"]
        parts.append(b)
    out = pd.concat(parts, ignore_index=True).drop_duplicates(["wafer", "stage", "level", "entity"])
    out["key"] = out["level"] + " | " + out["stage"] + " | " + out["entity"]
    return out


def bh_fdr(p: np.ndarray) -> np.ndarray:
    p = np.asarray(p, float)
    n = len(p)
    order = np.argsort(p)
    ranked = p[order] * n / (np.arange(n) + 1)
    q = np.minimum.accumulate(ranked[::-1])[::-1]
    out = np.empty(n)
    out[order] = np.clip(q, 0, 1)
    return out


def is_substitution(level: str, r: pd.Series, good_stage: Optional[pd.DataFrame]) -> bool:
    """True when good wafers ran the SAME kind of process at this stage on a DIFFERENT entity.

    That is a head-to-head assignment difference (the classic commonality signature). If the good
    wafers have no equipment of that class at the stage, the bad-only entity is either an extra
    step in the bad lot's flow or simply not logged for the good lot - weaker evidence.
    """
    if good_stage is None or good_stage.empty:
        return False
    if level == "TOOL":
        return bool((good_stage.eqp_class == r.eqp_class).any())
    if level == "CHAMBER":
        return bool(((good_stage.eqp_class == r.eqp_class) & (good_stage.module_type == r.module_type)).any())
    return bool(((good_stage.tool == r.tool) & (good_stage.module == r.module)).any()
                or ((good_stage.eqp_class == r.eqp_class) & (good_stage.module_type == r.module_type)).any())


def commonality_table(long: pd.DataFrame, bad: set, good: set) -> pd.DataFrame:
    NB, NG = len(bad), len(good)
    stage_w = long.groupby("stage")["wafer"].apply(set).to_dict()
    p_floor = stats.fisher_exact([[NB, 0], [0, NG]], alternative="greater")[1]
    good_ctx = {stg: g for stg, g in long[long.wafer.isin(good)].groupby("stage")}
    rows = []
    for (lvl, stg, ent), g in long.groupby(["level", "stage", "entity"]):
        ws = set(g["wafer"])
        b, gg = len(ws & bad), len(ws & good)
        sb, sg = len(stage_w[stg] & bad), len(stage_w[stg] & good)
        p = stats.fisher_exact([[b, NB - b], [gg, NG - gg]], alternative="greater")[1]
        bad_cov, good_cov = b / NB, gg / NG
        delta = bad_cov - good_cov
        odds = ((b + .5) * (NG - gg + .5)) / ((NB - b + .5) * (gg + .5))
        overall = (b + gg) / (NB + NG)
        comparable = sb > 0 and sg > 0
        if delta <= 0:
            cat = "NEUTRAL / GOOD-ENRICHED"
        elif sg == 0:
            cat = "COVERAGE GAP"
        elif b == NB and gg == 0:
            cat = CAT_SUB if is_substitution(lvl, g.iloc[0], good_ctx.get(stg)) else CAT_EXTRA
        elif b == NB:
            cat = "ALL-BAD COMMON"
        else:
            cat = "BAD-ENRICHED"
        evidence = min(1.0, max(0.0, math.log10(p) / math.log10(p_floor))) if p < 1 else 0.0
        score = 100 * max(delta, 0) * evidence * CATEGORY_WEIGHT[cat] * LEVEL_WEIGHT[lvl]
        rows.append(dict(
            level=lvl, stage=stg, entity=ent, key=f"{lvl} | {stg} | {ent}",
            tool=g["tool"].iloc[0], module=g["module"].iloc[0], recipe=g["recipe"].iloc[0],
            eqp_class=g["eqp_class"].iloc[0], module_type=g["module_type"].iloc[0],
            eqp_type=g["eqp_type"].iloc[0], family=g["family"].iloc[0],
            bad_hits=b, good_hits=gg, n_bad=NB, n_good=NG,
            bad_stage_obs=sb, good_stage_obs=sg, comparable=comparable,
            bad_cov=bad_cov, good_cov=good_cov, delta_cov=delta,
            commonality_ratio=bad_cov / overall if overall else np.nan,
            odds_ratio=odds, fisher_p=p, category=cat, commonality_score=score,
            bad_wafers=", ".join(sorted(ws & bad)), good_wafers=", ".join(sorted(ws & good)),
        ))
    t = pd.DataFrame(rows)
    t["fdr_q"] = bh_fdr(t["fisher_p"].values)
    t.attrs["p_floor"] = p_floor
    return t.sort_values(["commonality_score", "delta_cov"], ascending=False).reset_index(drop=True)


def adjusted_mi(a, b) -> float:
    """Adjusted mutual information (chance-corrected, 0 = random, 1 = perfect)."""
    try:
        from sklearn.metrics import adjusted_mutual_info_score
        return float(max(0.0, adjusted_mutual_info_score(b, a)))
    except Exception:
        ct = pd.crosstab(pd.Series(a), pd.Series(b)).values
        n = ct.sum()
        pxy = ct / n
        px, py = pxy.sum(1, keepdims=True), pxy.sum(0, keepdims=True)
        with np.errstate(divide="ignore", invalid="ignore"):
            mi = np.nansum(pxy * np.log(pxy / (px @ py)))
        h = -np.sum(py * np.log(py))
        return float(mi / h) if h > 0 else 0.0


def stage_divergence(main: pd.DataFrame, bad: set, good: set, stage_order: pd.Series) -> pd.DataFrame:
    """Cramer's V / normalized MI between a wafer's chamber path at a stage and its label."""
    sig = (main.assign(ch=main["tool"] + "::" + main["module"])
           .groupby(["stage", "wafer"]).agg(ch=("ch", lambda s: " + ".join(sorted(set(s)))),
                                            tl=("tool", lambda s: " + ".join(sorted(set(s))))).reset_index())
    rows = []
    for stg, g in sig.groupby("stage"):
        ws = set(g["wafer"])
        nb, ng = len(ws & bad), len(ws & good)
        lab = g["wafer"].map(lambda w: "BAD" if w in bad else "GOOD")
        if nb == 0 or ng == 0:
            rows.append(dict(stage=stg, comparable=False, n_bad=nb, n_good=ng, cramers_v=np.nan, ami=np.nan,
                             nmi=np.nan, chi2_p=np.nan, n_paths=g["ch"].nunique(),
                             coverage="BAD-only" if ng == 0 else "GOOD-only"))
            continue
        # chance-corrected adjusted mutual information on the chamber path: robust to the many unique
        # paths that track/cluster tools create (raw Cramer's V would read 1.0 for any all-unique path)
        ami = adjusted_mi(g["ch"].values, lab.values)
        ct = pd.crosstab(g["tl"], lab)                 # Cramer's V on the coarser tool-level path
        if ct.shape[0] < 2:
            v, p, nmi = 0.0, 1.0, 0.0
        else:
            chi2, p, _, _ = stats.chi2_contingency(ct, correction=False)
            n = ct.values.sum()
            v = math.sqrt(chi2 / (n * (min(ct.shape) - 1)))
            pxy = ct.values / n
            px, py = pxy.sum(1, keepdims=True), pxy.sum(0, keepdims=True)
            with np.errstate(divide="ignore", invalid="ignore"):
                mi = np.nansum(pxy * np.log(pxy / (px @ py)))
            hy = -np.sum(py * np.log(py))
            nmi = mi / hy if hy > 0 else 0.0
        rows.append(dict(stage=stg, comparable=True, n_bad=nb, n_good=ng, cramers_v=min(v, 1.0), ami=ami,
                         nmi=float(nmi), chi2_p=p, n_paths=g["ch"].nunique(), coverage="Both"))
    out = pd.DataFrame(rows)
    out["order"] = out["stage"].map(stage_order)
    return out.sort_values("order").reset_index(drop=True)


# ----------------------------------------------------------------------------
# 3. FDC health (DCQV)
# ----------------------------------------------------------------------------
def cliffs_delta(a: np.ndarray, b: np.ndarray) -> float:
    a, b = np.asarray(a), np.asarray(b)
    if len(a) == 0 or len(b) == 0:
        return np.nan
    gt = sum((x > b).sum() for x in a)
    lt = sum((x < b).sum() for x in a)
    return (gt - lt) / (len(a) * len(b))


def dcqv_analysis(main: pd.DataFrame, allrows: pd.DataFrame, thr: float) -> Tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    m = main.dropna(subset=["dcqv"])
    n_bad_total = main.loc[main.label == "BAD", "wafer"].nunique()
    per = (m.groupby(["stage", "tool", "module", "module_type", "wafer", "label"])["dcqv"].min().reset_index())
    rows = []
    for (stg, tool, mod), g in per.groupby(["stage", "tool", "module"]):
        b = g.loc[g.label == "BAD", "dcqv"].values
        gd = g.loc[g.label == "GOOD", "dcqv"].values
        baseline = "same chamber"
        if len(b) and len(gd) < 2:
            # chamber never/rarely used by good wafers -> compare with the good wafers' peer chambers
            # of the same module type at the same stage (the chambers that replaced it)
            peer = per[(per.stage == stg) & (per.module_type == g.module_type.iloc[0]) & (per.label == "GOOD")]
            gd = peer.groupby("wafer")["dcqv"].min().values
            baseline = "stage peers"
        if len(b) == 0 or len(gd) < 2:
            continue
        med_g, med_b = np.median(gd), np.median(b)
        mad = stats.median_abs_deviation(gd, scale="normal")
        iqr = np.subtract(*np.percentile(gd, [75, 25]))
        scale = max(mad, iqr / 1.349, 0.005)               # robust scale with a floor for quantised DCQV
        rz = (med_b - med_g) / scale
        try:
            p = stats.mannwhitneyu(b, gd, alternative="two-sided").pvalue
        except ValueError:
            p = 1.0
        rows.append(dict(stage=stg, tool=tool, module=mod, key=f"{stg} | {tool} :: {mod}", baseline=baseline,
                         n_bad=len(b), n_good=len(gd), bad_median=med_b, good_median=med_g,
                         good_min=gd.min(), delta=med_b - med_g, robust_z=rz, mw_p=p,
                         cliffs_delta=cliffs_delta(b, gd),
                         degraded=bool(rz <= -3 and b.max() < gd.min() and len(b) >= min(2, n_bad_total))))
    dq = pd.DataFrame(rows)
    if len(dq):
        dq = dq.sort_values("robust_z").reset_index(drop=True)

    a = allrows.dropna(subset=["dcqv"]).copy()
    a["exc"] = a["dcqv"] < thr
    exc = a.groupby(["tool", "label"]).agg(rows=("exc", "size"), excursions=("exc", "sum")).reset_index()
    exc["rate"] = exc["excursions"] / exc["rows"]
    ex = exc.pivot_table(index="tool", columns="label", values=["rate", "rows", "excursions"], fill_value=0)
    ex.columns = [f"{a}_{b.lower()}" for a, b in ex.columns]
    ex = ex.reset_index()
    for c in ["rate_bad", "rate_good", "rows_bad", "rows_good", "excursions_bad", "excursions_good"]:
        if c not in ex:
            ex[c] = 0
    ex["rate_diff"] = ex["rate_bad"] - ex["rate_good"]
    ex = ex.sort_values("rate_diff", ascending=False).reset_index(drop=True)
    return dq, ex, per


# ----------------------------------------------------------------------------
# 4. Process-flow anomalies
# ----------------------------------------------------------------------------
def flow_anomalies(df: pd.DataFrame, gap_h: float, thr: float) -> Tuple[pd.DataFrame, pd.DataFrame]:
    recs, revisit_rows = [], []
    for w, g in df.groupby("wafer"):
        main = g[g.route_class == "MAIN"]
        revisits = 0
        for (stg, op), s in main.groupby(["stage", "operation"]):
            t = s["start"].sort_values().dropna()
            visits = 1 + int((t.diff().dt.total_seconds() / 3600 > gap_h).sum()) if len(t) else 0
            if visits > 1:
                revisits += visits - 1
                revisit_rows.append(dict(wafer=w, label=g.label.iloc[0], stage=stg, operation=op, visits=visits))
        ev = lambda cls: g[g.route_class == cls].groupby(["route", "operation"]).ngroups
        recs.append(dict(
            wafer=w, label=g.label.iloc[0], root_lot=g.root_lot.iloc[0],
            records=len(g), stages=main["stage"].nunique(), tools=g["tool"].nunique(),
            rework_events=ev("REWORK"), retest_events=ev("RETEST"), wat_events=ev("WAT"),
            untracked_runs=g[g.route_class == "UNTRACKED"].groupby(["tool", "start"]).ngroups,
            stage_revisits=revisits, lot_ids=g["lot"].nunique(),
            first_start=g["start"].min(), last_stop=g["stop"].max(),
            cycle_days=(g["stop"].max() - g["start"].min()).total_seconds() / 86400,
            mean_dcqv=g["dcqv"].mean(), min_dcqv=g["dcqv"].min(),
            excursions=int((g["dcqv"] < thr).sum()),
            excursion_rate=float((g["dcqv"] < thr).mean()),
        ))
    return pd.DataFrame(recs).sort_values(["label", "wafer"]).reset_index(drop=True), pd.DataFrame(revisit_rows)


def qtime_analysis(main: pd.DataFrame, bad: set, good: set) -> pd.DataFrame:
    rows = []
    for w, g in main.groupby("wafer"):
        s = g.groupby("stage").agg(first=("start", "min"), last=("stop", "max")).sort_values("first")
        prev_last = s["last"].shift(1)
        q = (s["first"] - prev_last).dt.total_seconds() / 3600
        for stg, val in q.dropna().items():
            rows.append(dict(wafer=w, stage=stg, qtime_h=max(val, 0.0)))
    q = pd.DataFrame(rows)
    if q.empty:
        return q
    q["label"] = np.where(q["wafer"].isin(bad), "BAD", "GOOD")
    agg = q.groupby(["stage", "label"])["qtime_h"].median().unstack()
    agg = agg.dropna(subset=[c for c in ["BAD", "GOOD"] if c in agg]).reset_index()
    if {"BAD", "GOOD"} <= set(agg.columns):
        agg["log_ratio"] = np.log2((agg["BAD"] + 0.5) / (agg["GOOD"] + 0.5))
        agg = agg.reindex(agg["log_ratio"].abs().sort_values(ascending=False).index).reset_index(drop=True)
    return agg


def confounding_checks(df: pd.DataFrame, bad: set, good: set) -> List[Dict]:
    out = []
    bl = df[df.wafer.isin(bad)].root_lot.unique()
    gl = df[df.wafer.isin(good)].root_lot.unique()
    if len(bl) == 1:
        out.append(dict(level="serious", title="Lot-level confounding",
                        text=f"All {len(bad)} bad wafers come from one lot ({bl[0]}); good wafers come from "
                             f"{len(gl)} lot(s) ({', '.join(gl)}). A tool difference cannot be fully separated "
                             f"from a lot (incoming material / route-version) effect. Confirm with more lots."))
    b0, b1 = df[df.wafer.isin(bad)].start.min(), df[df.wafer.isin(bad)].start.max()
    g0, g1 = df[df.wafer.isin(good)].start.min(), df[df.wafer.isin(good)].start.max()
    overlap = max(pd.Timedelta(0), min(b1, g1) - max(b0, g0))
    if overlap == pd.Timedelta(0):
        out.append(dict(level="serious", title="No time overlap",
                        text=f"Bad wafers ran {b0:%Y-%m-%d} → {b1:%Y-%m-%d}, good wafers ran {g0:%Y-%m-%d} → "
                             f"{g1:%Y-%m-%d}. Tool-state drift, PMs and material changes in between are aliased "
                             f"with the tool assignments. Overlay PM/event logs on the suspect tools."))
    NB, NG = len(bad), len(good)
    p_floor = stats.fisher_exact([[NB, 0], [0, NG]], alternative="greater")[1]
    out.append(dict(level="warning", title="Statistical power",
                    text=f"With {NB} bad vs {NG} good wafers the smallest attainable Fisher p-value is "
                         f"{p_floor:.4f}. Results rank hypotheses; they are not proof. Many entities will be "
                         f"statistically indistinguishable (aliased) - see the alias groups."))
    return out


# ----------------------------------------------------------------------------
# 5. Machine learning layer
# ----------------------------------------------------------------------------
def build_feature_matrix(long: pd.DataFrame, per_dcqv: pd.DataFrame, anom: pd.DataFrame,
                         wafers: List[str]) -> Tuple[pd.DataFrame, Dict[str, List[str]], Dict[str, str]]:
    hit = (pd.crosstab(long["wafer"], long["key"]) > 0).astype(float).reindex(wafers).fillna(0)
    dq = per_dcqv.assign(k="DCQV | " + per_dcqv.stage + " | " + per_dcqv.tool + " :: " + per_dcqv.module)
    dqw = dq.pivot_table(index="wafer", columns="k", values="dcqv", aggfunc="min").reindex(wafers)
    dqw = dqw.loc[:, dqw.notna().all()]           # complete-case only, no imputation leakage
    an = anom.set_index("wafer").reindex(wafers)[
        ["rework_events", "retest_events", "untracked_runs", "stage_revisits", "lot_ids"]].add_prefix("FLOW | ")
    X = pd.concat([hit, dqw, an.astype(float)], axis=1)
    X = X.loc[:, X.std(ddof=0) > 0]
    # de-alias: identical columns (or exact complements for binaries) are one feature group
    groups: Dict[str, List[str]] = {}
    member_of: Dict[str, str] = {}
    seen: Dict[Tuple, str] = {}
    for c in X.columns:
        v = X[c].values
        sig = tuple(np.round(v, 9))
        if sig in seen:
            groups[seen[sig]].append(c)
            member_of[c] = seen[sig]
        else:
            seen[sig] = c
            groups[c] = [c]
            member_of[c] = c
    return X[list(groups.keys())], groups, member_of


def ml_analysis(X: pd.DataFrame, y: np.ndarray, groups: Dict[str, List[str]], cfg: Config) -> Dict:
    res = {"available": HAS_SKLEARN, "n_features_raw": sum(len(v) for v in groups.values()),
           "n_features_dealiased": X.shape[1]}
    if not HAS_SKLEARN or X.shape[1] == 0:
        return res
    rng = np.random.default_rng(cfg.seed)
    Xs = StandardScaler().fit_transform(X.values)
    bi, gi = np.where(y == 1)[0], np.where(y == 0)[0]
    freq_pos = np.zeros(X.shape[1])
    for _ in range(cfg.n_bootstrap):
        idx = np.r_[rng.choice(bi, len(bi), replace=True), rng.choice(gi, len(gi), replace=True)]
        if len(set(y[idx])) < 2:
            continue
        cols = rng.random(X.shape[1]) < 0.5                    # random feature subspace
        if cols.sum() == 0:
            continue
        lr = LogisticRegression(penalty="l1", solver="liblinear", C=float(rng.uniform(0.05, 1.0)),
                                class_weight="balanced", max_iter=2000)
        lr.fit(Xs[idx][:, cols], y[idx])
        coef = np.zeros(X.shape[1])
        coef[cols] = lr.coef_[0]
        freq_pos += (coef > 1e-8)
    stab = freq_pos / (cfg.n_bootstrap * 0.5)                   # normalise by subspace inclusion rate
    stab = np.clip(stab, 0, 1)

    et = ExtraTreesClassifier(n_estimators=1000, max_features="sqrt", class_weight="balanced",
                              random_state=cfg.seed, min_samples_leaf=1)
    et.fit(X.values, y)
    imp = et.feature_importances_

    def loo(model_fn, Xm):
        pred = np.zeros(len(y))
        for tr, te in LeaveOneOut().split(Xm):
            if len(set(y[tr])) < 2:
                pred[te] = y[tr][0]
                continue
            m = model_fn()
            m.fit(Xm[tr], y[tr])
            pred[te] = m.predict(Xm[te])
        acc = float((pred == y).mean())
        tpr = float(((pred == 1) & (y == 1)).sum() / max(1, (y == 1).sum()))
        tnr = float(((pred == 0) & (y == 0)).sum() / max(1, (y == 0).sum()))
        return acc, (tpr + tnr) / 2

    res["loo_forest_acc"], res["loo_forest_bal"] = loo(
        lambda: ExtraTreesClassifier(n_estimators=300, max_features="sqrt", class_weight="balanced",
                                     random_state=cfg.seed), X.values)
    res["loo_l1_acc"], res["loo_l1_bal"] = loo(
        lambda: LogisticRegression(penalty="l1", solver="liblinear", C=0.5, class_weight="balanced"), Xs)

    dt_ = DecisionTreeClassifier(max_depth=2, class_weight="balanced", random_state=cfg.seed)
    short = [c if len(c) < 70 else c[:67] + "..." for c in X.columns]
    dt_.fit(X.values, y)
    res["tree_rules"] = export_text(dt_, feature_names=short)
    res["table"] = pd.DataFrame({
        "group": X.columns, "n_aliases": [len(groups[c]) for c in X.columns],
        "stability": stab, "forest_importance": imp,
        "bad_mean": X.values[y == 1].mean(0), "good_mean": X.values[y == 0].mean(0),
        "members": [" || ".join(groups[c]) for c in X.columns],
    }).sort_values(["stability", "forest_importance"], ascending=False).reset_index(drop=True)
    res["alias_sizes"] = sorted([len(v) for v in groups.values()], reverse=True)
    return res


# ----------------------------------------------------------------------------
# 6. Evidence fusion
# ----------------------------------------------------------------------------
def fuse_evidence(comm: pd.DataFrame, dq: pd.DataFrame, ml: Dict, member_of: Dict[str, str],
                  cfg: Config) -> pd.DataFrame:
    t = comm[comm.delta_cov > 0].copy()
    if "table" in ml:
        mt = ml["table"].set_index("group")
        fmax = mt["forest_importance"].max() or 1
        t["stability"] = t["key"].map(lambda k: mt["stability"].get(member_of.get(k, ""), 0.0)).fillna(0)
        t["forest"] = t["key"].map(lambda k: mt["forest_importance"].get(member_of.get(k, ""), 0.0) / fmax).fillna(0)
        t["alias_group"] = t["key"].map(lambda k: member_of.get(k, k))
        t["n_aliases"] = t["alias_group"].map(lambda g: int(mt["n_aliases"].get(g, 1)))
    else:
        t["stability"], t["forest"], t["alias_group"], t["n_aliases"] = 0.0, 0.0, t["key"], 1

    def dq_signal(r) -> Tuple[float, float]:
        if dq.empty:
            return 0.0, np.nan
        sel = dq[(dq.stage == r.stage) & (dq.tool == r.tool)]
        if r.level == "CHAMBER":
            sel = sel[sel.module == r.entity.split(" :: ")[1]]
        if sel.empty:
            return 0.0, np.nan
        z = sel["robust_z"].min()
        return float(np.clip(-z / 6.0, 0, 1)), float(z)

    sig = t.apply(dq_signal, axis=1, result_type="expand")
    t["dcqv_signal"], t["dcqv_robust_z"] = sig[0], sig[1]
    # recurrence: the same tool/chamber shows up as an all-bad entity at several stages of the flow
    strong = t[(t.bad_hits == t.n_bad) & (t.good_hits == 0)]
    rec = strong.groupby(["level", "entity"])["stage"].nunique()
    t["recurrence"] = [int(rec.get((l, en), 0)) for l, en in zip(t.level, t.entity)]
    t["recur_signal"] = np.clip((t["recurrence"] - 1) / 3.0, 0, 1)
    t["rca_score"] = 100 * (W_COMMONALITY * t["commonality_score"] / 100 + W_STABILITY * t["stability"]
                            + W_FOREST * t["forest"] + W_DCQV * t["dcqv_signal"] + W_RECUR * t["recur_signal"])

    def tier(r) -> str:
        if r.category == CAT_SUB and r.level in ("TOOL", "CHAMBER"):
            return "HIGH"
        if r.category in (CAT_SUB, CAT_EXTRA, "ALL-BAD COMMON") or r.dcqv_signal >= 0.5:
            return "MEDIUM"
        return "LOW"

    t["tier"] = t.apply(tier, axis=1)
    t["action"] = t["family"].map(FAMILY_ACTIONS).fillna(DEFAULT_ACTION)
    t = collapse_siblings(t)
    t = t.sort_values(["rca_score", "level"], ascending=[False, True]).reset_index(drop=True)
    t["rank"] = np.arange(1, len(t) + 1)
    return t


def collapse_siblings(t: pd.DataFrame) -> pd.DataFrame:
    """Merge chambers/recipes of the same tool & stage that have the identical wafer pattern.

    e.g. CMP cleaner modules CLN_1..CLN_4 that every bad wafer and no good wafer touched are one
    finding, not four. The merged row keeps the strongest score and lists all members.
    """
    keys = ["level", "stage", "tool", "bad_wafers", "good_wafers", "category"]
    out = []
    for _, g in t.groupby(keys, sort=False):
        g = g.sort_values("rca_score", ascending=False)
        r = g.iloc[0].copy()
        if len(g) > 1:
            parts = [x.split(" :: ", 1)[1] for x in g.entity]
            r["entity"] = f"{r.tool} :: " + ", ".join(sorted(parts))
            r["dcqv_signal"] = g["dcqv_signal"].max()
            r["dcqv_robust_z"] = g["dcqv_robust_z"].min()
            r["stability"] = g["stability"].max()
            r["forest"] = g["forest"].max()
            r["recurrence"] = g["recurrence"].max()
            r["recur_signal"] = g["recur_signal"].max()
            r["rca_score"] = g["rca_score"].max()
        r["n_members"] = len(g)
        out.append(r)
    return pd.DataFrame(out)


def good_path_at(main: pd.DataFrame, good: set, stage: str, eqp_class: Optional[str] = None,
                 module_type=None) -> str:
    """What the good wafers used at this stage - restricted to the same kind of process when known."""
    g = main[(main.stage == stage) & (main.wafer.isin(good))]
    if eqp_class is not None and (g.eqp_class == eqp_class).any():
        g = g[g.eqp_class == eqp_class]
        mts = [module_type] if isinstance(module_type, str) else list(module_type or [])
        if mts and g.module_type.isin(mts).any():
            g = g[g.module_type.isin(mts)]
    if g.empty:
        return "—"
    v = (g["tool"] + " :: " + g["module"]).value_counts()
    return ", ".join(f"{k} ({n})" for k, n in v.head(3).items())


# ----------------------------------------------------------------------------
# 7. Dashboard (Plotly, self-contained)
# ----------------------------------------------------------------------------
def _base_layout(**kw) -> Dict:
    lay = dict(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(family="system-ui, -apple-system, 'Segoe UI', sans-serif", color=C["ink2"], size=12),
        margin=dict(l=60, r=24, t=36, b=56),
        hoverlabel=dict(bgcolor=C["surface"], bordercolor=C["axis"], font=dict(color=C["ink"], size=12)),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0, font=dict(color=C["ink2"])),
        xaxis=dict(gridcolor=C["grid"], zerolinecolor=C["axis"], linecolor=C["axis"], tickcolor=C["axis"],
                   tickfont=dict(color=C["muted"])),
        yaxis=dict(gridcolor=C["grid"], zerolinecolor=C["axis"], linecolor=C["axis"], tickcolor=C["axis"],
                   tickfont=dict(color=C["muted"])),
        bargap=0.25,
    )
    for k, v in kw.items():
        if isinstance(v, dict) and isinstance(lay.get(k), dict):
            lay[k] = {**lay[k], **v}
        else:
            lay[k] = v
    return lay


def _clip(s: str, n: int = 58) -> str:
    return s if len(s) <= n else s[: n - 1] + "…"


def build_figures(ctx: Dict) -> Dict[str, Dict]:
    F: Dict[str, Dict] = {}
    rca, comm, div, dq, ex, per, anom, q, jac = (ctx[k] for k in
                                                  ["rca", "comm", "div", "dq", "ex", "per", "anom", "q", "jac"])
    top_n = ctx["cfg"].top_n

    # F1 - fused suspect ranking
    top = rca.head(top_n).iloc[::-1]
    data = []
    for lvl in LEVELS:
        s = top[top.level == lvl]
        if s.empty:
            continue
        data.append(dict(
            type="bar", orientation="h", name=lvl.title(), x=s.rca_score.round(1).tolist(),
            y=[f"#{r} {_clip(st + ' · ' + e, 54)}" for r, st, e in zip(s["rank"], s.stage, s.entity)],
            marker=dict(color=LEVEL_COLOR[lvl], cornerradius=4),
            text=[f"{v:.0f}" for v in s.rca_score], textposition="outside", textfont=dict(color=C["ink2"]),
            customdata=np.c_[s.category, s.bad_hits, s.good_hits, s.fisher_p.round(4),
                             s.stability.round(2), s.dcqv_robust_z.round(2).fillna(0), s.tier, s.recurrence].tolist(),
            hovertemplate="<b>%{y}</b><br>RCA score %{x}<br>Category %{customdata[0]}<br>"
                          "Bad hits %{customdata[1]} · Good hits %{customdata[2]}<br>Fisher p %{customdata[3]}"
                          "<br>Stability %{customdata[4]} · DCQV z %{customdata[5]}<br>Tier %{customdata[6]}"
                          "<br>Recurs at %{customdata[7]} stage(s)<extra></extra>"))
    order = [f"#{r} {_clip(st + ' · ' + e, 54)}" for r, st, e in zip(top["rank"], top.stage, top.entity)]
    F["fig_rank"] = dict(data=data, layout=_base_layout(
        height=max(420, 30 * len(top) + 80), margin=dict(l=380, r=50, t=36, b=40),
        xaxis=dict(title="Fused RCA score (0–100)", range=[0, 105]),
        yaxis=dict(categoryorder="array", categoryarray=order, tickfont=dict(color=C["ink2"], size=11)),
        barmode="overlay"))

    # F2 - coverage plane (bubble = number of entities sharing the same bad/good coverage)
    data = []
    draw = ["NEUTRAL / GOOD-ENRICHED", "COVERAGE GAP", "BAD-ENRICHED", "ALL-BAD COMMON", CAT_EXTRA, CAT_SUB]
    NBt, NGt = len(ctx["bad"]), len(ctx["good"])
    for cat in draw:
        s = comm[comm.category == cat]
        if s.empty:
            continue
        agg = s.groupby(["good_hits", "bad_hits"]).agg(n=("key", "size"), ex=("key", lambda k: "<br>".join(
            _clip(x, 70) for x in list(k)[:8]) + ("<br>…" if len(k) > 8 else ""))).reset_index()
        off = {CAT_SUB: 0.12, CAT_EXTRA: -0.12, "COVERAGE GAP": 0.0}.get(cat, 0.0)   # keep co-located groups visible
        data.append(dict(
            type="scatter", mode="markers", name=f"{cat} ({len(s)})",
            x=(agg.good_hits + off).tolist(), y=agg.bad_hits.tolist(),
            marker=dict(color=CATEGORY_COLOR[cat], size=(10 + 34 * np.sqrt(agg.n / max(1, len(comm)) * 8)).round(1).tolist(),
                        sizemode="diameter", opacity=0.85, line=dict(color=C["surface"], width=2)),
            customdata=np.c_[agg.n, agg.ex].tolist(),
            hovertemplate=f"<b>{cat}</b><br>bad %{{y}}/{NBt} · good %{{x:.0f}}/{NGt}<br>%{{customdata[0]}} entities"
                          "<br>%{customdata[1]}<extra></extra>"))
    F["fig_volcano"] = dict(data=data, layout=_base_layout(
        height=460, legend=dict(orientation="h", y=1.12),
        xaxis=dict(title=f"Good wafers that used the entity (of {NGt})", range=[-0.6, NGt + 0.6], dtick=1),
        yaxis=dict(title=f"Bad wafers that used the entity (of {NBt})", range=[-0.4, NBt + 0.5], dtick=1),
        annotations=[dict(x=0.2, y=NBt + 0.32, text="◀ ideal commonality signature: all bad, no good",
                          showarrow=False, xanchor="left", font=dict(color=C["ink2"], size=11))]))

    # F3 - stage divergence along the flow
    d = div[div.comparable].copy()
    data = []
    for nm, lo, hi_, col in [("Separating (AMI ≥ 0.6)", 0.6, 9, C["red"]), ("Partial (0.2–0.6)", 0.2, 0.6, C["yellow"]),
                             ("Shared / random (< 0.2)", -9, 0.2, C["good"])]:
        s = d[(d.ami >= lo) & (d.ami < hi_)]
        data.append(dict(type="bar", name=nm, x=s.stage.tolist(), y=s.ami.round(3).tolist(),
                         marker=dict(color=col, cornerradius=3),
                         customdata=np.c_[s.cramers_v.round(2), s.n_bad, s.n_good, s.n_paths, s.order.round(2)].tolist(),
                         hovertemplate="<b>%{x}</b><br>AMI (chamber path) %{y}<br>Cramér's V (tool path) %{customdata[0]}"
                                       "<br>bad/good wafers %{customdata[1]}/%{customdata[2]}<br>distinct chamber paths "
                                       "%{customdata[3]}<br>operation ≈ %{customdata[4]}<extra></extra>"))
    F["fig_flow"] = dict(data=data, layout=_base_layout(
        height=400, margin=dict(l=60, r=20, t=40, b=120), barmode="overlay",
        xaxis=dict(title="", tickangle=-60, tickfont=dict(size=10, color=C["muted"]),
                   categoryorder="array", categoryarray=d.stage.tolist()),
        yaxis=dict(title="Adjusted mutual information", range=[0, 1.05])))

    # F4 - wafer x entity hit matrix
    hm = rca.head(25)
    wafers = ctx["wafer_order"]
    hits = ctx["long"].assign(v=1).pivot_table(index="wafer", columns="key", values="v", aggfunc="max")
    hits = hits.reindex(index=wafers, columns=hm.key).fillna(0)
    ylab = [f"{ctx['labels'][w]} · {w}" for w in wafers]
    F["fig_hit"] = dict(data=[dict(
        type="heatmap", z=hits.values.tolist(), x=[f"#{r} {_clip(s + ' · ' + e, 40)}" for r, s, e in
                                                  zip(hm["rank"], hm.stage, hm.entity)],
        y=ylab, colorscale=[[0, "#242422"], [1, C["good"]]], zmin=0, zmax=1, showscale=False,
        xgap=2, ygap=2, hovertemplate="%{y}<br>%{x}<br>passed: %{z}<extra></extra>")],
        layout=_base_layout(height=420, margin=dict(l=190, r=20, t=20, b=210),
                            xaxis=dict(tickangle=-55, tickfont=dict(size=10), showgrid=False),
                            yaxis=dict(autorange="reversed", showgrid=False, tickfont=dict(color=C["ink2"]))))

    # F5 - DCQV distribution for most-degraded chambers
    data = []
    if not dq.empty:
        keys = dq[(dq.robust_z < 0) & (dq.n_bad >= min(2, len(ctx["bad"])))].head(8)
        parts = []
        for k in keys.itertuples():
            bsel = per[(per.stage == k.stage) & (per.tool == k.tool) & (per.module == k.module) & (per.label == "BAD")]
            if k.baseline == "same chamber":
                gsel = per[(per.stage == k.stage) & (per.tool == k.tool) & (per.module == k.module) & (per.label == "GOOD")]
            else:
                mt = bsel.module_type.iloc[0]
                gsel = (per[(per.stage == k.stage) & (per.module_type == mt) & (per.label == "GOOD")]
                        .sort_values("dcqv").drop_duplicates("wafer"))
            lbl = f"{k.stage}<br>{k.tool}::{k.module}" + ("" if k.baseline == "same chamber" else " †")
            parts.append(pd.concat([bsel, gsel]).assign(k=lbl))
        sub = pd.concat(parts) if parts else per.iloc[:0].assign(k="")
        for lab, col in [("GOOD", C["good"]), ("BAD", C["bad"])]:
            s = sub[sub.label == lab]
            data.append(dict(type="box", name=lab.title(), x=s.k.tolist(), y=s.dcqv.round(5).tolist(),
                             marker=dict(color=col, size=8, line=dict(color=C["surface"], width=1)),
                             line=dict(color=col, width=1.5), fillcolor="rgba(0,0,0,0)",
                             boxpoints="all", jitter=0.4, pointpos=0, text=s.wafer.tolist(),
                             hovertemplate="%{text}<br>DCQV %{y}<extra>" + lab + "</extra>"))
    F["fig_dcqv"] = dict(data=data, layout=_base_layout(
        height=420, boxmode="group", margin=dict(l=60, r=20, t=36, b=110),
        xaxis=dict(tickfont=dict(size=10)), yaxis=dict(title="Wafer min DCQV in step")))

    # F6 - excursion rate by tool
    e = ex[(ex.rate_bad + ex.rate_good) > 0].head(12)
    F["fig_exc"] = dict(data=[
        dict(type="bar", name="Good", x=e.tool.tolist(), y=(100 * e.rate_good).round(1).tolist(),
             marker=dict(color=C["good"], cornerradius=3), customdata=e.rows_good.tolist(),
             hovertemplate="%{x}<br>Good excursion rate %{y}%<br>rows %{customdata}<extra></extra>"),
        dict(type="bar", name="Bad", x=e.tool.tolist(), y=(100 * e.rate_bad).round(1).tolist(),
             marker=dict(color=C["bad"], cornerradius=3), customdata=e.rows_bad.tolist(),
             hovertemplate="%{x}<br>Bad excursion rate %{y}%<br>rows %{customdata}<extra></extra>")],
        layout=_base_layout(height=380, barmode="group", yaxis=dict(title=f"% records DCQV < {ctx['cfg'].dcqv_threshold}"),
                            xaxis=dict(tickangle=-40)))

    # F7 - timeline
    df = ctx["df"]
    data = []
    for lab, col in [("GOOD", C["good"]), ("BAD", C["bad"])]:
        s = df[(df.label == lab) & (df.route_class == "MAIN")].dropna(subset=["op_num"])
        data.append(dict(type="scattergl", mode="markers", name=f"{lab.title()} · main route",
                         x=s.start.dt.strftime("%Y-%m-%d %H:%M").tolist(), y=s.op_num.tolist(),
                         marker=dict(color=col, size=6, opacity=0.65),
                         text=(s.wafer + " · " + s.stage + " · " + s.tool).tolist(),
                         hovertemplate="%{text}<br>%{x}<br>op %{y}<extra></extra>"))
    s = df[df.route_class != "MAIN"]
    ytop = float(df.op_num.max() or 0) * 1.04
    data.append(dict(type="scattergl", mode="markers", name="Rework / retest / untracked",
                     x=s.start.dt.strftime("%Y-%m-%d %H:%M").tolist(), y=[ytop] * len(s),
                     marker=dict(color=C["yellow"], size=9, symbol="x"),
                     text=(s.wafer + " · " + s.route_class + " · " + s.stage + " · " + s.tool).tolist(),
                     hovertemplate="%{text}<br>%{x}<extra></extra>"))
    F["fig_time"] = dict(data=data, layout=_base_layout(
        height=400, xaxis=dict(title="Process start time", type="date"),
        yaxis=dict(title="Operation number (route position)")))

    # F8 - flow anomalies per wafer
    metrics = [("rework_events", "Rework events", C["yellow"]), ("retest_events", "Retest events", C["violet"]),
               ("stage_revisits", "Stage re-visits", C["magenta"]), ("untracked_runs", "Untracked runs", C["aqua"])]
    xw = [f"{r.label} · {r.wafer}" for r in anom.itertuples()]
    F["fig_anom"] = dict(data=[dict(type="bar", name=lbl, x=xw, y=anom[m].tolist(),
                                    marker=dict(color=col, cornerradius=3),
                                    hovertemplate="%{x}<br>" + lbl + ": %{y}<extra></extra>")
                               for m, lbl, col in metrics],
                         layout=_base_layout(height=400, barmode="group", margin=dict(l=60, r=20, t=36, b=110),
                                             xaxis=dict(tickangle=-30), yaxis=dict(title="Count per wafer")))

    # F9 - Q-time
    if not q.empty and "log_ratio" in q:
        qq = q.head(15)
        F["fig_q"] = dict(data=[
            dict(type="bar", name="Good median", x=qq.stage.tolist(), y=qq.GOOD.round(1).tolist(),
                 marker=dict(color=C["good"], cornerradius=3), hovertemplate="%{x}<br>Good median Q-time %{y} h<extra></extra>"),
            dict(type="bar", name="Bad median", x=qq.stage.tolist(), y=qq.BAD.round(1).tolist(),
                 marker=dict(color=C["bad"], cornerradius=3), hovertemplate="%{x}<br>Bad median Q-time %{y} h<extra></extra>")],
            layout=_base_layout(height=420, barmode="group", margin=dict(l=60, r=20, t=36, b=120),
                                xaxis=dict(tickangle=-45, tickfont=dict(size=10)),
                                yaxis=dict(title="Queue time before step (h)", type="log")))
    else:
        F["fig_q"] = dict(data=[], layout=_base_layout(height=200))

    # F10 - path similarity
    F["fig_jac"] = dict(data=[dict(
        type="heatmap", z=jac.values.round(3).tolist(), x=[f"{ctx['labels'][w][0]}·{w[-5:]}" for w in jac.columns],
        y=[f"{ctx['labels'][w]} · {w}" for w in jac.index], zmin=0, zmax=1, xgap=2, ygap=2,
        colorscale=[[0, "#104281"], [0.5, "#3987e5"], [1, "#cde2fb"]],
        colorbar=dict(title=dict(text="Jaccard", font=dict(color=C["ink2"])), tickfont=dict(color=C["muted"])),
        hovertemplate="%{y} vs %{x}<br>Jaccard %{z}<extra></extra>")],
        layout=_base_layout(height=420, margin=dict(l=190, r=20, t=20, b=70),
                            yaxis=dict(autorange="reversed", showgrid=False), xaxis=dict(showgrid=False)))

    # F11/F12 - ML
    ml = ctx["ml"]
    if "table" in ml:
        mt = ml["table"].head(top_n).iloc[::-1]
        lab = [_clip(g.replace("CHAMBER | ", "CH | ").replace("RECIPE | ", "RC | "), 60) +
               (f"  (+{n - 1})" if n > 1 else "") for g, n in zip(mt.display, mt.n_aliases)]
        F["fig_stab"] = dict(data=[dict(type="bar", orientation="h", x=mt.stability.round(3).tolist(), y=lab,
                                        marker=dict(color=C["violet"], cornerradius=4), name="Stability",
                                        customdata=mt.members.map(lambda m: _clip(m, 300)).tolist(),
                                        hovertemplate="Selection frequency %{x}<br>%{customdata}<extra></extra>")],
                             layout=_base_layout(height=max(380, 28 * len(mt) + 60), showlegend=False,
                                                 margin=dict(l=420, r=30, t=20, b=46),
                                                 xaxis=dict(title="L1 stability-selection frequency", range=[0, 1.05]),
                                                 yaxis=dict(tickfont=dict(size=10, color=C["ink2"]))))
        mt2 = ml["table"].sort_values("forest_importance", ascending=False).head(top_n).iloc[::-1]
        lab2 = [_clip(g.replace("CHAMBER | ", "CH | ").replace("RECIPE | ", "RC | "), 60) +
                (f"  (+{n - 1})" if n > 1 else "") for g, n in zip(mt2.display, mt2.n_aliases)]
        F["fig_rf"] = dict(data=[dict(type="bar", orientation="h", x=mt2.forest_importance.round(4).tolist(), y=lab2,
                                      marker=dict(color=C["aqua"], cornerradius=4), name="Importance",
                                      customdata=mt2.members.map(lambda m: _clip(m, 300)).tolist(),
                                      hovertemplate="Gini importance %{x}<br>%{customdata}<extra></extra>")],
                           layout=_base_layout(height=max(380, 28 * len(mt2) + 60), showlegend=False,
                                               margin=dict(l=420, r=30, t=20, b=46),
                                               xaxis=dict(title="Extra-Trees impurity importance"),
                                               yaxis=dict(tickfont=dict(size=10, color=C["ink2"]))))
    # F13 - coverage
    cov = div["coverage"].value_counts().reindex(["Both", "BAD-only", "GOOD-only"]).fillna(0)
    F["fig_cov"] = dict(data=[dict(type="bar", x=["Observed in both groups", "Bad wafers only", "Good wafers only"],
                                   y=cov.values.tolist(), marker=dict(color=[C["good"], C["bad"], C["muted"]], cornerradius=4),
                                   text=[str(int(v)) for v in cov.values], textposition="outside",
                                   textfont=dict(color=C["ink2"]),
                                   hovertemplate="%{x}: %{y} stages<extra></extra>")],
                        layout=_base_layout(height=300, showlegend=False, yaxis=dict(title="Process stages"),
                                            margin=dict(l=60, r=20, t=30, b=40)))
    return F


class _Enc(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, (np.integer,)):
            return int(o)
        if isinstance(o, (np.floating,)):
            return None if not np.isfinite(o) else float(o)
        if isinstance(o, np.ndarray):
            return o.tolist()
        if isinstance(o, (pd.Timestamp, dt.datetime)):
            return o.isoformat()
        return str(o)


def _sanitize(o):
    if isinstance(o, float) and not math.isfinite(o):
        return None
    if isinstance(o, dict):
        return {k: _sanitize(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_sanitize(v) for v in o]
    return o


def plotly_js() -> str:
    try:
        from plotly.offline import get_plotlyjs
        return "<script>" + get_plotlyjs() + "</script>"
    except Exception:
        return '<script src="https://cdn.jsdelivr.net/npm/plotly.js-dist-min@2.35.2/plotly.min.js"></script>'


def e(s) -> str:
    return html.escape(str(s))


def fmt_p(p: float) -> str:
    return f"{p:.3g}" if p >= 1e-3 else f"{p:.1e}"


TIER_BADGE = {"HIGH": ("crit", "▲", "High"), "MEDIUM": ("serious", "●", "Medium"), "LOW": ("muted", "○", "Low")}
ALERT_ICON = {"serious": "⚠", "warning": "ⓘ", "critical": "⛔"}


def render_html(ctx: Dict, figs: Dict[str, Dict]) -> str:
    cfg, rca, comm, div, dq, ex, anom, ml = (ctx[k] for k in ["cfg", "rca", "comm", "div", "dq", "ex", "anom", "ml"])
    NB, NG = len(ctx["bad"]), len(ctx["good"])
    top = rca.iloc[0] if len(rca) else None
    n_excl = int(comm.category.isin([CAT_SUB, CAT_EXTRA]).sum())
    n_sub = int((comm.category == CAT_SUB).sum())
    sub_stages = comm[(comm.category == CAT_SUB) & (comm.level != "RECIPE")].stage.nunique()
    n_gap = int((comm.category == "COVERAGE GAP").sum())
    n_perfect = int(((rca.head(25).bad_hits == NB) & (rca.head(25).good_hits == 0)).sum())
    div_c = div[div.comparable]
    n_div_full = int((div_c.ami >= 0.6).sum())
    n_degraded = int(dq["degraded"].sum()) if len(dq) else 0
    hi = rca[rca.tier == "HIGH"]
    bad_an = anom[anom.label == "BAD"]
    good_an = anom[anom.label == "GOOD"]

    try:
        wafer_mw_p = stats.mannwhitneyu(bad_an.mean_dcqv, good_an.mean_dcqv, alternative="less").pvalue
    except ValueError:
        wafer_mw_p = float("nan")
    # ------------------------------------------------------------- KPI cards
    def kpi(label, value, sub, accent=""):
        return (f'<div class="kpi {accent}"><div class="kpi-label">{e(label)}</div>'
                f'<div class="kpi-value">{value}</div><div class="kpi-sub">{sub}</div></div>')

    kpis = "".join([
        kpi("Wafers analysed", f"{NB + NG}", f'<span class="dot bad"></span>{NB} bad &nbsp; <span class="dot good"></span>{NG} good'),
        kpi("FDC records", f"{len(ctx['df']):,}", f"{ctx['df'].tool.nunique()} tools · {ctx['df'].stage.nunique()} stages · "
                                               f"{ctx['info']['dup_rows']} duplicates removed"),
        kpi("Entities tested", f"{len(comm):,}", "tool, chamber and recipe at each main-route stage"),
        kpi("Head-to-head substitutions", f"{n_sub}", f"at {sub_stages} stages good wafers ran the same process on a "
            f"different tool/chamber · {n_excl} bad-exclusive entities in total", "accent-red"),
        kpi("Separating stages", f"{n_div_full}/{len(div_c)}", "comparable stages whose chamber path separates the groups "
            "beyond chance (AMI ≥ 0.6)", "accent-yellow"),
        kpi("Degraded chambers (DCQV)", f"{n_degraded}", "bad-wafer median below every good wafer and robust z ≤ −3", "accent-violet"),
        kpi("Off-route moves per wafer", f"{(bad_an.untracked_runs + bad_an.retest_events).mean():.0f} vs "
            f"{(good_an.untracked_runs + good_an.retest_events).mean():.0f}",
            f"bad vs good · untracked {bad_an.untracked_runs.mean():.0f} vs {good_an.untracked_runs.mean():.0f}, retest "
            f"{bad_an.retest_events.mean():.0f} vs {good_an.retest_events.mean():.0f}, rework {bad_an.rework_events.mean():.0f} vs "
            f"{good_an.rework_events.mean():.0f}, lot IDs {bad_an.lot_ids.mean():.0f} vs {good_an.lot_ids.mean():.0f}"),
        kpi("Bad-wafer mean DCQV", f"{bad_an.mean_dcqv.mean():.4f}",
            f"vs {good_an.mean_dcqv.mean():.4f} good · excursion rate {100 * bad_an.excursion_rate.mean():.1f}% vs {100 * good_an.excursion_rate.mean():.1f}% · "
            f"Mann-Whitney p {fmt_p(wafer_mw_p)}", "accent-violet"),
        kpi("ML LOO accuracy", (f"{100 * ml.get('loo_forest_bal', float('nan')):.0f}%" if "loo_forest_bal" in ml else "n/a"),
            (f"Extra-Trees balanced accuracy · L1-logistic {100 * ml.get('loo_l1_bal', 0):.0f}% · "
             f"{ml.get('n_features_raw', 0)} → {ml.get('n_features_dealiased', 0)} de-aliased features") if "loo_forest_bal" in ml else "scikit-learn not installed"),
    ])

    # ------------------------------------------------------------- verdict
    verdict = ""
    if top is not None:
        good_alt = good_path_at(ctx["main"], ctx["good"], top.stage, top.eqp_class,
                                top.module_type if top.level != "TOOL" else None)
        tb = TIER_BADGE[top.tier]
        seen, also_rows = {(top.level, top.entity)}, []
        for r in rca.iloc[1:].itertuples():
            if (r.level, r.entity) in seen or r.level == "RECIPE":
                continue
            seen.add((r.level, r.entity))
            n_st = int(r.recurrence) if r.recurrence else 1
            also_rows.append(f"<div class='also-r'><span class='badge {TIER_BADGE[r.tier][0]}'>{TIER_BADGE[r.tier][1]}</span>"
                             f"<span class='mono'>{e(r.entity)}</span><span class='dim'>{e(r.stage)}"
                             f"{f' +{n_st - 1} more stage(s)' if n_st > 1 else ''}</span></div>")
            if len(also_rows) == 5:
                break
        also = "".join(also_rows)
        verdict = f"""
        <div class="verdict">
          <div class="verdict-tag">Prime suspect · rank #1</div>
          <div class="verdict-main">{e(top.stage)} &nbsp;→&nbsp; <span class="mono">{e(top.entity)}</span></div>
          <div class="verdict-row">
            <span class="badge {tb[0]}">{tb[1]} {tb[2]} confidence</span>
            <span class="chip">{e(top.level.title())} level</span>
            <span class="chip">{e(top.eqp_type)}</span>
            <span class="chip">Bad {top.bad_hits}/{NB} · Good {top.good_hits}/{NG}</span>
            <span class="chip">Fisher p {fmt_p(top.fisher_p)}</span>
            <span class="chip">RCA {top.rca_score:.0f}/100</span>
            {f'<span class="chip">Recurs at {int(top.recurrence)} stages: ' + e(", ".join(sorted(set(rca[(rca.level == top.level) & (rca.entity == top.entity)].stage)))) + '</span>' if top.recurrence > 1 else ''}
          </div>
          <p>At this stage the good wafers ran on <span class="mono">{e(good_alt)}</span>.
          {e(top.action)}</p>
          <div class="also"><div class="also-h">Also implicated</div>{also}</div>
        </div>"""

    alerts = "".join(
        f'<div class="alert {a["level"]}"><span class="alert-ic">{ALERT_ICON.get(a["level"], "ⓘ")}</span>'
        f'<div><b>{e(a["title"])}.</b> {e(a["text"])}</div></div>' for a in ctx["conf"])

    # ------------------------------------------------------------- findings text
    top3 = rca.head(3)
    top3_txt = "; ".join(f"<b>{e(r.stage)}</b> on <span class='mono'>{e(r.entity)}</span> ({e(r.category.lower())})"
                         for r in top3.itertuples())
    full_stages = ", ".join(e(s) for s in div_c.sort_values("ami", ascending=False)[div_c.ami >= 0.6].stage.head(14))
    worst_dq = dq[dq.n_bad >= min(2, NB)].head(3) if len(dq) else pd.DataFrame()
    dq_txt = "; ".join(f"<span class='mono'>{e(r.key)}</span> (bad median {r.bad_median:.4f} vs good "
                       f"{r.good_median:.4f}, z = {r.robust_z:.1f})" for r in worst_dq.itertuples()) or "No chamber with comparable DCQV data."
    exc_top = ex.head(3)
    exc_txt = "; ".join(f"<span class='mono'>{e(r.tool)}</span> {100 * r.rate_bad:.1f}% bad vs {100 * r.rate_good:.1f}% good"
                        for r in exc_top.itertuples())
    rev = ctx["revisits"]
    rev_txt = (", ".join(f"{e(s)} ({n} wafer-revisits)" for s, n in
                         rev[rev.label == "BAD"].groupby("stage").size().sort_values(ascending=False).head(6).items())
               if len(rev) else "none")
    q = ctx["q"]
    q_txt = ("; ".join(f"{e(r.stage)} {r.BAD:.1f} h vs {r.GOOD:.1f} h" for r in q.head(4).itertuples())
             if not q.empty and "log_ratio" in q else "n/a")
    jac = ctx["jac"]
    bb = jac.loc[sorted(ctx["bad"]), sorted(ctx["bad"])].values
    gg = jac.loc[sorted(ctx["good"]), sorted(ctx["good"])].values
    bg = jac.loc[sorted(ctx["bad"]), sorted(ctx["good"])].values
    within_b = bb[np.triu_indices(len(bb), 1)].mean() if len(bb) > 1 else np.nan
    within_g = gg[np.triu_indices(len(gg), 1)].mean() if len(gg) > 1 else np.nan
    between = bg.mean()
    ml_txt = ""
    if "table" in ml:
        mt = ml["table"]
        ml_txt = (f"{ml['n_features_raw']} raw features collapse into {ml['n_features_dealiased']} distinguishable "
                  f"patterns; the largest alias group holds {ml['alias_sizes'][0]} features that behave identically "
                  f"across all wafers. Top stable feature: <span class='mono'>{e(_clip(mt.display.iloc[0], 90))}</span> "
                  f"(selection frequency {mt.stability.iloc[0]:.2f}).")

    # ------------------------------------------------------------- RCA table
    trs = []
    for r in rca.head(20).itertuples():
        tb = TIER_BADGE[r.tier]
        alt = good_path_at(ctx["main"], ctx["good"], r.stage, r.eqp_class, r.module_type if r.level != "TOOL" else None)
        dz = "—" if pd.isna(r.dcqv_robust_z) else f"{r.dcqv_robust_z:.1f}"
        trs.append(f"""<tr>
          <td class="num">{r.rank}</td><td><span class="badge {tb[0]}">{tb[1]} {tb[2]}</span></td>
          <td class="mono">{e(r.stage)}</td><td>{e(r.level.title())}</td>
          <td class="mono">{e(r.entity)}</td><td class="mono dim">{e(_clip(alt, 60))}</td>
          <td><span class="cat" style="--c:{CATEGORY_COLOR[r.category]}">{e(r.category)}</span></td>
          <td class="num">{r.bad_hits}/{NB}</td><td class="num">{r.good_hits}/{NG}</td>
          <td class="num">{fmt_p(r.fisher_p)}</td><td class="num">{r.stability:.2f}</td><td class="num">{dz}</td>
          <td class="num"><b>{r.rca_score:.1f}</b></td><td class="small">{e(r.action)}</td></tr>""")
    rca_table = "".join(trs)

    dq_rows = "".join(
        f"<tr><td class='mono'>{e(r.stage)}</td><td class='mono'>{e(r.tool)} :: {e(r.module)}{'' if r.baseline == 'same chamber' else ' †'}</td>"
        f"<td class='num'>{r.bad_median:.4f}</td><td class='num'>{r.good_median:.4f}</td>"
        f"<td class='num'>{r.robust_z:.1f}</td><td class='num'>{r.cliffs_delta:.2f}</td><td class='num'>{fmt_p(r.mw_p)}</td>"
        f"<td>{'<span class=\"badge crit\">▼ Degraded</span>' if r.degraded else '<span class=\"badge muted\">○ Normal</span>'}</td></tr>"
        for r in dq[dq.n_bad >= min(2, NB)].head(12).itertuples()) if len(dq) else ""

    anom_rows = "".join(
        f"<tr><td><span class='dot {'bad' if r.label == 'BAD' else 'good'}'></span>{e(r.label)}</td><td class='mono'>{e(r.wafer)}</td>"
        f"<td class='num'>{r.stages}</td><td class='num'>{r.rework_events}</td><td class='num'>{r.retest_events}</td>"
        f"<td class='num'>{r.untracked_runs}</td><td class='num'>{r.stage_revisits}</td><td class='num'>{r.lot_ids}</td>"
        f"<td class='num'>{r.cycle_days:.1f}</td><td class='num'>{r.mean_dcqv:.4f}</td><td class='num'>{r.excursions}</td></tr>"
        for r in anom.itertuples())

    # head-to-head substitution table (classic commonality output)
    sub = comm[(comm.category == CAT_SUB) & (comm.level != "RECIPE")].copy()
    sub["order"] = sub.stage.map(ctx["stage_order"])
    sub_rows = []
    for stg, g in sub.sort_values("order").groupby("stage", sort=False):
        ch = g[g.level == "CHAMBER"]
        tl = g[g.level == "TOOL"]
        bad_path = ", ".join(sorted(set(ch.entity))) or ", ".join(sorted(set(tl.entity)))
        kind = "Tool swap" if len(tl) else "Chamber swap"
        sub_rows.append(f"<tr><td class='mono'>{e(stg)}</td><td>{kind}</td>"
                        f"<td class='mono' style='color:var(--bad)'>{e(bad_path)}</td>"
                        f"<td class='mono' style='color:var(--good)'>{e(good_path_at(ctx['main'], ctx['good'], stg, g.eqp_class.iloc[0], sorted(set(ch.module_type)) if len(ch) else None))}</td>"
                        f"<td class='mono dim'>{e(g.eqp_type.iloc[0])}</td></tr>")
    sub_table = "".join(sub_rows) or "<tr><td colspan='5'>No head-to-head substitutions found.</td></tr>"

    rules = e(ml.get("tree_rules", "scikit-learn not available"))

    figs_json = json.dumps(_sanitize(json.loads(json.dumps(figs, cls=_Enc))))
    gen = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    files = ", ".join(f["file"] for f in ctx["info"]["files"])

    def section(fid, title, what, how, finding, height_cls=""):
        return f"""
      <section class="card">
        <div class="card-head"><h2>{title}</h2></div>
        <p class="what">{what}</p>
        <div id="{fid}" class="chart {height_cls}"></div>
        <div class="read"><div><h4>How to read it</h4><p>{how}</p></div>
        <div class="finding"><h4>Finding</h4><p>{finding}</p></div></div>
      </section>"""

    body_sections = "".join([
        section("fig_rank", "1 · Fused suspect ranking",
                "Every tool, chamber and recipe that bad wafers used more often than good wafers, scored 0–100 by blending "
                f"commonality ({int(W_COMMONALITY * 100)}%), DCQV degradation ({int(W_DCQV * 100)}%), recurrence of the same "
                f"tool/chamber across stages ({int(W_RECUR * 100)}%), L1 stability selection ({int(W_STABILITY * 100)}%) and "
                f"Extra-Trees importance ({int(W_FOREST * 100)}%).",
                "Longer bars are stronger suspects. Colour shows the granularity of the entity. Hover for the raw evidence "
                "behind each score. A chamber-level hit is more actionable than a tool-level hit for the same stage.",
                f"Top three suspects: {top3_txt}."),
        section("fig_volcano", "2 · Commonality coverage plane",
                "Every tested tool/chamber/recipe placed by how many bad wafers (y) and how many good wafers (x) passed "
                "through it. Bubble size is the number of entities at that point; colour is the evidence category.",
                "The top-left corner (all bad, no good) is the commonality signature; the further right, the more good "
                "wafers share the entity and the weaker the suspicion. Red = head-to-head substitution, yellow = extra or "
                "unlogged step, grey = coverage gap (stage never recorded on good wafers). Hover a bubble to list its entities.",
                f"{n_excl} entities sit at the maximum (every bad wafer, no good wafer). {n_sub} of them are head-to-head "
                f"substitutions (red); the rest (yellow) are extra or unlogged steps. {n_gap} more are coverage gaps that "
                f"need good-wafer data before they can be judged."),
        section("fig_flow", "3 · Where the paths diverge along the flow",
                "For each stage recorded on both groups, the chance-corrected adjusted mutual information (AMI) between the "
                "wafer's chamber path at that stage and its good/bad label, in route order. Hover also shows Cramér's V on "
                "the coarser tool-level path.",
                "AMI near 1 (red) means the chamber assignment alone separates bad from good at that stage. AMI corrects "
                "for chance, so track or cluster tools that give every wafer a unique module sequence do not score "
                "high just for being diverse. Blue stages ran on shared chambers and can be ruled out.",
                f"{n_div_full} of {len(div_c)} comparable stages separate the groups beyond chance, strongest first: {full_stages}."),
        section("fig_hit", "4 · Wafer × suspect pass matrix",
                "Which wafer passed through each of the top-25 suspects. Rows are wafers (bad first), columns are suspects "
                "in rank order.",
                "A perfect commonality signature is a solid block for the bad rows and empty cells for the good rows. "
                "Columns lit for some good wafers are weaker suspects.",
                f"{n_perfect} of the top {len(rca.head(25))} suspects show the perfect signature (every bad wafer, no good wafer). "
                f"Entities lit for only one bad wafer would point to a second, independent cause."),
        section("fig_dcqv", "5 · FDC health (DCQV) of the most-degraded chambers",
                "Per-wafer minimum DCQV at the eight stage/chamber combinations where bad wafers deviate most from the "
                "good-wafer baseline (robust z-score on median / MAD). Only rows seen on every bad wafer are plotted. † = the good "
                "wafers never used this chamber, so the baseline is their peer chamber of the same module type at the same stage.",
                "DCQV is the FDC data-collection quality / health index (1.0 = ideal). A bad-wafer cloud sitting below the "
                "whole good-wafer box points to an abnormal chamber state during that run, not just a different assignment.",
                f"Strongest DCQV deviations: {dq_txt}."),
        section("fig_exc", "6 · DCQV excursion rate by tool",
                f"Share of FDC records with DCQV below {cfg.dcqv_threshold}, split by group. Tools are ordered by how much "
                f"higher the bad-wafer excursion rate is.",
                "A tool whose bad-wafer excursion rate is well above its good-wafer rate was less healthy while processing "
                "the bad lot. Hover to check the record count before acting on small samples.",
                f"Largest excursion-rate gaps: {exc_txt}."),
        section("fig_time", "7 · Process timeline",
                "Every main-route FDC record plotted by start time against route position, plus off-route events "
                "(rework, retest, untracked moves) on the top band.",
                "Separated clouds mean the groups never ran at the same time, so tool state is aliased with calendar time. "
                "Clusters of × markers show where the bad lot left the main route.",
                "Check PM, part-swap and recipe-change logs on the suspect tools for the window between the two groups."),
        section("fig_anom", "8 · Flow anomalies per wafer",
                "Counts of off-route activity per wafer: rework passes, retest-stage moves, stage re-visits (the same stage "
                f"operation processed again more than {cfg.revisit_gap_hours:g} h later) and untracked (UNDEFINED-route) runs.",
                "Extra litho rework and re-visits often co-occur with yield loss, either as a symptom of an upstream "
                "problem or as a direct cause (resist strip damage, extra thermal budget).",
                f"Stages re-visited by bad wafers: {rev_txt}."),
        section("fig_q", "9 · Queue time (Q-time) before each step",
                "Median idle hours between finishing the previous stage and starting this one, for the stages where bad and "
                "good wafers differ most (log scale).",
                "Long Q-time before Cu or barrier steps allows oxidation and moisture uptake. Bars much taller for bad "
                "wafers flag possible Q-time violations.",
                f"Largest Q-time differences (bad vs good): {q_txt}."),
        section("fig_jac", "10 · Wafer path similarity",
                "Jaccard similarity of tool-level main-route paths (set of stage → tool assignments) between every pair of wafers.",
                "Two bright blocks on the diagonal with a dark off-diagonal mean bad and good wafers took systematically "
                "different routes through the fab, which is the fingerprint of tool commonality.",
                f"Mean similarity within bad wafers {within_b:.2f}, within good {within_g:.2f}, between groups {between:.2f}."),
    ])
    ml_sections = ""
    if "fig_stab" in figs:
        ml_sections = "".join([
            section("fig_stab", "11 · ML · L1-logistic stability selection",
                    f"{cfg.n_bootstrap} bootstrap resamples × random 50% feature subspaces × random regularisation strength. "
                    "The bar is how often a feature group was selected with a bad-wafer-positive coefficient.",
                    "Frequency near 1 means the feature is selected no matter how the data are perturbed. "
                    "“(+k)” means k other features have exactly the same wafer pattern and cannot be told apart statistically; "
                    "the label shows the member with the strongest commonality score. When many features separate the "
                    "groups perfectly, L1 spreads its choice across them, so frequencies stay low and the ranking matters "
                    "more than the absolute value.",
                    ml_txt),
            section("fig_rf", "12 · ML · Extra-Trees feature importance",
                    "Impurity importance from a 1,000-tree class-balanced Extra-Trees model on de-aliased features "
                    "(tool/chamber/recipe passes, per-chamber DCQV, flow anomalies).",
                    "Importance is shared among equally good splits, so with perfectly separable data it spreads across "
                    "alias groups. Read it together with stability selection, not alone.",
                    f"Leave-one-out balanced accuracy: Extra-Trees {100 * ml.get('loo_forest_bal', 0):.0f}%, "
                    f"L1-logistic {100 * ml.get('loo_l1_bal', 0):.0f}%. High accuracy here confirms the groups are separable; "
                    f"it does not by itself identify the cause."),
        ])

    css = CSS
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FDC Commonality RCA</title>
<style>{css}</style>{plotly_js()}</head>
<body>
<header class="hero">
  <div class="hero-inner">
    <div class="eyebrow">Yield root-cause analysis · Tool commonality</div>
    <h1>{e(cfg.title)}</h1>
    <p class="sub">{NB} low-yield wafers vs {NG} reference wafers · main route <span class="mono">{e(ctx['main_route'])}</span> ·
      generated {gen} · engine v{__version__}</p>
  </div>
</header>
<main>
  <div class="kpis">{kpis}</div>
  <div class="two">{verdict}<div class="alerts"><h3>Read before acting</h3>{alerts}</div></div>

  <section class="card">
    <div class="card-head"><h2>Root-cause candidate table</h2></div>
    <p class="what">Top 20 entities from the fused ranking with the full evidence trail and the tool the good wafers used at
    the same stage. Confidence tiers: <span class="badge crit">▲ High</span> head-to-head tool or chamber substitution;
    <span class="badge serious">● Medium</span> recipe change, extra/unlogged step, shared by every bad wafer, or strong DCQV
    degradation; <span class="badge muted">○ Low</span> partial or coverage-gap. Siblings with identical wafer patterns
    (e.g. several modules of one tool) are merged into one row.</p>
    <div class="tablewrap"><table>
      <thead><tr><th>#</th><th>Tier</th><th>Stage</th><th>Level</th><th>Suspect entity</th><th>Good wafers used</th>
      <th>Category</th><th>Bad</th><th>Good</th><th>Fisher p</th><th>Stability</th><th>DCQV z</th><th>RCA</th><th>Recommended check</th></tr></thead>
      <tbody>{rca_table}</tbody></table></div>
  </section>

  <section class="card">
    <div class="card-head"><h2>Head-to-head substitutions · where the bad lot took a different tool</h2></div>
    <p class="what">Stages where both groups ran the same kind of process but every bad wafer used a tool or chamber that no
    good wafer used. This is the cleanest commonality evidence because the step itself is matched. Listed in route order.</p>
    <div class="tablewrap"><table><thead><tr><th>Stage</th><th>Type</th><th>Bad wafers used</th><th>Good wafers used (count)</th>
    <th>Equipment type</th></tr></thead><tbody>{sub_table}</tbody></table></div>
  </section>

  {body_sections}
  {ml_sections}

  <section class="card">
    <div class="card-head"><h2>13 · Data coverage</h2></div>
    <p class="what">How many process stages carry FDC context for both groups versus only one. Commonality is only fully
    valid where both groups were observed.</p>
    <div id="fig_cov" class="chart short"></div>
    <div class="read"><div><h4>How to read it</h4><p>Bad-only stages produce “coverage gap” candidates that must be checked
    against MES history for the good lot before being trusted. Good-only stages usually mean the bad-lot data window starts
    later in the flow.</p></div>
    <div class="finding"><h4>Finding</h4><p>{int((div.coverage == 'Both').sum())} stages comparable, {int((div.coverage == 'BAD-only').sum())} bad-only,
    {int((div.coverage == 'GOOD-only').sum())} good-only.</p></div></div>
  </section>

  <div class="two">
    <section class="card">
      <div class="card-head"><h2>DCQV chamber statistics</h2></div>
      <p class="what">Stage/chamber combinations ranked by robust z of the bad-wafer median against the good-wafer baseline.</p>
      <div class="tablewrap"><table><thead><tr><th>Stage</th><th>Chamber</th><th>Bad med</th><th>Good med</th><th>Robust z</th>
      <th>Cliff δ</th><th>MW p</th><th>State</th></tr></thead><tbody>{dq_rows}</tbody></table></div>
      <p class="foot">Baseline = same chamber on good wafers, or † peer chambers at the same stage when good wafers never used it.</p>
    </section>
    <section class="card">
      <div class="card-head"><h2>Decision-tree rules (depth 2)</h2></div>
      <p class="what">The simplest rules that separate the groups. Several equally valid splits usually exist (aliasing),
      so treat the rule as one representative of its alias group.</p>
      <pre class="rules">{rules}</pre>
    </section>
  </div>

  <section class="card">
    <div class="card-head"><h2>Wafer summary</h2></div>
    <div class="tablewrap"><table><thead><tr><th>Group</th><th>Wafer</th><th>Stages</th><th>Rework</th><th>Retest</th>
    <th>Untracked</th><th>Re-visits</th><th>Lot IDs</th><th>Span (d)</th><th>Mean DCQV</th><th>DCQV excursions</th></tr></thead>
    <tbody>{anom_rows}</tbody></table></div>
  </section>

  <section class="card method">
    <div class="card-head"><h2>Methodology</h2></div>
    <div class="grid3">
      <div><h4>① Commonality statistics</h4><p>Each main-route (stage, entity) pair is tested at tool, chamber and recipe
      level. Coverage = share of a group that passed through it; Δ-coverage = bad − good. A one-sided Fisher exact test gives p,
      Benjamini–Hochberg gives q, and a Haldane-corrected odds ratio is reported. A bad-exclusive entity is a
      <i>substitution</i> when good wafers ran the same equipment class (and module type) at that stage on a different
      entity, otherwise an <i>extra/unlogged</i> step. Score = 100 × Δ-coverage × evidence (log p ÷ log p<sub>min</sub>) ×
      category weight (substitution 1.0, extra 0.55, coverage gap 0.35) × level weight (recipe 0.75). Stage divergence uses
      chance-corrected adjusted mutual information on the chamber path and Cramér's V on the tool path.</p></div>
      <div><h4>② FDC health &amp; flow</h4><p>For every stage/chamber, the per-wafer minimum DCQV is compared with a robust
      z-score (median; scale = max(MAD, IQR/1.349, 0.005)), Mann-Whitney U and Cliff's δ. Chambers the good wafers never
      used are compared against their peer chambers of the same module type at that stage. Excursion rate counts DCQV &lt;
      {cfg.dcqv_threshold}. Flow analysis classifies routes (main, rework, retest, WAT, untracked), detects stage re-visits
      (same stage and operation) separated by more than {cfg.revisit_gap_hours:g} h, counts lot-ID splits and computes Q-time between consecutive stages.</p></div>
      <div><h4>③ Machine learning &amp; fusion</h4><p>Binary pass features, per-chamber DCQV and flow counts are de-aliased
      (identical wafer patterns merged), then ranked by L1-logistic stability selection (bootstrap, random subspace and
      random C) and Extra-Trees impurity importance. Generalisation is checked with leave-one-out CV. The final RCA score blends
      commonality {W_COMMONALITY}, DCQV {W_DCQV}, cross-stage recurrence {W_RECUR}, stability {W_STABILITY} and forest {W_FOREST}.</p></div>
    </div>
    <p class="foot">Input files: {e(files)}</p>
  </section>
</main>
<footer>FDC Tool-Commonality RCA · v{__version__} · results rank hypotheses for engineering verification, not proof of causation.</footer>
<script>
const FIGS = {figs_json};
const CFG = {{displaylogo:false, responsive:true, modeBarButtonsToRemove:['lasso2d','select2d','autoScale2d']}};
for (const [id, f] of Object.entries(FIGS)) {{
  const el = document.getElementById(id);
  if (el && f.data && f.data.length) Plotly.newPlot(el, f.data, f.layout, CFG);
  else if (el) el.innerHTML = '<div class="empty">Not enough data for this view.</div>';
}}
</script>
</body></html>"""


CSS = """
:root{--page:#0d0d0d;--surface:#1a1a19;--surface2:#21211f;--ink:#fff;--ink2:#c3c2b7;--muted:#898781;
--grid:#2c2c2a;--axis:#383835;--good:#3987e5;--bad:#d95926;--red:#e66767;--yellow:#c98500;--violet:#9085e9;
--crit:#d03b3b;--serious:#ec835a;--warn:#fab219;--ring:rgba(255,255,255,.08)}
*{box-sizing:border-box}html{color-scheme:dark}
body{margin:0;background:var(--page);color:var(--ink2);font:14px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.92em;color:var(--ink)}
.hero{background:radial-gradient(1200px 300px at 15% 0%,rgba(57,135,229,.22),transparent 60%),
radial-gradient(900px 260px at 85% 10%,rgba(217,89,38,.18),transparent 60%),#111110;border-bottom:1px solid var(--ring)}
.hero-inner{max-width:1440px;margin:0 auto;padding:40px 24px 30px}
.eyebrow{text-transform:uppercase;letter-spacing:.14em;font-size:11px;color:var(--muted);font-weight:600}
h1{color:var(--ink);font-size:30px;margin:8px 0 6px;letter-spacing:-.01em}
.sub{margin:0;color:var(--ink2)}
main{max-width:1440px;margin:0 auto;padding:22px 24px 40px}
.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px;margin-bottom:16px}
.kpi{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:16px 18px;position:relative;overflow:hidden}
.kpi:before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--good)}
.kpi.accent-red:before{background:var(--red)}.kpi.accent-yellow:before{background:var(--yellow)}.kpi.accent-violet:before{background:var(--violet)}
.kpi-label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
.kpi-value{font-size:32px;color:var(--ink);font-weight:700;margin:4px 0 2px;letter-spacing:-.02em}
.kpi-sub{font-size:12.5px;color:var(--ink2)}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:5px;vertical-align:middle}
.dot.bad{background:var(--bad)}.dot.good{background:var(--good)}
.two{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:16px}
@media(max-width:1000px){.two{grid-template-columns:1fr}}
.verdict{background:linear-gradient(135deg,rgba(230,103,103,.14),rgba(26,26,25,1) 55%);border:1px solid rgba(230,103,103,.35);
border-radius:12px;padding:20px 22px}
.verdict-tag{font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:var(--red);font-weight:700}
.verdict-main{font-size:21px;color:var(--ink);font-weight:650;margin:8px 0 12px;word-break:break-word}
.verdict-row{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px}
.verdict p{margin:6px 0 0}
.also{margin-top:14px;border-top:1px solid var(--ring);padding-top:10px}
.also-h{font-size:11px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);font-weight:600;margin-bottom:6px}
.also-r{display:flex;gap:10px;align-items:center;padding:4px 0;font-size:13px}.also-r .dim{color:var(--muted)}
.chip{background:var(--surface2);border:1px solid var(--ring);border-radius:999px;padding:3px 10px;font-size:12px;color:var(--ink2)}
.badge{display:inline-block;border-radius:6px;padding:2px 8px;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid}
.badge.crit{color:#ffb3b3;border-color:rgba(208,59,59,.6);background:rgba(208,59,59,.15)}
.badge.serious{color:#ffc3a8;border-color:rgba(236,131,90,.55);background:rgba(236,131,90,.12)}
.badge.muted{color:var(--ink2);border-color:var(--axis);background:transparent}
.alerts{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:16px 18px}
.alerts h3{margin:0 0 10px;color:var(--ink);font-size:15px}
.alert{display:flex;gap:10px;padding:9px 10px;border-radius:8px;margin-bottom:8px;background:var(--surface2);border-left:3px solid var(--warn)}
.alert.serious{border-left-color:var(--serious)}.alert-ic{font-size:16px;line-height:1.3}
.alert b{color:var(--ink)}
.card{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:18px 20px 16px;margin-bottom:16px}
.card-head h2{margin:0;color:var(--ink);font-size:17px;letter-spacing:-.005em}
.what{margin:6px 0 10px;color:var(--ink2);max-width:1100px}
.chart{width:100%;min-height:380px}.chart.short{min-height:300px}
.read{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:8px}
@media(max-width:900px){.read{grid-template-columns:1fr}}
.read h4,.method h4{margin:0 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.read p{margin:0;font-size:13.5px}
.finding{background:rgba(57,135,229,.07);border:1px solid rgba(57,135,229,.25);border-radius:8px;padding:10px 12px}
.finding p{color:var(--ink)}
.tablewrap{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;color:var(--muted);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.05em;
padding:8px 10px;border-bottom:1px solid var(--axis);white-space:nowrap;position:sticky;top:0;background:var(--surface)}
td{padding:8px 10px;border-bottom:1px solid var(--grid);vertical-align:top}
tr:hover td{background:rgba(255,255,255,.025)}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
td.small{font-size:12px;color:var(--ink2);min-width:280px}.dim{color:var(--ink2)!important}
.cat{display:inline-flex;align-items:center;gap:6px;font-size:12px;white-space:nowrap}
.cat:before{content:"";width:8px;height:8px;border-radius:2px;background:var(--c)}
pre.rules{background:#121211;border:1px solid var(--ring);border-radius:8px;padding:12px;color:var(--ink);font-size:12px;
overflow-x:auto;white-space:pre;margin:0}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}
@media(max-width:1000px){.grid3{grid-template-columns:1fr}}
.method p{font-size:13.5px;margin:0}.foot{margin-top:14px!important;color:var(--muted);font-size:12px}
.empty{color:var(--muted);padding:40px;text-align:center}
footer{text-align:center;color:var(--muted);font-size:12px;padding:20px 24px 40px}
"""


# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------
def run(cfg: Config) -> Dict:
    paths = sorted({p for pat in cfg.inputs for p in glob.glob(pat)})
    if not paths:
        raise SystemExit(f"No input files match {cfg.inputs}")
    print(f"[1/7] Loading {len(paths)} FDC files ...")
    df, info = load_fdc(paths)
    df = assign_labels(df, cfg)
    df, main_route = classify_routes(df)
    labels = df.groupby("wafer")["label"].first().to_dict()
    bad = {w for w, l in labels.items() if l == "BAD"}
    good = {w for w, l in labels.items() if l == "GOOD"}
    wafer_order = sorted(bad) + sorted(good)
    main = df[df.route_class == "MAIN"].copy()
    stage_order = main.groupby("stage")["op_num"].median()
    print(f"      {len(df):,} rows · {len(bad)} bad / {len(good)} good wafers · main route {main_route}")

    print("[2/7] Commonality statistics ...")
    long = entity_long(main)
    comm = commonality_table(long, bad, good)
    div = stage_divergence(main, bad, good, stage_order)

    print("[3/7] FDC health (DCQV) ...")
    dq, ex, per = dcqv_analysis(main, df, cfg.dcqv_threshold)

    print("[4/7] Flow anomalies & Q-time ...")
    anom, revisits = flow_anomalies(df, cfg.revisit_gap_hours, cfg.dcqv_threshold)
    q = qtime_analysis(main, bad, good)
    conf = confounding_checks(df, bad, good)

    print("[5/7] Machine learning ...")
    X, groups, member_of = build_feature_matrix(long, per, anom, wafer_order)
    y = np.array([1 if w in bad else 0 for w in wafer_order])
    ml = ml_analysis(X, y, groups, cfg)

    if "table" in ml:
        sc = comm.set_index("key")["commonality_score"].to_dict()

        def best(members: str) -> str:
            ms = members.split(" || ")
            return max(ms, key=lambda m: sc.get(m, -1.0))

        ml["table"]["display"] = ml["table"]["members"].map(best)
    print("[6/7] Evidence fusion ...")
    rca = fuse_evidence(comm, dq, ml, member_of, cfg)

    sets = long[long.level == "TOOL"].groupby("wafer")["key"].apply(set)
    jac = pd.DataFrame(index=wafer_order, columns=wafer_order, dtype=float)
    for a in wafer_order:
        for b in wafer_order:
            sa, sb = sets.get(a, set()), sets.get(b, set())
            jac.loc[a, b] = len(sa & sb) / len(sa | sb) if (sa | sb) else 0.0

    ctx = dict(cfg=cfg, df=df, info=info, main=main, main_route=main_route, labels=labels, bad=bad, good=good,
               wafer_order=wafer_order, long=long, comm=comm, div=div, dq=dq, ex=ex, per=per, anom=anom,
               revisits=revisits, q=q, conf=conf, ml=ml, rca=rca, jac=jac, p_floor=comm.attrs["p_floor"],
               stage_order=stage_order)

    print("[7/7] Rendering dashboard ...")
    figs = build_figures(ctx)
    with open(cfg.out_html, "w", encoding="utf-8") as f:
        f.write(render_html(ctx, figs))
    if cfg.csv_dir:
        os.makedirs(cfg.csv_dir, exist_ok=True)
        rca.to_csv(os.path.join(cfg.csv_dir, "rca_ranking.csv"), index=False)
        comm.to_csv(os.path.join(cfg.csv_dir, "commonality_all_entities.csv"), index=False)
        div.to_csv(os.path.join(cfg.csv_dir, "stage_divergence.csv"), index=False)
        dq.to_csv(os.path.join(cfg.csv_dir, "dcqv_chamber_stats.csv"), index=False)
        ex.to_csv(os.path.join(cfg.csv_dir, "dcqv_excursion_by_tool.csv"), index=False)
        anom.to_csv(os.path.join(cfg.csv_dir, "wafer_flow_anomalies.csv"), index=False)
        q.to_csv(os.path.join(cfg.csv_dir, "qtime_by_stage.csv"), index=False)
        if "table" in ml:
            ml["table"].to_csv(os.path.join(cfg.csv_dir, "ml_feature_groups.csv"), index=False)
    print(f"Done → {cfg.out_html}" + (f"  (tables in {cfg.csv_dir}/)" if cfg.csv_dir else ""))
    print("\nTop suspects:")
    for r in rca.head(8).itertuples():
        print(f"  #{r.rank:<2} {r.tier:<6} {r.rca_score:5.1f}  {r.stage:<14} {r.level:<8} {r.entity}")
    return ctx


def parse_args(argv=None) -> Config:
    ap = argparse.ArgumentParser(description="FDC tool-commonality root-cause analyzer with HTML dashboard")
    ap.add_argument("--input", "-i", nargs="+", default=["*.txt"], help="FDC file glob(s), tab-separated")
    ap.add_argument("--bad", default="M900037", help="comma-separated lot/wafer prefixes of low-yield wafers")
    ap.add_argument("--good", default="M900011", help="comma-separated lot/wafer prefixes of reference wafers")
    ap.add_argument("--labels", help="optional CSV with columns wafer,label (BAD/GOOD) - overrides prefixes")
    ap.add_argument("--out", default="FDC_RCA_Dashboard.html", help="output HTML dashboard")
    ap.add_argument("--csv-dir", default="rca_outputs", help="folder for CSV result tables ('' to skip)")
    ap.add_argument("--dcqv-threshold", type=float, default=0.97, help="DCQV value treated as an excursion")
    ap.add_argument("--revisit-gap", type=float, default=2.0, help="hours between runs that count as a stage re-visit")
    ap.add_argument("--top", type=int, default=15, help="suspects shown in ranking charts")
    ap.add_argument("--bootstrap", type=int, default=300, help="stability-selection resamples")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--title", default="FDC Tool-Commonality Root-Cause Analysis")
    a = ap.parse_args(argv)
    return Config(inputs=a.input, bad_keys=[s.strip() for s in a.bad.split(",") if s.strip()],
                  good_keys=[s.strip() for s in a.good.split(",") if s.strip()], labels_csv=a.labels,
                  out_html=a.out, csv_dir=a.csv_dir or None, dcqv_threshold=a.dcqv_threshold,
                  revisit_gap_hours=a.revisit_gap, top_n=a.top, n_bootstrap=a.bootstrap, seed=a.seed, title=a.title)


if __name__ == "__main__":
    run(parse_args())
