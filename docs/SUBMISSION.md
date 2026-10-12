# Submission kit — VA-10 Congressional App Challenge 2026

**Submit by Oct 19 (hard deadline Mon Oct 26, 12:00 pm EDT). Feature freeze Oct 12.**
Fill in every `[brackets]` yourself — the origin story and numbers must be yours.

## One sentence
> "Driveby is an app that coaches new drivers on safety and fuel efficiency using their own phone as a dashcam."

## Video (3:00 hard cap — rehearse to 2:45)

| Time | Beat | Notes |
|---|---|---|
| 0:00–0:15 | "I'm [name], and [teammate] — we're juniors at [school]. Driveby is an app that coaches new drivers on safety and fuel efficiency using their own phone as a dashcam." | Faces, not a slide |
| 0:15–0:35 | The problem: [local teen-crash statistic + citation, e.g. Virginia DMV crash facts for drivers 16–19; Rt 7 / Rt 28 / I-66 corridors] + your personal story | Face to camera |
| 0:35–0:50 | Setup: pick your car (EPA lookup), mount the phone, **say the safety rule**: "The student doesn't touch the phone while moving — a licensed adult drives or a passenger handles it." | Fast |
| 0:50–2:00 | **Demo (70 s, the whole competition):** real drive → summary → two score rings → tap a hard-braking event → the blurred clip plays with the speed trace and "You slowed from 41 to 12 mph in 2.1 s on Route 7… about 3¢" → tailgating clip with "0.8 s behind" box → Trends | Screen-record the phone at native resolution (Control Center → Screen Recording); film the car separately at golden hour |
| 2:00–2:20 | Validation chart: "I didn't want to invent a number, so I logged every fill-up and checked whether my score predicted MPG. It does — **n = [9], r² = [0.__]**. Suggestive; the next step is more data. The safety score isn't validated — that would need crash data." | Use notebooks/out/validation.png |
| 2:20–2:40 | Tech: "Swift and SwiftUI on iOS, Apple's Vision and Core ML with a YOLOv8 model on the phone, Python with OpenCV, NumPy and SciPy for validation, Supabase/PostgreSQL for the backend." One hard problem (below). Then the privacy line, out loud. | |
| 2:40–3:00 | Hazard map + GeoJSON export: "Your data stays yours. But stripped of everything identifying and pooled together…" Then 2.0 roadmap, fast. End. | |

**The two lines to memorise** (docs/PRIVACY.md). **Things that quietly cost points:** filming a phone screen with
another phone, background noise, windshield glare, "um" in the first 10 s, running over 3:00, forgetting to name
the languages.

### The one hard problem (pick one, explain in 20 s)
- **Syncing 50 Hz motion data with 30 fps video.** "A separate dashcam has its own clock that drifts. We made the
  phone the dashcam, so the camera frames and the accelerometer share one hardware clock — a frame at 12.400 s and a
  sensor sample at 12.400 s are the same instant. We still record the camera's start delay so clips line up exactly."
- **A score without labelled ground truth.** "Nobody labels 'efficient driving'. So we built the score from physics —
  kinetic energy thrown away by braking, idling, high-speed drag — and checked it against the one ground truth we
  could collect: real fuel economy from the fuel log."
- **The accelerometer lies about direction.** "A phone in a mount at an angle reports acceleration in its own frame.
  We sidestepped orientation entirely: forward acceleration comes from the derivative of GPS Doppler speed, and the
  gyroscope gives yaw rate about the gravity axis, which doesn't depend on how the phone is mounted."

## Submission answers (draft — rewrite in your own voice)

**What does your app do?**
Driveby turns a phone into a driving coach for new drivers. It records a drive (GPS, accelerometer, gyroscope and
camera), then — after you park — scores how efficiently and how safely you drove, and shows each moment that cost you
points: tap an event and you see the clip, the speed and braking trace, and a plain-English explanation with a
dollar figure ("Easing off earlier here would have saved about 3¢"). The efficiency score is validated against real
fuel economy. Faces and licence plates are blurred on the phone before any video is saved. Pooled anonymously
(k-anonymity), hard-braking events become a public map of the district's most dangerous intersections that can be
exported for VDOT or county traffic engineering.

**What inspired you?** [Your first-person origin story, ~150 words — written Day 3.]

**Who is it for?** New drivers in VA-10 (Loudoun and Prince William) and their parents; at scale, county traffic engineers.

**What technical difficulties did you face?** [The one hard problem above, plus the honest limits: OSM speed limits
can be missing; safety score not validated; blur recall measured at [__]% on a [60]-frame spot check.]

**What tools and languages did you use?** Swift, SwiftUI, AVFoundation, Core Motion, Core Location, Vision, Core ML,
Core Bluetooth, MapKit, Swift Charts; Python (NumPy, pandas, SciPy, OpenCV, Ultralytics YOLOv8, Matplotlib, Jupyter);
PostgreSQL on Supabase; OpenStreetMap Overpass API; EPA fueleconomy.gov API; Xcode, Git.

**What would you change in a 2.0 version?** Lane-departure detection (classical CV, then segmentation); traffic-light
state at intersections; an opt-in parent/teen shared view; importing footage from a standalone dashcam SD card;
an optional passive audio chime for hard braking (never a screen alert); partnering with Loudoun County traffic
engineering so the hazard map has enough contributors to be useful.

**What did you learn?** [Your words — e.g. reporting n with r², designing privacy into the architecture instead of
adding it later, why "right-of-way detection" is an open research problem.]

## AI usage disclosure (required — paste and adjust)
> We used AI assistants while building Driveby. Claude (Anthropic) helped draft parts of the Swift and Python code,
> the database schema, test fixtures and documentation, which we then reviewed, tested on real drives, and modified.
> [ChatGPT/Copilot — list if used, and for what.] The app itself runs no generative AI; its computer vision uses a
> standard pretrained open-source detector (YOLOv8n) and Apple's built-in face detector.

## Open-source libraries, models and data (required)

| Component | License | Used for |
|---|---|---|
| Ultralytics YOLOv8n (model + `ultralytics` package) | AGPL-3.0 | Vehicle/person detection (blur zones, following distance) |
| coremltools | BSD-3-Clause | Converting YOLOv8n to Core ML |
| NumPy, SciPy, pandas, Matplotlib | BSD-3 / BSD / PSF-style | Signal processing, statistics, charts |
| OpenCV (`opencv-python`) | Apache-2.0 | Video frames, blur, calibration |
| Requests | Apache-2.0 | Overpass API |
| supabase-py | MIT | Optional laptop upload |
| python-OBD | GPL-2.0 | Optional laptop OBD check |
| Jupyter | BSD-3 | Validation notebook |
| OpenStreetMap data via Overpass API | ODbL | Speed limits, road names ("© OpenStreetMap contributors") |
| fueleconomy.gov web services | U.S. Government (public domain) | EPA MPG ratings |
| Apple frameworks (SwiftUI, Vision, Core ML, …) | Apple SDK | iOS app |
| Supabase (PostgreSQL, GoTrue, PostgREST) | Apache-2.0 / PostgreSQL | Backend |

## Final checklist
- [ ] Video 1–3 min on YouTube, **Public** (check in an incognito window)
- [ ] Every participant's name, app name, purpose, target audience said in the video
- [ ] Tools and languages said out loud
- [ ] Functionality shown, not described
- [ ] AI usage disclosed · every open-source library documented
- [ ] Six questions answered, incl. 2.0
- [ ] Source code ready to hand over (this repo) — judges may request it
- [ ] Submitted by Oct 19
