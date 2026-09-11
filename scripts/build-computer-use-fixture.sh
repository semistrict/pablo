#!/bin/zsh
set -euo pipefail

project_directory=${0:A:h:h}
fixture_directory=$(mktemp -d /tmp/pablo-computer-use-fixture.XXXXXX)
fixture_bundle="$fixture_directory/Pablo Computer Use Fixture.app"
mkdir -p "$fixture_bundle/Contents/MacOS"
trap 'rm -rf "$fixture_directory"' ERR
swiftc "$project_directory/Tests/Fixtures/ComputerUseFixture/main.swift" \
    -framework AppKit -o "$fixture_bundle/Contents/MacOS/PabloComputerUseFixture"
cat > "$fixture_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.semistrict.pablo.fixture.control</string>
<key>CFBundleName</key><string>Pablo Computer Use Fixture</string>
<key>CFBundleExecutable</key><string>PabloComputerUseFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
echo "$fixture_bundle"
