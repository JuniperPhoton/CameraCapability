@preconcurrency import AVFoundation

enum CameraError: LocalizedError {
    case cannotAddInput
    case noPhotoData
    case photoLibraryDenied

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: "The session can't add an input for this device."
        case .noPhotoData: "The capture produced no photo data."
        case .photoLibraryDenied: "Photo library add access was denied."
        }
    }
}

/// Owns the `AVCaptureSession` and performs all session work on a private serial queue.
nonisolated final class CaptureService: @unchecked Sendable {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    private let queue = DispatchQueue(label: "CameraCapability.session")
    private var currentInput: AVCaptureDeviceInput?
    private var inFlightCaptures: [Int64: PhotoCaptureDelegate] = [:]

    func configure(with device: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try applyInput(for: device)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRunning() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func capturePhoto(rotationAngle: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let settings = if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    AVCapturePhotoSettings()
                }
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .balanced

                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }

                let id = settings.uniqueID
                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.queue.async { self?.inFlightCaptures[id] = nil }
                    continuation.resume(with: result)
                }
                inFlightCaptures[id] = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func applyInput(for device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        if let currentInput {
            session.removeInput(currentInput)
        }
        guard session.canAddInput(input) else {
            if let currentInput, session.canAddInput(currentInput) {
                session.addInput(currentInput)
            }
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)
        currentInput = input

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()

        // The active format is settled after commit, so pick the largest photo size it supports.
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
    }
}

nonisolated private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private var result: Result<Data, Error>?

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(CameraError.noPhotoData)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(.failure(error))
        } else {
            completion(result ?? .failure(CameraError.noPhotoData))
        }
    }
}
