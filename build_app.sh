#!/bin/zsh
# Builds Glitch AI.app into ./build
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Glitch AI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Icon/figure.png "$APP/Contents/Resources/figure.png"
cp .build/release/GlitchAI "$APP/Contents/MacOS/GlitchAI"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glitch AI</string>
  <key>CFBundleIdentifier</key><string>com.glitch.ai</string>
  <key>CFBundleExecutable</key><string>GlitchAI</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Glitch listens when you hold the talk key.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Glitch turns what you say into text.</string>
  <key>NSAppleEventsUsageDescription</key><string>Glitch controls apps on your behalf.</string>
</dict>
</plist>
EOF
# Sign with the personal "Glitch Dev" certificate so macOS sees the same app after every rebuild
# and keeps its permissions (mic, screen, Keychain). Falls back to ad-hoc if it's missing.
if security find-identity -p codesigning | grep -q '"Glitch Dev"'; then
  codesign --force --sign "Glitch Dev" "$APP"
else
  echo "Glitch Dev certificate not found; signing ad-hoc (permissions will reset)."
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
# Keep the copy in /Applications (what Spotlight and Launchpad open) up to date.
if [ -d "/Applications/Glitch AI.app" ]; then
  rm -rf "/Applications/Glitch AI.app"
  ditto "$APP" "/Applications/Glitch AI.app"
  echo "Updated /Applications/Glitch AI.app"
fi
