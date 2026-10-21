#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
APP="$ROOT/build/刘老大.app"
DIST="$ROOT/dist"
PACKAGE="Liulaoda-$VERSION-arm64"

"$ROOT/scripts/build.sh"
mkdir -p "$DIST"
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}liulaoda-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto --norsrc --noextattr "$APP" "$STAGING/刘老大.app"
codesign --verify --deep --strict "$STAGING/刘老大.app"
python3 - "$STAGING/刘老大.app" "$DIST/$PACKAGE.zip" <<'PY'
from pathlib import Path
import sys
import zipfile

app, output = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in [app, *sorted(app.rglob("*"))]:
        archive.write(path, Path(app.name) / path.relative_to(app))
PY
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "刘老大 $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DIST/$PACKAGE.dmg"
(
    cd "$DIST"
    shasum -a 256 "$PACKAGE.dmg" "$PACKAGE.zip" > SHA256SUMS.txt
)
echo "$DIST"
