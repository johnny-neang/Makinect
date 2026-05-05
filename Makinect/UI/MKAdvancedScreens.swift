// MKAdvancedScreens — Galaxy, Presets, MIDI, Output. All four ported from
// the Claude Design handoff. These are visual-fidelity mocks; the
// underlying systems (preset bank, MIDI mappings, multi-display routing)
// don't exist in the engine yet, so the controls operate on local mock
// state and don't persist. They prove the layout + chrome work, ready
// for the real backends to be wired in.

import SwiftUI

// MARK: - Galaxy (embedding-space scatter)

struct MKGalaxyScreen: View {
    @Bindable var manager: KinectManager
    @State private var facet: MKVizCategory? = nil
    @State private var query: String = ""

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.055, green: 0.055, blue: 0.086),
                         Color(red: 0.024, green: 0.024, blue: 0.031)],
                center: .center, startRadius: 0, endRadius: 800
            )

            // Cluster labels
            ForEach(MKGalaxy.clusters, id: \.label) { cluster in
                Text(cluster.label.uppercased())
                    .font(MK.Font.mono09)
                    .tracking(1.4)
                    .foregroundStyle(cluster.isCapstone ? MK.Color.accentWarm : MK.Color.textTertiary)
                    .position(x: cluster.x, y: cluster.y)
            }

            // Dots — one per visualizer
            ForEach(VisualizationKind.allCases) { kind in
                let dot = MKGalaxy.dotFor(kind)
                let cat = MKVizCategory.category(for: kind)
                let dim = facet != nil && facet != cat
                let active = manager.visualization == kind
                Circle()
                    .fill(MKGalaxy.color(for: cat))
                    .frame(width: dot.size, height: dot.size)
                    .shadow(color: MKGalaxy.color(for: cat), radius: dot.size * 0.6)
                    .opacity(dim ? 0.18 : 1)
                    .position(x: dot.x, y: dot.y)
                    .overlay(active ? Circle()
                        .stroke(MK.Color.accent, lineWidth: 1.5)
                        .frame(width: dot.size + 8, height: dot.size + 8)
                        .position(x: dot.x, y: dot.y) : nil)
                    .onTapGesture { manager.visualization = kind }
            }

            // Focused viz card next to the active dot
            if let active = manager.visualization {
                let dot = MKGalaxy.dotFor(active)
                MKGalaxyCard(kind: active)
                    .frame(width: 200)
                    .position(x: dot.x + 130, y: dot.y - 30)
            }

            // Top toolbar
            VStack {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(MK.Color.textTertiary)
                            .font(.system(size: 11))
                        TextField(#"Search by feel: "warm and slow"…"#, text: $query)
                            .textFieldStyle(.plain)
                            .font(MK.Font.label12)
                            .foregroundStyle(MK.Color.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 320, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))

                    facetPill("All", selected: facet == nil) { facet = nil }
                    ForEach(MKVizCategory.allCases.filter { $0 != .featured }, id: \.self) { cat in
                        facetPill(cat.label, selected: facet == cat) { facet = (facet == cat) ? nil : cat }
                    }

                    Spacer()

                    Text("Embed: CLIP-ViT · 768d → UMAP 2d")
                        .font(MK.Font.mono10)
                        .foregroundStyle(MK.Color.textTertiary)
                }
                .padding(16)
                Spacer()
            }

            // Legend (bottom-left)
            VStack {
                Spacer()
                HStack {
                    legend
                    Spacer()
                    minimap
                }
                .padding(16)
            }

            // Zoom controls (top-right under toolbar)
            VStack {
                Spacer().frame(height: 56)
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        zoomButton("+")
                        zoomButton("−")
                        zoomButton("⌂")
                    }
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .background(MK.Color.bgWindow)
        .clipped()
    }

    private func facetPill(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MK.Font.label11)
                .foregroundStyle(selected ? MK.Color.accent : MK.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? MK.Color.accentDim : Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(selected ? MK.Color.accent : MK.Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func zoomButton(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 14))
            .foregroundStyle(MK.Color.textSecondary)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(MK.Color.hairline, lineWidth: 1))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(MKVizCategory.allCases.filter { $0 != .featured }, id: \.self) { cat in
                HStack(spacing: 6) {
                    Circle().fill(MKGalaxy.color(for: cat)).frame(width: 8, height: 8)
                    Text("\(cat.label) · \(MKGalaxy.count(for: cat))")
                        .font(MK.Font.mono10)
                        .foregroundStyle(MK.Color.textSecondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))
    }

    private var minimap: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            RoundedRectangle(cornerRadius: 3)
                .fill(MK.Color.accentDim)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(MK.Color.accent, lineWidth: 1))
                .frame(width: 50, height: 35)
                .offset(x: 42, y: 27)
        }
        .frame(width: 140, height: 90)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))
    }
}

private enum MKGalaxy {
    struct Cluster { let label: String; let x: CGFloat; let y: CGFloat; let isCapstone: Bool }
    struct Dot { let x: CGFloat; let y: CGFloat; let size: CGFloat }

    // Scaled to a 1280×620 inner canvas (post-toolbar). Approximate, look-good.
    static let clusters: [Cluster] = [
        .init(label: "Volumetric ▸ Aurora", x: 250, y: 150, isCapstone: false),
        .init(label: "Optical ▸ Heat",      x: 820, y: 110, isCapstone: false),
        .init(label: "Particles ▸ Dust",    x: 380, y: 380, isCapstone: false),
        .init(label: "Surface ▸ Water",     x: 920, y: 400, isCapstone: false),
        .init(label: "Skeletal ▸ Body",     x: 620, y: 500, isCapstone: false),
        .init(label: "★ Capstone",          x: 640, y: 260, isCapstone: true)
    ]

    static func color(for cat: MKVizCategory) -> Color {
        switch cat {
        case .volumetric: return Color(red: 0.30, green: 0.65, blue: 0.95)
        case .surface:    return Color(red: 0.30, green: 0.85, blue: 0.65)
        case .optical:    return Color(red: 1.00, green: 0.55, blue: 0.30)
        case .particles:  return Color(red: 0.85, green: 0.45, blue: 0.95)
        case .skeletal:   return Color(red: 0.65, green: 0.45, blue: 0.95)
        case .capstone:   return MK.Color.accentWarm
        case .featured:   return MK.Color.accent
        }
    }

    static func count(for cat: MKVizCategory) -> Int {
        VisualizationKind.allCases.filter { MKVizCategory.category(for: $0) == cat }.count
    }

    /// Stable per-viz position around its cluster center, derived from
    /// a hash of the rawValue so it doesn't wander across launches.
    static func dotFor(_ kind: VisualizationKind) -> Dot {
        let cat = MKVizCategory.category(for: kind)
        let center: CGPoint = {
            switch cat {
            case .volumetric: return CGPoint(x: 250, y: 200)
            case .optical:    return CGPoint(x: 820, y: 160)
            case .particles:  return CGPoint(x: 380, y: 430)
            case .surface:    return CGPoint(x: 920, y: 450)
            case .skeletal:   return CGPoint(x: 620, y: 540)
            case .capstone:   return CGPoint(x: 640, y: 300)
            case .featured:   return CGPoint(x: 500, y: 350)
            }
        }()
        let h = abs(kind.rawValue.hashValue)
        let r: CGFloat = 70
        let angle = CGFloat(h % 360) * .pi / 180
        let dist = CGFloat((h / 360) % 100) / 100 * r
        let size = CGFloat(5 + (h % 6))
        return Dot(
            x: center.x + cos(angle) * dist,
            y: center.y + sin(angle) * dist,
            size: size
        )
    }
}

private struct MKGalaxyCard: View {
    let kind: VisualizationKind
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Preview gradient
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(
                    colors: [Color(hue: 0.55, saturation: 0.6, brightness: 0.85),
                             Color(hue: 0.78, saturation: 0.6, brightness: 0.45),
                             Color(red: 0.024, green: 0.024, blue: 0.031)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: 90)
            Text(kind.rawValue)
                .font(MK.Font.label12)
                .foregroundStyle(MK.Color.textPrimary)
            Text("\(MKVizCategory.category(for: kind).label.uppercased()) · k=12 NEAREST")
                .font(MK.Font.mono09).tracking(0.6)
                .foregroundStyle(MK.Color.textTertiary)
            HStack(spacing: 4) {
                Text("Preview")
                    .font(MK.Font.label10)
                    .foregroundStyle(MK.Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                Text("Send to Output ⏎")
                    .font(MK.Font.label10).bold()
                    .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(MK.Color.accent))
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(MK.Color.bgVibrancy.background(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MK.Color.accent, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 20, y: 12)
    }
}

// MARK: - Presets (bar-quantized timeline)

struct MKPresetsScreen: View {
    var body: some View {
        HStack(spacing: 0) {
            presetsList.frame(width: 240)
            timelineArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            rightDetail.frame(width: 320)
        }
        .background(MK.Color.bgWindow)
    }

    private var presetsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHead("▾ SHOWS").padding(.bottom, 6)
            presetRow("Show 1 — Daft Punk", meta: "32 BARS · 4 CUES · 124 BPM",
                      active: true, badge: "EDIT")
            presetRow("Show 2 — Aphex", meta: "64 BARS · 8 CUES")
            presetRow("Show 3 — Burial", meta: "FREE · 6 CUES")

            Rectangle().fill(MK.Color.hairline).frame(height: 1).padding(.vertical, 12)

            sectionHead("▾ SNAPSHOTS").padding(.bottom, 6)
            presetRow("Aurora · Warm",     meta: "VOLUMETRIC AURORA")
            presetRow("Aurora · Cold",     meta: "VOLUMETRIC AURORA")
            presetRow("Smoke · Inferno",   meta: "SMOKE GOD")
            presetRow("Heart · Slow",      meta: "HEART PULSE")
            presetRow("Filament · Pull",   meta: "FILAMENT COSMOLOGY")
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(MK.Color.hairline).frame(width: 1) }
    }

    private func presetRow(_ name: String, meta: String, active: Bool = false, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(MK.Font.label12).foregroundStyle(MK.Color.textPrimary)
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold)).tracking(0.6)
                        .foregroundStyle(MK.Color.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(MK.Color.accentDim))
                }
            }
            Text(meta).font(MK.Font.mono09).tracking(0.4).foregroundStyle(MK.Color.textTertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? MK.Color.accent.opacity(0.10) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? MK.Color.accentDim : Color.clear, lineWidth: 1))
    }

    private var timelineArea: some View {
        VStack(spacing: 0) {
            tToolbar.frame(height: 36)
            barsRuler.frame(height: 24)
            lanes.frame(maxHeight: .infinity)
            tBottom.frame(height: 80)
        }
    }

    private var tToolbar: some View {
        HStack(spacing: 8) {
            ghostBtn("▶ Play"); ghostBtn("⏮"); ghostBtn("⏭")
            Text("3.2.0 / 32.0.0").font(MK.Font.mono11)
                .foregroundStyle(MK.Color.textSecondary).padding(.horizontal, 12)

            HStack(spacing: 1) {
                zoomSeg("1/4", on: false); zoomSeg("1", on: true); zoomSeg("2", on: false)
                zoomSeg("4", on: false);   zoomSeg("8 bars", on: false)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(MK.Color.hairline, lineWidth: 1))

            Spacer()
            ghostBtn("Snap: ¼ note"); ghostBtn("+ Cue")
        }
        .padding(.horizontal, 12)
        .background(MK.Color.bgElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(MK.Color.hairline).frame(height: 1) }
    }

    private func ghostBtn(_ label: String) -> some View {
        Text(label)
            .font(MK.Font.label11)
            .foregroundStyle(MK.Color.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(MK.Color.hairlineStrong, lineWidth: 1))
    }

    private func zoomSeg(_ label: String, on: Bool) -> some View {
        Text(label)
            .font(MK.Font.mono10)
            .foregroundStyle(on ? MK.Color.accent : MK.Color.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? MK.Color.accentDim : Color.white.opacity(0.02))
    }

    private var barsRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 100)
            ForEach(0..<13) { i in
                let major = (i % 4 == 0)
                let label: String = {
                    switch i {
                    case 0: return "1"
                    case 4: return "5 INTRO"
                    case 8: return "9 BUILD"
                    case 12: return "13 DROP"
                    default: return "\(i + 1)"
                    }
                }()
                Text(label)
                    .font(MK.Font.mono09)
                    .foregroundStyle(major ? MK.Color.textSecondary : MK.Color.textTertiary)
                    .padding(.top, 4).padding(.leading, 4)
                    .frame(width: 60, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(major ? MK.Color.hairlineStrong : MK.Color.hairline)
                            .frame(width: 1)
                    }
            }
            Spacer(minLength: 0)
        }
        .background(MK.Color.bgElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(MK.Color.hairline).frame(height: 1) }
    }

    private var lanes: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                lane(title: "VIZ", meta: "Active layer") {
                    clip(at: 0,   width: 240, name: "Aurora · Warm", bars: "4 BARS",
                         hue: 0.55, opacity: 1)
                    clip(at: 240, width: 240, name: "Aurora · Cold", bars: "4 BARS · XFADE 8",
                         hue: 0.55, opacity: 0.7)
                    clip(at: 480, width: 300, name: "Smoke God", bars: "5 BARS",
                         hue: 0.07, opacity: 1)
                }
                lane(title: "CC74", meta: "Drop magnitude") {
                    autoLine(points: [(0,0.7),(60,0.7),(120,0.7),(180,0.7),(240,0.5),
                                      (300,0.25),(360,0.13),(420,0.04),(480,0.04),
                                      (540,0.5),(600,0.7),(660,0.7),(720,0.7)],
                             color: MK.Color.accentWarm)
                }
                lane(title: "HUE A", meta: "0 → 1") {
                    autoLine(points: [(0,0.5),(240,0.5),(240,0.25),(480,0.25),
                                      (480,0.7),(720,0.7)],
                             color: MK.Color.accent)
                }
                lane(title: "CUES", meta: "Markers") {
                    cueLabel("A · Warm Up", at: 0)
                    cueLabel("B · Build", at: 240)
                    cueLabel("C · Drop ★", at: 480)
                    cueLabel("D · Outro", at: 600)
                }
            }
            // Section backgrounds
            sectionBG(at: 100,  width: 240, color: MK.Color.accent)
            sectionBG(at: 340,  width: 240, color: MK.Color.accentWarm)
            sectionBG(at: 580,  width: 200, color: MK.Color.danger)

            // Playhead
            Rectangle()
                .fill(MK.Color.accent)
                .frame(width: 2)
                .shadow(color: MK.Color.accent, radius: 6)
                .offset(x: 230)
                .frame(maxHeight: .infinity)
        }
        .clipped()
    }

    private func lane<Content: View>(title: String, meta: String,
                                     @ViewBuilder _ tracks: () -> Content) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MK.Font.label11).foregroundStyle(MK.Color.textPrimary)
                Text(meta).font(MK.Font.mono09).foregroundStyle(MK.Color.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(width: 100, height: 56, alignment: .leading)
            .background(MK.Color.bgElevated)
            .overlay(alignment: .trailing) {
                Rectangle().fill(MK.Color.hairline).frame(width: 1)
            }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .background(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.99),
                                    .init(color: MK.Color.hairline, location: 1.0)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: Rectangle()
                    )
                tracks()
            }
            .frame(maxWidth: .infinity, maxHeight: 56, alignment: .topLeading)
        }
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(MK.Color.hairline).frame(height: 1) }
    }

    private func clip(at x: CGFloat, width: CGFloat, name: String, bars: String,
                      hue: Double, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Text(bars).font(MK.Font.mono09).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: width, height: 40, alignment: .topLeading)
        .background(LinearGradient(
            colors: [Color(hue: hue, saturation: 0.6, brightness: 0.55),
                     Color(hue: hue + 0.15, saturation: 0.6, brightness: 0.40)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(opacity)
        .offset(x: x, y: 8)
    }

    private func autoLine(points: [(CGFloat, CGFloat)], color: Color) -> some View {
        GeometryReader { geo in
            Path { p in
                guard let first = points.first else { return }
                let h = geo.size.height
                let yFor = { (v: CGFloat) -> CGFloat in (1 - v) * (h - 12) + 6 }
                p.move(to: CGPoint(x: first.0, y: yFor(first.1)))
                for pt in points.dropFirst() {
                    p.addLine(to: CGPoint(x: pt.0, y: yFor(pt.1)))
                }
            }
            .stroke(color, lineWidth: 1.5)

            ForEach(0..<points.count, id: \.self) { i in
                let pt = points[i]
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .position(x: pt.0, y: (1 - pt.1) * (geo.size.height - 12) + 6)
            }
        }
    }

    private func cueLabel(_ text: String, at x: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold)).tracking(0.6)
            .foregroundStyle(Color(red: 0.10, green: 0.05, blue: 0))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(MK.Color.accentWarm)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .offset(x: x, y: 0)
    }

    private func sectionBG(at x: CGFloat, width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .opacity(0.06)
            .frame(width: width)
            .offset(x: x)
            .frame(maxHeight: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }

    private var tBottom: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("▾ AUDIO ANALYSIS · daft-punk-set.wav")
                    .font(MK.Font.mono09).tracking(0.8)
                    .foregroundStyle(MK.Color.textTertiary)
                HStack(spacing: 1) {
                    ForEach(0..<48, id: \.self) { i in
                        let h = CGFloat([0.40, 0.50, 0.35, 0.60, 0.45, 0.55, 0.30, 0.50,
                                          0.65, 0.40, 0.70, 0.50, 0.75, 0.80, 0.90, 0.95,
                                          0.85, 0.78, 0.65, 0.55][i % 20])
                        Rectangle()
                            .fill(MK.Color.textTertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: h * 50)
                    }
                }
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        sectionTag("INTRO", color: MK.Color.accent)
                            .frame(width: geo.size.width * 0.30)
                        sectionTag("BUILD", color: MK.Color.accentWarm)
                            .frame(width: geo.size.width * 0.30)
                        sectionTag("DROP", color: MK.Color.danger)
                            .frame(width: geo.size.width * 0.25)
                        sectionTag("OUTRO", color: MK.Color.magenta)
                            .frame(width: geo.size.width * 0.15)
                    }
                }
                .frame(height: 14)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MK.Color.bgElevated)
        }
        .overlay(alignment: .top) { Rectangle().fill(MK.Color.hairline).frame(height: 1) }
    }

    private var rightDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHead("▾ SELECTION").padding(.bottom, 4)
            Text("Aurora · Warm → Cold")
                .font(MK.Font.title16).foregroundStyle(MK.Color.textPrimary)
            Text("CROSSFADE · BAR 9.1 → 13.1")
                .font(MK.Font.mono09).tracking(0.6)
                .foregroundStyle(MK.Color.textTertiary)
                .padding(.bottom, 14)

            mockSlider(label: "Crossfade Length", value: "4 bars", frac: 0.5)
            mockSlider(label: "Curve",            value: "ease-in-out", frac: 0.5,
                       tint: MK.Color.accentWarm)
            mockSlider(label: "Quantize to",      value: "Bar", frac: 0.5)

            Rectangle().fill(MK.Color.hairline).frame(height: 1).padding(.vertical, 14)

            sectionHead("▾ AI SUGGESTIONS").padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 6) {
                (Text("\"At bar 13 the snare drops out. Lower hue temp by ")
                 + Text("0.3").foregroundColor(MK.Color.accent).bold()
                 + Text(" for emotional contrast?\""))
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textSecondary)
                HStack(spacing: 6) {
                    kbdTag("Apply"); kbdTag("Dismiss")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(MK.Color.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(MK.Color.accentDim, lineWidth: 1))

            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .leading) { Rectangle().fill(MK.Color.hairline).frame(width: 1) }
    }
}

// Helpers shared by Presets / MIDI / Output

@ViewBuilder
private func sectionHead(_ label: String) -> some View {
    Text(label)
        .font(MK.Font.label09).tracking(0.8)
        .foregroundStyle(MK.Color.textSecondary)
}

@ViewBuilder
private func mockSlider(label: String, value: String, frac: CGFloat,
                        tint: Color = MK.Color.accent) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text(label).font(MK.Font.label11).foregroundStyle(MK.Color.textSecondary)
            Spacer()
            Text(value).font(MK.Font.mono10).foregroundStyle(MK.Color.textPrimary)
        }
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint).frame(width: geo.size.width * frac)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .offset(x: geo.size.width * frac - 7)
            }
            .frame(height: 4)
        }
        .frame(height: 16)
    }
    .padding(.bottom, 10)
}

@ViewBuilder
private func kbdTag(_ label: String) -> some View {
    Text(label)
        .font(MK.Font.mono10)
        .foregroundStyle(MK.Color.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(MK.Color.hairline, lineWidth: 1))
}

@ViewBuilder
private func sectionTag(_ label: String, color: Color) -> some View {
    Text(label)
        .font(.system(size: 8, weight: .bold)).tracking(0.6)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color)
}
