#!/bin/sh
# ABOUTME: Cuts a GitHub release of the plugin bundle: tags the current commit
# ABOUTME: with the manifest version and attaches an installable zip.
set -e
cd "$(dirname "$0")"

BUNDLE=build.erik.calibration
VERSION=$(python3 -c "import json; print(json.load(open('$BUNDLE/manifest.json'))['version'])")
TAG="v$VERSION"
ZIP="$BUNDLE-$TAG.zip"

[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
git fetch --tags --quiet
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "tag $TAG already exists"
    exit 1
fi

rm -f "$ZIP"
zip -qr "$ZIP" "$BUNDLE" -x '*.DS_Store'
git tag "$TAG"
git push --quiet origin main "$TAG"
gh release create "$TAG" "$ZIP" --title "$TAG" \
    --notes "Install: unzip and copy \`$BUNDLE\` into PrusaSlicer's user plugin folder (see the README for per-OS paths), then **Menu > Plugins > Rescan Plugins**. Requires PrusaSlicer 3.0.0-alpha11 or newer."
rm -f "$ZIP"
echo "released $TAG"
