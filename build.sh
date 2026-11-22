#!/bin/zsh
# Builds Dimmer.app and installs it to ~/Applications
# Note: each rebuild is a "new app" to macOS, so switch Dimmer off/on again in
# System Settings → Privacy & Security → Accessibility afterwards.
set -e
cd "$(dirname "$0")"
APP=Dimmer.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O main.swift -o $APP/Contents/MacOS/Dimmer

# App icon
rm -rf build && mkdir build
swift makeicon.swift build/Dimmer.iconset
iconutil -c icns build/Dimmer.iconset -o $APP/Contents/Resources/Dimmer.icns

cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Dimmer</string>
<key>CFBundleIdentifier</key><string>local.dimmer</string>
<key>CFBundleExecutable</key><string>Dimmer</string>
<key>CFBundleIconFile</key><string>Dimmer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>local.dimmer</string>
  <key>CFBundleURLSchemes</key><array><string>dimmer</string></array>
</dict></array>
</dict></plist>
PL
codesign --force -s - $APP
mkdir -p ~/Applications && rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/$APP
echo "Installed to ~/Applications/$APP"
