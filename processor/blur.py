from __future__ import annotations

import random
from pathlib import Path

import cv2
import numpy as np

PAD = 6

_models = {}


def _yolo(path):
    from ultralytics import YOLO
    if path not in _models:
        _models[path] = YOLO(path)
    return _models[path]


def _boxes(model, frame, classes=None, conf=0.25):
    res = model(frame, verbose=False, conf=conf)[0]
    out = []
    for b in res.boxes:
        if classes is not None and int(b.cls) not in classes:
            continue
        out.append(tuple(map(int, b.xyxy[0])))
    return out


class Redactor:
    def __init__(self, plate_model: str | None = "license_plate_detector.pt", face_model: str | None = "yolov8n-face.pt",
                 coco_model: str = "yolov8n.pt"):
        self.plate = _yolo(plate_model) if plate_model and Path(plate_model).exists() else None
        self.face = _yolo(face_model) if face_model and Path(face_model).exists() else None
        self.coco = _yolo(coco_model)
        self.haar = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")

    def boxes(self, frame):
        boxes = []
        if self.plate is not None:
            boxes += _boxes(self.plate, frame)
        if self.face is not None:
            boxes += _boxes(self.face, frame)
        for x1, y1, x2, y2 in _boxes(self.coco, frame, classes={2, 3, 5, 7}):
            w, h = x2 - x1, y2 - y1
            boxes.append((int(x1 + 0.15 * w), int(y1 + 0.45 * h), int(x2 - 0.15 * w), y2))
        for x1, y1, x2, y2 in _boxes(self.coco, frame, classes={0}):
            h = y2 - y1
            boxes.append((x1, y1, x2, int(y1 + 0.3 * h)))
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        for (x, y, w, h) in self.haar.detectMultiScale(gray, 1.1, 4, minSize=(16, 16)):
            boxes.append((x, y, x + w, y + h))
        return boxes

    def redact(self, frame):
        for x1, y1, x2, y2 in self.boxes(frame):
            x1, y1 = max(0, x1 - PAD), max(0, y1 - PAD)
            x2, y2 = min(frame.shape[1], x2 + PAD), min(frame.shape[0], y2 + PAD)
            roi = frame[y1:y2, x1:x2]
            if roi.size:
                k = max(15, ((x2 - x1) // 3) | 1)
                small = cv2.resize(roi, (max(1, (x2 - x1) // 8), max(1, (y2 - y1) // 8)), interpolation=cv2.INTER_LINEAR)
                pix = cv2.resize(small, (x2 - x1, y2 - y1), interpolation=cv2.INTER_NEAREST)
                frame[y1:y2, x1:x2] = cv2.GaussianBlur(pix, (k, k), 0)
        return frame


_default: Redactor | None = None


def redact(frame):
    global _default
    if _default is None:
        _default = Redactor()
    return _default.redact(frame)


def write_redacted_video(src: str | Path, dst: str | Path, redactor: Redactor | None = None, fps: float | None = None):
    r = redactor or Redactor()
    cap = cv2.VideoCapture(str(src))
    if not cap.isOpened():
        raise IOError(f"cannot open {src}")
    fps = fps or cap.get(cv2.CAP_PROP_FPS) or 30.0
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    writer = cv2.VideoWriter(str(dst), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    n = 0
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            writer.write(r.redact(frame))
            n += 1
    finally:
        cap.release()
        writer.release()
    return n


def write_redacted_frames(frames, dst: str | Path, fps: float = 15.0, redactor: Redactor | None = None):
    r = redactor or Redactor()
    h, w = frames[0].shape[:2]
    writer = cv2.VideoWriter(str(dst), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    try:
        for f in frames:
            writer.write(r.redact(f))
    finally:
        writer.release()
    return len(frames)


def spot_check(video: str | Path, out_png: str | Path, n: int = 20, seed: int | None = None):
    cap = cv2.VideoCapture(str(video))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    rng = random.Random(seed)
    idx = sorted(rng.sample(range(total), min(n, total))) if total else []
    tiles = []
    for i in idx:
        cap.set(cv2.CAP_PROP_POS_FRAMES, i)
        ok, f = cap.read()
        if ok:
            f = cv2.resize(f, (480, 270))
            cv2.putText(f, f"frame {i}", (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
            tiles.append(f)
    cap.release()
    if not tiles:
        return None
    while len(tiles) % 4:
        tiles.append(np.zeros_like(tiles[0]))
    rows = [np.hstack(tiles[i:i + 4]) for i in range(0, len(tiles), 4)]
    sheet = np.vstack(rows)
    cv2.imwrite(str(out_png), sheet)
    return idx


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description="Blur plates + faces in a video, or spot-check a blurred one.")
    p.add_argument("src")
    p.add_argument("--out", help="redacted output video (.mp4)")
    p.add_argument("--spot-check", help="write a 20-frame contact sheet PNG instead")
    p.add_argument("--plate-model", default="license_plate_detector.pt")
    p.add_argument("--face-model", default="yolov8n-face.pt")
    a = p.parse_args()
    if a.spot_check:
        print(spot_check(a.src, a.spot_check))
    else:
        print(write_redacted_video(a.src, a.out, Redactor(a.plate_model, a.face_model)), "frames written")
