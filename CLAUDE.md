# Fillet

## Building

- Never build for x86_64. OpenCascade (`libOCCT.a`) is built for arm64 only, so an x86_64 slice fails to link. For the iOS simulator, target a specific simulator and pass `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, never `generic/platform=iOS Simulator`:

  ```sh
  xcodebuild -project App/Fillet.xcodeproj -scheme Fillet -destination "id=<simulator-udid>" \
    -derivedDataPath build/dd-sim CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
  ```

- Device builds need a real signing identity (`project.yml` sets ad-hoc `-`): pass `CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates`. The team comes from `App/Local.xcconfig`.
