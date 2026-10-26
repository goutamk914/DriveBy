from __future__ import annotations

import json
from collections import Counter, defaultdict
from datetime import datetime, timezone

from . import contract as C

CELL = C.CELL
K_EVENTS = C.K_EVENTS
K_USERS = C.K_USERS


def cell_key(lat, lon):
    return f"{round(lat/CELL)*CELL:.4f}_{round(lon/CELL)*CELL:.4f}"


def cell_center(lat, lon):
    return round(lat / CELL) * CELL, round(lon / CELL) * CELL


def aggregate(contributions, k_events=K_EVENTS, k_users=K_USERS):
    events, users, kinds, centers = Counter(), defaultdict(set), defaultdict(Counter), {}
    for c in contributions:
        if c["kind"] not in C.HAZARD_KINDS:
            continue
        k = cell_key(c["lat"], c["lon"])
        events[k] += 1
        users[k].add(c["user"])
        kinds[k][c["kind"]] += 1
        centers[k] = cell_center(c["lat"], c["lon"])
    now = datetime.now(timezone.utc).isoformat()
    out = []
    for k, n in events.items():
        u = len(users[k])
        if n >= k_events and u >= k_users:
            dominant = sorted(kinds[k].items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
            out.append({"cell_key": k, "lat": centers[k][0], "lon": centers[k][1], "event_count": n,
                        "distinct_users": u, "dominant_kind": dominant, "updated_at": now})
    return sorted(out, key=lambda r: -r["event_count"])


def to_geojson(cells, cell=CELL) -> dict:
    h = cell / 2
    feats = []
    for c in cells:
        lat, lon = c["lat"], c["lon"]
        ring = [[lon - h, lat - h], [lon + h, lat - h], [lon + h, lat + h], [lon - h, lat + h], [lon - h, lat - h]]
        feats.append({"type": "Feature",
                      "geometry": {"type": "Polygon", "coordinates": [[[round(x, 6), round(y, 6)] for x, y in ring]]},
                      "properties": {k: c[k] for k in ("cell_key", "event_count", "distinct_users", "dominant_kind", "updated_at") if k in c}
                      | {"center_lat": round(lat, 6), "center_lon": round(lon, 6)}})
    return {"type": "FeatureCollection", "name": "driveby_hazard_cells",
            "metadata": {"generator": "Driveby processor", "cell_size_deg": cell, "k_events": K_EVENTS, "k_users": K_USERS,
                         "crs": "EPSG:4326",
                         "description": "Anonymised aggregate of hard-braking and sharp-turn events (k-anonymity)."},
            "features": feats}


def write_geojson(cells, path):
    with open(path, "w") as fh:
        json.dump(to_geojson(cells), fh, indent=2)
