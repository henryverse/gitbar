#!/bin/bash
# Builds dist/GitBar.app (menu bar app with the gitbar CLI inside it).
#   ./build.sh            build only
#   ./build.sh --install  also copy to ~/Applications and link `gitbar` into ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=dist/GitBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN/GitBarApp" "$APP/Contents/MacOS/GitBar"
cp "$BIN/gitbar" "$APP/Contents/Helpers/gitbar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.gitbar.app</string>
  <key>CFBundleName</key><string>GitBar</string>
  <key>CFBundleDisplayName</key><string>GitBar</string>
  <key>CFBundleExecutable</key><string>GitBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Helpers/gitbar"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  osascript -e 'tell application id "com.gitbar.app" to quit' >/dev/null 2>&1 || true
  rm -rf "$HOME/Applications/GitBar.app"
  cp -R "$APP" "$HOME/Applications/GitBar.app"
  ln -sf "$HOME/Applications/GitBar.app/Contents/Helpers/gitbar" "$HOME/.local/bin/gitbar"
  open "$HOME/Applications/GitBar.app"
  echo "Installed ~/Applications/GitBar.app and ~/.local/bin/gitbar"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: add ~/.local/bin to your PATH to use \`gitbar\` directly.";; esac
fi
