# Data contract (frozen Week 1)

The interface between the phone app and the Python processor. Once locked, neither side blocks the other.
Source of truth in code: `Driveby/Core/Contract.swift` ⇄ `processor/contract.py` (thresholds are mirrored and parity-tested).

## Clock

`t` = **seconds since recording start on the monotonic system clock** (`ProcessInfo.systemUptime` /
`mach_absolute_time`). CoreMotion sample timestamps and AVFoundation capture presentation times are on this same
clock, so a video frame at t = 12.400 s and a motion sample at t = 12.400 s are the same instant (Decision 1).
GPS fixes carry wall-clock timestamps; the recorder converts each to the monotonic clock at arrival. Wall clock
(`started_at`) is stored for display only and never used for alignment.

## `drive_000N.jsonl` — one JSON object per line, flushed every 5 s

| type | fields | rate | notes |
|---|---|---|---|
| `gps` | `t, lat, lon, spd, acc, hdg` | 1 Hz | `spd` m/s (Doppler) or `null`; `acc` horizontal accuracy m; `hdg` course ° or `null`. Fixes with `acc > 20` are dropped at ingest. |
| `imu` | `t, ax, ay, az, gx, gy, gz[, yaw]` | 50 Hz | `a*` specific force m/s² **including gravity** (+9.81 on the axis pointing up, as in the guide's sample); `g*` rad/s; optional `yaw` = rotation rate about the gravity axis (orientation-free). If `yaw` is absent the processor estimates gravity with a 1 s low-pass and projects the gyro onto it. |
| `obd` | `t[, rpm, kph, maf, fuel_lph]` | ~1 Hz | optional (ELM327 BLE). `maf` g/s, `fuel_lph` L/h (PID 015E). |
| `lead` | `t, bx, by, bw, bh, dist` | ≤15 Hz | optional. Lead vehicle in our lane from the on-device detector; box normalised to the video frame, origin top-left; `dist` metres = 1.8 × focal_px ÷ box_width_px. |

Example:
```json
{"t":12.400,"type":"gps","lat":39.0450000,"lon":-77.4870000,"spd":18.20,"acc":4.0,"hdg":271.4}
{"t":12.420,"type":"imu","ax":0.110,"ay":-0.030,"az":9.790,"gx":0.0010,"gy":0.0020,"gz":-0.0140,"yaw":-0.0130}
```
A half-written final line (crash, dead battery) is skipped and counted (`malformed_lines`), never fatal.
Unknown `type`s are ignored (forward compatible).

## `drive.json` — sidecar

```json
{ "drive_id": "…", "video_file": "drive_0007.mov", "sensor_file": "drive_0007.jsonl",
  "video_start_t": 0.83, "video_end_t": 1834.2, "video_interrupted": false,
  "vehicle_id": "…", "device": "iPhone14,5", "started_at": "2026-09-14T16:00:00Z", "ended_at": "…",
  "focal_px": 1012.4, "video_width": 1280, "video_height": 720, "app_version": "1.0", "recording_mode": "camera",
  "supervisor": "Jordan K." }
```
`supervisor` (optional) = the licensed adult confirmed in the pre-drive checklist; copied into the hours log.
`video_start_t` = sensor-clock time of the video's first frame (camera start latency is recorded, not assumed
zero). It is written as soon as the first frame reaches disk, so a crashed drive still aligns.
Sensor time of video time *v* = `video_start_t + v`.

Deviation from the guide: the video is **`.mov`** (H.264, 720p30, keyframe every 1 s) instead of `.mp4`, because
fragmented QuickTime files written by `AVAssetWriter` stay playable up to the last 2-second fragment if the app
crashes or the battery dies. OpenCV and ffmpeg read it the same way.

## `analysis.json` (written by the app AND by `processor/run.py`, same shape)

`trip_start_t, trip_end_t, distance_m, duration_s, moving_s, max_speed_mps, components{brake_waste, idle_frac,
jerk_rms, high_speed, accel_waste}, safety{…points, fractions, per_10_miles_factor, score}, events[…], trace[2 Hz:
t, v, a, lat, lon, a_lat, headway, limit], speed_limits_available, speed_limit_coverage, tailgating_available,
gps_fixes, imu_samples, malformed_lines, imu_jerk_rms, obd_fuel_gal, obd_method, processed_at`.

**Coaching fields (app only, optional — `version` 3; the Python processor omits them and both sides still decode):**

| key | contents |
|---|---|
| `skills` | `{"stats": {"<skill>": {"good": n, "total": n}}}` — skills `smooth_braking`, `smooth_acceleration`, `turns` (episodes), `speed_control`, `following_distance` (seconds), `stop_signs` (signs). Percent = good ÷ total, shown only once total ≥ 3 episodes / 60 s. |
| `stop_signs` | `[{nodeId, t, lat, lon, minSpeedMps, approachSpeedMps, approachPeakDecel, outcome: full_stop·rolling·missed, road}]` — OSM `highway=stop` nodes on the road being driven, approached from ≥ 8 m. Full stop < 0.7 m/s, rolling < 4.5 m/s. |
| `highlights` | `[{id, kind, t, tEnd, severity, lat, lon, eventId, headline, body, tip, clipPath, place}]` — good moments (`good_stop`, `smooth_stop`, `smooth_turn`) and stop-sign moments (`rolling_stop`, `missed_stop`). Scored events are merged in at display time, so the reflection timeline = events + highlights, ordered by `t`. |

Each highlight with video gets its own blurred clip (`clips/<kind>_<t>.mov`), cut exactly like event clips, so
tapping any moment on the timeline plays the footage of that instant.

The efficiency score is NOT stored in analysis.json — it is derived from `components` with the current scoring
model (weights + normalisation), so re-fitting the weights re-scores every drive consistently.

## `events` (matches `db/schema.sql`)

| field | meaning |
|---|---|
| `id` | UUID |
| `kind` | `hard_brake` · `hard_accel` · `harsh_corner` · `speeding` · `idle` · `tailgating` (`lane_drift` reserved for 2.0) |
| `t_offset_s` | sensor time of event start (same clock as `t`). "4:32 into your drive" = `t_offset_s − trip_start_t` |
| `t_end_s`, `t_peak_s` | event end / most extreme sample (local JSON; in Supabase they live in `detail`) |
| `severity` | 0…1 |
| `lat`, `lon` | at the peak |
| `detail` | `duration_s, v_start_mps, v_end_mps, peak, limit_mps, road, headway_s, lead_dist_m, energy_j` |
| `clip_path` | `clips/<kind>_<t>.mov` locally; `<user>/<drive>/<event>.mov` in storage (opt-in) |

### Thresholds (Step 2.2)

| event | condition | severity |
|---|---|---|
| hard_brake | a_long < −3.0 m/s² sustained 0.5 s | −3 → 0, −6 → 1 |
| hard_accel | a_long > 2.5 m/s² sustained 0.5 s | 2.5 → 0, 5 → 1 |
| harsh_corner | \|v × yaw_rate\| > 3.0 m/s² sustained 0.5 s | 3 → 0, 6 → 1 |
| speeding | v > limit + 4.5 m/s (~10 mph) for ≥ 5 s | 0.6·excess(4.5→13.4 m/s) + 0.4·duration(0→60 s) |
| idle | v < 0.5 m/s for > 60 s | 60 s → 0, 300 s → 1 |
| tailgating | headway < 1.0 s sustained 3 s, only above 5 m/s | 1.0 s → 0, 0.4 s → 1 |

Debounce: same-kind events merge if one starts ≤ 2 s after the previous ends, or < 5 s after the previous starts.
Longitudinal acceleration = `np.gradient(savgol_filter(v, 21, 3), 0.1)` on the 10 Hz GPS-speed series (Decision 3).
GPS-gap samples (nearest valid fix > 3 s away) never trigger acceleration events.

## `practice_log.json` (Documents) and `practice_logs` (Supabase)

One entry per supervised session: `id, drive_id (null for hand-entered), started_at, duration_s, night_s,
supervisor, notes, manual`. Recorded drives are logged automatically when scored; `night_s` = minutes between
sunset and sunrise (NOAA solar equations at the trip's first GPS fix, sampled each minute). Hand entries use
central Virginia for the sunset estimate unless the night minutes are typed in. Exported as CSV and as a PDF with
a parent/guardian signature line — a personal record, not the official DMV form.

## Hazard cell key

`f"{round(lat/0.0005)*0.0005:.4f}_{round(lon/0.0005)*0.0005:.4f}"` — Python rounding (half-to-even) on the
double. Identical in `Core/Hazard.swift`, `processor/hazard.py` and `publish_hazard_cells()` (verified by tests).
