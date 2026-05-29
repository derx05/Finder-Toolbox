#!/usr/bin/env bash
#
# package-release.sh — turn an exported "Finder Toolbox.app" into a release zip.
#
# Workflow:
#   1. Export a Developer ID–signed, notarized "Finder Toolbox.app" from Xcode.
#   2. Drop it into builds_new/ at the repo root.
#   3. Run: ./tools/package-release.sh
#
# The script:
#   - Reads CFBundleShortVersionString and CFBundleVersion from Info.plist.
#   - Sanitises them into a release slug: FinderToolbox-{version}-{build}.zip
#   - Zips with ditto (the bundle inside stays exactly "Finder Toolbox.app").
#   - Writes the zip to   builds/<slug>.zip
#   - Runs Sparkle's sign_update on it.
#   - Copies the (identical) zip to builds_signed/<slug>.zip
#   - Writes the signature line to builds_signed/<slug>.zip.sig
#   - Prints the <enclosure> snippet ready to paste into appcast.xml.
#
# The .app filename is intentionally never version-stamped: manual installers
# need a stable "Finder Toolbox.app" so drag-to-/Applications doesn't pile up
# duplicates and Sparkle's in-place replace stays sane.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INBOX="$REPO_ROOT/builds_new"
BUILDS="$REPO_ROOT/builds"
SIGNED="$REPO_ROOT/builds_signed"
APP_NAME="Finder Toolbox.app"

mkdir -p "$INBOX" "$BUILDS" "$SIGNED"

SRC_APP="$INBOX/$APP_NAME"
if [[ ! -d "$SRC_APP" ]]; then
    echo "error: expected $SRC_APP" >&2
    echo "drop the exported '$APP_NAME' into builds_new/ and re-run." >&2
    exit 1
fi

PLIST="$SRC_APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")

# Slug: lowercase, spaces → dashes. Keeps existing dots (e.g. 2026.05.29.01).
slug_version=$(printf '%s' "$VERSION" | tr '[:upper:] ' '[:lower:]-')
slug_build=$(printf '%s' "$BUILD"   | tr '[:upper:] ' '[:lower:]-')
SLUG="FinderToolbox-${slug_version}-${slug_build}"
ZIP_NAME="${SLUG}.zip"

BUILDS_ZIP="$BUILDS/$ZIP_NAME"
SIGNED_ZIP="$SIGNED/$ZIP_NAME"
SIG_FILE="$SIGNED/${ZIP_NAME}.sig"

if [[ -e "$BUILDS_ZIP" || -e "$SIGNED_ZIP" ]]; then
    echo "error: $ZIP_NAME already exists in builds/ or builds_signed/." >&2
    echo "bump the build number, or remove the old artifact first." >&2
    exit 1
fi

# Locate sign_update inside DerivedData (Sparkle ships it via SPM artifact bundle).
# Prefer the newest by mtime so a stale DerivedData doesn't win.
SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
    -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | head -1 || true)

if [[ -z "${SIGN_UPDATE:-}" || ! -x "$SIGN_UPDATE" ]]; then
    echo "error: sign_update not found under DerivedData." >&2
    echo "open the Xcode project once so SPM resolves Sparkle, then retry." >&2
    exit 1
fi

echo "→ packaging $VERSION ($BUILD)"
echo "  slug:   $SLUG"
echo "  source: $SRC_APP"

# Zip into builds/. ditto with --keepParent preserves the .app directory
# at the top of the archive; the bundle name stays "Finder Toolbox.app".
ditto -c -k --sequesterRsrc --keepParent "$SRC_APP" "$BUILDS_ZIP"
echo "  wrote:  $BUILDS_ZIP"

# Identical bytes go to builds_signed/ — "signed" here means we have a
# recorded Sparkle EdDSA signature for this exact file.
cp "$BUILDS_ZIP" "$SIGNED_ZIP"

SIG_LINE=$("$SIGN_UPDATE" "$SIGNED_ZIP")
printf '%s\n' "$SIG_LINE" > "$SIG_FILE"

echo "  wrote:  $SIGNED_ZIP"
echo "  wrote:  $SIG_FILE"
echo
echo "appcast enclosure:"
# sign_update prints both sparkle:edSignature="…" and length="…" on one line.
cat <<EOF
    <enclosure
        url="https://github.com/derx05/Finder-Toolbox/releases/download/v${slug_version}/${ZIP_NAME}"
        ${SIG_LINE}
        type="application/octet-stream" />
EOF

echo
echo "next steps:"
echo "  - upload $SIGNED_ZIP to the GitHub Release for v${slug_version}"
echo "  - paste the enclosure block into appcast.xml"
echo "  - rm \"$SRC_APP\"   # once you've confirmed the zip looks right"
