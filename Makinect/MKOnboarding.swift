// MKOnboarding — first-run coach mark. Shown over the entire shell
// until the user has completed (or skipped) the three-step flow.
// Dismissal flips app.didOnboard, which persists so the overlay
// doesn't reappear on subsequent launches.
//
// Three minimal steps:
//   1. Allow microphone — needed for audio reactivity. Skippable.
//   2. Connect Kinect — or skip into Synthetic source. Either path
//      gets the user to a working visualization.
//   3. Done — reveal the live UI.

import SwiftUI

struct MKOnboardingOverlay: View {
    @Bindable var manager: KinectManager
    @Bindable var app: MKAppState

    @State private var step: Int = 0     // 0..2

    var body: some View {
        ZStack {
            // Scrim — clicks pass through to nothing; the cards are
            // the only interactive surface during onboarding.
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                Text("Welcome to Makinect")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(MK.Color.textPrimary)
                Text("Audio-reactive visuals for live shows. Three quick checks before you start.")
                    .font(MK.Font.label12)
                    .foregroundStyle(MK.Color.textSecondary)
                    .frame(maxWidth: 480, alignment: .center)
                    .multilineTextAlignment(.center)

                Group {
                    switch step {
                    case 0: micCard
                    case 1: kinectCard
                    default: doneCard
                    }
                }

                progressDots
                Spacer()
            }
            .frame(maxWidth: 560)
            .padding(40)
        }
        .transition(.opacity)
    }

    // MARK: - Step cards

    private var micCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                stepHeader("01", "Microphone access")
                Text("Visualizers respond to RMS, pitch, BPM, and onsets — the audio engine needs the mic to do that. We never record or transmit audio.")
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textSecondary)
                statusLine(
                    color: manager.audio.permission == .authorized ? MK.Color.success
                         : manager.audio.permission == .denied      ? MK.Color.danger
                         : MK.Color.accentWarm,
                    text: "Permission: \(manager.audio.permission.rawValue)"
                )
                HStack(spacing: 8) {
                    if manager.audio.permission != .authorized {
                        primaryButton(manager.audio.permission == .denied
                                      ? "Open System Settings"
                                      : "Allow microphone") {
                            if manager.audio.permission == .denied {
                                manager.audio.openMicrophoneSettings()
                            } else {
                                manager.audio.requestPermission()
                            }
                        }
                    }
                    secondaryButton(manager.audio.permission == .authorized
                                    ? "Continue →" : "Skip →") {
                        step = 1
                    }
                }
            }
        }
    }

    private var kinectCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                stepHeader("02", "Stream source")
                Text("Pick where pixels come from. Kinect uses a connected sensor for depth + skeleton tracking. Synthetic runs procedural compute kernels — no hardware needed.")
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textSecondary)
                statusLine(
                    color: manager.isConnected ? MK.Color.success
                         : (manager.source == .synthetic ? MK.Color.accent : MK.Color.textTertiary),
                    text: manager.source == .synthetic
                        ? "Synthetic source · ready"
                        : (manager.isConnected ? "Kinect connected" : "Kinect: \(manager.statusMessage)")
                )
                HStack(spacing: 8) {
                    if manager.source == .kinect {
                        primaryButton(manager.isConnected ? "Continue →" : "Connect Kinect") {
                            if manager.isConnected { step = 2 }
                            else                   { manager.connect() }
                        }
                        secondaryButton("Skip — use Synthetic") {
                            manager.source = .synthetic
                            if manager.visualization == nil {
                                manager.visualization = .volumetricAurora
                            }
                            step = 2
                        }
                    } else {
                        primaryButton("Continue →") { step = 2 }
                        secondaryButton("Switch to Kinect") {
                            manager.source = .kinect
                        }
                    }
                }
            }
        }
    }

    private var doneCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                stepHeader("03", "You're set")
                Text("Performance is the entry tab. Click any scene pad to arm it, click again to commit. Tap-tempo with ⌥T. Panic with Esc. Press ⌘L to browse the 38-viz library.")
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textSecondary)
                Text("⌘1–⌘8 swap tabs · ⌃1–⌃8 fire scenes · ⌘S saves a snapshot")
                    .font(MK.Font.mono09)
                    .foregroundStyle(MK.Color.textTertiary)
                HStack(spacing: 8) {
                    primaryButton("Start visualizing") {
                        // Land them in Performance with a viz running.
                        if manager.visualization == nil {
                            manager.visualization = .volumetricAurora
                        }
                        app.tab = .performance
                        app.didOnboard = true
                    }
                    secondaryButton("Back") { step = 1 }
                }
            }
        }
    }

    // MARK: - Atoms

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(24)
            .frame(maxWidth: 480, alignment: .leading)
            .background(MK.Color.bgVibrancy.background(.ultraThinMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MK.Color.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 16)
    }

    private func stepHeader(_ num: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(num)
                .font(MK.Font.mono09)
                .tracking(1.4)
                .foregroundStyle(MK.Color.accent)
            Text(title)
                .font(MK.Font.title16)
                .foregroundStyle(MK.Color.textPrimary)
        }
    }

    private func statusLine(color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            MKPip(color: color)
            Text(text)
                .font(MK.Font.label11)
                .foregroundStyle(MK.Color.textPrimary)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MK.Font.label12).bold()
                .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.accent))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MK.Font.label12)
                .foregroundStyle(MK.Color.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(i == step ? MK.Color.accent : MK.Color.textTertiary)
                    .frame(width: 8, height: 8)
            }
        }
    }
}
