from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np
import pandas as pd

from . import contract as C

_vehicle_model = None


def vehicle_model():
    global _vehicle_model
    if _vehicle_model is None:
        from ultralytics import YOLO
        _vehicle_model = YOLO("yolov8n.pt")
    return _vehicle_model


def lead_vehicle_box(frame, lane_frac: float = 0.15):
    dets = vehicle_model()(frame, verbose=False)[0].boxes
    best = None
    for b in dets:
        if int(b.cls) not in (2, 5, 7):
            continue
        x1, y1, x2, y2 = b.xyxy[0].tolist()
        cx = (x1 + x2) / 2
        if abs(cx - frame.shape[1] / 2) > lane_frac * frame.shape[1]:
            continue
        if best is None or (x2 - x1) > (best[2] - best[0]):
            best = (x1, y1, x2, y2)
    return best


def lead_vehicle_distance(frame, focal_px, real_width_m=C.VEHICLE_REAL_WIDTH):
    box = lead_vehicle_box(frame)
    if box is None:
        return None
    w = box[2] - box[0]
    return (real_width_m * focal_px) / w if w > 0 else None


def time_headway(distance_m, speed_mps):
    return distance_m / speed_mps if speed_mps and speed_mps > 0.5 else None


def lead_samples_from_video(video_index, focal_px, every_s=0.2) -> pd.DataFrame:
    rows = []
    for t, frame in video_index.iter_frames(every_s):
        box = lead_vehicle_box(frame)
        if box is None:
            continue
        h, w = frame.shape[:2]
        bw = box[2] - box[0]
        rows.append({"t": t, "bx": box[0] / w, "by": box[1] / h, "bw": bw / w, "bh": (box[3] - box[1]) / h,
                     "dist": C.VEHICLE_REAL_WIDTH * focal_px / bw})
    return pd.DataFrame(rows, columns=["t", "bx", "by", "bw", "bh", "dist"])


def annotate_clip(video_index, df: pd.DataFrame, t0: float, t1: float, out_path: str | Path, focal_px: float):
    from .blur import write_redacted_frames
    frames = []
    for t in np.arange(t0, t1, 1 / 15):
        f = video_index.frame_at(float(t))
        if f is None:
            continue
        box = lead_vehicle_box(f)
        i = int(np.clip(round((t - df.t.iloc[0]) / df.attrs.get("dt", 0.1)), 0, len(df) - 1))
        v = float(df.v.iloc[i])
        if box is not None:
            x1, y1, x2, y2 = map(int, box)
            d = C.VEHICLE_REAL_WIDTH * focal_px / max(x2 - x1, 1)
            h = time_headway(d, v)
            color = (0, 0, 255) if h is not None and h < 1 else (0, 200, 255) if h is not None and h < 2 else (0, 200, 0)
            cv2.rectangle(f, (x1, y1), (x2, y2), color, 3)
            label = f"{h:.1f} s behind" if h is not None else f"{d:.0f} m"
            cv2.putText(f, label, (x1, max(30, y1 - 10)), cv2.FONT_HERSHEY_SIMPLEX, 1.0, color, 3)
        cv2.putText(f, f"{v * C.MPS_TO_MPH:.0f} mph", (20, 50), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (255, 255, 255), 3)
        frames.append(f)
    if not frames:
        return 0
    write_redacted_frames(frames, out_path, fps=15)
    return len(frames)
