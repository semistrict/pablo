#!/bin/zsh

set -euo pipefail

expected_bundle_identifier=${1:?Pass the expected bundle identifier}
expected_team_identifier=${2:?Pass the expected team identifier}
expected_app_group=${3:?Pass the expected app group identifier}
expected_application="$expected_team_identifier.$expected_bundle_identifier"
profile_directories=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
)

for directory in $profile_directories; do
    profiles=(
        "$directory"/*.provisionprofile(Nom)
        "$directory"/*.mobileprovision(Nom)
    )
    for profile in $profiles; do
        temporary_profile=$(mktemp "${TMPDIR:-/tmp}/pablo-profile-search.XXXXXX")
        if security cms -D -i "$profile" > "$temporary_profile" 2>/dev/null; then
            profile_application=$(
                /usr/libexec/PlistBuddy \
                    -c 'Print :Entitlements:com.apple.application-identifier' \
                    "$temporary_profile" 2>/dev/null || true
            )
            profile_all_devices=$(
                plutil -extract ProvisionsAllDevices raw "$temporary_profile" 2>/dev/null || true
            )
            profile_app_groups=$(
                /usr/libexec/PlistBuddy \
                    -c 'Print :Entitlements:com.apple.security.application-groups' \
                    "$temporary_profile" 2>/dev/null || true
            )
            if [[ $profile_application == $expected_application &&
                  $profile_all_devices == true &&
                  ( $profile_app_groups == *"$expected_app_group"* ||
                    $profile_app_groups == *"$expected_team_identifier.*"* ) ]]; then
                rm -f "$temporary_profile"
                echo "$profile"
                exit 0
            fi
        fi
        rm -f "$temporary_profile"
    done
done

echo "No Developer ID provisioning profile found for $expected_bundle_identifier." >&2
exit 1
