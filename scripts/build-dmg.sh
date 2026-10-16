#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/QuotaPeek.app}"
OUTPUT="${2:-$ROOT/dist/QuotaPeek.dmg}"
if [[ $# -gt 2 || ! -d "$APP" || "$(uname -s)" != Darwin ]]; then
    printf 'Usage: bash scripts/build-dmg.sh [QuotaPeek.app] [output.dmg]\nRequires macOS and an already built app.\n' >&2
    exit 2
fi
APP="$(cd -- "$(dirname -- "$APP")" && pwd)/$(basename -- "$APP")"
mkdir -p "$(dirname -- "$OUTPUT")"
OUTPUT="$(cd -- "$(dirname -- "$OUTPUT")" && pwd)/$(basename -- "$OUTPUT")"
/usr/bin/codesign --verify --deep --strict "$APP"

# Build-only helper: Finder can be configured not to write .DS_Store on mounted images.
# Write it directly instead of changing the user's global Finder preferences.
TOOLS="$ROOT/.build/dmg-tools"
if [[ ! -x "$TOOLS/bin/python" ]]; then
    python3 -m venv "$TOOLS"
fi
if ! "$TOOLS/bin/python" -c 'from importlib.metadata import version; assert version("ds-store") == "1.3.1"' 2>/dev/null; then
    "$TOOLS/bin/python" -m pip install --disable-pip-version-check --quiet ds-store==1.3.1
fi

WORK="$(mktemp -d "$(dirname -- "$OUTPUT")/.QuotaPeek-dmg.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/content"
/usr/bin/ditto "$APP" "$WORK/content/QuotaPeek.app"
ln -s /Applications "$WORK/content/Applications"
"$TOOLS/bin/python" "$ROOT/scripts/dmg-layout.py" "$WORK/content"
read -r SIZE_MB _ <<< "$(/usr/bin/du -sm "$WORK/content")"
/usr/bin/hdiutil create -quiet -volname QuotaPeek -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -size "$((SIZE_MB + 32))m" -srcfolder "$WORK/content" "$WORK/QuotaPeek.dmg"
/usr/bin/hdiutil verify -quiet "$WORK/QuotaPeek.dmg"
mv -f -- "$WORK/QuotaPeek.dmg" "$OUTPUT"
printf 'Created disk image: %s\n' "$OUTPUT"
