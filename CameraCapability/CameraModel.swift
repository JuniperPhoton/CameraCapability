@preconcurrency import AVFoundation
import Observation
import Photos

enum CameraPosition: String, CaseIterable, Identifiable {
    case back = "Back"
    case front = "Front"
    case unspecified = "Any"

    var id: Self { self }

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .back: .back
        case .front: .front
        case .unspecified: .unspecified
        }
    }
}

struct DeviceTypeOption: Identifiable {
    let type: AVCaptureDevice.DeviceType
    let name: String

    var id: String { type.rawValue }

    /// The capture device types listed in "Choosing a Capture Device".
    static let all: [DeviceTypeOption] = [
        .init(type: .builtInWideAngleCamera, name: "Wide"),
        .init(type: .builtInUltraWideCamera, name: "Ultra Wide"),
        .init(type: .builtInTelephotoCamera, name: "Telephoto"),
        .init(type: .builtInDualCamera, name: "Dual (W+T)"),
        .init(type: .builtInDualWideCamera, name: "Dual Wide (UW+W)"),
        .init(type: .builtInTripleCamera, name: "Triple"),
        .init(type: .builtInTrueDepthCamera, name: "TrueDepth"),
        .init(type: .builtInLiDARDepthCamera, name: "LiDAR Depth"),
        .init(type: .external, name: "External"),
    ]

    static func name(for type: AVCaptureDevice.DeviceType) -> String {
        all.first { $0.type == type }?.name ?? type.rawValue
    }
}

struct InfoSection: Identifiable {
    let title: String
    let rows: [InfoRow]

    var id: String { title }
}

struct InfoRow: Identifiable {
    let key: String
    let value: String

    var id: String { key }
}

@Observable
final class CameraModel {
    private(set) var availableDevices: [AVCaptureDevice] = []
    private(set) var position: CameraPosition = .back
    private(set) var currentDevice: AVCaptureDevice?
    private(set) var isConfiguring = false
    /// Whether the session is running. Device info is read without opening the camera, so this starts off.
    private(set) var isCameraOpen = false
    private(set) var isCapturing = false
    private(set) var zoomFactor: CGFloat = 1
    private(set) var statusMessage: String?

    /// Bumped periodically so views re-read live device values (ISO, exposure, active constituent, ...).
    private(set) var liveTick = 0

    @ObservationIgnored private let service = CaptureService()
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    var session: AVCaptureSession { service.session }

    // MARK: - Lifecycle

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            showStatus("Camera access denied. Enable it in Settings.", autoHide: false)
            return
        }

        availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: DeviceTypeOption.all.map(\.type),
            mediaType: .video,
            position: .unspecified
        ).devices

        guard let initial = device(for: .builtInWideAngleCamera, position: position)
            ?? availableDevices.first(where: { position.avPosition == $0.position })
            ?? availableDevices.first
        else {
            showStatus("No camera available on this device.", autoHide: false)
            return
        }

        await switchTo(initial)
        startLiveUpdates()
    }

    func setCameraOpen(_ open: Bool) async {
        guard open != isCameraOpen, !isConfiguring, let currentDevice else { return }
        isConfiguring = true
        defer { isConfiguring = false }

        if open {
            do {
                try await service.configure(with: currentDevice)
                await service.startRunning()
                isCameraOpen = true
                // The preview connection only exists once an input is added, so reapply rotation.
                setUpRotationCoordinator(for: currentDevice)
            } catch {
                showStatus("Failed to open \(currentDevice.localizedName): \(error.localizedDescription)")
            }
        } else {
            await service.stop()
            isCameraOpen = false
        }
    }

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        previewLayer.session = service.session
        if let currentDevice {
            setUpRotationCoordinator(for: currentDevice)
        }
    }

    // MARK: - Selection

    func device(for type: AVCaptureDevice.DeviceType, position: CameraPosition) -> AVCaptureDevice? {
        availableDevices.first { device in
            device.deviceType == type && (position == .unspecified || device.position == position.avPosition)
        }
    }

    func isAvailable(_ type: AVCaptureDevice.DeviceType) -> Bool {
        device(for: type, position: position) != nil
    }

    func select(position newPosition: CameraPosition) {
        position = newPosition
        let preferredType = currentDevice?.deviceType ?? .builtInWideAngleCamera
        guard let device = device(for: preferredType, position: newPosition)
            ?? DeviceTypeOption.all.lazy.compactMap({ self.device(for: $0.type, position: newPosition) }).first
        else { return }
        Task { await switchTo(device) }
    }

    func select(type: AVCaptureDevice.DeviceType) {
        guard let device = device(for: type, position: position) else { return }
        Task { await switchTo(device) }
    }

    private func switchTo(_ device: AVCaptureDevice) async {
        guard device != currentDevice, !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }

        do {
            if isCameraOpen {
                try await service.configure(with: device)
            }
            currentDevice = device
            zoomFactor = device.videoZoomFactor
            setUpRotationCoordinator(for: device)
        } catch {
            showStatus("Failed to use \(device.localizedName): \(error.localizedDescription)")
        }
    }

    // MARK: - Zoom

    var zoomRange: ClosedRange<CGFloat> {
        guard let currentDevice else { return 1...1 }
        let lower = currentDevice.minAvailableVideoZoomFactor
        let upper = min(currentDevice.maxAvailableVideoZoomFactor, 20)
        return lower...max(lower, upper)
    }

    func setZoom(_ factor: CGFloat) {
        guard let currentDevice else { return }
        let clamped = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        do {
            try currentDevice.lockForConfiguration()
            currentDevice.videoZoomFactor = clamped
            currentDevice.unlockForConfiguration()
            zoomFactor = clamped
        } catch {
            showStatus("Zoom failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture

    func capturePhoto() async {
        guard currentDevice != nil, isCameraOpen, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        do {
            let data = try await service.capturePhoto(rotationAngle: angle)
            try await PhotoLibrary.save(data)
            showStatus("Saved to Photos")
        } catch {
            showStatus("Capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Rotation

    private func setUpRotationCoordinator(for device: AVCaptureDevice) {
        guard let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { @Sendable [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Status

    private func showStatus(_ message: String, autoHide: Bool = true) {
        statusMessage = message
        statusTask?.cancel()
        guard autoHide else { return }
        statusTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    private func startLiveUpdates() {
        liveTask?.cancel()
        liveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                liveTick &+= 1
                if let currentDevice, !currentDevice.isRampingVideoZoom {
                    zoomFactor = currentDevice.videoZoomFactor
                }
            }
        }
    }
}

// MARK: - Info

extension CameraModel {
    var infoSections: [InfoSection] {
        _ = liveTick
        guard let device = currentDevice else { return [] }
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

        var deviceRows: [InfoRow] = [
            .init(key: "Name", value: device.localizedName),
            .init(key: "Type", value: device.deviceType.rawValue),
            .init(key: "Position", value: device.position.debugName),
            .init(key: "Model ID", value: device.modelID),
            .init(key: "Unique ID", value: device.uniqueID),
            .init(key: "Virtual", value: device.isVirtualDevice.description),
        ]
        if device.isVirtualDevice {
            deviceRows += [
                .init(key: "Constituents", value: device.constituentDevices.map { DeviceTypeOption.name(for: $0.deviceType) }.joined(separator: ", ")),
                .init(key: "Switch-over zoom", value: device.virtualDeviceSwitchOverVideoZoomFactors.map { format2($0.doubleValue) }.joined(separator: ", ")),
                .init(key: "Switching behavior", value: device.primaryConstituentDeviceSwitchingBehavior.debugName),
            ]
        }

        let frameRates = format.videoSupportedFrameRateRanges
            .map { "\(format2($0.minFrameRate))-\(format2($0.maxFrameRate))" }
            .joined(separator: ", ")
        let photoSizes = format.supportedMaxPhotoDimensions
            .map { "\($0.width)x\($0.height)" }
            .joined(separator: ", ")

        let formatRows: [InfoRow] = [
            .init(key: "Video size", value: "\(dimensions.width)x\(dimensions.height)"),
            .init(key: "Frame rates", value: frameRates),
            .init(key: "Active frame duration", value: "\(format2(device.activeVideoMinFrameDuration.seconds * 1000)) ms"),
            .init(key: "Field of view", value: "\(format2(Double(format.videoFieldOfView)))°"),
            .init(key: "Max photo sizes", value: photoSizes),
            .init(key: "Color space", value: device.activeColorSpace.debugName),
            .init(key: "Video HDR", value: format.isVideoHDRSupported.description),
            .init(key: "Depth formats", value: "\(format.supportedDepthDataFormats.count)"),
            .init(key: "Zoom (available)", value: "\(format2(device.minAvailableVideoZoomFactor))-\(format2(device.maxAvailableVideoZoomFactor))"),
            .init(key: "Format count", value: "\(device.formats.count)"),
        ]

        var liveRows: [InfoRow] = [
            .init(key: "Zoom factor", value: "\(format2(device.videoZoomFactor)) (display \(format2(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier))x)"),
            .init(key: "ISO", value: format2(Double(device.iso))),
            .init(key: "Exposure", value: exposureString(device.exposureDuration)),
            .init(key: "Lens position", value: format2(Double(device.lensPosition))),
            .init(key: "Lens aperture", value: "f/\(format2(Double(device.lensAperture)))"),
            .init(key: "Min focus distance", value: "\(device.minimumFocusDistance) mm"),
            .init(key: "White balance", value: whiteBalanceString(device)),
            .init(key: "Adjusting", value: "focus \(device.isAdjustingFocus), exposure \(device.isAdjustingExposure)"),
        ]
        if let primary = device.activePrimaryConstituent {
            liveRows.insert(.init(key: "Active constituent", value: DeviceTypeOption.name(for: primary.deviceType)), at: 0)
        }

        let photoOutput = service.photoOutput
        let sessionRows: [InfoRow] = [
            .init(key: "Running", value: session.isRunning.description),
            .init(key: "Preset", value: session.sessionPreset.rawValue),
            .init(key: "Photo max size", value: "\(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height)"),
            .init(key: "Photo codecs", value: photoOutput.availablePhotoCodecTypes.map(\.rawValue).joined(separator: ", ")),
            .init(key: "Discovered devices", value: availableDevices.map { "\(DeviceTypeOption.name(for: $0.deviceType)) (\($0.position.debugName))" }.joined(separator: ", ")),
        ]

        return [
            InfoSection(title: "Live", rows: liveRows),
            InfoSection(title: "Device", rows: deviceRows),
            InfoSection(title: "Active Format", rows: formatRows),
            InfoSection(title: "Exposure Support", rows: exposureSupportRows(for: format)),
            InfoSection(title: "Session", rows: sessionRows),
        ]
    }

    private func format2(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func format2(_ value: CGFloat) -> String {
        format2(Double(value))
    }

    /// Queries `supportsExposureModeCustom(lensAperture:duration:iso:)` for every Auto/Locked combination
    /// of aperture, duration and ISO. "Lock" uses the Current constants, so no arbitrary values are picked.
    private func exposureSupportRows(for format: AVCaptureDevice.Format) -> [InfoRow] {
        let apertureStops = format.recommendedLensApertureStops.map { "f/\(format2(Double($0)))" }.joined(separator: ", ")
        var rows: [InfoRow] = [
            .init(key: "Aperture range", value: "f/\(format2(Double(format.minLensAperture)))-f/\(format2(Double(format.maxLensAperture))) (default f/\(format2(Double(format.defaultLensAperture))))"),
            .init(key: "Aperture stops", value: apertureStops.isEmpty ? "-" : apertureStops),
            .init(key: "ISO range", value: "\(format2(Double(format.minISO)))-\(format2(Double(format.maxISO)))"),
            .init(key: "Duration range", value: "\(exposureString(format.minExposureDuration)) - \(exposureString(format.maxExposureDuration))"),
        ]

        for apertureLocked in [false, true] {
            for durationLocked in [false, true] {
                for isoLocked in [false, true] {
                    let supported = format.supportsExposureModeCustom(
                        lensAperture: apertureLocked ? AVCaptureDevice.currentLensAperture : AVCaptureDevice.autoLensAperture,
                        duration: durationLocked ? AVCaptureDevice.currentExposureDuration : AVCaptureDevice.autoExposureDuration,
                        iso: isoLocked ? AVCaptureDevice.currentISO : AVCaptureDevice.autoISO
                    )
                    let key = [("A", apertureLocked), ("D", durationLocked), ("ISO", isoLocked)]
                        .map { "\($0.0):\($0.1 ? "lock" : "auto")" }
                        .joined(separator: " ")
                    let mode = exposureModeName(apertureLocked: apertureLocked, durationLocked: durationLocked, isoLocked: isoLocked)
                    rows.append(.init(key: key, value: "\(supported ? "✅" : "❌") \(mode)"))
                }
            }
        }
        return rows
    }

    private func exposureModeName(apertureLocked: Bool, durationLocked: Bool, isoLocked: Bool) -> String {
        switch (apertureLocked, durationLocked, isoLocked) {
        case (false, false, false): "full auto"
        case (true, false, false): "aperture priority"
        case (false, true, false): "shutter priority"
        case (false, false, true): "ISO priority"
        case (true, true, false): "auto ISO"
        case (true, false, true): "auto duration"
        case (false, true, true): "auto aperture"
        case (true, true, true): "full manual"
        }
    }

    private func whiteBalanceString(_ device: AVCaptureDevice) -> String {
        let gains = device.deviceWhiteBalanceGains
        let range: ClosedRange<Float> = 1...device.maxWhiteBalanceGain
        // Gains can be 0 or otherwise out of range (e.g. before the first frame), and converting
        // them then raises an NSRangeException, so show the raw gains instead.
        guard range.contains(gains.redGain), range.contains(gains.greenGain), range.contains(gains.blueGain) else {
            return "gains r\(format2(Double(gains.redGain))) g\(format2(Double(gains.greenGain))) b\(format2(Double(gains.blueGain)))"
        }
        let values = device.temperatureAndTintValues(for: gains)
        return "\(Int(values.temperature))K, tint \(Int(values.tint))"
    }

    private func exposureString(_ duration: CMTime) -> String {
        let seconds = duration.seconds
        guard seconds > 0, seconds.isFinite else { return "-" }
        return seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : "\(format2(seconds)) s"
    }
}

// MARK: - Photo library

nonisolated enum PhotoLibrary {
    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CameraError.photoLibraryDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

// MARK: - Debug names

private extension AVCaptureDevice.Position {
    var debugName: String {
        switch self {
        case .back: "back"
        case .front: "front"
        case .unspecified: "unspecified"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

private extension AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior {
    var debugName: String {
        switch self {
        case .unsupported: "unsupported"
        case .auto: "auto"
        case .restricted: "restricted"
        case .locked: "locked"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

private extension AVCaptureColorSpace {
    var debugName: String {
        switch self {
        case .sRGB: "sRGB"
        case .P3_D65: "P3 D65"
        case .HLG_BT2020: "HLG BT2020"
        case .appleLog: "Apple Log"
        default: "raw(\(rawValue))"
        }
    }
}
