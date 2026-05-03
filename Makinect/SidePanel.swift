// SidePanel — Sidebar with connection controls, stream mode picker, and adjustable parameters

import SwiftUI

struct SidePanel: View {
    @Bindable var manager: KinectManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Connection
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

            // Stream mode
            GroupBox("Stream Mode") {
                Picker("Mode", selection: $manager.cameraMode) {
                    ForEach(CameraMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Skeleton toggle (visible in RGB and Skeleton modes)
            if manager.cameraMode == .rgb || manager.cameraMode == .skeleton {
                GroupBox("Pose Detection") {
                    Toggle("Show Skeleton Overlay", isOn: $manager.showSkeleton)
                }
            }

            // Depth segmentation controls (visible in Segmented mode)
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

            Spacer()

            // Status
            Text(manager.statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}
