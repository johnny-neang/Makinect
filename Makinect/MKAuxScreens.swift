// MKAuxScreens — Audio (full DSP monitor + device picker) and Settings
// (Stream Mode + Depth Range + Kinect device + ResourceMonitor) screens.

import SwiftUI
import CoreAudio

// MARK: - Audio

struct MKAudioScreen: View {
    @Bindable var manager: KinectManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Audio Monitor")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(MK.Color.textPrimary)
                Text("Live DSP — waveform, 8-band FFT, spectrogram, pitch / chord / key / BPM, RMS + LUFS, onsets.")
                    .font(MK.Font.label12)
                    .foregroundStyle(MK.Color.textSecondary)

                // Audio device picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("INPUT DEVICE")
                        .font(MK.Font.label09).tracking(0.8)
                        .foregroundStyle(MK.Color.textTertiary)
                    Picker("", selection: Binding(
                        get: { manager.audio.selectedInputID ?? AudioDeviceID(0) },
                        set: { manager.audio.switchInput(to: $0) }
                    )) {
                        ForEach(manager.audio.availableInputs) { dev in
                            Text(dev.name).tag(dev.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(MK.Color.accent)
                }

                Rectangle().fill(MK.Color.hairline).frame(height: 1)

                AudioMonitorView(audio: manager.audio)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(MK.Color.bgElevated))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MK.Color.hairline, lineWidth: 1))
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MK.Color.bgWindow)
    }
}

// MARK: - Settings

struct MKSettingsScreen: View {
    @Bindable var manager: KinectManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(MK.Color.textPrimary)

                // Stream Mode
                MKSettingsCard(title: "STREAM MODE") {
                    Picker("", selection: Binding(
                        get: { manager.source },
                        set: { manager.source = $0 }
                    )) {
                        ForEach(InputSource.allCases) { src in
                            Text(src.rawValue).tag(src)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Depth Range
                MKSettingsCard(title: "DEPTH RANGE (mm)") {
                    VStack(alignment: .leading, spacing: 12) {
                        MKKnobRow(
                            label: "Near",
                            value: Double(manager.segmentationNearMM),
                            formatted: "\(Int(manager.segmentationNearMM))",
                            range: 0...4500,
                            onChange: { manager.segmentationNearMM = Float($0) }
                        )
                        MKKnobRow(
                            label: "Far",
                            value: Double(manager.segmentationFarMM),
                            formatted: "\(Int(manager.segmentationFarMM))",
                            range: 0...4500,
                            tint: MK.Color.accentWarm,
                            onChange: { manager.segmentationFarMM = Float($0) }
                        )
                    }
                }

                // Kinect device
                MKSettingsCard(title: "KINECT DEVICE") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            MKPip(color: manager.isConnected ? MK.Color.success : MK.Color.textTertiary)
                            Text(manager.isConnected ? "Connected" : "Disconnected")
                                .font(MK.Font.label12)
                                .foregroundStyle(MK.Color.textPrimary)
                        }
                        if let serial = manager.serialNumber {
                            Text("Serial: \(serial)")
                                .font(MK.Font.mono10)
                                .foregroundStyle(MK.Color.textTertiary)
                        }
                        if let fw = manager.firmwareVersion {
                            Text("Firmware: \(fw)")
                                .font(MK.Font.mono10)
                                .foregroundStyle(MK.Color.textTertiary)
                        }
                        Text(manager.statusMessage)
                            .font(MK.Font.label11)
                            .foregroundStyle(MK.Color.textSecondary)
                    }
                }

                // Resource monitor
                MKSettingsCard(title: "SYSTEM") {
                    ResourceMonitorView(monitor: manager.resourceMonitor)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MK.Color.bgWindow)
    }
}

private struct MKSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MK.Font.label09).tracking(0.8)
                .foregroundStyle(MK.Color.textSecondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MK.Color.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MK.Color.hairline, lineWidth: 1))
    }
}

