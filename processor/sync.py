from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path

from .scoring import ScoringModel


def main(argv=None):
    from supabase import create_client
    p = argparse.ArgumentParser()
    p.add_argument("folders", nargs="+")
    p.add_argument("--email", required=True)
    a = p.parse_args(argv)
    sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_ANON_KEY"])
    auth = sb.auth.sign_in_with_password({"email": a.email, "password": getpass.getpass("Password: ")})
    uid = auth.user.id
    model = ScoringModel()
    for f in map(Path, a.folders):
        side = json.loads((f / "drive.json").read_text())
        an = json.loads((f / "analysis.json").read_text())
        drive_id = side["drive_id"]
        sb.table("drives").upsert({
            "id": drive_id, "user_id": uid, "vehicle_id": side.get("vehicle_id"), "started_at": side["started_at"],
            "ended_at": side.get("ended_at"), "distance_m": an["distance_m"], "duration_s": an["duration_s"],
            "efficiency_score": model.efficiency_score(an["components"]), "safety_score": an["safety"]["score"],
            "fuel_gal": an.get("obd_fuel_gal"), "processed": True,
        }).execute()
        sb.table("events").delete().eq("drive_id", drive_id).execute()
        rows = [{"id": e["id"], "drive_id": drive_id, "t_offset_s": e["t_offset_s"], "kind": e["kind"],
                 "severity": e["severity"], "lat": e.get("lat"), "lon": e.get("lon"), "detail": e.get("detail", {})}
                for e in an["events"]]
        if rows:
            sb.table("events").insert(rows).execute()
        print(f"{f.name}: uploaded {len(rows)} events")
    sb.rpc("publish_hazard_cells", {}).execute()
    print("hazard cells refreshed")


if __name__ == "__main__":
    main()
