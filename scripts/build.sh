#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/刘老大.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
swiftc -parse-as-library -O -target arm64-apple-macosx15.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreGraphics \
  "$ROOT/Sources/TutorialCapture/Main.swift" "$ROOT/Sources/TutorialCapture/ScreenRecorder.swift" \
  "$ROOT/Sources/TutorialCapture/EagleAPI.swift" \
  "$ROOT/Sources/TutorialCapture/PreviewClipboard.swift" \
  -o "$APP/Contents/MacOS/TutorialCapture"
codesign --force --deep --sign - --identifier local.awei.TutorialCapture \
  --requirements '=designated => identifier "local.awei.TutorialCapture"' "$APP"
echo "$APP"
