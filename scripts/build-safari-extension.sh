#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
destination=${1:?Pass the destination .appex path}
configuration=${2:-release}
case ${configuration:l} in
    debug) xcode_configuration=Debug ;;
    release) xcode_configuration=Release ;;
    *) echo "Unsupported Safari extension configuration: $configuration" >&2; exit 1 ;;
esac
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/pablo-safari-extension.XXXXXX")
project_root="$temporary_directory/PabloSafariHost"
project_path="$project_root/PabloSafariHost.xcodeproj"
extension_source="$project_root/PabloSafariHost Extension"
build_root="$temporary_directory/build"
extension_architectures=${PABLO_ARCHITECTURES:-$(uname -m)}
web_extension_source="$temporary_directory/WebExtension"
version=$(plutil -extract CFBundleShortVersionString raw "$project_directory/Resources/Pablo-Info.plist")
build=$(plutil -extract CFBundleVersion raw "$project_directory/Resources/Pablo-Info.plist")
trap 'rm -rf "$temporary_directory"' EXIT

ditto "$project_directory/SafariExtension/Resources" "$web_extension_source"
if [[ ! -f "$project_directory/SafariExtension/Generated/rrweb-recorder.js" ]]; then
    echo "Missing generated rrweb recorder. Run ./scripts/build-rrweb-assets.sh." >&2
    exit 1
fi
install -m 644 \
    "$project_directory/SafariExtension/Generated/rrweb-recorder.js" \
    "$web_extension_source/rrweb-recorder.js"
mkdir -p "$web_extension_source/icons"
icon_source="$project_directory/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png"
for size in 48 64 96 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$web_extension_source/icons/icon-$size.png" >/dev/null
done
for size in 16 19 32 38; do
    sips -z "$size" "$size" "$icon_source" --out "$web_extension_source/icons/toolbar-$size.png" >/dev/null
done

xcrun safari-web-extension-packager \
    --macos-only \
    --swift \
    --copy-resources \
    --no-open \
    --no-prompt \
    --force \
    --app-name PabloSafariHost \
    --bundle-identifier com.ramon.pablo.safari \
    --project-location "$temporary_directory" \
    "$web_extension_source"

ruby -e 'File.binwrite(ARGV[2], File.binread(ARGV[0]) + "\n" + File.binread(ARGV[1]))' \
    "$project_directory/SafariExtension/SafariWebExtensionHandler.swift" \
    "$project_directory/Sources/Pablo/RRWebSpoolStore.swift" \
    "$extension_source/SafariWebExtensionHandler.swift"

xcodebuild \
    -quiet \
    -project "$project_path" \
    -target "PabloSafariHost Extension" \
    -configuration "$xcode_configuration" \
    SYMROOT="$build_root" \
    CODE_SIGNING_ALLOWED=NO \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    PRODUCT_BUNDLE_IDENTIFIER=com.ramon.pablo.safari.extension \
    PRODUCT_NAME="Pablo Safari" \
    PRODUCT_MODULE_NAME=PabloSafariHost_Extension \
    INFOPLIST_KEY_CFBundleDisplayName="Pablo Safari" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" \
    ARCHS="$extension_architectures" \
    ONLY_ACTIVE_ARCH=NO \
    build

mkdir -p "${destination:h}"
ditto "$build_root/$xcode_configuration/Pablo Safari.appex" "$destination"
