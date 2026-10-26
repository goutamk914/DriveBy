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
