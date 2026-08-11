#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
bundle_path="$project_directory/dist/Pablo.app"
info_plist="$project_directory/Resources/Pablo-Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
build=$(plutil -extract CFBundleVersion raw "$info_plist")
release_zip="$project_directory/dist/Pablo-$version-$build-mac-arm64.zip"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/pablo-notarization.XXXXXX")
submission_zip="$temporary_directory/Pablo.zip"
signing_identity=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1)

if [[ -z $signing_identity ]]; then
    echo "A Developer ID Application signing identity is required." >&2
    exit 1
fi

PABLO_SIGNING_IDENTITY="$signing_identity" \
PABLO_ARCHITECTURES="arm64" \
    "$script_directory/build-app.sh" release

codesign --verify --deep --strict --verbose=2 "$bundle_path"
ditto -c -k --keepParent "$bundle_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" \
    --keychain-profile pablo-notary \
    --wait
xcrun stapler staple "$bundle_path"
xcrun stapler validate "$bundle_path"
ditto -c -k --keepParent "$bundle_path" "$release_zip"
spctl --assess --type execute --verbose=4 "$bundle_path"

echo "$release_zip"
