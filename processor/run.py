from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from . import contract as C
from . import events as E
from . import ingest as I
from . import scoring as S
from . import speedlimits as SL


def obd_fuel(obd, t0, t1):
    w = obd[(obd.t >= t0) & (obd.t <= t1)]
    if len(w) < 10:
        return None, None
    rate = w.dropna(subset=["fuel_lph"])
    if len(rate) >= len(w) // 2:
        t, gps = rate.t.to_numpy(float), rate.fuel_lph.to_numpy(float) / C.LITRES_PER_GALLON / 3600
        method = "fuel_rate"
    else:
        maf = w.dropna(subset=["maf"])
        t, gps = maf.t.to_numpy(float), maf.maf.to_numpy(float) / C.STOICHIOMETRIC_AFR / C.GRAMS_GASOLINE_PER_GALLON
        method = "maf"
    if len(t) < 10:
        return None, None
    dt = np.diff(t)
    ok = (dt > 0) & (dt < 10)
    return float(np.sum(0.5 * (gps[1:] + gps[:-1])[ok] * dt[ok])), method


def analyze(drive: I.Drive, ways, mass_kg=1500.0, regen=0.0) -> dict:
    if drive.trip is None:
        raise ValueError("never moved")
    df = drive.trip_df
    dist, dur = float(df.distance_m.iloc[-1]), I.duration(df)
    if dist < C.MIN_TRIP_DISTANCE or dur < C.MIN_TRIP_DURATION:
        raise ValueError(f"too short: {dist:.0f} m, {dur:.0f} s")
    limits = SL.match(df, ways) if ways is not None else None
    evs = E.detect(df, limits, mass_kg)
    comps = S.components(df, mass_kg, regen)
    safety = S.safety_score(evs, df)
    hw = E.headway(df)
    step = max(int(I.round_half_away(0.5 / df.attrs["dt"])), 1)
    trace = []
    for i in range(0, len(df), step):
        trace.append({"t": float(df.t.iloc[i]), "v": float(df.v.iloc[i]), "a": float(df.a_long.iloc[i]),
                      "lat": float(df.lat.iloc[i]), "lon": float(df.lon.iloc[i]), "a_lat": float(df.a_lat.iloc[i]),
                      "headway": None if np.isnan(hw[i]) else float(hw[i]),
                      "limit": None if limits is None or np.isnan(limits.limit_mps.iloc[i]) else float(limits.limit_mps.iloc[i])})
    t0, t1 = float(df.t.iloc[0]), float(df.t.iloc[-1] + df.attrs["dt"])
    fuel, method = obd_fuel(drive.log.obd, t0, t1)
    cov = 0.0 if limits is None else float(np.mean(~np.isnan(limits.limit_mps.to_numpy(float))))
    return {
        "version": 2, "trip_start_t": t0, "trip_end_t": t1, "distance_m": dist, "duration_s": dur,
        "moving_s": float(np.sum(df.v.to_numpy() >= C.IDLE_SPEED) * df.attrs["dt"]),
        "max_speed_mps": float(df.v.max()), "components": comps, "safety": safety,
        "events": [{"id": e.id, "kind": e.kind, "t_offset_s": e.t_offset_s, "t_end_s": e.t_end_s, "t_peak_s": e.t_peak_s,
                    "severity": e.severity, "lat": e.lat, "lon": e.lon,
                    "detail": {k: v for k, v in e.detail.items() if v is not None}} for e in evs],
        "trace": trace, "speed_limits_available": limits is not None and cov > 0, "speed_limit_coverage": cov,
        "tailgating_available": bool(np.any(~np.isnan(df.lead_dist.to_numpy(float)))),
        "gps_fixes": len(drive.log.gps), "imu_samples": len(drive.log.imu), "malformed_lines": drive.log.malformed_lines,
        "imu_jerk_rms": None if np.isnan(df.attrs.get("imu_jerk_rms", np.nan)) else df.attrs["imu_jerk_rms"],
        "obd_fuel_gal": fuel, "obd_method": method,
        "processed_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }


def process_folder(folder, offline=False, vision=False, mass_kg=1500.0, regen=0.0, cache=None):
    drive = I.load_drive(folder, open_video=vision)
    if vision and drive.video is not None and drive.sidecar.get("focal_px"):
        from .vision import lead_samples_from_video
        drive.log.lead = lead_samples_from_video(drive.video, drive.sidecar["focal_px"])
        drive.df = I.resample(drive.log)
        drive.trip = I.segment_trip(drive.df)
    df = drive.trip_df if drive.trip else drive.df
    ways = SL.fetch_ways(df.lat.to_numpy(), df.lon.to_numpy(), cache=cache, offline=offline)
    a = analyze(drive, ways, mass_kg, regen)
    Path(folder, "analysis.json").write_text(json.dumps(a, indent=1, sort_keys=True))
    return a


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("path")
    p.add_argument("--all", action="store_true")
    p.add_argument("--offline", action="store_true")
    p.add_argument("--vision", action="store_true")
    p.add_argument("--mass", type=float, default=1500.0)
    p.add_argument("--regen", type=float, default=0.0)
    a = p.parse_args(argv)
    folders = sorted(q for q in Path(a.path).iterdir() if (q / "drive.json").exists()) if a.all else [Path(a.path)]
    cache = SL.OverpassCache()
    for f in folders:
        try:
            r = process_folder(f, a.offline, a.vision, a.mass, a.regen, cache)
            m = S.ScoringModel()
            print(f"{f.name}: {r['distance_m']/C.METRES_PER_MILE:.1f} mi, {len(r['events'])} events, "
                  f"efficiency {m.efficiency_score(r['components']):.0f}, safety {r['safety']['score']:.0f}")
            for e in r["events"]:
                print(f"   {e['t_offset_s']:8.1f}s  {e['kind']:<13} sev {e['severity']:.2f}")
        except Exception as ex:
            print(f"{f.name}: skipped ({ex})")


if __name__ == "__main__":
    main()
