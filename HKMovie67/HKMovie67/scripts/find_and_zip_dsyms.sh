#!/bin/bash
# find_and_zip_dsyms.sh
# Usage: ./find_and_zip_dsyms.sh <uuid1> [uuid2 ...]
# Searches common Xcode locations for dSYM files matching given UUIDs and zips them.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <UUID> [UUID ...]"
  exit 1
fi

OUT_DIR="$HOME/Desktop/dSYMs_found_$(date +%Y%m%d%H%M%S)"
mkdir -p "$OUT_DIR"

for UUID in "$@"; do
  echo "Searching for UUID: $UUID"
  FOUND=0

  # Search Archives
  find "$HOME/Library/Developer/Xcode/Archives" -type d -name "*.xcarchive" -print0 2>/dev/null \
    | xargs -0 -I{} sh -c '
      D="{}/dSYMs"; if [ -d "$D" ]; then for f in "$D"/*.dSYM 2>/dev/null; do
        if [ -e "$f" ]; then
          dwarfdump --uuid "$f" 2>/dev/null | grep -i "$1" >/dev/null && echo "FOUND in: $f" && cp -R "$f" "$2/" && FOUND=1
        fi
      done; fi
    ' _ "$UUID" "$OUT_DIR" || true

  # Search DerivedData (may be large)
  find "$HOME/Library/Developer/Xcode/DerivedData" -type d -name "*.dSYM" -print0 2>/dev/null \
    | xargs -0 -I{} sh -c 'dwarfdump --uuid "{}" 2>/dev/null | grep -i "$1" >/dev/null && echo "FOUND in: {}" && cp -R "{}" "$2/"' _ "$UUID" "$OUT_DIR" || true

  echo "Search for $UUID complete."
done

if [ -n "$(ls -A "$OUT_DIR")" ]; then
  ZIP_PATH="$HOME/Desktop/dSYMs_$(date +%Y%m%d%H%M%S).zip"
  (cd "$OUT_DIR" && zip -r "$ZIP_PATH" .)
  echo "Zipped found dSYMs to: $ZIP_PATH"
else
  echo "No matching dSYMs found."
fi

echo "Done.\nIf you get a zip with the dSYMs, upload it to App Store Connect → App → Activity → Builds → (select build) → Diagnostics → Upload dSYM(s)."
