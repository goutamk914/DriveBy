# Deploying Driveby

Three independent pieces. Only the first is required for a working app.

1. **iOS app** — Xcode → your iPhone → TestFlight / App Store
2. **Supabase** (optional) — accounts, cloud history, the public hazard map
3. **Python processor** (laptop) — validation notebook, tuning, imported footage

---

## 1. iOS app

### Requirements
- Xcode 26 on macOS, an Apple ID (free works for your own phone; App Store/TestFlight needs the $99/yr Apple Developer Program)
- iPhone with iOS 17 or later (iPhone XS/XR and newer)

### Build to your phone
1. Open `Driveby.xcodeproj`.
2. Target **Driveby** → *Signing & Capabilities*:
   - **Team**: your team
   - **Bundle Identifier**: `com.gkanakadandi.Driveby` (change if Xcode says it's unavailable)
   - Background Modes are declared in `Driveby-Info.plist` (Location updates, Uses Bluetooth LE accessories). You don't need to add the capability manually; if Xcode offers to, accept.
3. Choose your iPhone as the destination → **⌘R**. First run on a device: on the phone, *Settings → General → VPN & Device Management → trust your developer certificate*.
4. The build runs **Privacy Lint** first. If it fails, someone wrote video outside `RedactingVideoWriter.swift` — fix that; don't disable the phase.

Project settings applied by `tools/patch_xcodeproj.py` (already applied; re-running is harmless):
iOS 17.0 deployment target · iPhone only · Swift 5 language mode with explicit `@MainActor` on UI classes ·
`Driveby-Info.plist` merged · Privacy Lint build phase.

### First-launch checklist on the phone
- Location **While Using** — required. (Background recording continues if the phone locks during a drive you started.)
- Camera — optional (sensors-only mode works without it).
- Settings → **Mount check**: landscape, horizon level, lens centred above the dash line, mark the mount with tape.
- Do one 10-minute drive with a passenger operating the phone. Open it from Home → the drive scores within seconds.

### TestFlight (lets teammates / judges install it)
1. Xcode → *Product → Archive* (destination "Any iOS Device (arm64)").
2. Organizer → **Distribute App → App Store Connect → Upload**.
3. App Store Connect → *My Apps → +* → New App (name "Driveby", primary language English, the bundle ID above, SKU `driveby`).
4. TestFlight tab → add internal testers (up to 100, no review) or an external group (needs a short beta review).
5. *Test Information*: paste the review notes below.

### App Store submission (optional for the competition)
- **Category**: Navigation (or Education). **Age rating**: 4+.
- **Privacy Nutrition Label** — "Data Linked to You", purpose *App Functionality* only, **no tracking**:
  - Location → Precise Location (only if the user signs in and syncs)
  - Contact Info → Email Address (account)
  - User Content → Photos or Videos (only if the user opts in to clip backup)
  - Usage Data → Other usage data (drive scores/events)
- **Privacy policy URL**: required. A simple page summarising docs/PRIVACY.md is enough.
- **Account deletion**: in-app (Settings → Account → Delete account…) ✔︎ (guideline 5.1.1(v)).
- **Review notes** (paste):
  > Driveby is a practice aid for learner drivers who drive with a licensed adult supervisor; it states clearly that it does not replace a driving instructor. It records drives using the phone as a dashcam. All faces and licence plates are blurred on-device before any video is written. To test without driving: complete onboarding (choose "Can't find it? Enter my car manually" if offline), then tap Start drive → confirm the supervisor and tick the checklist → Start recording → Hold to stop. A drive needs ≥500 m and ≥2 min of movement to be scored; shorter recordings are discarded with a message. Background location is used only to continue a drive the user started if the phone locks. No live alerts are shown while driving. Account creation is optional; demo account: (create one in Supabase and put it here).

---

## 2. Supabase (accounts, sync, public hazard map)

1. Create a free project at <https://supabase.com> (region: US East).
2. **SQL Editor → New query** → paste **all of `db/schema.sql`** → Run. (Idempotent — safe to run again after updates.)
   - Creates `vehicles`, `drives`, `events`, `fuel_logs`, `practice_logs` with row-level security (users see only their rows),
     the public `hazard_cells` table, `publish_hazard_cells()` (the only writer of that table, enforcing k-anonymity),
     `delete_my_account()`, and a private `clips` storage bucket with per-user folder policies.
3. **Authentication → Providers → Email**: enabled. For a demo, you may turn *Confirm email* off so sign-up signs in immediately
   (the app also handles the confirm-email flow).
4. **Project Settings → API**: copy the **Project URL** and the **anon public** key into
   `Driveby/Resources/Config.plist` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). Never use the `service_role` key in the app.
   (Or paste them at runtime: Settings → About → Developer.)
   **Updating an existing project?** Re-run the whole file — it adds `practice_logs`. Until you do, sync stops at
   the hours-log step.
5. Rebuild. Settings → Account → **Create account**. Drives sync after each processed drive and when the app opens.
6. Optional: nightly recompute instead of per-sync — enable the `pg_cron` extension and run the commented
   `cron.schedule(...)` line at the end of `schema.sql`.

Verify locally before touching production (no Supabase needed):
```bash
pip install pgserver psycopg2-binary pandas scipy numpy
python db/test_schema.py        # → ALL SCHEMA CHECKS PASSED (incl. practice_logs RLS + cascade)
```

---

## 2b. Google Maps Platform (optional)

Without a key, every moment and hazard cell still has **Google Maps** and **Street View** buttons (plain links,
free). A key adds two things on the drive page: the route snapped exactly onto the road (Roads API) and
intersection names on each moment (Geocoding API).

1. <https://console.cloud.google.com> → create a project → *Billing* (Google's monthly free credit covers a class
   project's usage).
2. *APIs & Services → Library* → enable **Roads API** and **Geocoding API**.
3. *Credentials → Create credentials → API key* → **Restrict key**:
   - Application restriction: **iOS apps** → add your bundle ID (`com.gkanakadandi.Driveby` or yours).
   - API restriction: **Roads API** and **Geocoding API** only.
4. Paste it into `Driveby/Resources/Config.plist` → `GOOGLE_MAPS_API_KEY` (or at runtime: Settings → About →
   Developer). The app sends the `X-Ios-Bundle-Identifier` header so the iOS restriction works.

Google results are fetched when a screen opens and kept in memory only (Maps Platform terms limit caching).
Speed limits stay on OpenStreetMap: Google's speed-limit data requires an Asset Tracking licence.

---

## 3. Python processor (laptop)

```bash
python3.11 -m venv .venv && source .venv/bin/activate
pip install -r processor/requirements.txt
```

**Get drives off the phone:** Drive → *Export raw data for the Python processor* → AirDrop the zip → unzip into `data/`
(each drive folder has `drive.json`, `drive_000N.jsonl`, the blurred `drive_000N.mov`, `analysis.json`).
**Fuel log:** Settings → Vehicles → Fuel log → share icon → save as `data/fuel_log.csv`.

```bash
python -m processor.run data/ --all                  # events + scores for every drive (caches Overpass tiles in SQLite)
python -m processor.validate --fuel data/fuel_log.csv --drives data/ --vehicle-epa 32
jupyter notebook notebooks/validation.ipynb          # the full Phase 3 analysis → notebooks/out/validation.png
python -m processor.blur data/drive_0007/drive_0007.mov --spot-check notebooks/out/spotcheck.png
```

Import the fitted weights into the app: AirDrop `notebooks/out/scoring_model.json` to the phone →
Settings → Scoring model → **Import**.

### Re-exporting the Core ML models
`Driveby/MLModels/yolov8n.mlpackage` is included. To regenerate it, or to add a dedicated licence-plate detector:
```bash
pip install ultralytics coremltools
python tools/export_models.py                       # yolov8n
python tools/export_models.py --plate plates.pt     # → MLModels/plate_detector.mlpackage (auto-used by the app)
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Speed limits weren't available" on a drive | Phone was offline when the drive was scored. Drive page → *Retry speed limits*. |
| Drive discarded "too short" | Step 1.3: trips under 500 m or 2 min are discarded by design. |
| "No usable GPS signal" | Parking garage / no sky view. The drive is kept but not scored. |
| Video ends early, "camera stopped part-way" | Phone locked, a call came in, or it overheated. Sensors keep recording; later events have no clip. Keep the screen on (Driveby disables auto-lock while recording) and out of direct sun. |
| OBD adapter doesn't appear | iPhones only see **Bluetooth LE** adapters. Ignition must be on. |
| Privacy Lint build failure | A video writer exists outside `RedactingVideoWriter.swift`. That's the point of the check. |
| `swift test` can't find XCTest on Linux | Install a full Swift toolchain (swift.org), not just the compiler. |
