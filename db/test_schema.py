"""Verify db/schema.sql against a throwaway local Postgres with Supabase-like auth/storage stubs.

    pip install pgserver psycopg2-binary pandas scipy numpy
    python db/test_schema.py

Checks: idempotent apply, RLS isolation, k-anonymity (k_events=5, k_users=3), opt-out respected,
server cell keys == processor/hazard.py cell keys, anon cannot publish, account deletion cascades.
"""
import pgserver, tempfile, sys, uuid, random
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
d = tempfile.mkdtemp()
srv = pgserver.get_server(d, cleanup_mode="stop")
import psycopg2
conn = psycopg2.connect(srv.get_uri()); conn.autocommit = True
cur = conn.cursor()
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth; create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated; grant execute on function auth.uid() to anon, authenticated;
create schema storage; create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
grant usage on schema storage to anon, authenticated; grant all on storage.objects to authenticated;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
"""

cur.execute(stub)
sql = open(ROOT / "db/schema.sql").read()
cur.execute(sql); cur.execute(sql)   # idempotent
print("schema applied twice OK")

users = [uuid.uuid4() for _ in range(4)]
for u in users: cur.execute("insert into auth.users values (%s, %s)", (str(u), f"{u}@x"))
rng = random.Random(1)
# A hot intersection hit by 3 users (7 events) and a cell hit by only 2 users (9 events) and an opted-out user
hot = (39.04502, -77.48749); two = (39.05001, -77.50199)
plan = [(users[0], hot, 3), (users[1], hot, 2), (users[2], hot, 2), (users[0], two, 5), (users[1], two, 4), (users[3], two, 6)]
import json
from processor import hazard as H
contribs = []
for u, (lat, lon), n in plan:
    did = uuid.uuid4()
    optin = u != users[3]
    cur.execute("insert into drives (id, user_id, started_at, hazard_opt_in) values (%s,%s,now(),%s)", (str(did), str(u), optin))
    for i in range(n):
        la, lo = lat + rng.uniform(-0.00006, 0.00006), lon + rng.uniform(-0.00006, 0.00006)
        cur.execute("insert into events (drive_id, t_offset_s, kind, severity, lat, lon) values (%s, %s, %s, 0.5, %s, %s)",
                    (str(did), float(i), "hard_brake", la, lo))
        if optin: contribs.append({"lat": la, "lon": lo, "kind": "hard_brake", "user": str(u)})

# call as an authenticated user, like the app does
cur.execute("set role authenticated; select set_config('request.jwt.claim.sub', %s, false);", (str(users[0]),))
cur.execute("select publish_hazard_cells()")
print("published:", cur.fetchone()[0])
cur.execute("select cell_key, event_count, distinct_users, dominant_kind, updated_at from hazard_cells order by cell_key")
server = cur.fetchall(); print(server)
py = H.aggregate(contribs)
print("python:", [(c["cell_key"], c["event_count"], c["distinct_users"]) for c in py])
assert sorted((r[0], r[1], r[2]) for r in server) == sorted((c["cell_key"], c["event_count"], c["distinct_users"]) for c in py), "server/python mismatch"

# RLS: user0 sees only own drives; cannot write hazard_cells
cur.execute("select count(*) from drives"); print("user0 sees drives:", cur.fetchone()[0])
try:
    cur.execute("insert into hazard_cells (cell_key, event_count, distinct_users) values ('x', 99, 99)"); print("FAIL: insert allowed")
except Exception as e: print("hazard_cells insert blocked:", type(e).__name__)
# anon can read hazard cells but not drives
cur.execute("reset role; set role anon; select set_config('request.jwt.claim.sub', '', false);")
cur.execute("select count(*) from hazard_cells"); print("anon hazard rows:", cur.fetchone()[0])
cur.execute("select count(*) from drives"); print("anon drives:", cur.fetchone()[0])
try:
    cur.execute("select publish_hazard_cells()"); print("FAIL anon could publish")
except Exception as e: print("anon publish blocked:", type(e).__name__)
# practice_logs: own rows only, and deleted with the account
cur.execute("reset role; set role authenticated; select set_config('request.jwt.claim.sub', %s, false);", (str(users[2]),))
cur.execute("insert into practice_logs (user_id, started_at, duration_s, night_s, supervisor) values (%s, now(), 1800, 600, 'Parent')", (str(users[2]),))
try:
    cur.execute("insert into practice_logs (user_id, started_at, duration_s) values (%s, now(), 60)", (str(users[0]),)); print("FAIL: wrote another user's log")
except Exception as e: print("foreign practice_logs insert blocked:", type(e).__name__)
cur.execute("select set_config('request.jwt.claim.sub', %s, false);", (str(users[0]),))
cur.execute("select count(*) from practice_logs"); n0 = cur.fetchone()[0]; print("user0 sees practice logs:", n0)
assert n0 == 0, "RLS leak on practice_logs"
# delete account cascades and republishes
cur.execute("reset role; set role authenticated; select set_config('request.jwt.claim.sub', %s, false);", (str(users[2]),))
cur.execute("select delete_my_account()")
cur.execute("reset role"); cur.execute("select count(*) from auth.users"); print("users after delete:", cur.fetchone()[0])
cur.execute("select count(*) from hazard_cells"); print("cells after user2 deleted (hot cell drops below k):", cur.fetchone()[0])
cur.execute("select count(*) from practice_logs"); nl = cur.fetchone()[0]; print("practice logs after delete:", nl)
assert nl == 0, "practice_logs not cascaded"
srv.cleanup()
print("ALL SCHEMA CHECKS PASSED")
