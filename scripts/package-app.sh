#!/bin/bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PaperCompanion"
APP_VERSION="$(tr -d '[:space:]' < "$PACKAGE_ROOT/VERSION")"

# Outside the home folder's indexed areas on purpose: an .app bundle sitting in
# the repo gets picked up by LaunchServices, so Alfred and Spotlight offer the
# build alongside the copy installed in /Applications. ~/Library is not scanned.
# (.metadata_never_index does not prevent this — app bundles are indexed anyway.)
DEFAULT_OUTPUT_ROOT="$HOME/Library/Caches/PaperCompanion/build"
INSTALL_ROOT="/Applications"

INSTALL=0
FORCE=0
OUTPUT_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage: package-app.sh [--install] [--force] [OUTPUT_ROOT]

  --install    Copy the packaged bundle to /Applications when it is built.
  --force      Let --install replace a bundle that is not Paper Companion.
  OUTPUT_ROOT  Where to build the .app (default: a disposable cache directory).

Environment:
  UNIVERSAL=1  Build arm64 + x86_64. Needed only for a bundle you hand to
               someone else; roughly twice as slow, and pointless for a local
               install, which runs on this machine's architecture anyway.

An app you build here is never quarantined, so it opens without the Gatekeeper
warning that a downloaded, un-notarized bundle would trigger.
USAGE
      exit 0 ;;
    -*) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)  OUTPUT_ROOT="$1" ;;
  esac
  shift
done
OUTPUT_ROOT="${OUTPUT_ROOT:-$DEFAULT_OUTPUT_ROOT}"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"

cd "$PACKAGE_ROOT"

# A plain release build is native-only, so a bundle built on Apple Silicon will
# not launch on an Intel Mac. Set UNIVERSAL=1 for anything you hand to someone
# else; local iteration stays single-arch because the universal build is roughly
# twice as slow. Note the differing output paths: --arch moves the product into
# .build/apple/Products/Release.
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  EXECUTABLE="$PACKAGE_ROOT/.build/apple/Products/Release/$APP_NAME"
else
  swift build -c release
  EXECUTABLE="$PACKAGE_ROOT/.build/release/$APP_NAME"
fi

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
lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ "$INSTALL" != "1" ]]; then
  echo "$APP_BUNDLE"
  exit 0
fi

INSTALLED="$INSTALL_ROOT/$APP_NAME.app"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist")"

# Replacing a running app leaves the old code mapped and fails in confusing
# ways later, so refuse rather than half-install.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quit $APP_NAME and run again: it is running, and replacing it now would corrupt the install." >&2
  exit 1
fi

if [[ ! -w "$INSTALL_ROOT" ]]; then
  echo "$INSTALL_ROOT is not writable by $(whoami). Install elsewhere: package-app.sh \"$HOME/Applications\"" >&2
  exit 1
fi

if [[ -e "$INSTALLED" ]]; then
  # Reinstalling over a previous version is the normal case, so replace our own
  # bundle without ceremony. Anything else sharing the name is someone else's
  # app and is not ours to delete.
  EXISTING_ID="$(plutil -extract CFBundleIdentifier raw "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" && "$FORCE" != "1" ]]; then
    echo "Refusing to replace $INSTALLED: its bundle id is '${EXISTING_ID:-unreadable}', not $BUNDLE_ID. Pass --force to override." >&2
    exit 1
  fi
  rm -rf "$INSTALLED"
fi

cp -R "$APP_BUNDLE" "$INSTALLED"
echo "Installed $APP_NAME $APP_VERSION to $INSTALLED"
