#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
configuration=${1:-release}
bundle_path="$project_directory/dist/Pablo.app"
contents_path="$bundle_path/Contents"
executable_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
plugins_path="$contents_path/PlugIns"
main_executable_name=$(plutil -extract CFBundleExecutable raw "$project_directory/Resources/Pablo-Info.plist")
temporary_cache="${TMPDIR:-/tmp}/pablo-clang-cache"
architecture_arguments=()
if [[ -n ${PABLO_ARCHITECTURES:-} ]]; then
    for architecture in ${(z)PABLO_ARCHITECTURES}; do
        architecture_arguments+=(--arch "$architecture")
    done
fi

"$script_directory/build-rrweb-assets.sh"

mkdir -p "$temporary_cache"
CLANG_MODULE_CACHE_PATH="$temporary_cache" swift build \
    --package-path "$project_directory" \
    --disable-sandbox \
    --configuration "$configuration" \
    "${architecture_arguments[@]}" \
    --product PabloApp
CLANG_MODULE_CACHE_PATH="$temporary_cache" swift build \
    --package-path "$project_directory" \
    --disable-sandbox \
    --configuration "$configuration" \
    "${architecture_arguments[@]}" \
    --product pablo
binary_path=$(CLANG_MODULE_CACHE_PATH="$temporary_cache" swift build \
    --package-path "$project_directory" \
    --disable-sandbox \
    --configuration "$configuration" \
    "${architecture_arguments[@]}" \
    --show-bin-path)

rm -rf "$bundle_path"
mkdir -p "$executable_path"
mkdir -p "$resources_path"
mkdir -p "$plugins_path"
if [[ ${main_executable_name:l} == pablo ]]; then
    echo "CFBundleExecutable must not differ from the bundled CLI name only by letter case." >&2
    exit 1
fi
install -m 755 "$binary_path/PabloApp" "$executable_path/$main_executable_name"
install -m 755 "$binary_path/pablo" "$executable_path/pablo"
install -m 644 "$project_directory/Resources/Pablo-Info.plist" "$contents_path/Info.plist"
PABLO_ARCHITECTURES="${PABLO_ARCHITECTURES:-}" \
    "$script_directory/build-safari-extension.sh" "$plugins_path/Pablo Safari.appex" "$configuration"
for resource_bundle in "$binary_path"/*.bundle(N); do
    ditto "$resource_bundle" "$resources_path/${resource_bundle:t}"
done

if cmp -s "$executable_path/$main_executable_name" "$executable_path/pablo"; then
    echo "The GUI executable was overwritten by the CLI executable." >&2
    exit 1
fi

xcrun actool \
    "$project_directory/Resources/Assets.xcassets" \
    --compile "$resources_path" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$temporary_cache/Pablo-asset-info.plist"

if [[ -n ${PABLO_SIGNING_IDENTITY:-} ]]; then
    signing_identity=$PABLO_SIGNING_IDENTITY
else
    signing_identity=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -n 1)
fi

if [[ -z $signing_identity ]]; then
    echo "No Apple Development signing identity was found." >&2
    echo "Set PABLO_SIGNING_IDENTITY=- only when an explicit ad-hoc build is intended." >&2
    exit 1
fi

team_identifier=D9G32AG3E5
app_group_identifier=D9G32AG3E5.com.ramon.pablo.safari
if [[ $signing_identity == "Developer ID Application:"* ]]; then
    app_profile=${PABLO_APP_PROVISIONING_PROFILE:-$($script_directory/find-distribution-profile.sh \
        com.ramon.pablo "$team_identifier" "$app_group_identifier")}
    safari_profile=${PABLO_SAFARI_EXTENSION_PROVISIONING_PROFILE:-$($script_directory/find-distribution-profile.sh \
        com.ramon.pablo.safari.extension "$team_identifier" "$app_group_identifier")}
    "$script_directory/validate-distribution-profile.sh" \
        "$app_profile" com.ramon.pablo "$team_identifier" "$app_group_identifier"
    "$script_directory/validate-distribution-profile.sh" \
        "$safari_profile" com.ramon.pablo.safari.extension \
        "$team_identifier" "$app_group_identifier"
    install -m 644 "$app_profile" "$contents_path/embedded.provisionprofile"
    install -m 644 "$safari_profile" \
        "$plugins_path/Pablo Safari.appex/Contents/embedded.provisionprofile"
fi

signing_arguments=(--force --sign "$signing_identity")
if [[ $signing_identity == "Developer ID Application:"* ]]; then
    signing_arguments+=(--options runtime --timestamp)
else
    signing_arguments+=(--timestamp=none)
fi

codesign "${signing_arguments[@]}" "$executable_path/pablo"
codesign \
    "${signing_arguments[@]}" \
    --entitlements "$project_directory/SafariExtension/PabloSafariExtension.entitlements" \
    "$plugins_path/Pablo Safari.appex"
codesign \
    "${signing_arguments[@]}" \
    --entitlements "$project_directory/Resources/Pablo.entitlements" \
    --identifier com.ramon.pablo \
    "$bundle_path"

echo "Signed with: $signing_identity"

echo "$bundle_path"
