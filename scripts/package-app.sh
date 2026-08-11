#!/bin/bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Outside the home folder's indexed areas on purpose: an .app bundle sitting in
# the repo gets picked up by LaunchServices, so Alfred and Spotlight offer the
# build alongside the copy installed in /Applications. ~/Library is not scanned.
# (.metadata_never_index does not prevent this — app bundles are indexed anyway.)
DEFAULT_OUTPUT_ROOT="$HOME/Library/Caches/PaperCompanion/build"
OUTPUT_ROOT="${1:-$DEFAULT_OUTPUT_ROOT}"
APP_NAME="PaperCompanion"
APP_VERSION="$(tr -d '[:space:]' < "$PACKAGE_ROOT/VERSION")"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"
EXECUTABLE="$PACKAGE_ROOT/.build/release/$APP_NAME"

cd "$PACKAGE_ROOT"
swift build -c release

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Release executable not found: $EXECUTABLE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"

if [[ -e "$APP_BUNDLE" ]]; then
  # The default output is a disposable build directory; anything else is the
  # user's own, so refuse to overwrite it.
  if [[ "$OUTPUT_ROOT" == "$DEFAULT_OUTPUT_ROOT" ]]; then
    rm -rf "$APP_BUNDLE"
  else
    echo "Refusing to replace existing app bundle: $APP_BUNDLE" >&2
    exit 1
  fi
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PACKAGE_ROOT/support/PaperCompanion.icns" "$APP_BUNDLE/Contents/Resources/PaperCompanion.icns"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

sed "s/__APP_VERSION__/$APP_VERSION/g" "$PACKAGE_ROOT/support/Info.plist.in" > "$APP_BUNDLE/Contents/Info.plist"

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
test -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "$APP_BUNDLE"
