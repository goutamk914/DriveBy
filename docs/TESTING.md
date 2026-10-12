# Testing

## Automated (run before every push)

| Command | What it proves |
|---|---|
| `swift test` | 25 tests: numerics match SciPy/NumPy (Savitzky–Golay, gradient, percentile, linregress); the app's on-device pipeline reproduces the Python processor on two scripted drives (events, timing, severity, components, safety score, OBD fuel); every scripted manoeuvre is found and nothing else; k-anonymity; GeoJSON has no identifiers; tank-to-tank with partial fills; weight fitting; OBD parsing; sidecar keys; trip detector; scoring-model JSON from Python imports in Swift. |
| `python -m pytest processor/tests -q` | 13 tests: fixture reproducibility, bad-GPS-fix filtering, debounce, no-GPS failure, k-anonymity, cell keys, tank intervals, weight fitting, maxspeed parsing, privacy lint. |
| `python db/test_schema.py` | Schema applies twice; RLS isolation; anon can read hazard cells but not drives and can't publish; k = (5 events, 3 users) enforced; opted-out drives excluded; server cell keys == Python cell keys; account deletion cascades and re-publishes. |
| Xcode build | Privacy Lint phase. |
| `python tools/make_fixtures.py` | Regenerates fixtures after an intentional algorithm change (then both suites must pass again). |

## Field-test protocol (Step 1.4 — collect 10 varied drives)

- 2 highway (Rt 7, Rt 28 or I-66)
- 3 suburban arterial with signals
- 2 residential
- 1 rain or dusk — **you want to know now if CV degrades, not in October**
- 2 parking lot / stop-and-go

For each: same mount position (tape mark), passenger operates the phone, note anything odd in a log.

**Spot-check three events per drive against the clip** (Phase 2 "done when"). For blur, run the in-app
*Privacy spot-check* on at least 3 drives (60 frames) and record the leak count.

## Edge cases (Concept checklist: "What happens with…")

| Case | Expected behaviour | How to test |
|---|---|---|
| No GPS signal | Drive kept, marked "No usable GPS signal", not scored | Record 3 min in a parking garage |
| Dead battery / crash mid-drive | On next launch the drive is recovered: JSONL flushed every 5 s, video playable to the last 2 s fragment, `video_start_t` already in the sidecar → processed normally with a "damaged line skipped" note | Start a drive, force-quit from the app switcher, relaunch |
| Corrupt/missing video | Scores still computed from sensors; events show "No clip" | Delete the .mov from an exported drive and run `processor.run` |
| 4-second / 30-second trip | Discarded with "Trip too short to score (needs 500 m and 2 min)" | Start + stop in the driveway |
| Phone locked mid-drive | Video finalised ("camera stopped part-way"), sensors continue via background location, drive scored | Lock the phone 5 min into a drive (passenger) |
| Offline when the drive ends | Scored without speeding; "Retry speed limits" on the drive page | Airplane mode after parking |
| Phone overheating | Detection rate drops at *serious*; video stops at *critical*; sensors continue | Windshield in summer sun |
| Low storage (< 1 GB) | Records sensors only, tells you why | Fill the phone |
| Location permission denied | Start drive shows how to enable it | Deny in onboarding |
| OBD adapter unplugged mid-drive | Logging stops; drive scored from GPS; no OBD fuel | Unplug during a drive |

## Week 7 hardening (Step 7, "test on two other cars and one other phone")

- [ ] A second phone model (different camera FOV → check `focal_px` in drive.json, and Mount check)
- [ ] Two other cars (different mass → edit in Settings → Vehicles; a hybrid → regen factor)
- [ ] Someone else installs it via TestFlight and completes a drive without help (Phase 6 "done when")

## Weekly self-grading checklist (run every Sunday)

**Concept**
- [ ] Purpose in one sentence, with no "and"?
- [ ] Specific person who benefits (new drivers in VA-10 and their parents)?
- [ ] Local statistic with a citation?
- [ ] First-person origin story written down?
- [ ] What exists already, and in one sentence why Driveby is different?

**Technology**
- [ ] Runs end-to-end on a phone that isn't mine?
- [ ] Tested with a drive I didn't plan in advance?
- [ ] No GPS / dead battery / corrupt video / 4-second trip — all handled (table above)?
- [ ] Can I explain the hardest bug I fixed in 20 seconds, out loud, without notes?
- [ ] Every dependency documented (docs/SUBMISSION.md)?
- [ ] AI usage disclosed?

**Video**
- [ ] Under 3:00 with 10 s to spare? Names, app name, purpose in the first 20 s?
- [ ] Real drive, not a simulator? Tools and languages said out loud?
- [ ] Would someone who's never seen it understand it by 0:40?
