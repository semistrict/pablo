#!/bin/zsh

set -euo pipefail

profile_path=${1:?Pass a provisioning profile path}
expected_bundle_identifier=${2:?Pass the expected bundle identifier}
expected_team_identifier=${3:?Pass the expected team identifier}
expected_app_group=${4:?Pass the expected app group identifier}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/pablo-profile-validation.XXXXXX")
decoded_profile="$temporary_directory/profile.plist"
trap 'rm -rf "$temporary_directory"' EXIT

if [[ ! -f $profile_path ]]; then
    echo "Provisioning profile does not exist: $profile_path" >&2
    exit 1
fi

if ! security cms -D -i "$profile_path" > "$decoded_profile"; then
    echo "Provisioning profile is not a valid Apple CMS document: $profile_path" >&2
    exit 1
fi

profile_team=$(plutil -extract TeamIdentifier.0 raw "$decoded_profile")
profile_application=$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded_profile"
)
profile_entitlement_team=$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$decoded_profile"
)
profile_expiration=$(plutil -extract ExpirationDate raw "$decoded_profile")
profile_all_devices=$(plutil -extract ProvisionsAllDevices raw "$decoded_profile" 2>/dev/null || true)
expected_application="$expected_team_identifier.$expected_bundle_identifier"

if [[ $profile_team != $expected_team_identifier ]]; then
    echo "Provisioning profile team '$profile_team' does not match '$expected_team_identifier'." >&2
    exit 1
fi
if [[ $profile_application != $expected_application ]]; then
    echo "Provisioning profile application '$profile_application' does not match '$expected_application'." >&2
    exit 1
fi
if [[ $profile_entitlement_team != $expected_team_identifier ]]; then
    echo "Provisioning profile entitlement team '$profile_entitlement_team' does not match '$expected_team_identifier'." >&2
    exit 1
fi
if [[ $profile_all_devices != true ]]; then
    echo "Provisioning profile is not a Developer ID distribution profile." >&2
    exit 1
fi

expiration_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiration" '+%s')
current_epoch=$(date -u '+%s')
if (( expiration_epoch <= current_epoch )); then
    echo "Provisioning profile expired at $profile_expiration." >&2
    exit 1
fi

app_groups=$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' \
        "$decoded_profile"
)
if [[ $app_groups != *"$expected_app_group"* &&
      $app_groups != *"$expected_team_identifier.*"* ]]; then
    echo "Provisioning profile does not authorize app group '$expected_app_group'." >&2
    exit 1
fi

echo "Validated Developer ID profile for $expected_bundle_identifier"
