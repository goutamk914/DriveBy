# Driveby: 3:00 Video Script

A comedy skit in a homemade driving simulator, a DMV scene, a quick app reveal, then four "Algorithm" slides with the speaker's camera in the bottom-right corner. Ends back at the DMV. Hard stop at 3:00.

Pace: about 2.7 words per second. Read each block out loud with a timer before filming.

**Cast:** DRIVER (permit holder), INSTRUCTOR (parent or driving teacher, clipboard), two FRIENDS in the back seat, DMV VOICE (off camera).

**The simulator:** four chairs set up like a car (two in front, two behind), a steering wheel (cardboard, a toy, or a video game wheel), and a sign taped to the wall: "DRIVER'S ED SIMULATOR".

---

## Part 1: The simulator (0:00 to 1:05)

| Time | On screen | Audio |
|---|---|---|
| 0:00 to 0:10 | Title text: **"Driver's Ed, Week 3"**. Wide shot of the chair car. DRIVER grips the wheel. INSTRUCTOR in the passenger chair. FRIENDS in the back. | Engine sound. INSTRUCTOR: "Mirrors. Seatbelt. Take the next left." |
| 0:10 to 0:22 | DRIVER nods, then spins the wheel hand over hand, way too far and way too fast. Both FRIENDS tip sideways and fall off their chairs. INSTRUCTOR slowly writes on the clipboard. Text: **"Turns: needs work"** | Tire screech, then a thud. FRIEND (from the floor): "Bro." |
| 0:22 to 0:35 | Everyone climbs back on. DRIVER slams the brake. Everyone lurches forward. | INSTRUCTOR: "You had the whole block to stop." DRIVER: "Then why does nobody tell me until after I mess up?" |
| 0:35 to 0:55 | DMV waiting area. DRIVER and FRIEND sit side by side holding number tickets. | FRIEND: "You ready?" DRIVER: "I've done forty hours of this and I still can't tell if I'm getting better." DMV VOICE: "Now serving B17." DRIVER checks the ticket. B17. Stands up slowly. |
| 0:55 to 1:05 | Back in the chair car. Now a phone is mounted on the dash running Driveby. DRIVER taps Start drive and starts to whip the wheel again. The FRIENDS grab their chairs. DRIVER slows the turn down. The FRIENDS stay upright and fist-bump. | PHONE: "That turn was sharp. Slow down before you start turning." |

## Part 2: The reveal (1:05 to 1:25)

Screen recording of Driveby on the phone, with quick cuts of the chair car.

| Time | On screen | Audio |
|---|---|---|
| 1:05 to 1:25 | Home screen, the live drive screen, a drive score, the Hours tab. | VO: "This is Driveby. Put your phone on the dash and it becomes your driving coach. It scores every drive, speaks up the moment you speed or follow too close, checks every stop sign, and fills in your permit hours for you. Every mistake turns into feedback while there's still time to fix it." |

## Part 3: How it works (1:25 to 2:49)

Use the slide deck. Webcam bubble in the bottom-right corner (the slides leave that space empty).

| Time | Slide | Audio |
|---|---|---|
| 1:25 to 1:46 | **Drive Score: Algorithm** | "When you drive, Driveby records GPS once a second and motion fifty times a second. We smooth the speed with a Savitzky-Golay filter, then flag hard braking, sharp turns, speeding and tailgating. Speed limits come from OpenStreetMap. Each event lowers your safety score, and your speed trace sets your efficiency score." |
| 1:46 to 2:07 | **Live Coach: Algorithm** | "The live coach runs a YOLOv8 model on the phone fifteen times a second. It finds the car ahead and estimates the distance from how wide it looks. Divide by your speed and you get your following time. Under one second for three seconds, and Driveby tells you to back off. Faces and plates are blurred on the phone." |
| 2:07 to 2:28 | **Stop Signs and Skills: Algorithm** | "For stop signs, we match your GPS trace to the road, pull that street's stop signs from OpenStreetMap, and find your slowest speed as you pass. Under 0.7 meters per second counts as a full stop. Every stop, turn and brake feeds your skill scores, and Driveby picks what to practice next." |
| 2:28 to 2:49 | **Permit Hours: Algorithm** | "Supervised drives go straight into your permit log, and night hours are worked out from the sun's position where you drove. Have a paper log? Snap a photo. Apple's Vision framework reads it and our parser adds up the hours. When you hit your goal, export a PDF for your parent to sign." |

## Part 4: Back at the DMV (2:49 to 3:00)

| Time | On screen | Audio |
|---|---|---|
| 2:49 to 3:00 | DMV again. DRIVER and FRIEND side by side, DRIVER holding a new license. End card: **"Driveby. Every drive counts."** | FRIEND: "So what changed?" DRIVER (holds up the phone): "I could finally see what I was doing wrong." |

---

## Filming notes

- **The phone line at 0:55** is Driveby's real new-driver voice line for a sharp turn. The chair car doesn't move, so dub it in editing (screen-record the app saying it, or add it as a voice-over).
- **Filming the app without driving (for Part 2):** turn on a demo in Settings, then tap Start drive. The phone plays real dashcam footage and Driveby coaches it live. Its speeding warning ("You're speeding. Slow down to 40.") plays about 1 minute 49 seconds into the demo drive.
- The fall at 0:10 is the big laugh. Film it two or three times from the side, and add the tire screech in editing.
- Keep the total at 3:00 or less.
- Turn on captions (YouTube auto captions are fine; fix "Driveby" and "YOLOv8").
- Use royalty-free music and sound effects.
- Upload to YouTube as Unlisted and paste the link into the Congressional App Challenge form.
