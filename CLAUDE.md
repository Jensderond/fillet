# Fillet

## Building

- Never build for x86_64. OpenCascade (`vendor/OCCT.xcframework`) is built for arm64 only, so an x86_64 slice fails to link. For the iOS simulator, target a specific simulator and pass `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, never `generic/platform=iOS Simulator`:

  ```sh
  xcodebuild -project App/Fillet.xcodeproj -scheme Fillet -destination "id=<simulator-udid>" \
    -derivedDataPath build/dd-sim CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
  ```

- Device builds need a real signing identity (`project.yml` sets ad-hoc `-`): pass `CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates`. The team comes from `App/Local.xcconfig`.

## Releasing

Every Mac release is signed with a Developer ID and notarized. Never publish an ad-hoc or unnotarized build.

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml`; commit as `build: Set the version to X.Y.Z (N)`.
2. `scripts/release.sh X.Y.Z`: signs with the keychain's "Developer ID Application" identity, notarizes and staples the app and the DMG, checks both with Gatekeeper. It needs the `notarytool` keychain profile `$FILLET_NOTARY_PROFILE` (default `fillet`); if that is missing it stops: fix it, don't work around it.
3. Only publish if both show "Notarized Developer ID". Create the GitHub release "Fillet X.Y.Z" on tag `vX.Y.Z` with `build/release/Fillet-X.Y.Z.dmg`; put the SHA-256 line from the end of the output under *Checksum*.
