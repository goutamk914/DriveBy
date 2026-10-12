# Spec traceability — the two planning PDFs → this codebase

*Driving App Plan* (strategy: what and why) and *Build Guide* (how). ✅ built · ⏭ deliberately cut by the plan (2.0) · ⚠️ deviation, with reason.

## Strategy doc — Part 2, the recommended version

| Requirement | Status | Implementation |
|---|---|---|
| Tier 1 · Drive recording: GPS + accelerometer + gyroscope, auto trip start/stop | ✅ | `Capture/SensorRecorder.swift` (GPS 1 Hz BestForNavigation, IMU 50 Hz), `Capture/RecordingController.swift` (manual + *auto-start when the car moves*, auto-stop after 3 min parked), `Core/Ingest.swift` `TripSegmenter` / `LiveTripDetector` |
| Tier 1 · Efficiency score from accel/brake smoothness, idle time, speed variance | ✅ | `Core/Scoring.swift` `Efficiency.components` (braking energy, idle fraction, jerk RMS, high-speed fraction, accel waste) — Build Guide Step 3.2 |
| Tier 1 · Validation chart: score vs tank-to-tank MPG | ✅ | `Views/Trends/ValidationView.swift`, `Core/Validation.swift`, `notebooks/validation.ipynb`, `processor/validate.py` |
| Tier 1 · Safety score from dashcam CV: ~~lane departure~~, following distance, hard braking | ✅ / ⏭ | Following distance (YOLOv8n on-device, pinhole distance, headway) + hard braking + harsh cornering + speeding: `Core/Events.swift`, `Core/Scoring.swift` `Safety`, `Capture/Redactor.swift`. Lane detection cut for 2026 by the Build Guide team plan. |
| Tier 1 · Drive detail timeline — tap an event, see the clip and what triggered it | ✅ | `Views/Drive/DriveDetailView.swift` → `Views/Drive/EventDetailView.swift` (blurred clip + live speed/g overlay + lead-vehicle box + synced sensor-trace charts + plain-English cause) |
| Tier 1 · Accounts + persistent history + trend lines | ✅ | `Services/Supabase.swift`, `Services/SyncService.swift`, `Views/Trends/TrendsView.swift`, local history in `Store/` |
| Tier 1 · On-device face and plate blurring before any storage or upload | ✅ | `Capture/Redactor.swift`, `Capture/RedactingVideoWriter.swift`, `Scripts/privacy_lint.sh` |
| Tier 1 · Anonymised district hazard heatmap | ✅ | `Views/Hazard/HazardMapView.swift`, `Core/Hazard.swift`, `db/schema.sql` `publish_hazard_cells()` |
| Tier 2 · Opt-in parent/teen shared view | ⏭ | Cut by the Build Guide team plan ("Nice, not differentiating") → 2.0 list in About + SUBMISSION |
| Tier 2 · EPA baseline MPG lookup (fueleconomy.gov) | ✅ | `Services/Network.swift` `FuelEconomyAPI`, `Views/Onboarding/VehiclePickerView.swift` (handles the single-item `menuItem` object quirk) |
| Tier 2 · Export hazard data as CSV/GeoJSON | ✅ | `Core/Hazard.swift` `GeoJSON`, share menu on the Hazard Map |
| Tier 2 · OBD-II integration | ✅ | `Services/OBDManager.swift` (ELM327 BLE), `Core/OBDParser.swift`, per-trip fuel in `Core/DriveAnalysis.swift` |
| Tier 3 · Live alerts, traffic lights, multi-user leaderboards, anything about other people's vehicles | ⏭ | Not built, by design. Listed as 2.0 (no leaderboards / no plate data ever). |
| Cut: licence-plate capture | ✅ removed | Plates are only ever destroyed (blurred). |
| Replace public leaderboard with private weekly streaks + trend lines | ✅ | `Core/Trends.swift`, Home + Skills → Score trends |
| Live alerts → post-drive; passive audio only if anything | ✅ | No in-drive alerts; dim "Eyes on the road" screen. Passive chime listed as 2.0 |
| Manual odometer/gas entry demoted to validation tool | ✅ | Fuel log (Settings → Vehicles) is framed as validation ground truth |
| No "right-of-way" claim; red-light = 2.0 | ✅ | Not claimed anywhere |
| Differentiator paragraph | ✅ | About screen + SUBMISSION.md |
| Safety rule written down and said out loud | ✅ | Onboarding step (must accept), Settings → Safety rules, recording screen |
| Honest validation ("state n", "safety not validated") | ✅ | `ValidationResult.honestSummary`, score-ring captions, About → Honest limits |
| Hazard map seeded honestly, thresholds shown ("7 hard-braking events from 3 drivers") | ✅ | `HazardCell.summary`; your own cells shown privately with progress toward k |
| Stack: SwiftUI + CoreMotion (iOS-only option), Supabase, Python + OpenCV, YOLOv8n, OSM Overpass, fueleconomy.gov, charts | ✅ | Swift Charts replaces Victory Native/Recharts (they're React libraries; the SwiftUI path uses Apple's) |

## Build Guide

| Item | Status | Implementation |
|---|---|---|
| Decision 1: the phone IS the dashcam; one clock | ✅ | `MonotonicClock`; CoreMotion timestamps + capture PTS + converted GPS times share the mach clock; `video_start_t` recorded, not assumed |
| Decision 2: three components | ✅ ⚠️ | App + `processor/` + Supabase. ⚠️ The app *also* runs events/scoring/blur on-device so (a) someone else can install it and complete a drive unaided and (b) the "blurred on the phone before anything is written" line is literally true. The guide explicitly allows on-device CV. Raw unblurred video never exists anywhere. |
| Decision 3: GPS for longitudinal, accelerometer for jerk, gyro yaw for lateral | ✅ | `Ingest.resample` (SG-smoothed Doppler speed → gradient), `yawSeries` (gyro about gravity), `imu_jerk_rms` diagnostic |
| Decision 4: OBD dongle; MAF fallback `MAF/14.7/2830` | ✅ | `DriveAnalyzer.obdFuel`, `processor/run.py obd_fuel` |
| Decision 5: stack | ✅ ⚠️ | "App (alt): SwiftUI + AVFoundation + CoreMotion" chosen (iOS-only target). MapKit replaces react-native-maps (no key either); Swift Charts replaces Victory Native. |
| Day 2: repo structure, `.gitignore` data/ and footage | ✅ | `processor/{ingest,blur,vision,events,scoring}.py`, `db/schema.sql`, `data/`, `notebooks/` |
| Schema: vehicles, drives, events, fuel_logs, hazard_cells (no user_id) | ✅ ⚠️ | `db/schema.sql` — additive columns only (cascade deletes, epa_id, fuel_type, atv_type, regen_factor, hazard_opt_in, filled_to_full) |
| RLS on drives/events/vehicles/fuel_logs; hazard_cells world-readable, insert-only via server function | ✅ | Verified by `db/test_schema.py` |
| Step 1.1: GPS 1 Hz, accel/gyro 50 Hz, JSONL, monotonic `t`, BestForNavigation, keep-awake, background, flush every 5 s | ✅ | `SensorRecorder`, `SampleFileWriter`, `isIdleTimerDisabled`, `UIBackgroundModes: location` |
| Step 1.2: 720p30, sidecar JSON with `video_start_t` | ✅ ⚠️ | `CameraRecorder`, `DriveSidecar`. ⚠️ `.mov` not `.mp4` — fragmented QuickTime survives crashes (edge case "dead battery / corrupt video") |
| Step 1.3: trip segmentation thresholds | ✅ | `Thresholds.trip*`, `TripSegmenter`, discard < 500 m or < 120 s |
| Step 2.1: drop acc > 20 m; SG window 21 order 3; gradient | ✅ | parity-tested against SciPy |
| Step 2.2: event thresholds + debounce | ✅ | `Core/Events.swift` ⇄ `processor/events.py` |
| Step 2.3: Overpass once per drive (tiled), maxspeed + highway fallback, 25 m + 45° heading match, cache | ✅ | `Core/SpeedLimits.swift`, `Services/Network.swift` (disk cache), `processor/speedlimits.py` (SQLite cache) |
| Step 3.1–3.4: braking energy, components, percentile normalisation, weights, regression, honest reporting, residuals | ✅ | `Core/Scoring.swift`, `Core/Validation.swift`, notebook. Regen factor per vehicle for hybrids/EVs. |
| Step 4.1: blur first, always; no bypass; grep for writers | ✅ | Redactor + RedactingVideoWriter + Privacy Lint build phase; `processor/blur.py` is the only `cv2.VideoWriter` file |
| Step 4.2: lane detection | ⏭ | Cut for 2026 per the guide |
| Phase 4 "done when": spot-check 20 random frames, know the miss rate | ✅ | Drive → Privacy spot-check (tap to flag); `processor/blur.py --spot-check` |
| Step 5.1–5.2: following distance, focal from calibration, headway < 1.0 s sustained 3 s | ✅ | Focal from AVFoundation's factory intrinsic matrix (per frame), override from `tools/calibrate_camera.py` checkerboard |
| Step 5.3: safety formula, per 10 miles, "not validated" | ✅ | `Safety.score` — coefficients exactly as specified |
| Phase 6: screen map, onboarding, EPA lookup, plain-English copy with $ figure from the user's fuel log | ✅ | Views/, `Core/EventCopy.swift` (physics-based gallons, price from latest fill-up) |
| Step 7.1–7.3: k-anonymity (CELL 0.0005, K_EVENTS 5, K_USERS 3), seed honestly, GeoJSON export | ✅ | three implementations with identical cell keys (tests) |
| Phase 8: video beat sheet, two lines, submission checklist, AI + open-source disclosure | ✅ | `docs/SUBMISSION.md` |
| Failure modes table | ✅ | `docs/TESTING.md` edge cases; Privacy shortcut prevented structurally |

## Learner-feature requests (October 2026)

| Request | Status | Where / how |
|---|---|---|
| Search instead of a dropdown for car model | ✅ | `VehiclePickerView`: tap a year (or type it), then free-text search "honda civic" / "chevy malibu" / "cr-v awd" → trim. Matching in `Core/VehicleSearch.swift` (nicknames, multi-word makes, dash-insensitive), unit-tested. |
| Beginner (step by step) and Advanced (only significant issues) modes | ✅ | Chosen in onboarding, switchable in Settings. Beginner: full pre-drive checklist, every moment with a tip, guided "Moment 1 of N" walk-through, drills in steps. Advanced: mount check only, `DriveMoment.isSignificant` filter (speeding, tailgating, missed stops, severity ≥ 0.35), compact timeline. Neither mode alerts while driving. |
| Connect to Google Maps API | ✅ ⚠️ | `Services/GoogleMaps.swift`: Maps + Street View links (no key), Roads API snap-to-road, Geocoding intersection names (optional key). ⚠️ Speed limits stay on OpenStreetMap — Google's speed-limit data requires an Asset Tracking licence; MapKit still draws the maps. |
| Safety score + what to practise next | ✅ | Skills tab (distance-weighted safety average of last 10 drives), reflection screen, Home card; `PracticePlanner` picks the weakest skills (and night driving if night hours are short) with step-by-step drills. |
| Log hours of driving for the license | ✅ | Hours tab: every scored drive logged automatically with supervisor + night minutes (NOAA sunset); manual add/edit; Virginia 45 h / 15 night default (editable); PDF with signature line + CSV export; synced to `practice_logs`. |
| VERY clear that the app doesn't replace an instructor | ✅ | Onboarding page with three required checkboxes (also shown once to existing installs), banner on Home / checklist / reflection / Hours / Skills, About section, PDF footer, supervisor confirmation before every recording. |
| Obvious recording symbol | ✅ | Pulsing red "● REC 12:34" badge + a thick red frame around the entire screen while recording. |
| Driver skill tab (Smooth Braking 67%, Turn 76%) | ✅ | `SkillsView` — six skills as % bars with "8 of 12 slow-downs", change vs the previous 10 drives, tap for the definition and a drill. |
| Post-drive reflection timeline; tap → the exact clip | ✅ | `ReflectionView` opens automatically after a drive is scored; `MomentTimeline` ("2:15 Good stop-sign approach · 5:30 Hard brake"); each moment — good or bad — has its own blurred clip that `MomentDetailView` plays with the speed / g-force trace on the same clock. |
| Explain simply how a phone camera monitors driving | ✅ | "How Driveby watches your drive" onboarding page (also Settings → About) and README: GPS → speed, motion sensors → braking/turning, map → limits/stop signs, camera → replay clips + gap to the car ahead. |

## Notes for the judge's likely questions

- **Why is the safety score's fraction term small?** The guide's formula weights `tailgating_fraction` and
  `speeding_fraction` as 0–1 fractions (max −14/−15 points), while event sums are per 10 miles. Implemented exactly;
  coefficients live in `ScoringModel.safety` and can be retuned and exported from the notebook.
- **Accuracy of distance?** Pinhole model with a 1.8 m assumed car width: ±15–20% for SUVs/compacts. Headway
  thresholds (1 s / 2 s) are coarse enough that this doesn't flip classifications often; state it.
- **Plates on cars the detector misses?** Then their plate isn't blurred — stated honestly; mitigated by vehicle
  plate-zone blurring, text-region blurring, box persistence and padding; measured with the spot-check.
