"""Driveby data contract + thresholds — the Python twin of Driveby/Core/Contract.swift.

Frozen in Week 1. Both pipelines read these numbers; parity tests
(tests/test_parity.py and Tests/DrivebyCoreTests/ParityTests.swift) keep them identical.

sensors.jsonl (t = seconds since recording start, MONOTONIC clock):
    {"t":12.400,"type":"gps","lat":39.045,"lon":-77.487,"spd":18.2,"acc":4.0,"hdg":271.4}
    {"t":12.420,"type":"imu","ax":0.11,"ay":-0.03,"az":9.79,"gx":0.001,"gy":0.002,"gz":-0.014,"yaw":-0.013}
Optional Driveby extensions:
    {"t":13.000,"type":"obd","rpm":1850,"kph":64,"maf":7.21,"fuel_lph":4.10}
    {"t":13.033,"type":"lead","bx":0.41,"by":0.48,"bw":0.12,"bh":0.10,"dist":21.4}

drive.json sidecar:
    {"drive_id": "...", "video_file": "drive_0007.mov", "sensor_file": "drive_0007.jsonl",
     "video_start_t": 0.83, "vehicle_id": "...", "device": "iPhone 13"}
"""

# Step 1.3 — trip segmentation
TRIP_START_SPEED = 2.0       # m/s
TRIP_START_SUSTAIN = 10.0    # s
TRIP_END_SPEED = 0.5         # m/s
TRIP_END_SUSTAIN = 180.0     # s
MIN_TRIP_DISTANCE = 500.0    # m
MIN_TRIP_DURATION = 120.0    # s

# Step 2.1 — ingest
MAX_GPS_ACCURACY = 20.0      # m
RESAMPLE_HZ = 10.0
SAVGOL_WINDOW = 21           # ≈ 2.1 s at 10 Hz
SAVGOL_ORDER = 3

# Step 2.2 — events
HARD_BRAKE_A, HARD_BRAKE_FULL = -3.0, -6.0
HARD_ACCEL_A, HARD_ACCEL_FULL = 2.5, 5.0
HARSH_CORNER_A, HARSH_CORNER_FULL = 3.0, 6.0
ACCEL_SUSTAIN = 0.5
SPEEDING_MARGIN = 4.5        # m/s over limit (~10 mph)
SPEEDING_SUSTAIN = 5.0
SPEEDING_FULL_EXCESS = 13.4  # m/s over (~30 mph)
IDLE_SPEED = 0.5
IDLE_MIN = 60.0
IDLE_FULL = 300.0
DEBOUNCE_MERGE = 2.0
DEBOUNCE_MIN_GAP = 5.0

# Step 5.2 — following distance
TAILGATE_HEADWAY = 1.0
CLOSE_HEADWAY = 2.0
TAILGATE_SUSTAIN = 3.0
TAILGATE_MIN_SPEED = 5.0
TAILGATE_FULL_HEADWAY = 0.4
VEHICLE_REAL_WIDTH = 1.8     # m

# Step 3 — efficiency
BRAKING_INTERVAL_A = -0.5
HIGH_SPEED = 29.0            # m/s ≈ 65 mph
ACCEL_WASTE_A = 1.5

# Step 2.3 — speed limit matching
WAY_MATCH_RADIUS = 25.0
WAY_HEADING_TOLERANCE = 45.0

# Step 7.1 — hazard k-anonymity
CELL = 0.0005                # ≈ 55 m at this latitude
K_EVENTS = 5
K_USERS = 3

EVENT_KINDS = ("hard_brake", "hard_accel", "harsh_corner", "speeding", "idle", "lane_drift", "tailgating")
HAZARD_KINDS = ("hard_brake", "harsh_corner")

# Units
MPS_TO_MPH = 2.236936
METRES_PER_MILE = 1609.344
LITRES_PER_GALLON = 3.785411784
GRAMS_GASOLINE_PER_GALLON = 2830.0
STOICHIOMETRIC_AFR = 14.7
JOULES_PER_GALLON = 121.32e6
ENGINE_EFFICIENCY = 0.25

DEFAULT_WEIGHTS = {"brake_waste": .35, "idle_frac": .15, "jerk_rms": .15, "high_speed": .20, "accel_waste": .15}
DEFAULT_NORMALIZATION = {
    "brake_waste": (20_000.0, 450_000.0),
    "idle_frac": (0.0, 0.30),
    "jerk_rms": (0.15, 1.2),
    "high_speed": (0.0, 0.60),
    "accel_waste": (0.0, 0.08),
}
COMPONENT_KEYS = ("brake_waste", "idle_frac", "jerk_rms", "high_speed", "accel_waste")
SAFETY_COEFFICIENTS = {"hard_brake": 12.0, "tailgating_fraction": 14.0, "harsh_corner": 6.0, "speeding_fraction": 15.0}
