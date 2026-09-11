# Release automation

Pull requests and pushes to `main` run `.github/workflows/ci.yml`. It validates
the protobuf sources, runs the Swift test suite, builds the app, and rejects any
GUI or CLI executable that is not arm64-only.

Pushing a version tag such as `v0.1.12` runs
`.github/workflows/release.yml`. The tag must match
`CFBundleShortVersionString` and point at the current `main` commit. After the
source passes validation, the protected `release` environment supplies the
credentials needed to sign, notarize, staple, attest, and publish the ZIP.
If any required release secret is absent, source validation still runs but the
publish job exits successfully without producing or uploading a release.

## Configure GitHub

Create an environment named `release`, restrict it to protected tags, and add a
required reviewer. Store these environment secrets:

- `DEVELOPER_ID_CERTIFICATE_P12_BASE64` — a base64-encoded export of the
  Developer ID Application certificate and its private key.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD` — the export password for that P12.
- `PABLO_APP_PROVISIONING_PROFILE_BASE64` — the base64-encoded Developer ID
  provisioning profile for `com.semistrict.pablo`, with App Groups enabled.
- `PABLO_SAFARI_EXTENSION_PROVISIONING_PROFILE_BASE64` — the base64-encoded
  Developer ID provisioning profile for `com.semistrict.pablo.safari.extension`,
  authorized for `group.com.semistrict.pablo.safari`.
- `NOTARY_API_KEY_P8_BASE64` — a base64-encoded App Store Connect team API key.
- `NOTARY_API_KEY_ID` — the API key identifier.
- `NOTARY_API_ISSUER_ID` — the team API issuer identifier.

Use a team API key; Apple does not allow individual API keys with
`notarytool`. Keep the certificate and key files out of the repository.

The environment can be created from the repository checkout with:

```sh
gh api --method PUT repos/{owner}/{repo}/environments/release
```

Add its secrets without putting their values in shell history:

```sh
gh secret set --env release DEVELOPER_ID_CERTIFICATE_P12_BASE64
gh secret set --env release DEVELOPER_ID_CERTIFICATE_PASSWORD
gh secret set --env release PABLO_APP_PROVISIONING_PROFILE_BASE64
gh secret set --env release PABLO_SAFARI_EXTENSION_PROVISIONING_PROFILE_BASE64
gh secret set --env release NOTARY_API_KEY_P8_BASE64
gh secret set --env release NOTARY_API_KEY_ID
gh secret set --env release NOTARY_API_ISSUER_ID
```

The distribution script validates both profiles before signing and embeds each
one in its corresponding bundle. For local releases it discovers matching
Xcode-managed Developer ID profiles automatically; explicit
`PABLO_APP_PROVISIONING_PROFILE` and
`PABLO_SAFARI_EXTENSION_PROVISIONING_PROFILE` paths override discovery.
Xcode automatic signing must enable App Groups and set `REGISTER_APP_GROUPS=YES`
for the registered `group.com.semistrict.pablo.safari` container before exporting
with the Developer ID distribution method.

Configure the required reviewer and protected-tag rule in **Settings →
Environments → release**.

## Publish

Update both version values in `Resources/Pablo-Info.plist`, commit and push the
change to `main`, then create the matching tag:

```sh
git tag v0.1.12
git push origin v0.1.12
```

The release job refuses tags on older commits. It uploads only the arm64 ZIP
produced by `scripts/build-distribution.sh` and attaches provenance for that
exact file digest.

For a local release, extract the final ZIP into a clean temporary directory and
run the signature, Gatekeeper, and stapler checks described in the development
guide. Also run `python3 scripts/verify-packaged-resources.py /path/to/Pablo.app`
against that extracted app before uploading it. Quit any running Pablo app
first. This check launches the signed app with SwiftPM build directories
inaccessible and requests its packaged OpenAPI schema; a development checkout
cannot hide missing installed resources. It requires a valid signing profile
and does not apply to CI's ad-hoc packaging build.

The app and Safari extension use the `com.semistrict` namespace. After changing
bundle identifiers, macOS requires new privacy grants and Safari may require the
extension to be enabled again. Completed recordings stay in the existing Pablo
Recordings folder.
