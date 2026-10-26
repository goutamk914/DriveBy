from __future__ import annotations

import json
import math
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

from . import contract as C
from .ingest import round_half_away

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
TILE_DEG = 0.02

DEFAULT_LIMITS_MPH = {
    "motorway": 65, "trunk": 55, "primary": 45,
    "secondary": 40, "tertiary": 35,
    "residential": 25, "unclassified": 30, "service": 15,
    "motorway_link": 45, "trunk_link": 40, "primary_link": 35,
    "secondary_link": 30, "tertiary_link": 30, "living_street": 15,
}
DRIVABLE = ("^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|service|motorway_link|trunk_link|"
            "primary_link|secondary_link|tertiary_link|living_street)$")


def parse_maxspeed(raw) -> float | None:
    if not raw:
        return None
    s = str(raw).lower().strip().split(";")[0].strip()
    is_mph = "mph" in s
    digits = ""
    for ch in s:
        if ch.isdigit() or ch == ".":
            digits += ch
        else:
            break
    try:
        v = float(digits)
    except ValueError:
        return None
    if v <= 0:
        return None
    return v / C.MPS_TO_MPH if is_mph else v / 3.6


def display_name(ref, name):
    if ref:
        r = str(ref).split(";")[0].strip()
        parts = r.split(" ", 1)
        if len(parts) == 2:
            p = parts[0].upper()
            if p == "I":
                return f"I-{parts[1]}"
            if p == "US":
                return f"US-{parts[1]}"
            if p in ("VA", "SR", "MD", "DC"):
                return f"Route {parts[1]}"
        return r
    return name or None


@dataclass
class Way:
    id: int
    highway: str
    maxspeed: str | None
    name: str | None
    ref: str | None
    oneway: str | None
    geometry: list

    @property
    def limit_mps(self):
        tagged = parse_maxspeed(self.maxspeed)
        if tagged is not None:
            return tagged
        mph = DEFAULT_LIMITS_MPH.get(self.highway)
        return mph / C.MPS_TO_MPH if mph is not None else None

    @property
    def display(self):
        return display_name(self.ref, self.name)


def parse_overpass(payload: dict | str | bytes) -> list[Way]:
    if not isinstance(payload, dict):
        payload = json.loads(payload)
    ways = []
    for e in payload.get("elements", []):
        if e.get("type") != "way":
            continue
        tags = e.get("tags") or {}
        geom = e.get("geometry") or []
        if "highway" not in tags or len(geom) < 2:
            continue
        ways.append(Way(int(e.get("id", 0)), tags["highway"], tags.get("maxspeed"), tags.get("name"), tags.get("ref"),
                        tags.get("oneway"), [[p["lat"], p["lon"]] for p in geom]))
    return ways


def tiles(lat, lon):
    pad = 0.0005
    s = set()
    for a, b in zip(lat, lon):
        for dy in (-pad, pad):
            for dx in (-pad, pad):
                s.add((int(math.floor((b + dx) / TILE_DEG)), int(math.floor((a + dy) / TILE_DEG))))
    return sorted(s, key=lambda xy: (xy[1], xy[0]))


def tile_query(x: int, y: int) -> str:
    south, west = y * TILE_DEG, x * TILE_DEG
    bbox = f"{south:.4f},{west:.4f},{south + TILE_DEG:.4f},{west + TILE_DEG:.4f}"
    return f'[out:json][timeout:25];way["highway"~"{DRIVABLE}"]({bbox});out tags geom;'


class OverpassCache:

    def __init__(self, path: str | Path = "data/overpass_cache.sqlite"):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path))
        self.db.execute("create table if not exists tiles (key text primary key, fetched_at real, body text)")

    def get(self, key):
        row = self.db.execute("select body from tiles where key = ?", (key,)).fetchone()
        return row[0] if row else None

    def put(self, key, body):
        self.db.execute("insert or replace into tiles values (?, ?, ?)", (key, time.time(), body))
        self.db.commit()


def fetch_ways(lat, lon, cache: OverpassCache | None = None, offline: bool = False) -> list[Way] | None:
    import requests
    cache = cache or OverpassCache()
    ways: dict[int, Way] = {}
    for x, y in tiles(lat, lon):
        key = f"{x}_{y}"
        body = cache.get(key)
        if body is None:
            if offline:
                return None
            for attempt in range(3):
                try:
                    r = requests.post(OVERPASS_URL, data={"data": tile_query(x, y)}, timeout=40,
                                      headers={"User-Agent": "Driveby/1.0 (Congressional App Challenge)"})
                    if r.status_code == 200:
                        body = r.text
                        cache.put(key, body)
                        break
                    time.sleep(2 * (attempt + 1))
                except requests.RequestException:
                    time.sleep(2 * (attempt + 1))
            if body is None:
                return None
        for w in parse_overpass(body):
            ways[w.id] = w
    return list(ways.values())


def _heading_delta(a, b):
    d = abs((a - b) % 360.0)
    return 360 - d if d > 180 else d


def match(df: pd.DataFrame, ways: list[Way]) -> pd.DataFrame:
    n = len(df)
    out = pd.DataFrame({"limit_mps": [np.nan] * n, "road": [None] * n, "tagged": [False] * n})
    if n == 0 or not ways:
        return out
    dt = df.attrs.get("dt", 0.1)
    mid = n // 2
    lat0, lon0 = df.lat.iloc[mid], df.lon.iloc[mid]
    ky = math.pi / 180 * 6_371_008.8
    kx = ky * math.cos(math.radians(lat0))

    seg = []
    for wi, w in enumerate(ways):
        g = np.asarray(w.geometry, float)
        xs, ys = (g[:, 1] - lon0) * kx, (g[:, 0] - lat0) * ky
        for k in range(1, len(g)):
            seg.append((xs[k - 1], ys[k - 1], xs[k], ys[k], wi))
    seg = np.asarray(seg, float)
    ax, ay, bx, by, wid = seg.T
    dx, dy = bx - ax, by - ay
    len2 = dx * dx + dy * dy
    seg_bearing = (np.degrees(np.arctan2(dx, dy)) + 360) % 360

    step = max(int(round_half_away(1.0 / dt)), 1)
    limits, roads, tagged = [np.nan] * n, [None] * n, [False] * n
    last = (np.nan, None, False)
    lat, lon, hd, v = df.lat.to_numpy(), df.lon.to_numpy(), df.heading.to_numpy(), df.v.to_numpy()
    for i in range(n):
        if i % step != 0:
            limits[i], roads[i], tagged[i] = last
            continue
        px, py = (lon[i] - lon0) * kx, (lat[i] - lat0) * ky
        with np.errstate(invalid="ignore", divide="ignore"):
            t = np.where(len2 > 0, ((px - ax) * dx + (py - ay) * dy) / len2, 0.0)
        t = np.clip(t, 0, 1)
        dist = np.hypot(px - (ax + t * dx), py - (ay + t * dy))
        ok = dist <= C.WAY_MATCH_RADIUS
        if np.isfinite(hd[i]) and v[i] > 2.0:
            fwd = np.array([_heading_delta(hd[i], b) for b in seg_bearing])
            rev = np.array([_heading_delta(hd[i], b + 180) for b in seg_bearing])
            ow = np.array([str(ways[int(k)].oneway) for k in wid])
            allowed = np.where(np.isin(ow, ["yes", "true", "1"]), fwd <= C.WAY_HEADING_TOLERANCE,
                               np.where(np.isin(ow, ["-1", "reverse"]), rev <= C.WAY_HEADING_TOLERANCE,
                                        np.minimum(fwd, rev) <= C.WAY_HEADING_TOLERANCE))
            ok &= allowed
        if ok.any():
            k = int(np.argmin(np.where(ok, dist, np.inf)))
            w = ways[int(wid[k])]
            lm = w.limit_mps
            last = (np.nan if lm is None else lm, w.display, parse_maxspeed(w.maxspeed) is not None)
        else:
            last = (np.nan, None, False)
        limits[i], roads[i], tagged[i] = last
    out["limit_mps"], out["road"], out["tagged"] = limits, roads, tagged
    return out
