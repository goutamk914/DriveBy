# Driveby

**A coaching app that scores how safely and efficiently you drive, proves the efficiency score against real fuel data, and never records a single thing about anyone else.**

> **Driveby is a practice tool, not a driving instructor.** It does not replace a licensed instructor or a
> state-approved driver education course. Learners practise on their own time **with a licensed adult in the
> front passenger seat**, as a learner's permit requires — and never touch the phone while the car is moving.

VA-10 Congressional App Challenge 2026 · iOS (SwiftUI) · on-device computer vision · Python validation pipeline · Supabase

---

## What's in this repo

```
Driveby/                         ← repo root (this folder)
├── Driveby.xcodeproj            iOS project (Xcode 26, synchronized folder — every file in Driveby/ is compiled)
├── Driveby-Info.plist           usage strings, background modes (merged into the generated Info.plist)
├── Driveby/                     THE APP
│   ├── DrivebyApp.swift, ContentView.swift
│   ├── Core/                    pure-Swift logic, unit-tested on macOS/Linux (data contract, ingest, events,
│   │                            speed limits, scoring, validation, hazard k-anonymity, GeoJSON, OBD parser,
│   │                            coaching: skills, stop signs, moments, practice plan, sunset, hours log, car search)
│   ├── Capture/                 recorder: CoreMotion 50 Hz + GPS 1 Hz + 720p30 camera on ONE clock,
│   │                            Redactor (Vision + YOLOv8n) and RedactingVideoWriter (the only video writer)
│   ├── Processing/              post-drive pipeline + blurred clip export
│   ├── Services/                Overpass (OSM speed limits + stop signs), fueleconomy.gov (EPA), Google Maps
│   │                            (optional: snap-to-road, intersection names, Maps/Street View links), Supabase, OBD-II, sync
│   ├── Store/                   on-device storage (your data, as plain JSON/JSONL files)
│   ├── Views/                   SwiftUI screens — Drive · Skills · Hours · Hazard Map · Settings tabs,
│   │                            post-drive Reflection, pre-drive checklist, onboarding
│   ├── MLModels/yolov8n.mlpackage   Core ML YOLOv8n (vehicles, people) — exported with tools/export_models.py
│   ├── Resources/               Config.plist (Supabase URL/key), PrivacyInfo.xcprivacy
│   └── Assets.xcassets          app icon, accent colour
├── processor/                   Python processor (ingest, events, scoring, blur, vision, hazard, validate, run, sync)
├── notebooks/validation.ipynb   Phase 3: score vs real MPG → scatter with r² and n → scoring_model.json
├── db/schema.sql                Supabase schema + RLS + k-anonymous publish function + storage policies
├── db/test_schema.py            verifies the schema against a local Postgres
├── Tests/DrivebyCoreTests/      Swift unit + Swift↔Python parity tests (fixtures from tools/make_fixtures.py)
├── Package.swift                lets `swift test` run the Core tests without a simulator
├── Scripts/privacy_lint.sh      build phase: fails the build if video is written outside the redacting writer
├── tools/                       export_models, calibrate_camera, obd_check, make_fixtures, patch_xcodeproj
├── data/                        (git-ignored) raw drives exported from the phone
└── docs/                        DEPLOY · DATA_CONTRACT · PRIVACY · SUBMISSION · TESTING · SPEC_TRACE
```

## Open it and run it (5 minutes)

1. Open **`Driveby.xcodeproj`** in Xcode 26.
2. Select the **Driveby** target → *Signing & Capabilities* → choose your **Team**. If the bundle ID
   `com.gkanakadandi.Driveby` is taken, change it to something unique.
3. Plug in your iPhone (iOS 17+), pick it as the run destination, press **⌘R**.
   (The simulator builds and runs the UI, but has no camera, GPS motion or accelerometer — test drives need a real phone.)
4. Onboarding: "not a driving instructor" agreement → how it works → safety rules → Beginner or Advanced →
   search your car (EPA lookup) → baseline → permissions → mount check.
5. Mount the phone (landscape, centred, lens above the dash line), tap **Start drive**, tick the pre-drive
   checklist with your supervising driver, drive, park. After 3 minutes parked it stops itself; the drive is
   scored on the phone and the **post-drive reflection** opens.

Cloud sync is optional. Without `Config.plist` values the app runs fully local. To enable accounts, sync
and the public hazard map, follow **docs/DEPLOY.md** (Supabase setup takes ~10 minutes).

## How Driveby watches a drive (the simple version)

Mount the phone on the dash and drive normally. Four things do all the work:

1. **GPS → speed.** The same GPS a maps app uses says how fast you're going and where.
2. **Motion sensors → braking and turning.** The sensor that rotates your screen feels what a passenger feels:
   pushed forward when you brake hard, back when you speed up, sideways in a sharp turn.
3. **Map → speed limits and stop signs.** OpenStreetMap says the limit and where stop signs are, so Driveby can
   tell whether you slowed to a full stop.
4. **Camera → replay clips.** It records the road so you can rewatch any moment, and estimates the gap to the car
   ahead. Faces and plates are blurred on the phone before anything is saved.

After you park, Driveby puts it all on one timeline ("2:15 Good stop-sign approach · 5:30 Hard brake"), and
tapping a moment plays the exact clip. It can't see your eyes, mirrors, signals or hands — that's what your
supervising driver and instructor are for.

## Learner features

| Feature | Where |
|---|---|
| "Not a driving instructor" agreement in onboarding, banner on Home / checklist / reflection / hours, About | `Views/Onboarding/CoachingOnboarding.swift` (`DisclaimerAcceptView`), `Views/Components/Components.swift` (`DisclaimerBanner`), `Theme.swift` (`Disclaimer`) |
| Beginner (step-by-step) and Advanced (significant issues only) modes | `Core/Coaching.swift` (`DriverMode`, `DriveMoment.isSignificant`), `PreDriveChecklistView`, `ReflectionView`, Settings |
| Pre-drive checklist + required supervising adult | `Views/Home/PreDriveChecklistView.swift` |
| Obvious recording indicator: pulsing red REC badge with timer + red frame around the whole screen | `Views/Home/RecordingView.swift`, `RecBadge` |
| Driver Skills tab — Smooth Braking 67%, Turns 76%, Speed Control, Following Distance, Stop Signs, Smooth Acceleration | `Views/Skills/SkillsView.swift`, `Core/Coaching.swift` (`SkillAnalyzer`) |
| Safety score + "what to practise next" with drills | `SkillsView`, `ReflectionView`, `Core/Coaching.swift` (`PracticePlanner`) |
| Post-drive reflection: timeline of important moments, good AND bad; tap → the exact clip | `Views/Drive/ReflectionView.swift`, `MomentTimeline.swift`, `EventDetailView.swift` (`MomentDetailView`), `Processing/DriveProcessor.swift` (clip export) |
| Stop-sign approaches (full / rolling / flagged) from OpenStreetMap stop nodes | `Core/Coaching.swift` (`StopSignAnalyzer`), `Core/SpeedLimits.swift` (`OSMControl`) |
| Supervised-hours log (Virginia: 45 h, 15 after sunset), automatic night split, manual entries, PDF + CSV export | `Views/Hours/HoursLogView.swift`, `PracticeLogPDF.swift`, `Store/PracticeLogStore.swift`, `Core/Coaching.swift` (`Solar`) |
| Car search instead of dropdowns ("2019 honda civic", "chevy malibu") | `Views/Onboarding/VehiclePickerView.swift`, `Core/VehicleSearch.swift` |
| Google Maps: Maps / Street View links for every moment and hazard cell; optional Roads API snap-to-road and intersection names | `Services/GoogleMaps.swift`, `DriveDetailView`, `MomentDetailView`, `HazardMapView` |

## Architecture (Build Guide, Decision 2 — three components)

```
┌────────────────────┐  Records video + sensors on ONE monotonic clock, blurs faces/plates in
│ PHONE APP (SwiftUI)│  memory BEFORE encoding, detects events, scores, cuts blurred clips,
└─────────┬──────────┘  shows coaching, trends, validation and the hazard map.
          │ raw drive stays on the phone (export it yourself as a zip for the processor)
          ▼
┌────────────────────┐  Same algorithms in Python (parity-tested against the app), plus the
│ PROCESSOR (Python) │  validation notebook that fits the weights, CV for imported dashcam footage,
└─────────┬──────────┘  spot-check contact sheets and annotated demo clips.
          │ only blurred clips (opt-in) + numeric events leave the device
          ▼
┌────────────────────┐  Auth, drive records, events, fuel logs (row-level security), and the
│ BACKEND (Supabase) │  PUBLIC hazard_cells table — written only by a k-anonymous server function.
└────────────────────┘
```

Why the phone does the processing too: the plan's privacy line is *"faces and plates are blurred on the phone
before anything is written to disk."* Driveby makes that literally true — `RedactingVideoWriter` is the only
code path that writes video, and it receives frames only after `Redactor` has blurred them. The Python
processor remains for validation, tuning and imported footage, exactly as the Build Guide describes.

## Tier 1 (all built)

| Feature | Where |
|---|---|
| Drive recording: GPS 1 Hz + accel/gyro 50 Hz, auto trip start/stop | `Capture/SensorRecorder.swift`, `Capture/RecordingController.swift`, `Core/Ingest.swift` (`TripSegmenter`, `LiveTripDetector`) |
| Efficiency score (braking waste, idle, jerk, high speed, hard accel) | `Core/Scoring.swift` |
| Validation chart vs tank-to-tank MPG (r² and n) | `Views/Trends/ValidationView.swift`, `Core/Validation.swift`, `notebooks/validation.ipynb` |
| Safety score (hard braking, following distance, harsh cornering, speeding) | `Core/Scoring.swift` (`Safety`), `Core/Events.swift` |
| Drive detail timeline → tap event → blurred clip + sensor trace + plain-English cause | `Views/Drive/DriveDetailView.swift`, `Views/Drive/EventDetailView.swift`, `Core/EventCopy.swift` |
| Accounts + persistent history + trend lines | `Services/Supabase.swift`, `Services/SyncService.swift`, `Views/Trends/TrendsView.swift` |
| On-device face + plate blurring before any storage | `Capture/Redactor.swift`, `Capture/RedactingVideoWriter.swift`, `Scripts/privacy_lint.sh` |
| Anonymised district hazard heatmap (k-anonymity) + GeoJSON export | `Views/Hazard/HazardMapView.swift`, `Core/Hazard.swift`, `db/schema.sql` `publish_hazard_cells()` |

Tier 2 also built: EPA baseline lookup (fueleconomy.gov), GeoJSON/CSV export, OBD-II (ELM327 BLE) per-trip fuel.
Cut per the plan and listed as **2.0**: lane detection, traffic lights, parent/teen share, live alerts, dashcam SD import.

## Tests

```bash
swift test                                   # 38 Swift tests, incl. Swift ↔ Python parity, coaching, car search
pip install -r processor/requirements.txt
python -m pytest processor/tests -q          # 13 Python tests
python db/test_schema.py                     # schema: RLS, k-anonymity, cell-key parity, account deletion
sh Scripts/privacy_lint.sh                   # also runs on every Xcode build
```

The parity fixtures contain a scripted synthetic drive (hard brake, long idle, hard launch, sharp turn,
speeding stretch, tailgating stretch, a bad GPS fix, a half-written last line). Both pipelines must find
exactly those events with identical timing, severity and scores. Synthetic data is used **only** in tests —
never in the hazard map or the validation chart.

## Safety rules (part of the design)

- Driveby never replaces a driving instructor; every practice drive has a licensed adult in the front passenger seat.
- The student driver does not touch the phone while the car is moving.
- An experienced licensed adult drives during data collection, or a passenger operates the device.
- Start recording before shifting into drive; stop after parking.
- Say this rule out loud in the demo video.

The app enforces what it can: a required supervisor confirmation before every recording, no live alerts, no
scores while driving, a dimmed "Eyes on the road" screen while moving, and press-and-hold to stop
("Passenger: hold to stop"). Beginner vs Advanced only changes what you see before and after a drive.

## Docs

- **docs/DEPLOY.md** — Supabase, signing, TestFlight / App Store, privacy labels, review notes
- **docs/DATA_CONTRACT.md** — JSONL + sidecar formats, clocks, events schema
- **docs/PRIVACY.md** — what leaves the phone, k-anonymity, the two lines to memorise
- **docs/TESTING.md** — field-test protocol, edge cases, weekly self-grading checklist
- **docs/SUBMISSION.md** — video beat sheet, submission answers draft, AI disclosure, open-source list
- **docs/SPEC_TRACE.md** — every requirement in the two planning PDFs → where it's implemented, and the deliberate deviations
