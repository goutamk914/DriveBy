"""pytest for the Python processor.   Run:  python -m pytest processor/tests -q"""
import json
import subprocess
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from processor import contract as C, events as E, hazard as H, ingest as I, run as R, scoring as S, speedlimits as SL, validate as V

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "Tests/DrivebyCoreTests/Fixtures"


@pytest.mark.parametrize("name", ["synth_drive", "synth_drive_noyaw"])
def test_pipeline_reproduces_fixture(name):
    """The checked-in expected.json (also asserted by the Swift tests) is reproducible from the raw data."""
    folder = FIX / name
    d = I.load_drive(folder, open_video=False)
    a = R.analyze(d, SL.parse_overpass((folder / "overpass.json").read_text()))
    exp = json.loads((folder / "expected.json").read_text())
    assert a["distance_m"] == pytest.approx(exp["distance_m"])
    assert [e["kind"] for e in a["events"]] == [e["kind"] for e in exp["events"]]
    for k in C.COMPONENT_KEYS:
        assert a["components"][k] == pytest.approx(exp["components"][k])
    assert a["safety"]["score"] == pytest.approx(exp["safety"]["score"])


def test_scripted_manoeuvres_found():
    d = I.load_drive(FIX / "synth_drive", open_video=False)
    a = R.analyze(d, SL.parse_overpass((FIX / "synth_drive/overpass.json").read_text()))
    assert [e["kind"] for e in a["events"]] == ["hard_brake", "idle", "hard_accel", "harsh_corner", "speeding", "tailgating"]
    assert d.log.malformed_lines == 1          # half-written last line skipped, not fatal
    assert a["obd_method"] == "fuel_rate" and a["obd_fuel_gal"] > 0


def test_gps_accuracy_filter_drops_bad_fix():
    d = I.load_drive(FIX / "synth_drive", open_video=False)
    assert (d.log.gps.acc > C.MAX_GPS_ACCURACY).sum() == 1
    # the bad fix was 0.001° (~110 m) off — the resampled track must not jump
    step = np.hypot(np.diff(d.df.lat) * 111_000, np.diff(d.df.lon) * 86_000)
    assert step.max() < 5


def test_debounce_merges_and_enforces_gap():
    mk = lambda t0, t1, sev: E.Event("hard_brake", t0, t1, t0, sev)
    out = E.debounce([mk(10, 11, .2), mk(12.5, 13, .5), mk(14, 15, .1), mk(30, 31, .3)])
    assert len(out) == 2
    assert out[0].t_end_s == 15 and out[0].severity == .5


def test_no_gps_raises():
    log = I.SensorLog(pd.DataFrame(columns=["t", "lat", "lon", "spd", "acc", "hdg"]), pd.DataFrame(columns=["t", "ax", "ay", "az", "gx", "gy", "gz", "yaw"]),
                      pd.DataFrame(columns=["t"]), pd.DataFrame(columns=["t", "dist"]))
    with pytest.raises(I.NoUsableGPS):
        I.resample(log)


def test_k_anonymity():
    base = dict(lat=39.04512, lon=-77.48731, kind="hard_brake")
    two_users = [dict(base, user="a")] * 5 + [dict(base, user="b")] * 4
    assert H.aggregate(two_users) == []
    three = [dict(base, user="a")] * 3 + [dict(base, user="b")] * 2 + [dict(base, user="c")] * 2
    cells = H.aggregate(three)
    assert len(cells) == 1 and cells[0]["event_count"] == 7 and cells[0]["distinct_users"] == 3
    assert set(cells[0]) == {"cell_key", "lat", "lon", "event_count", "distinct_users", "dominant_kind", "updated_at"}
    gj = H.to_geojson(cells)
    assert gj["features"][0]["geometry"]["type"] == "Polygon"
    assert "user" not in json.dumps(gj).replace("distinct_users", "").replace("k_users", "")


def test_cell_keys_match_numerics_fixture():
    ref = json.loads((FIX / "numerics.json").read_text())
    for item in ref["cell_keys"]:
        assert H.cell_key(item["lat"], item["lon"]) == item["key"]


def test_tank_to_tank_with_partial(tmp_path):
    csv = tmp_path / "fuel.csv"
    csv.write_text("date,odometer,gallons,price_total,car_id,filled_to_full\n"
                   "2026-08-20,1000,10,35,x,True\n2026-08-25,1150,4,14,x,False\n2026-08-29,1300,6,21,x,True\n")
    fuel = V.load_fuel_log(csv)
    drives = pd.DataFrame([{"started_at": pd.Timestamp("2026-08-22 08:00"), "miles": 200.0,
                            **{k: 1.0 for k in C.COMPONENT_KEYS}}])
    t = V.tank_intervals(fuel, drives)
    assert len(t) == 1
    assert t.mpg.iloc[0] == pytest.approx(30.0)
    assert t.coverage.iloc[0] == pytest.approx(200 / 300)


def test_fit_weights_concentrates_on_true_driver():
    rows = []
    for i in range(12):
        bw = 30_000 + i * 35_000
        rows.append({"brake_waste": bw, "idle_frac": ((i * 5) % 7) / 30, "jerk_rms": 0.3 + ((i * 3) % 5) / 10,
                     "high_speed": 0.1, "accel_waste": 0.01})
    df = pd.DataFrame(rows)
    y = np.array([1.1 - r["brake_waste"] / 1_000_000 for r in rows])
    m = V.fit_weights(df, y, S.ScoringModel(), ridge_lambda=0.01)
    assert m.weights["brake_waste"] > 0.9 and m.fit_r2 > 0.95


def test_maxspeed_parsing():
    assert SL.parse_maxspeed("35 mph") == pytest.approx(35 / C.MPS_TO_MPH)
    assert SL.parse_maxspeed("50") == pytest.approx(50 / 3.6)
    assert SL.parse_maxspeed("none") is None
    assert SL.display_name("VA 7", None) == "Route 7"
    assert SL.display_name("I 66", None) == "I-66"


def test_privacy_lint_passes():
    r = subprocess.run(["sh", str(ROOT / "Scripts/privacy_lint.sh")], capture_output=True, text=True, env={"SRCROOT": str(ROOT), "PATH": "/usr/bin:/bin"})
    assert r.returncode == 0, r.stdout + r.stderr


def test_scoring_model_json_roundtrip_matches_swift_shape(tmp_path):
    m = S.ScoringModel()
    o = json.loads(m.to_json())
    assert set(o) >= {"version", "source", "weights", "normalization", "safety"}
    assert o["normalization"]["brake_waste"] == {"p5": 20000.0, "p95": 450000.0}
    assert S.ScoringModel.from_json(m.to_json()).weights == m.weights
