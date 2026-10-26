from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import savgol_filter

from . import contract as C


def round_half_away(x):
    x = np.asarray(x, dtype=float)
    return np.sign(x) * np.floor(np.abs(x) + 0.5)


@dataclass
class SensorLog:
    gps: pd.DataFrame
    imu: pd.DataFrame
    obd: pd.DataFrame
    lead: pd.DataFrame
    malformed_lines: int = 0


_GPS_COLS = ["t", "lat", "lon", "spd", "acc", "hdg"]
_IMU_COLS = ["t", "ax", "ay", "az", "gx", "gy", "gz", "yaw"]
_OBD_COLS = ["t", "rpm", "kph", "maf", "fuel_lph"]
_LEAD_COLS = ["t", "bx", "by", "bw", "bh", "dist"]


def parse_jsonl(path: str | Path) -> SensorLog:
    rows = {"gps": [], "imu": [], "obd": [], "lead": []}
    bad = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
                t = float(o["t"])
                kind = o["type"]
            except (ValueError, KeyError, TypeError):
                bad += 1
                continue
            if kind == "gps":
                if o.get("lat") is None or o.get("lon") is None:
                    bad += 1
                    continue
                spd = o.get("spd")
                spd = None if spd is None or spd < 0 else float(spd)
                hdg = o.get("hdg")
                hdg = None if hdg is None or hdg < 0 else float(hdg)
                acc = o.get("acc")
                rows["gps"].append([t, float(o["lat"]), float(o["lon"]), spd, 999.0 if acc is None else float(acc), hdg])
            elif kind == "imu":
                if any(o.get(k) is None for k in ("ax", "ay", "az")):
                    bad += 1
                    continue
                rows["imu"].append([t, o["ax"], o["ay"], o["az"], o.get("gx", 0.0), o.get("gy", 0.0), o.get("gz", 0.0), o.get("yaw")])
            elif kind == "obd":
                rows["obd"].append([t, o.get("rpm"), o.get("kph"), o.get("maf"), o.get("fuel_lph")])
            elif kind == "lead":
                if any(o.get(k) is None for k in ("bx", "by", "bw", "bh", "dist")):
                    bad += 1
                    continue
                rows["lead"].append([t, o["bx"], o["by"], o["bw"], o["bh"], o["dist"]])
    mk = lambda r, cols: pd.DataFrame(r, columns=cols).sort_values("t", kind="stable").reset_index(drop=True)
    return SensorLog(mk(rows["gps"], _GPS_COLS), mk(rows["imu"], _IMU_COLS), mk(rows["obd"], _OBD_COLS),
                     mk(rows["lead"], _LEAD_COLS), bad)


EARTH_R = 6_371_008.8


def haversine(lat1, lon1, lat2, lon2):
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dp, dl = np.radians(lat2 - lat1), np.radians(lon2 - lon1)
    a = np.sin(dp / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * EARTH_R * np.arctan2(np.sqrt(a), np.sqrt(1 - a))


def bearing(lat1, lon1, lat2, lon2):
    p1, p2, dl = math.radians(lat1), math.radians(lat2), math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def savgol(y: np.ndarray, window: int = C.SAVGOL_WINDOW, order: int = C.SAVGOL_ORDER) -> np.ndarray:
    n = len(y)
    if window > n:
        window = n if n % 2 == 1 else n - 1
    if window <= order or window < 3:
        return np.asarray(y, dtype=float).copy()
    return savgol_filter(np.asarray(y, dtype=float), window_length=window, polyorder=order, mode="interp")


class NoUsableGPS(Exception):
    pass


def resample(log: SensorLog, hz: float = C.RESAMPLE_HZ) -> pd.DataFrame:
    dt = 1.0 / hz
    g = log.gps
    fixes = g[(g.acc <= C.MAX_GPS_ACCURACY) & (g.acc >= 0)].reset_index(drop=True)
    if len(fixes) < 3:
        raise NoUsableGPS(f"only {len(fixes)} usable GPS fixes")

    ft = fixes.t.to_numpy(float)
    t0, t1 = ft[0], ft[-1]
    n = max(int(math.floor((t1 - t0) / dt)) + 1, 1)
    grid = t0 + np.arange(n) * dt

    lat_f, lon_f = fixes.lat.to_numpy(float), fixes.lon.to_numpy(float)
    spd = np.zeros(len(fixes))
    for i in range(len(fixes)):
        s = fixes.spd.iloc[i]
        if s is not None and not (isinstance(s, float) and math.isnan(s)):
            spd[i] = s
            continue
        j = i - 1 if i > 0 else min(i + 1, len(fixes) - 1)
        a, b = min(i, j), max(i, j)
        dtf = ft[b] - ft[a]
        spd[i] = haversine(lat_f[a], lon_f[a], lat_f[b], lon_f[b]) / dtf if dtf > 0 else 0.0

    lat = np.interp(grid, ft, lat_f)
    lon = np.interp(grid, ft, lon_f)
    v_raw = np.interp(grid, ft, spd)

    hdg_f = fixes.hdg.to_numpy(dtype=object)
    heading = np.full(n, np.nan)
    gap = np.zeros(n, dtype=bool)
    j = 0
    for i, q in enumerate(grid):
        while j + 1 < len(ft) and abs(ft[j + 1] - q) <= abs(ft[j] - q):
            j += 1
        h = hdg_f[j]
        heading[i] = np.nan if h is None or (isinstance(h, float) and math.isnan(h)) else float(h)
        gap[i] = abs(ft[j] - q) > 3.0
    for i in range(n):
        if np.isnan(heading[i]):
            a, b = max(i - 10, 0), min(i + 10, n - 1)
            if b > a and haversine(lat[a], lon[a], lat[b], lon[b]) > 5:
                heading[i] = bearing(lat[a], lon[a], lat[b], lon[b])

    smooth = savgol(v_raw)
    v = np.maximum(smooth, 0.0)
    a_long = np.gradient(smooth, dt) if n >= 2 else np.zeros(n)
    dist = np.zeros(n)
    if n > 1:
        dist[1:] = np.cumsum(0.5 * (v[1:] + v[:-1]) * dt)

    yaw = yaw_series(log.imu, grid, dt)
    df = pd.DataFrame({
        "t": grid, "lat": lat, "lon": lon, "heading": heading, "v_raw": v_raw, "v": v, "a_long": a_long,
        "yaw_rate": yaw, "a_lat": v * yaw, "distance_m": dist, "gps_gap": gap,
        "lead_dist": lead_series(log.lead, grid),
    })
    df.attrs["dt"] = dt
    df.attrs["imu_jerk_rms"] = imu_jerk(log.imu)
    return df


def yaw_series(imu: pd.DataFrame, grid: np.ndarray, dt: float) -> np.ndarray:
    if len(imu) == 0 or len(grid) == 0:
        return np.zeros(len(grid))
    t = imu.t.to_numpy(float)
    ax, ay, az = (imu[c].to_numpy(float) for c in ("ax", "ay", "az"))
    gx, gy, gz = (imu[c].to_numpy(float) for c in ("gx", "gy", "gz"))
    logged = imu.yaw.to_numpy(dtype=object)
    yaw = np.zeros(len(imu))
    g0, g1, g2 = ax[0], ay[0], az[0]
    alpha = 0.02
    for i in range(len(imu)):
        y = logged[i]
        if y is not None and not (isinstance(y, float) and math.isnan(y)):
            yaw[i] = float(y)
            continue
        g0 += alpha * (ax[i] - g0); g1 += alpha * (ay[i] - g1); g2 += alpha * (az[i] - g2)
        norm = math.sqrt(g0 * g0 + g1 * g1 + g2 * g2)
        yaw[i] = (gx[i] * g0 + gy[i] * g1 + gz[i] * g2) / norm if norm > 1e-6 else 0.0
    k = round_half_away((t - grid[0]) / dt).astype(int)
    ok = (k >= 0) & (k < len(grid))
    sums = np.bincount(k[ok], weights=yaw[ok], minlength=len(grid))
    counts = np.bincount(k[ok], minlength=len(grid))
    have = counts > 0
    if not have.any():
        return np.zeros(len(grid))
    return np.interp(grid, grid[have], sums[have] / counts[have])


def imu_jerk(imu: pd.DataFrame) -> float:
    if len(imu) <= 2:
        return float("nan")
    t = imu.t.to_numpy(float)
    m = np.sqrt(imu.ax.to_numpy(float) ** 2 + imu.ay.to_numpy(float) ** 2 + imu.az.to_numpy(float) ** 2)
    dt = np.diff(t)
    ok = (dt > 0.001) & (dt < 0.2)
    if not ok.any():
        return float("nan")
    j = np.diff(m)[ok] / dt[ok]
    return float(np.sqrt(np.mean(j ** 2)))


def lead_series(lead: pd.DataFrame, grid: np.ndarray) -> np.ndarray:
    out = np.full(len(grid), np.nan)
    if len(lead) == 0:
        return out
    lt, ld = lead.t.to_numpy(float), lead.dist.to_numpy(float)
    j = 0
    for i, q in enumerate(grid):
        while j + 1 < len(lt) and abs(lt[j + 1] - q) <= abs(lt[j] - q):
            j += 1
        if abs(lt[j] - q) <= 0.3:
            out[i] = ld[j]
    return out


def segment_trip(df: pd.DataFrame):
    dt = df.attrs.get("dt", 0.1)
    v = df.v_raw.to_numpy()
    need_start = int(round_half_away(C.TRIP_START_SUSTAIN / dt))
    need_end = int(round_half_away(C.TRIP_END_SUSTAIN / dt))
    run, start = 0, None
    for i in range(len(v)):
        run = run + 1 if v[i] > C.TRIP_START_SPEED else 0
        if run >= need_start:
            start = i - run + 1
            break
    if start is None:
        return None
    end, run = len(v) - 1, 0
    for i in range(start, len(v)):
        run = run + 1 if v[i] < C.TRIP_END_SPEED else 0
        if run >= need_end:
            end = i - run + 1
            break
    return start, max(end, start)


def trip_slice(df: pd.DataFrame, lo: int, hi: int) -> pd.DataFrame:
    s = df.iloc[lo:hi + 1].reset_index(drop=True).copy()
    s["distance_m"] = s.distance_m - s.distance_m.iloc[0]
    s.attrs = dict(df.attrs)
    return s


def duration(df: pd.DataFrame) -> float:
    dt = df.attrs.get("dt", 0.1)
    return float(df.t.iloc[-1] - df.t.iloc[0] + dt) if len(df) > 1 else 0.0


def index_at(df: pd.DataFrame, t: float) -> int:
    dt = df.attrs.get("dt", 0.1)
    i = int(round_half_away((t - df.t.iloc[0]) / dt))
    return min(max(i, 0), len(df) - 1)


class VideoIndex:

    def __init__(self, path: str | Path, video_start_t: float):
        import cv2
        self.path = str(path)
        self.video_start_t = float(video_start_t)
        self._cap = cv2.VideoCapture(self.path)
        if not self._cap.isOpened():
            raise IOError(f"cannot open video {path}")
        self.fps = self._cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.frame_count = int(self._cap.get(cv2.CAP_PROP_FRAME_COUNT))

    def frame_number(self, t_sensor: float) -> int:
        return int(round_half_away((t_sensor - self.video_start_t) * self.fps))

    def frame_at(self, t_sensor: float):
        import cv2
        n = self.frame_number(t_sensor)
        if n < 0 or (self.frame_count and n >= self.frame_count):
            return None
        self._cap.set(cv2.CAP_PROP_POS_MSEC, (t_sensor - self.video_start_t) * 1000.0)
        ok, frame = self._cap.read()
        return frame if ok else None

    def iter_frames(self, every_s: float = 0.2):
        import cv2
        self._cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        step = max(int(round(self.fps * every_s)), 1)
        i = 0
        while True:
            ok = self._cap.grab()
            if not ok:
                break
            if i % step == 0:
                ok, frame = self._cap.retrieve()
                if ok:
                    yield self.video_start_t + i / self.fps, frame
            i += 1

    def close(self):
        self._cap.release()


@dataclass
class Drive:
    folder: Path
    sidecar: dict
    log: SensorLog
    df: pd.DataFrame
    trip: tuple | None = None
    video: VideoIndex | None = None
    extra: dict = field(default_factory=dict)

    @property
    def trip_df(self) -> pd.DataFrame:
        if self.trip is None:
            raise ValueError("car never moved — no trip")
        return trip_slice(self.df, *self.trip)


def load_drive(folder: str | Path, open_video: bool = True) -> Drive:
    folder = Path(folder)
    sidecar = json.loads((folder / "drive.json").read_text())
    log = parse_jsonl(folder / sidecar.get("sensor_file", "sensors.jsonl"))
    df = resample(log)
    video = None
    vf = sidecar.get("video_file")
    if open_video and vf and (folder / vf).exists() and sidecar.get("video_start_t") is not None:
        try:
            video = VideoIndex(folder / vf, sidecar["video_start_t"])
        except (IOError, ImportError):
            video = None
    return Drive(folder=folder, sidecar=sidecar, log=log, df=df, trip=segment_trip(df), video=video)
