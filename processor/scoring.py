"""Phase 3 (efficiency score, validated against fuel) + Phase 5.3 (safety score, NOT validated).

Physics (Step 3.1): fuel goes to aerodynamic drag (∝ v²), rolling resistance (∝ v), accelerating
mass, and idling. Only braking is energy you bought and then threw away as heat.
Mirrors Driveby/Core/Scoring.swift.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

from . import contract as C
from .events import runs


def braking_intervals(df):
    """Contiguous runs with a_long < -0.5 m/s² (drag + engine braking above that isn't waste)."""
    return runs(df.a_long.to_numpy() < C.BRAKING_INTERVAL_A)


def braking_energy_per_km(df: pd.DataFrame, mass_kg: float, regen_factor: float = 0.0) -> float:
    """Kinetic energy dissipated by braking, per km. Units: J/km."""
    km = df.distance_m.iloc[-1] / 1000 if len(df) else 0.0
    if km <= 0.01:
        return 0.0
    v = df.v.to_numpy()
    total_j = 0.0
    for a, b in braking_intervals(df):
        v0, v1 = v[a], v[b]
        total_j += max(0.5 * mass_kg * (v0 ** 2 - v1 ** 2), 0.0)
    return total_j * (1 - min(max(regen_factor, 0.0), 1.0)) / km


def frac_time_above(df, threshold):
    return float(np.mean(df.v.to_numpy() > threshold)) if len(df) else 0.0


def mean_positive_accel_above(df, threshold):
    """Time-average of max(a_long − threshold, 0): captures how OFTEN and how HARD you launch."""
    return float(np.mean(np.maximum(df.a_long.to_numpy() - threshold, 0.0))) if len(df) else 0.0


def components(df: pd.DataFrame, mass_kg: float = 1500.0, regen_factor: float = 0.0) -> dict:
    dt = df.attrs.get("dt", 0.1)
    a_long = df.a_long.to_numpy()
    n = max(len(df), 1)
    jerk = np.gradient(a_long, dt) if len(df) > 1 else np.zeros(1)
    return {
        "brake_waste": braking_energy_per_km(df, mass_kg, regen_factor),     # J/km
        "idle_frac": float(np.sum(df.v.to_numpy() < C.IDLE_SPEED) / n),
        "jerk_rms": float(np.sqrt(np.sum(jerk ** 2) / n)) if len(df) > 1 else 0.0,
        "high_speed": frac_time_above(df, C.HIGH_SPEED),                    # 29 m/s ≈ 65 mph; drag ∝ v²
        "accel_waste": mean_positive_accel_above(df, C.ACCEL_WASTE_A),
    }


@dataclass
class ScoringModel:
    weights: dict = field(default_factory=lambda: dict(C.DEFAULT_WEIGHTS))
    normalization: dict = field(default_factory=lambda: {k: tuple(v) for k, v in C.DEFAULT_NORMALIZATION.items()})
    safety: dict = field(default_factory=lambda: dict(C.SAFETY_COEFFICIENTS))
    source: str = "default"
    fit_n: int | None = None
    fit_r2: float | None = None

    def normalized(self, comp: dict) -> dict:
        out = {}
        for k in C.COMPONENT_KEYS:
            p5, p95 = self.normalization[k]
            out[k] = float(np.clip((comp[k] - p5) / (p95 - p5), 0, 1)) if p95 > p5 else 0.0
        return out

    def efficiency_score(self, comp: dict) -> float:
        """score = 100 · (1 − clip(Σ w[k]·norm[k], 0, 1))"""
        norm = self.normalized(comp)
        return 100 * (1 - float(np.clip(sum(self.weights.get(k, 0) * norm[k] for k in C.COMPONENT_KEYS), 0, 1)))

    def with_corpus(self, corpus: list[dict], min_n: int = 5) -> "ScoringModel":
        """Normalise using p5/p95 across the whole drive corpus (fixed constants don't transfer between cars)."""
        if len(corpus) < min_n or self.source.startswith("fitted"):
            return self
        m = ScoringModel(dict(self.weights), dict(self.normalization), dict(self.safety), "corpus")
        for k in C.COMPONENT_KEYS:
            vals = np.array([c[k] for c in corpus], float)
            vals = vals[np.isfinite(vals)]
            p5, p95 = np.percentile(vals, 5), np.percentile(vals, 95)
            if p95 > p5:
                m.normalization[k] = (float(p5), float(p95))
        return m

    def to_json(self) -> str:
        """Same shape as Swift's ScoringModel Codable — import it in the app (Settings → Scoring model)."""
        return json.dumps({
            "version": 1, "source": self.source, "weights": self.weights,
            "normalization": {k: {"p5": v[0], "p95": v[1]} for k, v in self.normalization.items()},
            "safety": self.safety, "fitN": self.fit_n, "fitR2": self.fit_r2,
        }, indent=2, sort_keys=True)

    @classmethod
    def from_json(cls, s: str) -> "ScoringModel":
        o = json.loads(s)
        return cls(o["weights"], {k: (v["p5"], v["p95"]) for k, v in o["normalization"].items()},
                   o.get("safety", dict(C.SAFETY_COEFFICIENTS)), o.get("source", "imported"), o.get("fitN"), o.get("fitR2"))

    def save(self, path):
        Path(path).write_text(self.to_json())


def safety_score(events, df: pd.DataFrame, coefficients: dict | None = None) -> dict:
    """safety = 100 − 12·Σsev(hard_brake) − 14·tailgating_fraction − 6·Σsev(harsh_corner) − 15·speeding_fraction

    Event sums are normalised per 10 miles; fractions are of moving time. Built from established
    telematics thresholds — NOT validated (no crash data). Say so.
    """
    c = coefficients or C.SAFETY_COEFFICIENTS
    dt = df.attrs.get("dt", 0.1)
    miles = max(df.distance_m.iloc[-1] / C.METRES_PER_MILE, 1.0) if len(df) else 1.0
    factor = 10.0 / miles
    moving = float(np.sum(df.v.to_numpy() >= C.IDLE_SPEED)) * dt
    sev = lambda k: sum(e.severity for e in events if e.kind == k)
    tm = lambda k: sum(e.duration for e in events if e.kind == k)
    tail = min(max(tm("tailgating") / moving, 0), 1) if moving > 0 else 0.0
    spd = min(max(tm("speeding") / moving, 0), 1) if moving > 0 else 0.0
    hb = c["hard_brake"] * sev("hard_brake") * factor
    hc = c["harsh_corner"] * sev("harsh_corner") * factor
    tg = c["tailgating_fraction"] * tail
    sp = c["speeding_fraction"] * spd
    return {"hard_brake_points": hb, "tailgating_points": tg, "harsh_corner_points": hc, "speeding_points": sp,
            "tailgating_fraction": tail, "speeding_fraction": spd, "per_10_miles_factor": factor,
            "score": float(np.clip(100 - hb - tg - hc - sp, 0, 100))}
