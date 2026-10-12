#!/bin/sh
# privacy_lint.sh — Build Guide 4.1: "Enforce it structurally: any function that writes a clip to disk
# calls redact() on every frame first, with no bypass parameter. Then grep your codebase for VideoWriter
# and confirm every call site goes through it."
#
# Runs as an Xcode build phase ("Privacy Lint") and in CI. FAILS THE BUILD if any file other than the
# redacting writers creates a video writer, so the privacy guarantee can't be skipped under deadline pressure.
set -eu
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
status=0

# iOS: only RedactingVideoWriter.swift may construct an AVAssetWriter; nothing may use a movie-file output
# (which would write raw camera frames straight to disk).
swift_hits=$(grep -rnE 'AVAssetWriter\(|AVAssetWriterInput\(|AVCaptureMovieFileOutput|AVAssetWriterInputPixelBufferAdaptor\(' \
  "$ROOT/Driveby" --include='*.swift' | grep -v 'Driveby/Capture/RedactingVideoWriter.swift' || true)
if [ -n "$swift_hits" ]; then
  echo "error: Privacy lint — video written outside RedactingVideoWriter.swift:"
  echo "$swift_hits"
  status=1
fi

# Python processor: only blur.py may construct a cv2.VideoWriter.
if [ -d "$ROOT/processor" ]; then
  py_hits=$(grep -rnE 'VideoWriter\(' "$ROOT/processor" --include='*.py' | grep -v 'processor/blur.py' || true)
  if [ -n "$py_hits" ]; then
    echo "error: Privacy lint — cv2.VideoWriter outside processor/blur.py:"
    echo "$py_hits"
    status=1
  fi
fi

# The redacting writer must actually redact: the call into the Redactor must be present.
if ! grep -q 'redactor.process(' "$ROOT/Driveby/Capture/RedactingVideoWriter.swift"; then
  echo "error: Privacy lint — RedactingVideoWriter no longer calls redactor.process()"
  status=1
fi

[ $status -eq 0 ] && echo "Privacy lint: OK — every video write goes through redaction."
exit $status
