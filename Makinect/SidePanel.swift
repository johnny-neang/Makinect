// SidePanel — Sidebar with connection controls, stream mode picker, and adjustable parameters

import SwiftUI

struct SidePanel: View {
    @Bindable var manager: KinectManager

    private enum TopMode: String, CaseIterable, Identifiable {
        case stream = "Stream"
        case visualize = "Visualize"
        var id: String { rawValue }
    }
    @State private var topMode: TopMode = .stream

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Source — pick where the visualization textures come from.
                // Defaults to .kinect; .synthetic frees the user from needing a device.
                Picker("Source", selection: $manager.source) {
                    ForEach(InputSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: manager.source) { _, new in
                    // Synthetic mode is visualize-only — Stream is a CPU pipeline that
                    // depends on real device frames.
                    if new == .synthetic {
                        topMode = .visualize
                        if manager.visualization == nil { manager.visualization = .pointCloud }
                    }
                }

                // Connection — only relevant in Kinect mode
                if manager.source == .kinect {
                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(manager.isConnected ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text(manager.isConnected ? "Connected" : "Disconnected")
                            }

                            Button(manager.isConnected ? "Disconnect" : "Connect") {
                                if manager.isConnected {
                                    manager.disconnect()
                                } else {
                                    manager.connect()
                                }
                            }
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                // Top-level mode (Stream is hidden in synthetic since it requires a device)
                if manager.source == .kinect {
                    Picker("", selection: $topMode) {
                        ForEach(TopMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: topMode) { _, new in
                        if new == .stream { manager.visualization = nil }
                        else if manager.visualization == nil { manager.visualization = .pointCloud }
                    }
                }

                if manager.source == .kinect && topMode == .stream {
                    streamSection
                } else {
                    visualizationSection
                }

                // Device info
                if manager.isConnected {
                    GroupBox("Device Info") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let serial = manager.serialNumber {
                                LabeledContent("Serial", value: serial)
                            }
                            if let fw = manager.firmwareVersion, !fw.isEmpty {
                                LabeledContent("Firmware", value: fw)
                            }
                            LabeledContent("FPS", value: String(format: "%.1f", manager.currentFPS))
                            LabeledContent("Version", value: manager.activeVersion == .kinectV2 ? "Kinect v2" : "Kinect v1")
                        }
                        .font(.caption)
                    }
                }

                // Status
                Text(manager.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        GroupBox("Stream Mode") {
            Picker("Mode", selection: $manager.cameraMode) {
                ForEach(CameraMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        if manager.cameraMode == .rgb || manager.cameraMode == .skeleton {
            GroupBox("Pose Detection") {
                Toggle("Show Skeleton Overlay", isOn: $manager.showSkeleton)
            }
        }

        if manager.cameraMode == .segmented {
            GroupBox("Depth Segmentation") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Near Clip: \(Int(manager.segmentationNearMM)) mm")
                        .font(.callout)
                    Slider(value: $manager.segmentationNearMM, in: 0...4500, step: 50)

                    Text("Far Clip: \(Int(manager.segmentationFarMM)) mm")
                        .font(.callout)
                    Slider(value: $manager.segmentationFarMM, in: 0...4500, step: 50)
                }
            }
        }
    }

    @ViewBuilder
    private var visualizationSection: some View {
        GroupBox("Visualization") {
            Picker("Visualization", selection: Binding(
                get: { manager.visualization ?? .pointCloud },
                set: { manager.visualization = $0 }
            )) {
                ForEach(VisualizationKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        GroupBox("Depth Range") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Near: \(Int(manager.segmentationNearMM)) mm").font(.callout)
                Slider(value: $manager.segmentationNearMM, in: 0...4500, step: 50)
                Text("Far: \(Int(manager.segmentationFarMM)) mm").font(.callout)
                Slider(value: $manager.segmentationFarMM, in: 0...4500, step: 50)
            }
        }

        GroupBox("Audio Input") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Source", selection: Binding(
                    get: { manager.audio.selectedInputID ?? 0 },
                    set: { manager.audio.switchInput(to: $0) }
                )) {
                    ForEach(manager.audio.availableInputs) { input in
                        Text(input.name + (input.isKinect ? "  (Kinect)" : ""))
                            .tag(input.id)
                    }
                }
                .labelsHidden()

                Button("Refresh") { manager.audio.refreshInputs() }
                    .controlSize(.small)

                LabeledContent("RMS", value: String(format: "%.3f", manager.audio.rms))
                    .font(.caption)
            }
        }

        if manager.visualization == .pointCloud || manager.visualization == .voxelSculpt {
            GroupBox("Camera") {
                Text("Drag to orbit · Pinch / scroll to zoom")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
