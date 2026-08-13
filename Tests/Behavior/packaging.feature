Feature: Package and distribute a trustworthy Apple-silicon application

  @automated
  # AppBundlePackagingTests.appExecutableDoesNotCollideWithCLI
  Scenario: GUI and CLI executable names do not collide
    Given the source Info.plist defines the GUI executable
    Then its name is not `pablo` ignoring letter case
    And the bundled CLI remains `Contents/MacOS/pablo`

  @automated
  # AppBundlePackagingTests.reviewWindowUsesStandardApplicationActivation
  Scenario: Review uses a standard application activation policy
    Given the source Info.plist is loaded
    Then `LSUIElement` is not true
    And launching Pablo can present a standard review window

  @signed-app @manual
  Scenario: Local build has a stable development signature
    Given an Apple Development identity is installed with its private key
    When `scripts/build-app.sh` completes
    Then the app and bundled CLI signatures verify
    And the app team identifier matches the selected identity
    And rebuilding does not silently fall back to ad-hoc signing

  @distribution
  Scenario: Distribution contains arm64 executables only
    Given a Developer ID Application identity and notary profile are configured
    When `scripts/build-distribution.sh` completes
    Then GUI and CLI executables are thin arm64 Mach-O files
    And no x86_64 slice is present
    And the ZIP name ends in `mac-arm64.zip`

  @distribution
  Scenario: Extracted release passes signature, notarization, and Gatekeeper checks
    Given the exact release ZIP has been extracted into a clean temporary directory
    When the extracted app is checked with `codesign`, `spctl`, and stapler validation
    Then the Developer ID signature is valid
    And the notarization ticket is stapled and valid
    And Gatekeeper accepts the app

  @signed-app @manual
  Scenario: Finder, System Settings, Dock, and the app use the intended icon
    Given the app was rebuilt from `Resources/Assets.xcassets`
    When the tester views the same installed bundle in Finder, relevant privacy settings, Dock, and the running app
    Then the Pablo robot icon is visible consistently
    And no blank or stale placeholder icon appears
