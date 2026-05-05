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

                // Permission banner — visible until the user grants mic
                // access. Mirrors the affordances exposed in the existing
                // SidePanel + AudioMonitorView so we don't drift.
                if manager.audio.permission != .authorized {
                    permissionBanner
                }

                // Audio device picker (with empty-state fallback)
                VStack(alignment: .leading, spacing: 8) {
                    Text("INPUT DEVICE")
                        .font(MK.Font.label09).tracking(0.8)
                        .foregroundStyle(MK.Color.textTertiary)
                    if manager.audio.availableInputs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No audio inputs detected.")
                                .font(MK.Font.label11)
                                .foregroundStyle(MK.Color.textPrimary)
                            Text("Plug in a USB mic or check System Settings → Privacy → Microphone.")
                                .font(MK.Font.label11)
                                .foregroundStyle(MK.Color.textSecondary)
                            Button { manager.audio.refreshInputs() } label: {
                                Text("Rescan inputs")
                                    .font(MK.Font.label11)
                                    .foregroundStyle(MK.Color.accent)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(MK.Color.accentDim))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.bgElevated))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))
                    } else {
                        HStack(spacing: 8) {
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

                            Button { manager.audio.refreshInputs() } label: {
                                Text("Refresh")
                                    .font(MK.Font.label11)
                                    .foregroundStyle(MK.Color.textSecondary)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.white.opacity(0.04)))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .stroke(MK.Color.hairlineStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
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

    private var permissionBanner: some View {
        let perm = manager.audio.permission
        let pipColor: Color = (perm == .denied) ? MK.Color.danger : MK.Color.accentWarm

        return HStack(alignment: .top, spacing: 12) {
            MKPip(color: pipColor)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Microphone — \(perm.rawValue)")
                    .font(MK.Font.label12)
                    .foregroundStyle(MK.Color.textPrimary)
                Text("Audio reactivity needs mic access. Without it, the engine sees silence and visualizers stop reacting.")
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textSecondary)
                HStack(spacing: 8) {
                    if perm == .undetermined || perm == .requesting {
                        Button { manager.audio.requestPermission() } label: {
                            Text("Request access")
                                .font(MK.Font.label11).bold()
                                .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(MK.Color.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { manager.audio.openMicrophoneSettings() } label: {
                        Text("Open System Settings")
                            .font(MK.Font.label11)
                            .foregroundStyle(MK.Color.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(MK.Color.hairlineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(MK.Color.accentWarm.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(MK.Color.accentWarm.opacity(0.3), lineWidth: 1))
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
                    VStack(alignment: .leading, spacing: 10) {
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

                        // Real action buttons — finally surfaces the
                        // connect lifecycle outside SidePanel's full mode.
                        HStack(spacing: 8) {
                            Button {
                                if manager.isConnected { manager.disconnect() }
                                else                   { manager.connect() }
                            } label: {
                                Text(manager.isConnected ? "Disconnect" : "Connect")
                                    .font(MK.Font.label11).bold()
                                    .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(MK.Color.accent))
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.source == .synthetic)

                            Button { manager.scanForDevices() } label: {
                                Text("Rescan USB")
                                    .font(MK.Font.label11)
                                    .foregroundStyle(MK.Color.textPrimary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.white.opacity(0.04)))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .stroke(MK.Color.hairlineStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
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

