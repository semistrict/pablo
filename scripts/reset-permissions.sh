#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
info_plist="$project_directory/Resources/Pablo-Info.plist"
installed_app="/Applications/Pablo.app"
bundle_identifier=$(plutil -extract CFBundleIdentifier raw "$info_plist")
executable_name=$(plutil -extract CFBundleExecutable raw "$info_plist")
installed_executable="$installed_app/Contents/MacOS/$executable_name"

if [[ ! -d $installed_app ]]; then
    echo "Pablo is not installed at $installed_app." >&2
    exit 1
fi

installed_bundle_identifier=$(plutil -extract CFBundleIdentifier raw "$installed_app/Contents/Info.plist")
if [[ $installed_bundle_identifier != $bundle_identifier ]]; then
    echo "$installed_app has unexpected bundle identifier $installed_bundle_identifier." >&2
    exit 1
fi

for pid in $(pgrep -fx "$installed_executable" || true); do
    kill "$pid"
done

tccutil reset All "$bundle_identifier"
open "$installed_app"

echo "Reset every macOS privacy permission for $bundle_identifier."
echo "Grant Accessibility, Input Monitoring, and Screen & System Audio Recording again when prompted."
