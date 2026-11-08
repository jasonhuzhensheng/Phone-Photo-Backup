#!/bin/zsh
# Publishes a GitHub release that the app's updater picks up.
# Usage: scripts/release.sh [notes-file]
#   1. Bump CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist and commit.
#   2. Push the commit, then run this script. It builds the app, zips it as
#      Phone-Photo-Backup-<version>.zip and creates the release v<version> on GitHub with the
#      zip and its SHA-256 (also written into the notes as a fallback for the updater).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
ZIP="build/Phone-Photo-Backup-$VERSION.zip"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✘ Commit your changes first." >&2; exit 1
fi
if ! git branch -r --contains HEAD | grep -q .; then
  echo "✘ Push the current commit first." >&2; exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "✘ Release $TAG already exists. Bump the version in Resources/Info.plist." >&2; exit 1
fi

scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent "build/Phone Photo Backup.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
if [[ -n "${1:-}" ]]; then cat "$1" > "$NOTES"; else echo "Phone Photo Backup $VERSION" > "$NOTES"; fi
printf '\n\nSHA-256: %s\n' "$SHA" >> "$NOTES"

gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" \
  --title "Phone Photo Backup $VERSION" --notes-file "$NOTES"
echo "✔ Published $TAG ($SHA)"
