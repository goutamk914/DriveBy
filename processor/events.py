"""Phase 2 — event detection: detect core runs → debounce → enrich.

Thresholds (Build Guide Step 2.2, industry telematics values; tune on your own footage):
    hard_brake    a_long < -3.0 m/s² sustained 0.5 s      severity -3 → 0, -6 → 1
    hard_accel    a_long >  2.5 m/s² sustained 0.5 s      severity 2.5 → 0, 5 → 1
    harsh_corner  |v · yaw_rate| > 3.0 m/s² sustained 0.5 s   severity 3 → 0, 6 → 1
    speeding      v > limit + 4.5 m/s for ≥ 5 s           0.6·excess + 0.4·duration
    idle          v < 0.5 m/s for > 60 s                  60 s → 0, 300 s → 1
    tailgating    headway < 1.0 s sustained 3 s           1.0 s → 0, 0.4 s → 1
Debounce: same-kind events within 2 s merge; a 5 s minimum gap between starts.
Mirrors Driveby/Core/Events.swift (parity-tested).
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field, asdict

import numpy as np
import pandas as pd

from . import contract as C
from .ingest import index_at


def ramp(v, a, b):
    if a == b:
        return 1.0 if v >= b else 0.0
    if v != v:  # NaN
        return 0.0
    return float(min(max((v - a) / (b - a), 0.0), 1.0))


def runs(mask):
    out, start = [], None
    for i, m in enumerate(mask):
        if m and start is None:
            start = i
        if not m and start is not None:
            out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(mask) - 1))
    return out


@dataclass
class Event:
    kind: str
    t_offset_s: float          # sensor time at event start
    t_end_s: float
    t_peak_s: float
    severity: float
    lat: float | None = None
    lon: float | None = None
    detail: dict = field(default_factory=dict)
    clip_path: str | None = None
    id: str = field(default_factory=lambda: str(uuid.uuid4()))

    @property
    def duration(self):
        return max(self.t_end_s - self.t_offset_s, 0.0)

    def to_row(self, drive_id: str | None = None) -> dict:
        d = asdict(self)
        if drive_id:
            d["drive_id"] = drive_id
        return d


def _run_events(df, kind, mask, sustain, peak_score, severity):
    dt = df.attrs.get("dt", 0.1)
    t, lat, lon = df.t.to_numpy(), df.lat.to_numpy(), df.lon.to_numpy()
    out = []
    for a, b in runs(mask):
        duration = (b - a + 1) * dt
        if duration < sustain - 1e-9:
            continue
        peak = a
        for i in range(a, b + 1):
            if peak_score(i) > peak_score(peak):
                peak = i
        out.append(Event(kind, float(t[a]), float(t[b] + dt), float(t[peak]), float(severity(peak, duration)),
                         float(lat[peak]), float(lon[peak])))
    return out


def headway(df: pd.DataFrame) -> np.ndarray:
    """Time headway (s) = lead distance / speed; NaN when no lead or v < 5 m/s. Gaps ≤ 0.5 s bridged."""
    dt = df.attrs.get("dt", 0.1)
    n = len(df)
    h = np.full(n, np.nan)
    ld, v = df.lead_dist.to_numpy(float), df.v.to_numpy(float)
    bridge = int(round(0.5 / dt))
    last = None
    for i in range(n):
        if np.isnan(ld[i]) or v[i] < C.TAILGATE_MIN_SPEED:
            continue
        h[i] = ld[i] / v[i]
        if last is not None and 1 < i - last <= bridge + 1 and not np.isnan(h[last]):
            for k in range(last + 1, i):
                if v[k] >= C.TAILGATE_MIN_SPEED:
                    h[k] = h[last]
        last = i
    return h


def detect_raw(df: pd.DataFrame, limits: pd.DataFrame | None) -> list[Event]:
    a_long, a_lat, gap, v = df.a_long.to_numpy(), df.a_lat.to_numpy(), df.gps_gap.to_numpy(), df.v.to_numpy()
    ev: list[Event] = []
    ev += _run_events(df, "hard_brake", (a_long < C.HARD_BRAKE_A) & ~gap, C.ACCEL_SUSTAIN,
                      lambda i: -a_long[i], lambda i, _: ramp(a_long[i], C.HARD_BRAKE_A, C.HARD_BRAKE_FULL))
    ev += _run_events(df, "hard_accel", (a_long > C.HARD_ACCEL_A) & ~gap, C.ACCEL_SUSTAIN,
                      lambda i: a_long[i], lambda i, _: ramp(a_long[i], C.HARD_ACCEL_A, C.HARD_ACCEL_FULL))
    lat_abs = np.abs(a_lat)
    ev += _run_events(df, "harsh_corner", (lat_abs > C.HARSH_CORNER_A) & ~gap, C.ACCEL_SUSTAIN,
                      lambda i: lat_abs[i], lambda i, _: ramp(lat_abs[i], C.HARSH_CORNER_A, C.HARSH_CORNER_FULL))
    if limits is not None:
        lim = limits.limit_mps.to_numpy(float)
        over = np.where(np.isnan(lim), -np.inf, v - lim)
        ev += _run_events(df, "speeding", over > C.SPEEDING_MARGIN, C.SPEEDING_SUSTAIN, lambda i: over[i],
                          lambda i, d: 0.6 * ramp(over[i], C.SPEEDING_MARGIN, C.SPEEDING_FULL_EXCESS)
                          + 0.4 * min(max(d / 60, 0), 1))
    # idle: > 60 s (strict), peak = middle of the run
    dt = df.attrs.get("dt", 0.1)
    t, lat, lon = df.t.to_numpy(), df.lat.to_numpy(), df.lon.to_numpy()
    for a, b in runs(v < C.IDLE_SPEED):
        d = (b - a + 1) * dt
        if d > C.IDLE_MIN:
            mid = (a + b) // 2
            ev.append(Event("idle", float(t[a]), float(t[b] + dt), float(t[mid]), ramp(d, C.IDLE_MIN, C.IDLE_FULL),
                            float(lat[mid]), float(lon[mid])))
    h = np.where(np.isnan(hw := headway(df)), np.inf, hw)
    ev += _run_events(df, "tailgating", h < C.TAILGATE_HEADWAY, C.TAILGATE_SUSTAIN, lambda i: -h[i],
                      lambda i, _: ramp(h[i], C.TAILGATE_HEADWAY, C.TAILGATE_FULL_HEADWAY))
    return ev


def debounce(events: list[Event]) -> list[Event]:
    result = []
    for kind in C.EVENT_KINDS:
        lst = sorted([e for e in events if e.kind == kind], key=lambda e: e.t_offset_s)
        merged: list[Event] = []
        for e in lst:
            if merged and (e.t_offset_s - merged[-1].t_end_s <= C.DEBOUNCE_MERGE + 1e-9
                           or e.t_offset_s - merged[-1].t_offset_s < C.DEBOUNCE_MIN_GAP - 1e-9):
                last = merged[-1]
                last.t_end_s = max(last.t_end_s, e.t_end_s)
                if e.severity > last.severity:
                    last.severity, last.t_peak_s, last.lat, last.lon = e.severity, e.t_peak_s, e.lat, e.lon
            else:
                merged.append(e)
        result += merged
    return result


def enrich(e: Event, df: pd.DataFrame, limits: pd.DataFrame | None, mass_kg: float) -> Event:
    dt = df.attrs.get("dt", 0.1)
    n = len(df)
    a = index_at(df, e.t_offset_s)
    b = max(index_at(df, e.t_end_s - dt), a)
    p = index_at(df, e.t_peak_s)
    v, a_long, a_lat = df.v.to_numpy(), df.a_long.to_numpy(), df.a_lat.to_numpy()
    d = {"duration_s": (b - a + 1) * dt}
    if e.kind in ("hard_brake", "hard_accel"):
        braking = e.kind == "hard_brake"
        inm = (lambda i: a_long[i] < C.BRAKING_INTERVAL_A) if braking else (lambda i: a_long[i] > -C.BRAKING_INTERVAL_A)
        lo, hi = a, b
        while lo > 0 and inm(lo - 1):
            lo -= 1
        while hi < n - 1 and inm(hi + 1):
            hi += 1
        d.update(v_start_mps=float(v[lo]), v_end_mps=float(v[hi]), duration_s=(hi - lo) * dt, peak=float(a_long[p]))
        if braking:
            d["energy_j"] = max(0.5 * mass_kg * (v[lo] ** 2 - v[hi] ** 2), 0.0)
    elif e.kind == "harsh_corner":
        d.update(v_start_mps=float(v[p]), peak=float(abs(a_lat[p])))
    elif e.kind == "speeding":
        d["v_start_mps"] = float(v[p])
        if limits is not None and not np.isnan(limits.limit_mps.iloc[p]):
            d["limit_mps"] = float(limits.limit_mps.iloc[p])
            d["peak"] = float(v[p] - d["limit_mps"])
    elif e.kind == "tailgating":
        h = headway(df)
        d.update(headway_s=None if np.isnan(h[p]) else float(h[p]), peak=None if np.isnan(h[p]) else float(h[p]),
                 lead_dist_m=None if np.isnan(df.lead_dist.iloc[p]) else float(df.lead_dist.iloc[p]),
                 v_start_mps=float(v[p]))
    if limits is not None:
        d["road"] = limits.road.iloc[p]
    e.detail = d
    return e


def detect(df: pd.DataFrame, limits: pd.DataFrame | None = None, mass_kg: float = 1500.0) -> list[Event]:
    """Full pipeline on a trip slice. `limits` from speedlimits.match(), or None when unavailable."""
    if len(df) < 2:
        return []
    raw = detect_raw(df, limits)
    return sorted((enrich(e, df, limits, mass_kg) for e in debounce(raw)), key=lambda e: e.t_offset_s)


def events_frame(events: list[Event]) -> pd.DataFrame:
    """Timestamped event list — Phase 2 'done when'."""
    return pd.DataFrame([{**{k: v for k, v in asdict(e).items() if k != "detail"}, **e.detail} for e in events])
