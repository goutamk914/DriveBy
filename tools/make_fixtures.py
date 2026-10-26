import json
import sys
from pathlib import Path

import numpy as np
from scipy import stats
from scipy.signal import savgol_filter

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from processor import ingest as I, run as R, speedlimits as SL, synth, hazard as H
from processor.scoring import ScoringModel

FIX = ROOT / "Tests/DrivebyCoreTests/Fixtures"


def drive_fixture(name, with_yaw):
    folder = FIX / name
    synth.generate(folder, with_yaw_field=with_yaw)
    d = I.load_drive(folder, open_video=False)
    ways = SL.parse_overpass((folder / "overpass.json").read_text())
    a = R.analyze(d, ways)
    a.pop("processed_at"); a.pop("trace")
    a["efficiency_score_default_model"] = ScoringModel().efficiency_score(a["components"])
    a["no_limits"] = R.analyze(d, None)["events"]
    (folder / "expected.json").write_text(json.dumps(a, indent=1, sort_keys=True, default=float))


def numerics_fixture():
    rng = np.random.default_rng(3)
    y = np.cumsum(rng.normal(0, 1, 60))
    short = y[:9]
    x = rng.normal(0, 1, 30); yy = 2.5 * x + rng.normal(0, 0.5, 30) + 1
    lr = stats.linregress(x, yy)
    keys = [(39.04025, -77.48975), (39.0402499, -77.4897501), (38.99999, -77.50001), (39.045, -77.487), (39.04437, -77.51213)]
    out = {
        "y": y.tolist(), "savgol_21_3": savgol_filter(y, 21, 3).tolist(),
        "short": short.tolist(), "savgol_short": savgol_filter(short, 9, 3).tolist(),
        "gradient": np.gradient(y, 0.1).tolist(),
        "percentile_in": y.tolist(), "p5": float(np.percentile(y, 5)), "p95": float(np.percentile(y, 95)), "p50": float(np.percentile(y, 50)),
        "lr_x": x.tolist(), "lr_y": yy.tolist(), "lr_slope": lr.slope, "lr_intercept": lr.intercept, "lr_r": lr.rvalue,
        "cell_keys": [{"lat": a, "lon": b, "key": H.cell_key(a, b)} for a, b in keys],
        "maxspeed": {s: SL.parse_maxspeed(s) for s in ["35 mph", "50", "none", "25 mph;35 mph", "signals", "65 mph"]},
    }
    (FIX / "numerics.json").write_text(json.dumps(out, indent=1))
    m = ScoringModel(weights={"brake_waste": .5, "idle_frac": .1, "jerk_rms": .1, "high_speed": .2, "accel_waste": .1},
                     source="fitted:2026-10-01", fit_n=9, fit_r2=0.71)
    (FIX / "scoring_model_python.json").write_text(m.to_json())


if __name__ == "__main__":
    FIX.mkdir(parents=True, exist_ok=True)
    drive_fixture("synth_drive", True)
    drive_fixture("synth_drive_noyaw", False)
    numerics_fixture()
    print("fixtures written to", FIX)
