# CLAUDE.md

iOS SwiftUI app for debugging AVFoundation capture devices. See `README.md` for features and file layout.

## Build

The active developer directory is the Command Line Tools, and the project needs the iOS 27 SDK, so point at Xcode-Beta explicitly:

```sh
DEVELOPER_DIR=/Applications/Xcode-Beta.app/Contents/Developer \
  xcodebuild -project CameraCapability.xcodeproj -scheme CameraCapability \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

- Treat that build as the source of truth. SourceKit diagnostics in the editor are often stale or wrong for this project (e.g. "Cannot find 'CameraModel' in scope", "No such module 'UIKit'", SwiftUI macro plugin errors). Ignore them if `xcodebuild` succeeds.
- There are no tests. The Simulator has no cameras, so runtime behavior can only be checked on a physical device by the user. Say so rather than claiming a change works at runtime.

## Project settings

- The target is iOS only (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`). Most capture device types and exposure APIs are unavailable on macOS/visionOS.
- The project uses file system synchronized groups, so new `.swift` files in `CameraCapability/` are picked up without editing `project.pbxproj`.
- The Info.plist is generated. Add usage strings as `INFOPLIST_KEY_*` build settings in both Debug and Release configurations.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with Swift 5 language mode and approachable concurrency.

## Concurrency conventions

- Everything is implicitly `@MainActor` unless marked otherwise.
- Code that runs off the main thread or is called back by AVFoundation/Photos must be `nonisolated`, for example:
  - `CaptureService` and its session queue
  - `PhotoCaptureDelegate`
  - `PhotoLibrary`

  Otherwise closures get inferred as main-actor isolated.
- Session configuration, `startRunning` and `capturePhoto` go through `CaptureService`'s serial queue, bridged with checked continuations.
- KVO closures on the main-actor model are written `@Sendable` and hop back with `Task { @MainActor in ... }`.
- Import AVFoundation with `@preconcurrency`.

## AVFoundation pitfalls

Many AVFoundation calls raise Objective-C exceptions, which crash the app instead of throwing. The info panel re-evaluates every 250 ms, so any call in `CameraModel.infoSections` must be safe for any device and format:

- `temperatureAndTintValues(for:)` raises `NSRangeException` unless every gain is in `1...maxWhiteBalanceGain`. `deviceWhiteBalanceGains` can be 0 before the first frame. Guard like `whiteBalanceString(_:)` does.
- `setExposureModeCustom(...)` raises for unsupported combinations. Check `format.supportsExposureModeCustom(lensAperture:duration:iso:)` first.
- Device setters (zoom, exposure, focus) require `lockForConfiguration()`.

## Adding debug info

Add an `InfoRow` in `CameraModel.infoSections` (or a helper returning `[InfoRow]`, like `exposureSupportRows(for:)`). Format numbers with `format2(_:)` and durations with `exposureString(_:)`.

## Git

`CameraCapability.xcodeproj/xcuserdata/` is per-user Xcode state. Don't stage or commit it.
