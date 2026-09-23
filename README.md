# CameraCapability

A small iOS debugging app for exploring the capture devices and formats AVFoundation exposes on a real iPhone or iPad.

Pick a built-in camera type, see the live preview, and inspect what that device and its active format report, including which custom exposure modes it supports.

## Features

- **Camera selection.** Choose a position (Back / Front / Any) and one of the device types from [Choosing a Capture Device](https://developer.apple.com/documentation/avfoundation/choosing-a-capture-device):
  - Wide
  - Ultra Wide
  - Telephoto
  - Dual (Wide + Telephoto)
  - Dual Wide (Ultra Wide + Wide)
  - Triple
  - TrueDepth
  - LiDAR Depth
  - External

  Types that don't exist on the device for the selected position are greyed out and struck through. The selector stays pinned while the info panel scrolls.
- **Open camera toggle.** Off by default. Device and format info is read straight from `AVCaptureDevice`, so browsing devices doesn't start the session. Turn it on for the preview, live values and photo capture.
- **Preview.** An `AVCaptureVideoPreviewLayer` shows the full frame without cropping. `AVCaptureDevice.RotationCoordinator` keeps it level as the device rotates.
- **Photo capture.** The shutter button captures a HEVC photo (JPEG when HEVC isn't available) at the largest size the active format supports and saves it to Photos.
- **Zoom slider.** Useful for watching a virtual device (Dual, Dual Wide, Triple) switch between its constituent cameras.
- **Info panel.**

  | Section | What it shows |
  | --- | --- |
  | Live | Refreshed every 250 ms: active primary constituent, zoom factor (raw and display), ISO, exposure duration, lens position and aperture, white balance, focus/exposure adjusting state |
  | Device | Name, type, position, model and unique IDs, and for virtual devices the constituent devices, switch-over zoom factors and switching behavior |
  | Active Format | Video size, frame rate ranges, field of view, supported max photo dimensions, color space, video HDR, depth formats, available zoom range, format count |
  | Exposure Support | Aperture, ISO and exposure duration ranges, plus the result of `supportsExposureModeCustom(lensAperture:duration:iso:)` for all 8 Auto/Locked combinations of aperture, duration and ISO |
  | Session | Running state, preset, photo output max dimensions and codecs, all discovered devices |

  Values in the panel are selectable, so you can copy them.

## Requirements

- Xcode 27 (beta) or later
- iOS 27 or later. `supportsExposureModeCustom(lensAperture:duration:iso:)` and the lens aperture APIs are new in iOS 27.
- A physical device. The Simulator has no cameras.

## Running

1. Open `CameraCapability.xcodeproj`.
2. Set your development team under **Signing & Capabilities**.
3. Run on a connected iPhone or iPad.
4. Allow camera access. Photo library access is requested the first time you capture a photo.

## Project structure

| File | Responsibility |
| --- | --- |
| `CameraCapability/MyApp.swift` | App entry point |
| `CameraCapability/ContentView.swift` | UI layout, with the preview and shutter on top and the camera selector and info panel below |
| `CameraCapability/CameraPreview.swift` | `UIViewRepresentable` backed by `AVCaptureVideoPreviewLayer` |
| `CameraCapability/CameraModel.swift` | Observable model covering device discovery, selection, zoom, rotation, capture, and building the info panel sections |
| `CameraCapability/CaptureService.swift` | Owns the `AVCaptureSession` and photo output, runs session work on a private serial queue |

To inspect another property, add an `InfoRow` in `CameraModel.infoSections`. For a new group of values, add an `InfoSection`.
