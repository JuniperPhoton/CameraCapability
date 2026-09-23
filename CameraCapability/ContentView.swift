import AVFoundation
import SwiftUI

struct ContentView: View {
    @State private var model = CameraModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreview(model: model)

                if !model.isCameraOpen {
                    Label("Camera closed", systemImage: "video.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let message = model.statusMessage {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                CaptureButton(isCapturing: model.isCapturing) {
                    Task { await model.capturePhoto() }
                }
                .disabled(model.currentDevice == nil || !model.isCameraOpen)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)

                CameraToggle(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(12)
            }
            .background(.black)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.3 }
            .animation(.default, value: model.statusMessage)

            ControlPanel(model: model)
        }
        .task { await model.start() }
    }
}

/// Overlaid on the preview. Off by default, since device info doesn't need a running session.
private struct CameraToggle: View {
    let model: CameraModel

    var body: some View {
        Toggle("Open camera", isOn: Binding(
            get: { model.isCameraOpen },
            set: { open in Task { await model.setCameraOpen(open) } }
        ))
        .labelsHidden()
        .disabled(model.currentDevice == nil || model.isConfiguring)
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct CaptureButton: View {
    let isCapturing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 52, height: 52)
                if isCapturing {
                    ProgressView().tint(.white)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 40, height: 40)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isCapturing)
        .accessibilityLabel("Capture photo")
    }
}

private struct ControlPanel: View {
    let model: CameraModel

    var body: some View {
        VStack(spacing: 0) {
            CameraSelector(model: model)
                .padding()

            Divider()

            ScrollView {
                InfoContent(model: model)
                    .padding()
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

/// Position and device type selection, kept outside the scroll view so it stays pinned at the top.
private struct CameraSelector: View {
    let model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Position", selection: Binding(get: { model.position }, set: { model.select(position: $0) })) {
                ForEach(CameraPosition.allCases) { position in
                    Text(position.rawValue).tag(position)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DeviceTypeOption.all) { option in
                        DeviceTypeChip(
                            title: option.name,
                            isSelected: model.currentDevice?.deviceType == option.type,
                            isAvailable: model.isAvailable(option.type)
                        ) {
                            model.select(type: option.type)
                        }
                    }
                }
            }
            .disabled(model.isConfiguring)
        }
    }
}

private struct InfoContent: View {
    let model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.currentDevice != nil {
                ZoomControl(model: model)
            }

            ForEach(model.infoSections) { section in
                InfoSectionView(section: section)
            }
        }
    }
}

private struct DeviceTypeChip: View {
    let title: String
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .strikethrough(!isAvailable)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
    }
}

private struct ZoomControl: View {
    let model: CameraModel

    var body: some View {
        HStack {
            Text("Zoom")
                .font(.subheadline.weight(.medium))
            Slider(
                value: Binding(get: { model.zoomFactor }, set: { model.setZoom($0) }),
                in: model.zoomRange
            )
            Text(Double(model.zoomFactor).formatted(.number.precision(.fractionLength(2))))
                .font(.subheadline.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct InfoSectionView: View {
    let section: InfoSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.headline)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(section.rows) { row in
                    GridRow {
                        Text(row.key)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(row.value)
                            .textSelection(.enabled)
                    }
                    .font(.caption.monospaced())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
