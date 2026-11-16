#!/bin/bash
# Publie une version : ./release.sh 0.2.0
# Compile, archive l'app, signe l'archive (clé Sparkle du trousseau), génère appcast.xml
# et crée la GitHub Release. Les apps installées la détectent ensuite toutes seules.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage : ./release.sh <version>}"
DEPOT="blckdvc/Rafale"
OUTILS=".build/artifacts/sparkle/Sparkle/bin"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(($(git rev-list --count HEAD) + 1))" Resources/Info.plist
./build.sh

rm -rf dist && mkdir dist
ditto -c -k --sequesterRsrc --keepParent build/Rafale.app "dist/Rafale-$VERSION.zip"
"$OUTILS/generate_appcast" dist \
    --download-url-prefix "https://github.com/$DEPOT/releases/download/v$VERSION/"

git diff --quiet || git commit -am "Release $VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" "dist/Rafale-$VERSION.zip" dist/appcast.xml \
    --repo "$DEPOT" --title "Rafale $VERSION" --generate-notes
