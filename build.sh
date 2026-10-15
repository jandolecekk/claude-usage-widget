#!/bin/zsh
# Builds ClaudeUsage.app (bundle needed for macOS notifications), ad-hoc signed.
set -e
cd "${0:A:h}"
APP=ClaudeUsage.app
swiftc -O -parse-as-library ClaudeUsageWidget.swift -o ClaudeUsageWidget
mkdir -p $APP/Contents/MacOS
cp ClaudeUsageWidget $APP/Contents/MacOS/ClaudeUsage
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jandolecek.claude-usage</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "built $APP"
