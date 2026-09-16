#!/bin/sh
# Build a versioned Homebrew-compatible archive.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=${1:-${VERSION:-$(sed -n '1p' VERSION)}}
BUILD_NUMBER=${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
REQUIRE_NOTARIZATION=${REQUIRE_NOTARIZATION:-0}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
STAGE_DIR="$DIST_DIR/stage"
APP_PATH="$STAGE_DIR/SibDocks.app"
ZIP_PATH="$DIST_DIR/SibDocks-$VERSION.zip"

case "$VERSION" in
  ''|*[!0-9.]*) echo "version must contain only digits and dots: $VERSION" >&2; exit 2 ;;
esac

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
rm -rf "$STAGE_DIR"

if [ "$REQUIRE_NOTARIZATION" = "1" ] && {
  [ "$SIGNING_IDENTITY" = "-" ] || [ -z "$NOTARY_PROFILE" ];
}; then
  echo "a public release requires SIGNING_IDENTITY and NOTARY_PROFILE" >&2
  exit 2
fi

VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
APP_PATH="$APP_PATH" \
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
RESET_TCC=0 \
  ./build.sh

if [ -n "$NOTARY_PROFILE" ]; then
  # notarytool accepts a zip, and stapling the ticket into the app must happen
  # before the final archive and checksum are produced.
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
codesign --verify --deep --strict "$APP_PATH"

if [ "$SIGNING_IDENTITY" != "-" ]; then
  spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
printf '%s\n' "$SHA256" > "$ZIP_PATH.sha256"
printf 'archive: %s\nsha256: %s\n' "$ZIP_PATH" "$SHA256"
