#!/bin/bash
# Compile Rafale et assemble build/Rafale.app (Sparkle et traductions inclus).
# Signature : IDENTITE="Nom du certificat" ./build.sh, sinon le nom écrit dans le fichier
# local .identite, sinon signature ad hoc (les autorisations système seront alors à
# réaccorder après chaque recompilation).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Rafale.app"
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$(swift build -c release --show-bin-path)/Rafale" "$APP/Contents/MacOS/Rafale"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/*.png "$APP/Contents/Resources/"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

[ -z "${IDENTITE:-}" ] && [ -f .identite ] && IDENTITE="$(head -1 .identite)"
IDENTITE="${IDENTITE:--}"
# Sparkle se signe de l'intérieur vers l'extérieur, puis l'app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for piece in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc \
             Versions/B/Autoupdate Versions/B/Updater.app; do
    codesign --force --sign "$IDENTITE" "$FW/$piece"
done
codesign --force --sign "$IDENTITE" "$FW"
codesign --force --sign "$IDENTITE" "$APP"

echo "OK : $APP"
