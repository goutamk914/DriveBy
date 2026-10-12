"""Phase 3.3/3.4 — validate the efficiency score against real fuel data, and report it honestly.

    python -m processor.validate --fuel data/fuel_log.csv --drives data/ --vehicle-epa 32 --out notebooks/out

Fuel log CSV (Day 1): date, odometer, gallons, price_total, car_id   (optional: filled_to_full)
Drive folders must already be processed (analysis.json from `python -m processor.run`).

Outputs: validation.png (predicted vs actual, r² and n annotated), residuals.png,
scoring_model.json (fitted weights — import into the app).
Mirrors Driveby/Core/Validation.swift.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

from . import contract as C
from .scoring import ScoringModel


def load_fuel_log(path) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    rename = {"odometer": "odometer_mi", "date": "logged_at", "car_id": "vehicle_id"}
    df = df.rename(columns={k: v for k, v in rename.items() if k in df.columns})
    df["logged_at"] = pd.to_datetime(df["logged_at"])
    # a date with no time means "sometime that day" → noon (see docs/DATA_CONTRACT.md)
    no_time = df["logged_at"].dt.hour.eq(0) & df["logged_at"].dt.minute.eq(0)
    df.loc[no_time, "logged_at"] += pd.Timedelta(hours=12)
    if "filled_to_full" not in df.columns:
        df["filled_to_full"] = True
    df["logged_at"] = df["logged_at"].dt.tz_localize(None)
    return df.sort_values("odometer_mi").reset_index(drop=True)


def load_processed_drives(root) -> pd.DataFrame:
    rows = []
    for f in sorted(Path(root).glob("*/analysis.json")):
        a = json.loads(f.read_text())
        side = json.loads((f.parent / "drive.json").read_text())
        rows.append({"drive_id": side["drive_id"], "vehicle_id": side.get("vehicle_id"),
                     "started_at": pd.to_datetime(side["started_at"]).tz_localize(None),
                     "miles": a["distance_m"] / C.METRES_PER_MILE, "obd_fuel_gal": a.get("obd_fuel_gal"),
                     **a["components"]})
    return pd.DataFrame(rows)


def tank_intervals(fuel: pd.DataFrame, drives: pd.DataFrame) -> pd.DataFrame:
    """Tank-to-tank MPG between consecutive FULL fills; partial fills roll forward into the next full."""
    out = []
    last_full, pending = None, 0.0
    for _, r in fuel.iterrows():
        if last_full is None:
            if bool(r.filled_to_full):
                last_full = r
            continue
        pending += float(r.gallons)
        if not bool(r.filled_to_full):
            continue
        miles = float(r.odometer_mi - last_full.odometer_mi)
        if miles > 0 and pending > 0:
            inside = drives[(drives.started_at >= last_full.logged_at) & (drives.started_at < r.logged_at)] if len(drives) else drives
            rec = float(inside.miles.sum()) if len(inside) else 0.0
            row = {"start": last_full.logged_at, "end": r.logged_at, "odometer_miles": miles, "gallons": pending,
                   "mpg": miles / pending, "recorded_miles": rec, "coverage": min(rec / miles, 1.0), "n_drives": len(inside)}
            if rec > 0:
                for k in C.COMPONENT_KEYS:  # distance-weighted mean of each component (Step 3.3, without OBD)
                    row[k] = float((inside[k] * inside.miles).sum() / rec)
            out.append(row)
        last_full, pending = r, 0.0
    return pd.DataFrame(out)


def fit_weights(rows: pd.DataFrame, target: np.ndarray, base: ScoringModel, ridge_lambda: float = 0.5) -> ScoringModel | None:
    """Regress target on normalised components; negate and rescale coefficients into weights (sum = 1)."""
    if len(rows) < 6:
        return None
    X = np.array([[base.normalized(r)[k] for k in C.COMPONENT_KEYS] for r in rows[list(C.COMPONENT_KEYS)].to_dict("records")])
    y = np.asarray(target, float)
    Xc, yc = X - X.mean(0), y - y.mean()
    beta = np.linalg.solve(Xc.T @ Xc + ridge_lambda * np.eye(X.shape[1]), Xc.T @ yc)
    raw = np.maximum(-beta, 0)
    if raw.sum() <= 0:
        return None
    m = ScoringModel(dict(zip(C.COMPONENT_KEYS, (raw / raw.sum()).tolist())), dict(base.normalization), dict(base.safety),
                     f"fitted:{pd.Timestamp.now().date()}")
    scores = [m.efficiency_score(r) for r in rows[list(C.COMPONENT_KEYS)].to_dict("records")]
    lr = stats.linregress(scores, y)
    m.fit_n, m.fit_r2 = len(rows), float(lr.rvalue ** 2)
    return m


def honest_summary(n: int, r2: float | None) -> str:
    if r2 is None:
        return f"n={n} — not enough data yet."
    strength = ("too few points to conclude anything" if n < 8 else "weak" if r2 < .25 else "moderate" if r2 < .5
                else "suggestive — the obvious next step is more data" if n < 20 else "strong")
    return f"n={n}, r²={r2:.2f} — {strength}."


def plot(scores, target, ylabel, title, out_png, residual_png=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    scores, target = np.asarray(scores, float), np.asarray(target, float)
    lr = stats.linregress(scores, target) if len(scores) >= 3 else None
    fig, ax = plt.subplots(figsize=(7, 5), dpi=200)
    ax.scatter(scores, target, s=46, color="#2563eb", edgecolor="white", linewidth=0.8, zorder=3)
    if lr is not None:
        xs = np.linspace(scores.min() - 2, scores.max() + 2, 50)
        ax.plot(xs, lr.intercept + lr.slope * xs, color="#0f172a", linewidth=1.5, zorder=2)
        ax.text(0.03, 0.95, f"r² = {lr.rvalue**2:.2f}   n = {len(scores)}", transform=ax.transAxes, va="top",
                fontsize=13, fontweight="bold", color="#0f172a")
    ax.set_xlabel("Driveby efficiency score")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(alpha=0.25)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(out_png)
    plt.close(fig)
    if residual_png and lr is not None:
        fig, ax = plt.subplots(figsize=(7, 3), dpi=200)
        resid = target - (lr.intercept + lr.slope * scores)
        ax.axhline(0, color="#64748b", linewidth=1)
        ax.scatter(scores, resid, s=30, color="#dc2626")
        ax.set_xlabel("Efficiency score"); ax.set_ylabel("Residual")
        ax.set_title("Residuals — structure here means the model is missing something")
        fig.tight_layout(); fig.savefig(residual_png); plt.close(fig)
    return lr


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--fuel", required=True)
    p.add_argument("--drives", required=True)
    p.add_argument("--vehicle-epa", type=float, default=None, help="EPA combined MPG (normalises the target)")
    p.add_argument("--model", default=None, help="existing scoring_model.json to start from")
    p.add_argument("--out", default="notebooks/out")
    p.add_argument("--min-coverage", type=float, default=0.5)
    a = p.parse_args(argv)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    base = ScoringModel.from_json(Path(a.model).read_text()) if a.model else ScoringModel()
    drives = load_processed_drives(a.drives)
    base = base.with_corpus(drives[list(C.COMPONENT_KEYS)].to_dict("records")) if len(drives) else base

    # Prefer per-trip OBD fuel (hundreds of points) over tank-to-tank (≈9 points).
    obd = drives.dropna(subset=["obd_fuel_gal"]) if "obd_fuel_gal" in drives else drives.iloc[0:0]
    obd = obd[obd.obd_fuel_gal > 0.01] if len(obd) else obd
    if len(obd) >= 10:
        rows, mpg = obd, obd.miles / obd.obd_fuel_gal
        source = "per-trip OBD-II"
    else:
        tanks = tank_intervals(load_fuel_log(a.fuel), drives)
        rows = tanks[(tanks.coverage >= a.min_coverage)].dropna(subset=list(C.COMPONENT_KEYS)) if len(tanks) else tanks
        mpg = rows.mpg if len(rows) else pd.Series(dtype=float)
        source = "tank-to-tank"
        tanks.to_csv(out / "tank_intervals.csv", index=False)
    target = mpg / a.vehicle_epa if a.vehicle_epa else mpg
    ylabel = "Actual MPG ÷ EPA combined" if a.vehicle_epa else "Actual MPG"

    fitted = fit_weights(rows, target.to_numpy(), base) if len(rows) else None
    model = fitted or base
    scores = [model.efficiency_score(r) for r in rows[list(C.COMPONENT_KEYS)].to_dict("records")] if len(rows) else []
    lr = plot(scores, target, ylabel, f"Efficiency score vs real fuel economy ({source})",
              out / "validation.png", out / "residuals.png") if len(scores) else None
    model.save(out / "scoring_model.json")
    summary = honest_summary(len(scores), None if lr is None else lr.rvalue ** 2)
    (out / "summary.txt").write_text(summary + "\n")
    print(summary)
    print(f"wrote {out/'validation.png'}, {out/'scoring_model.json'}")


if __name__ == "__main__":
    main()
