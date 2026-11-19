#!/bin/zsh
# Builds "NextMeeting.app" and installs it to /Applications.
set -e
cd "$(dirname "$0")"
APP="build/NextMeeting.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift views.swift -o "$APP/Contents/MacOS/NextMeeting"
codesign --force --sign - "$APP"
pkill -x NextMeeting 2>/dev/null && sleep 1 || true
rm -rf "/Applications/NextMeeting.app"
cp -R "$APP" /Applications/
open "/Applications/NextMeeting.app"
echo "Installed /Applications/NextMeeting.app"
