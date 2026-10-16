#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UNIVERSAL=false
case "${1:-}" in
    "") ;;
    --universal) UNIVERSAL=true; shift ;;
    -h|--help)
        printf 'Usage: bash scripts/build-app.sh [--universal]\n'
        printf 'Optional: IDENTITY="Developer ID Application: ..." to sign for distribution.\n'
        printf 'Without IDENTITY, uses local ad-hoc signing. Notarization is not performed.\n'
        exit 0
        ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
if [[ $# -ne 0 ]]; then
    printf 'Unexpected arguments. Use --help for usage.\n' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Packaging requires macOS and the Xcode Command Line Tools.\n' >&2
    exit 1
fi

export MACOSX_DEPLOYMENT_TARGET=14.0
BUILD_ARGS=(--package-path "$ROOT" --configuration release --product QuotaPeek)
if [[ "$UNIVERSAL" == true ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
/usr/bin/xcrun swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(/usr/bin/xcrun swift build "${BUILD_ARGS[@]}" --show-bin-path)"
if [[ ! -x "$BIN_DIR/QuotaPeek" ]]; then
    printf 'Release executable not found: %s/QuotaPeek\n' "$BIN_DIR" >&2
    exit 1
fi

mkdir -p "$ROOT/dist"
# Stage inside dist so publishing the finished bundle is a same-volume move.
STAGING="$(mktemp -d "$ROOT/dist/.QuotaPeek-package.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
APP="$STAGING/QuotaPeek.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/QuotaPeek" "$APP/Contents/MacOS/QuotaPeek"
chmod 755 "$APP/Contents/MacOS/QuotaPeek"
/usr/bin/xcrun swift "$ROOT/scripts/generate-icon.swift" "$STAGING/AppIcon.iconset"
/usr/bin/iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$STAGING/AppIcon.iconset"

if [[ -n "${IDENTITY:-}" && "$IDENTITY" != - ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    /usr/bin/codesign --force --sign - "$APP"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/QuotaPeek.zip"
bash "$ROOT/scripts/build-dmg.sh" "$APP" "$STAGING/QuotaPeek.dmg"

# Only replace this script's named artifacts; leave all other dist files alone.
rm -rf -- "$ROOT/dist/QuotaPeek.app"
mv -- "$APP" "$ROOT/dist/QuotaPeek.app"
mv -f -- "$STAGING/QuotaPeek.zip" "$ROOT/dist/QuotaPeek.zip"
mv -f -- "$STAGING/QuotaPeek.dmg" "$ROOT/dist/QuotaPeek.dmg"
printf '\nCreated:\n  %s\n  %s\n  %s\n' "$ROOT/dist/QuotaPeek.app" "$ROOT/dist/QuotaPeek.dmg" "$ROOT/dist/QuotaPeek.zip"
printf 'Open QuotaPeek.dmg and drag QuotaPeek into Applications. Requires macOS 14 or later.\n'
if [[ -z "${IDENTITY:-}" || "$IDENTITY" == - ]]; then
    printf 'Ad-hoc signed only: Gatekeeper may block downloads on another Mac.\n'
fi
printf 'This script does not notarize. Public distribution requires Developer ID signing and Apple notarization.\n'
