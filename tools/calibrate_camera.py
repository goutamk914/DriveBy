"""Step 5.2 — checkerboard camera calibration (verify the focal length the app reads from AVFoundation).

1. Print a checkerboard (9×6 inner corners; https://github.com/opencv/opencv/blob/4.x/doc/pattern.png).
2. Put the phone in its mount (same zoom/lens the app uses — the 1× wide camera), take ~20 photos of the
   board from different angles and distances. AirDrop them to a folder.
3. python tools/calibrate_camera.py photos/ --cols 9 --rows 6

Prints fx/fy in pixels, rescaled to the app's 1280-pixel-wide video. Enter fx in
Settings → Camera calibration to override the automatic value. Don't guess from spec-sheet FOV.
"""
import argparse
import glob

import cv2
import numpy as np


def main():
    p = argparse.ArgumentParser()
    p.add_argument("folder")
    p.add_argument("--cols", type=int, default=9)
    p.add_argument("--rows", type=int, default=6)
    a = p.parse_args()
    objp = np.zeros((a.rows * a.cols, 3), np.float32)
    objp[:, :2] = np.mgrid[0:a.cols, 0:a.rows].T.reshape(-1, 2)
    objpoints, imgpoints, size = [], [], None
    for path in sorted(glob.glob(f"{a.folder}/*")):
        img = cv2.imread(path)
        if img is None:
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        size = gray.shape[::-1]
        ok, corners = cv2.findChessboardCorners(gray, (a.cols, a.rows), None)
        if ok:
            corners = cv2.cornerSubPix(gray, corners, (11, 11), (-1, -1),
                                       (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001))
            objpoints.append(objp); imgpoints.append(corners)
            print("✓", path)
        else:
            print("✗", path)
    if len(objpoints) < 8:
        raise SystemExit(f"only {len(objpoints)} usable photos — take more (20 is ideal)")
    rms, K, dist, _, _ = cv2.calibrateCamera(objpoints, imgpoints, size, None, None)
    fx, fy = K[0, 0], K[1, 1]
    width = max(size)
    scale = 1280.0 / width
    print(f"\nreprojection RMS: {rms:.3f} px   (under ~0.5 is good)")
    print(f"photo size {size}: fx={fx:.1f}  fy={fy:.1f}  cx={K[0,2]:.1f}  cy={K[1,2]:.1f}")
    print(f"→ at 1280-wide video: fx = {fx * scale:.1f} px   ← enter this in Settings → Camera calibration")


if __name__ == "__main__":
    main()
