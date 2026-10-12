"""Export the Core ML models the app bundles (Driveby/MLModels/). Run on macOS or Linux.

    pip install ultralytics coremltools
    python tools/export_models.py                     # yolov8n (COCO) — vehicles + people
    python tools/export_models.py --plate my_plates.pt  # optional dedicated licence-plate detector

`nms=True` produces a pipeline model Vision understands (VNRecognizedObjectObservation). Drop the
resulting .mlpackage into Driveby/MLModels/ — Xcode compiles it automatically; the app picks up
`plate_detector.mlpackage` by name and stops using the plate-zone heuristic.
Note: Ultralytics YOLO models are AGPL-3.0 — document this in the submission (it is, in AboutView).
"""
import argparse
import shutil
from pathlib import Path

from ultralytics import YOLO

DEST = Path(__file__).resolve().parents[1] / "Driveby" / "MLModels"


def export(weights: str, name: str):
    out = YOLO(weights).export(format="coreml", nms=True, imgsz=640)
    dst = DEST / f"{name}.mlpackage"
    if dst.exists():
        shutil.rmtree(dst)
    shutil.move(out, dst)
    print("wrote", dst)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--plate", help="YOLOv8 licence-plate weights (.pt) to export as plate_detector")
    a = p.parse_args()
    export("yolov8n.pt", "yolov8n")
    if a.plate:
        export(a.plate, "plate_detector")
