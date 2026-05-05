// MKPerformanceView — live cockpit. Hero canvas, floating glass HUDs, scene
// bar, NOW PLAYING card, kinect skeleton mini, beat grid, transport bar.

import SwiftUI

struct MKPerformanceView: View {
    @Bindable var manager: KinectManager
    @Bindable var app: MKAppState

    var body: some View {
        VStack(spacing: 0) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
                .frame(height: MK.Metrics.transportPerfHeight)
        }
    }

    private var canvas: some View {
        ZStack {
            // Hero visualization
            Group {
                if let viz = manager.visualization {
                    MetalKinectView(manager: manager, kind: viz)
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.30, green: 0.55, blue: 0.85),
                            Color(red: 0.20, green: 0.20, blue: 0.50),
                            Color(red: 0.02, green: 0.02, blue: 0.03)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }

            // Cyan scanline along the top of the canvas (signature design accent)
            VStack {
                Rectangle()
                    .fill(MK.Color.accent)
                    .frame(height: 1)
                    .shadow(color: MK.Color.accent, radius: 6)
                    .opacity(0.7)
                Spacer()
            }
            .allowsHitTesting(false)

            // Top-left HUD pills
            VStack {
                HStack(alignment: .top) {
                    perfHud
                    Spacer()
                }
                Spacer()
            }
            .padding(12)

            // NOW PLAYING — top-right
            VStack {
                HStack {
                    Spacer()
                    nowPlaying
                        .frame(width: 300)
                }
                Spacer()
            }
            .padding(12)

            // Scene bar — beneath the HUD
            VStack {
                Spacer().frame(height: 60)
                sceneBar.padding(.horizontal, 12)
                Spacer()
            }

            // Kinect skeleton mini — bottom-left, above beat grid
            VStack {
                Spacer()
                HStack {
                    kinectMini
                        .frame(width: 180, height: 100)
                    Spacer()
                }
                Spacer().frame(height: 80)  // leave room for beat grid
            }
            .padding(.horizontal, 12)

            // Beat grid — bottom
            VStack {
                Spacer()
                beatGrid.frame(height: 44)
            }
            .padding(12)

            // Panic flash
            if app.isPanicking {
                Color.black.transition(.opacity)
            }
        }
        .background(Color.black)
    }

    // MARK: - HUD pills

    private var perfHud: some View {
        HStack(spacing: 8) {
            MKHudPill(tone: .live) {
                MKPip(color: MK.Color.success)
                Text("LIVE")
            }
            MKHudPill {
                Text(String(format: "%.1f", manager.resourceMonitor.fps)).foregroundStyle(MK.Color.textPrimary)
                Text("fps")
            }
            MKHudPill(tone: .warm) {
                Text("BPM")
                Text(currentBPMString).foregroundStyle(MK.Color.accentWarm).bold()
            }
            MKHudPill {
                Text("CPU")
                Text("\(Int(manager.resourceMonitor.cpuPercent / max(1, manager.resourceMonitor.coreCount)))%")
                    .foregroundStyle(MK.Color.textPrimary)
            }
        }
    }

    // MARK: - Scene bar (8 slots — first 8 viz)

    private var sceneBar: some View {
        let kinds = Array(VisualizationKind.allCases.prefix(8))
        return MKGlass(radius: 8) {
            HStack(spacing: 4) {
                ForEach(Array(kinds.enumerated()), id: \.element) { idx, kind in
                    scenePad(idx: idx, kind: kind)
                }
            }
            .padding(6)
        }
        .frame(height: 56)
    }

    private func scenePad(idx: Int, kind: VisualizationKind) -> some View {
        let live = manager.visualization == kind
        let armed = app.armedKind == kind

        return Button {
            if live {
                // already live — no-op
            } else if armed {
                manager.visualization = kind
                app.armedKind = nil
            } else if app.armedKind == nil {
                app.armedKind = kind
            } else {
                // re-arm a different scene
                app.armedKind = kind
            }
        } label: {
            VStack(spacing: 2) {
                Text("⌃\(idx + 1)")
                    .font(MK.Font.mono09)
                    .foregroundStyle(live ? Color(red: 0, green: 0.06, blue: 0.09)
                                          : (armed ? MK.Color.accentWarm : MK.Color.textTertiary))
                    .opacity(live ? 0.6 : 1)
                Text(kind.rawValue.replacingOccurrences(of: " ", with: " "))
                    .font(MK.Font.label10)
                    .foregroundStyle(live ? Color(red: 0, green: 0.06, blue: 0.09)
                                          : (armed ? MK.Color.accentWarm : MK.Color.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(live ? MK.Color.accent
                              : (armed ? MK.Color.accentWarm.opacity(0.15)
                                       : Color.white.opacity(0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(armed ? MK.Color.accentWarm : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - NOW PLAYING

    private var nowPlaying: some View {
        MKGlass(radius: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("▾ NOW PLAYING")
                    .font(MK.Font.label09)
                    .tracking(1.4)
                    .foregroundStyle(MK.Color.textTertiary)
                Text(manager.visualization?.rawValue ?? "—")
                    .font(MK.Font.title18)
                    .foregroundStyle(MK.Color.textPrimary)
                    .padding(.bottom, 4)

                // Universal common params — Audio, Speed, Hue
                MKKnobRow(
                    label: "Audio",
                    value: Double(manager.common.audioReactivity),
                    formatted: String(format: "%.2f", manager.common.audioReactivity),
                    range: 0...1.5,
                    onChange: { manager.common.audioReactivity = Float($0) }
                )
                MKKnobRow(
                    label: "Speed",
                    value: Double(manager.common.speedMul),
                    formatted: String(format: "%.2fx", manager.common.speedMul),
                    range: 0...3,
                    tint: MK.Color.accentWarm,
                    onChange: { manager.common.speedMul = Float($0) }
                )
                MKKnobRow(
                    label: "Hue Shift",
                    value: Double(manager.common.hueShift) + 0.5,
                    formatted: String(format: "%+.2f", manager.common.hueShift),
                    range: 0...1,
                    tint: MK.Color.magenta,
                    midiTag: "CC74",
                    onChange: { manager.common.hueShift = Float($0) - 0.5 }
                )
            }
            .padding(14)
        }
    }

    // MARK: - Kinect skeleton mini

    private var kinectMini: some View {
        MKGlass(radius: 6) {
            ZStack(alignment: .topLeading) {
                MKSkeletonMini(skeletons: manager.poseDetector.skeletons)
                    .padding(.top, 14)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                HStack {
                    Text("KINECT 1")
                        .font(MK.Font.mono09)
                        .tracking(1.4)
                        .foregroundStyle(MK.Color.textTertiary)
                    Spacer()
                    Text(manager.isConnected ? "● 30 fps" : "● idle")
                        .font(MK.Font.mono09)
                        .foregroundStyle(manager.isConnected ? MK.Color.success : MK.Color.textTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Beat grid

    private var beatGrid: some View {
        MKGlass(radius: 6) {
            HStack(spacing: 2) {
                ForEach(0..<16) { i in
                    let isDownbeat = (i % 4 == 0)
                    let isNow = i == nowBeatIndex
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isNow ? MK.Color.accent
                                       : (isDownbeat ? MK.Color.accent.opacity(0.12)
                                                    : Color.white.opacity(0.04)))
                        Text(isDownbeat ? "\(i / 4 + 1)" : "\(i % 4 + 1)")
                            .font(MK.Font.mono09)
                            .foregroundStyle(isNow ? Color(red: 0, green: 0.06, blue: 0.09)
                                                  : (isDownbeat ? MK.Color.accent : MK.Color.textTertiary))
                            .padding(.bottom, 3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: isNow ? MK.Color.accent : .clear, radius: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Transport (bottom 60pt)

    private var transport: some View {
        HStack(spacing: 16) {
            // TAP
            Button { app.tap() } label: {
                Text("TAP ⌥T")
                    .font(MK.Font.label12).bold()
                    .foregroundStyle(Color(red: 0.10, green: 0.05, blue: 0))
                    .frame(width: 80, height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.accentWarm))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: .option)

            // BPM
            VStack(alignment: .leading, spacing: 2) {
                Text("BPM")
                    .font(MK.Font.label09).tracking(1.0)
                    .foregroundStyle(MK.Color.textTertiary)
                Text(currentBPMString)
                    .font(MK.Font.mono22)
                    .foregroundStyle(MK.Color.textPrimary)
            }

            // BAR.BEAT
            VStack(alignment: .leading, spacing: 2) {
                Text("BAR.BEAT")
                    .font(MK.Font.label09).tracking(1.0)
                    .foregroundStyle(MK.Color.textTertiary)
                Text(barBeatString).font(MK.Font.mono14).foregroundStyle(MK.Color.textPrimary)
            }

            // Audio meter + LUFS
            HStack(spacing: 8) {
                MKBarMeter(bands: manager.audio.bands)
                Text(String(format: "%.1f LUFS", manager.audio.lufs))
                    .font(MK.Font.mono11)
                    .foregroundStyle(MK.Color.textSecondary)
            }

            // AI Assist (placeholder — surface real recommendations later)
            VStack(alignment: .leading, spacing: 3) {
                Text("▾ AI ASSIST")
                    .font(MK.Font.label09).tracking(1.0)
                    .foregroundStyle(MK.Color.accent)
                Text(aiAssistMessage)
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.accentDim, lineWidth: 1))

            Spacer()

            Button { app.firePanic() } label: {
                Text("PANIC ESC")
                    .font(MK.Font.label11).bold()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(MK.Color.danger)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.danger, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(MK.Color.bgWindow)
        .overlay(alignment: .top) {
            Rectangle().fill(MK.Color.hairline).frame(height: 1)
        }
    }

    // MARK: - Derived state

    private var currentBPMString: String {
        let v: Float
        if app.hasManualBPM { v = app.manualBPM }
        else if manager.audio.bpm > 1 { v = manager.audio.bpm }
        else { v = 124.0 }
        return String(format: "%.1f", v)
    }

    private var nowBeatIndex: Int {
        let bpm = max(20, Double(app.hasManualBPM ? app.manualBPM
                                                  : (manager.audio.bpm > 1 ? manager.audio.bpm : 124.0)))
        let beatSec = 60.0 / bpm
        let phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: beatSec * 16)
        return Int(phase / beatSec) % 16
    }

    private var barBeatString: String {
        let i = nowBeatIndex
        return "\(i / 4 + 1).\(i % 4 + 1)"
    }

    private var aiAssistMessage: String {
        if manager.audio.onset {
            return "Onset · raise drop intensity"
        }
        if manager.audio.bpm > 1 {
            return "Tempo locked · \(String(format: "%.1f", manager.audio.bpm)) BPM"
        }
        return "Listening for beat…"
    }
}

// MARK: - Mini skeleton overlay

private struct MKSkeletonMini: View {
    let skeletons: [DetectedSkeleton]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let s = skeletons.first {
                    let pts = s.joints.compactMap { joint -> CGPoint? in
                        guard joint.confidence > 0.2 else { return nil }
                        return CGPoint(
                            x: joint.position.x * geo.size.width,
                            y: (1 - joint.position.y) * geo.size.height
                        )
                    }
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        Circle().fill(MK.Color.accent).frame(width: 4, height: 4).position(p)
                    }
                } else {
                    // Static silhouette stand-in
                    Path { p in
                        let w = geo.size.width, h = geo.size.height
                        // Head
                        p.addEllipse(in: CGRect(x: w*0.5 - 3, y: h*0.18, width: 6, height: 6))
                        // Spine
                        p.move(to: CGPoint(x: w*0.5, y: h*0.26))
                        p.addLine(to: CGPoint(x: w*0.5, y: h*0.62))
                        // Shoulders
                        p.move(to: CGPoint(x: w*0.32, y: h*0.34))
                        p.addLine(to: CGPoint(x: w*0.68, y: h*0.34))
                        // Arms
                        p.move(to: CGPoint(x: w*0.32, y: h*0.34))
                        p.addLine(to: CGPoint(x: w*0.22, y: h*0.55))
                        p.move(to: CGPoint(x: w*0.68, y: h*0.34))
                        p.addLine(to: CGPoint(x: w*0.78, y: h*0.55))
                        // Legs
                        p.move(to: CGPoint(x: w*0.5, y: h*0.62))
                        p.addLine(to: CGPoint(x: w*0.4, y: h*0.92))
                        p.move(to: CGPoint(x: w*0.5, y: h*0.62))
                        p.addLine(to: CGPoint(x: w*0.6, y: h*0.92))
                    }
                    .stroke(MK.Color.accent.opacity(0.7), lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - Audio meter (bar series)

struct MKBarMeter: View {
    let bands: [Float]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<min(bands.count, 8), id: \.self) { i in
                let h = max(2, CGFloat(min(1, bands[i] * 1.2)) * 22)
                Capsule()
                    .fill(MK.Color.accent)
                    .frame(width: 2, height: h)
            }
        }
        .frame(height: 22)
    }
}
