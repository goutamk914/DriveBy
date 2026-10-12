# Privacy design (a scored feature, not a footnote)

> **"We record other cars incidentally. We thought hard about whether to use that. We decided we had no right to —
> so faces and plates are blurred on the phone before anything is written to disk."**

> **"Your data stays yours. But stripped of everything identifying and pooled together, it becomes a map of the
> intersections where drivers brake hardest — something a county traffic engineer could actually act on."**

## 1. Blur before storage — enforced structurally

- Camera frames arrive in memory (`AVCaptureVideoDataOutput`). `RedactingVideoWriter.append()` runs the `Redactor`
  on the frame, renders a **new** blurred pixel buffer, and only that buffer is encoded. The camera's buffer is never
  handed to the encoder. There is no flag, parameter or alternative path.
- `Scripts/privacy_lint.sh` runs on every Xcode build and fails it if `AVAssetWriter`, `AVAssetWriterInput`,
  a pixel-buffer adaptor or `AVCaptureMovieFileOutput` appears in any other file (and if `cv2.VideoWriter` appears
  outside `processor/blur.py`).
- Event clips are cut (passthrough, no re-encode) from the already-blurred drive video, so they inherit the guarantee.
- No audio is recorded.

### What gets blurred
| Detector | Covers |
|---|---|
| Apple Vision face detector | faces (padded 30%) |
| YOLOv8n (Core ML, on-device) — cars, buses, trucks, motorcycles | the plate zone of every vehicle (front or rear): central 70% width, bottom 55% height |
| YOLOv8n — people | head zone (top 30% of the body box) — pedestrians' faces are too small for the face detector |
| Vision text-rectangle detector (fallback) | plate-shaped text regions |
| `plate_detector.mlpackage` (optional, drop into MLModels/) | dedicated licence-plate model |

Boxes persist 0.5 s and are expanded between analyses, so a one-frame detector miss doesn't leak. The blur is
pixellation + Gaussian (irreversible). **We err toward over-blurring** and state recall honestly: use Drive →
*Privacy spot-check* (20 random frames, tap to flag leaks) and quote the observed leak rate.

## 2. What leaves the phone

| Data | Leaves? |
|---|---|
| Unblurred video | **Never exists** |
| Full blurred drive video | No (auto-deleted after N days, user setting) |
| Raw sensor log (`.jsonl`) | No (unless *you* export it) |
| Drive summaries, scores, numeric events with location | Only if signed in → your private rows (RLS: only you can read them) |
| Blurred event clips | Only if signed in **and** opted in (off by default) → private bucket folder named by your user id |
| Hazard-map contribution | Pooled server-side; only k-anonymous counts become public; opt-out in Settings |
| Licence plates as data | Never read, stored or looked up. Plate capture was cut from the concept entirely. |
| Supervised-hours log (dates, minutes, supervisor names, notes) | Only if signed in → your private `practice_logs` rows (RLS). The learner's name is used only on the PDF you export. |
| Coordinates sent to Google | Only if a Google Maps key is configured: the drive's route points (Roads API) and one point per moment you open (Geocoding). Nothing about you or your account is sent; results are kept in memory only. The Google Maps / Street View buttons just open a link to that point. |

## 3. k-anonymity for the public map (Step 7.1)

- Events (hard braking, sharp turns) are binned into 0.0005° cells (≈55 m).
- `publish_hazard_cells()` (SECURITY DEFINER, the only writer of `hazard_cells`) publishes a cell **only** if it has
  **≥ 5 events from ≥ 3 distinct users**, counting only drives with `hazard_opt_in = true`.
- The public row has counts only: `cell_key, lat, lon, event_count, distinct_users, dominant_kind, updated_at`
  (truncated to the day). No user IDs, no trip timestamps.
- Your own contribution is shown to you privately (dashed blue cells) with progress toward the threshold —
  the honest way to "seed it" with one or two contributors without faking density.

## 4. Why no public leaderboard, no live alerts — and not an instructor

Driveby says, in onboarding (with three boxes to tick), on Home, on the pre-drive checklist, after every drive
and on the exported hours log: **it is a practice tool, not a driving instructor**, and every practice drive needs a
licensed adult in the front passenger seat. Every recording starts with that adult's confirmation.


A public ranking rewards checking the phone and competitive driving; real-time alerts are a distraction that can't
be filmed safely. Driveby uses private trends + weekly streaks and post-drive coaching instead.

## 5. Legal context the judge will know

Virginia HB 2724 (2025) restricts even law-enforcement ALPR use; *Neal v. Fairfax County Police Department* held that
untargeted plate collection and storage violated the Virginia Data Act. Driveby's design does the opposite of plate
collection: it destroys plate information before storage.
