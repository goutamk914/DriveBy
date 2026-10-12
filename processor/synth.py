"""Synthetic drive generator — test fixtures ONLY.

Produces a drive folder in the exact data-contract format with known, scripted manoeuvres
(hard brake, long idle, hard launch, sharp turn, speeding stretch, tailgating stretch) plus an
Overpass response for the route, so the Python and Swift pipelines can be checked against each
other and against ground truth. Never used to seed the hazard map or the validation chart —
those use real drives only (Build Guide 7.2: "Don't fake data").

    python -m processor.synth Tests/DrivebyCoreTests/Fixtures/synth_drive
"""
from __future__ import annotations

import json
import math
import sys
import uuid
from pathlib import Path

import numpy as np

LAT0, LON0 = 39.0400, -77.4900          # Loudoun County, VA
G = 9.80665


def profile():
    """(t, v, heading_deg, yaw_rate) at 100 Hz from a scripted manoeuvre list."""
    segs = [  # (duration_s, kind, arg)
        (20, "hold", 0), (12, "accel", 1.25), (48, "cruise", None), (4, "brake_to", 0.0),   # hard brake ≈ -3.75 m/s²
        (75, "hold", 0),                                                                     # idle 75 s
        (5.7, "accel", 2.8), (34, "cruise", None),                                          # hard launch
        (4, "turn", -90), (6, "accel", 1.0), (8, "accel", 1.35), (40, "cruise", None),      # sharp left, speed up
        (20, "cruise", None), (12, "decel", -1.0), (25, "cruise", None), (22, "decel", -1.0),
        (200, "hold", 0),                                                                   # parked → trip end
    ]
    dt = 0.01
    t, v, hdg = 0.0, 0.0, 90.0
    out = []
    for dur, kind, arg in segs:
        steps = int(round(dur / dt))
        if kind == "brake_to":
            rate = (arg - v) / dur
        for _ in range(steps):
            yaw = 0.0
            if kind == "accel":
                v += arg * dt
            elif kind == "decel":
                v = max(v + arg * dt, 0.0)
            elif kind == "brake_to":
                v = max(v + rate * dt, 0.0)
            elif kind == "hold":
                v = 0.0
            elif kind == "turn":
                yaw = math.radians(arg) / dur
                hdg = (hdg + math.degrees(yaw) * dt) % 360
            out.append((t, v, hdg, yaw))
            t += dt
    return np.array(out)


def generate(folder: str | Path, with_yaw_field: bool = True, seed: int = 7) -> dict:
    rng = np.random.default_rng(seed)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    P = profile()
    t, v, hdg, yaw = P[:, 0], P[:, 1], P[:, 2], P[:, 3]
    dt = 0.01
    # integrate position (local metres → lat/lon)
    ky = math.pi / 180 * 6_371_008.8
    kx = ky * math.cos(math.radians(LAT0))
    x = np.cumsum(v * np.sin(np.radians(hdg)) * dt)
    y = np.cumsum(v * np.cos(np.radians(hdg)) * dt)
    lat, lon = LAT0 + y / ky, LON0 + x / kx

    lines = []
    # GPS 1 Hz, first fix at t = 0.40 (startup latency)
    for k in np.arange(40, len(t), 100):
        acc = 4.0 + rng.uniform(0, 2)
        spd = max(v[k] + rng.normal(0, 0.12), 0.0)
        la = lat[k] + rng.normal(0, 1.0) / ky
        lo = lon[k] + rng.normal(0, 1.0) / kx
        h = None if v[k] < 1.0 else round(float(hdg[k]), 1)
        if k == 40 + 100 * 50:          # one garbage fix — must be dropped (acc > 20 m)
            acc, la = 35.0, la + 0.001
        lines.append((t[k], json.dumps({"t": round(float(t[k]), 3), "type": "gps", "lat": round(float(la), 7),
                                        "lon": round(float(lo), 7), "spd": round(float(spd), 2), "acc": round(acc, 1),
                                        "hdg": h}, separators=(",", ":"))))
    # IMU 50 Hz: phone tilted 20° back in a mount; gyro = yaw rate along the gravity axis
    tilt = math.radians(20)
    gdir = np.array([0.0, math.cos(tilt), math.sin(tilt)])          # unit "up" in device frame
    for k in range(0, len(t), 2):
        a_dev = G * gdir + rng.normal(0, 0.05, 3)
        w = yaw[k] * gdir + rng.normal(0, 0.003, 3)
        rec = {"t": round(float(t[k]), 3), "type": "imu", "ax": round(float(a_dev[0]), 3), "ay": round(float(a_dev[1]), 3),
               "az": round(float(a_dev[2]), 3), "gx": round(float(w[0]), 4), "gy": round(float(w[1]), 4), "gz": round(float(w[2]), 4)}
        if with_yaw_field:
            rec["yaw"] = round(float(yaw[k] + rng.normal(0, 0.003)), 4)
        lines.append((t[k], json.dumps(rec, separators=(",", ":"))))
    # Lead vehicle 20 m ahead during the fast cruise (headway ≈ 0.75 s), 10 Hz vision samples
    cruise_fast = np.where((t > 245) & (t < 252))[0]
    for k in cruise_fast[::10]:
        d = 20.0 + rng.normal(0, 0.4)
        lines.append((t[k], json.dumps({"t": round(float(t[k]), 3), "type": "lead", "bx": 0.45, "by": 0.5, "bw": 0.09,
                                        "bh": 0.08, "dist": round(d, 2)}, separators=(",", ":"))))
    # OBD 1 Hz: fuel rate model (L/h) = idle + speed + acceleration terms
    a = np.gradient(v, dt)
    for k in np.arange(70, len(t), 100):
        lph = 0.9 + 0.11 * v[k] + 1.6 * max(a[k], 0) * v[k] / 10
        lines.append((t[k], json.dumps({"t": round(float(t[k]), 3), "type": "obd", "rpm": 800 + 60 * v[k],
                                        "kph": round(v[k] * 3.6), "fuel_lph": round(lph, 2)}, separators=(",", ":"))))
    lines.sort(key=lambda r: r[0])
    body = "\n".join(l for _, l in lines) + "\n"
    body += '{"t":999.9,"type":"imu","ax":0.1'      # half-written last line (crash) — must be skipped
    (folder / "sensors.jsonl").write_text(body)

    side = {"drive_id": str(uuid.UUID(int=seed)), "video_file": None, "sensor_file": "sensors.jsonl",
            "video_start_t": None, "vehicle_id": None, "device": "synthetic", "started_at": "2026-09-14T16:00:00Z",
            "recording_mode": "sensors"}
    (folder / "drive.json").write_text(json.dumps(side, indent=2))

    # Overpass fixture: the main road (east-west, 35 mph, VA 7), the cross road north (secondary, no tag → 40),
    # a perpendicular residential street through the first stop (must NOT match while moving east).
    turn_idx = int(np.argmax(yaw != 0))
    end_turn = int(np.where(yaw != 0)[0][-1])
    def ll(i):
        return [round(float(lat[i]), 7), round(float(lon[i]), 7)]
    a_pts = [[LAT0, LON0 - 0.002], ll(turn_idx)]
    b_pts = [ll(end_turn), [float(lat[-1]) + 0.003, float(lon[end_turn])]]
    stop_idx = int(np.where(t >= 84)[0][0])
    c_pts = [[float(lat[stop_idx]) - 0.002, float(lon[stop_idx])], [float(lat[stop_idx]) + 0.002, float(lon[stop_idx])]]
    corner = [ll(turn_idx), ll((turn_idx + end_turn) // 2), ll(end_turn)]
    def way(i, hw, geom, **tags):
        return {"type": "way", "id": i, "tags": {"highway": hw, **tags},
                "geometry": [{"lat": p[0], "lon": p[1]} for p in geom]}
    overpass = {"version": 0.6, "elements": [
        way(101, "primary", a_pts, maxspeed="35 mph", ref="VA 7", name="Harry Byrd Highway"),
        way(102, "secondary", corner + b_pts, name="Belmont Ridge Road"),
        way(103, "residential", c_pts, name="Cedar Lane", maxspeed="25 mph"),
    ]}
    (folder / "overpass.json").write_text(json.dumps(overpass, indent=1))
    return {"folder": str(folder), "duration": float(t[-1])}


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "data/synth_drive"
    print(generate(out))
    print(generate(out + "_noyaw", with_yaw_field=False))
