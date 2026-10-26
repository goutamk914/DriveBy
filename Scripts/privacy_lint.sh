#!/bin/sh
set -eu
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
status=0

swift_hits=$(grep -rnE 'AVAssetWriter\(|AVAssetWriterInput\(|AVCaptureMovieFileOutput|AVAssetWriterInputPixelBufferAdaptor\(' \
  "$ROOT/Driveby" --include='*.swift' | grep -v 'Driveby/Capture/RedactingVideoWriter.swift' || true)
if [ -n "$swift_hits" ]; then
  echo "error: Privacy lint — video written outside RedactingVideoWriter.swift:"
  echo "$swift_hits"
  status=1
fi

if [ -d "$ROOT/processor" ]; then
  py_hits=$(grep -rnE 'VideoWriter\(' "$ROOT/processor" --include='*.py' | grep -v 'processor/blur.py' || true)
  if [ -n "$py_hits" ]; then
    echo "error: Privacy lint — cv2.VideoWriter outside processor/blur.py:"
    echo "$py_hits"
    status=1
  fi
fi

if ! grep -q 'redactor.process(' "$ROOT/Driveby/Capture/RedactingVideoWriter.swift"; then
  echo "error: Privacy lint — RedactingVideoWriter no longer calls redactor.process()"
  status=1
fi

[ $status -eq 0 ] && echo "Privacy lint: OK — every video write goes through redaction."
exit $status
