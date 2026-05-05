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
    @Bindable var app: MKAppState
    @State private var facet: MKVizCategory? = nil
    @State private var query: String = ""
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.055, green: 0.055, blue: 0.086),
                             Color(red: 0.024, green: 0.024, blue: 0.031)],
                    center: .center, startRadius: 0, endRadius: max(size.width, size.height)
                )

                // Zoomable scatter — clusters + dots + active card all
                // share the same scaleEffect so they pan together. The
                // toolbar / legend / minimap stay outside the transform.
                ZStack {
                    // Cluster labels
                    ForEach(MKGalaxy.clusters, id: \.label) { cluster in
                        Text(cluster.label.uppercased())
                            .font(MK.Font.mono09)
                            .tracking(1.4)
                            .foregroundStyle(cluster.isCapstone ? MK.Color.accentWarm : MK.Color.textTertiary)
                            .position(x: size.width * cluster.fx,
                                      y: size.height * cluster.fy)
                    }

                    // Dots — one per visualizer
                    ForEach(VisualizationKind.allCases) { kind in
                        let dot = MKGalaxy.dotFor(kind, size: size)
                        let cat = MKVizCategory.category(for: kind)
                        let dim = facet != nil && facet != cat
                        let queryMatches = query.isEmpty
                            || kind.rawValue.localizedCaseInsensitiveContains(query)
                            || cat.label.localizedCaseInsensitiveContains(query)
                        let visualOpacity = (dim || !queryMatches) ? 0.18 : 1.0
                        let active = manager.visualization == kind

                        Circle()
                            .fill(MKGalaxy.color(for: cat))
                            .frame(width: dot.size, height: dot.size)
                            .shadow(color: MKGalaxy.color(for: cat), radius: dot.size * 0.6)
                            .opacity(visualOpacity)
                            .position(x: dot.x, y: dot.y)
                            .overlay(active ? Circle()
                                .stroke(MK.Color.accent, lineWidth: 1.5)
                                .frame(width: dot.size + 8, height: dot.size + 8)
                                .position(x: dot.x, y: dot.y) : nil)
                            .onTapGesture { manager.visualization = kind }
                    }

                    // Focused viz card next to the active dot. Card
                    // position is normalized; +130/-30 offset is replaced
                    // by a clamped fractional shift so it never overflows
                    // the canvas at small window sizes.
                    if let active = manager.visualization {
                        let dot = MKGalaxy.dotFor(active, size: size)
                        let cardX = min(size.width - 110, dot.x + 130)
                        let cardY = max(120, dot.y - 30)
                        MKGalaxyCard(kind: active) {
                            // Preview — set it active without leaving Galaxy.
                            manager.visualization = active
                        } onSendToOutput: {
                            manager.visualization = active
                            app.tab = .performance
                        }
                        .frame(width: 200)
                        .position(x: cardX, y: cardY)
                    }
                }
                .scaleEffect(zoom, anchor: .center)
                .animation(.easeInOut(duration: 0.18), value: zoom)

                // Top toolbar
                VStack {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(MK.Color.textTertiary)
                                .font(.system(size: 11))
                            TextField(#"Search: "Aurora", "Volumetric", "warm"…"#, text: $query)
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

                // Legend (bottom-left) + minimap (bottom-right)
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
                            zoomButton("+") { zoom = min(zoom * 1.25, 4.0) }
                            zoomButton("−") { zoom = max(zoom / 1.25, 0.5) }
                            zoomButton("⌂") { zoom = 1.0 }
                        }
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
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

    private func zoomButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(MK.Color.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(MK.Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
            // Viewport rect tracks the zoom — at 1× it covers the full
            // minimap, at 2× it shrinks to a quarter, etc.
            let vpScale = 1.0 / max(0.5, zoom)
            RoundedRectangle(cornerRadius: 3)
                .fill(MK.Color.accentDim)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(MK.Color.accent, lineWidth: 1))
                .frame(width: 140 * vpScale, height: 90 * vpScale)
                .offset(x: (140 - 140 * vpScale) / 2,
                        y: (90 - 90 * vpScale) / 2)
        }
        .frame(width: 140, height: 90)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))
    }
}

private enum MKGalaxy {
    /// Fractional cluster center — multiplied by the canvas size at draw
    /// time so the layout reflows as the window resizes.
    struct Cluster { let label: String; let fx: CGFloat; let fy: CGFloat; let isCapstone: Bool }
    struct Dot { let x: CGFloat; let y: CGFloat; let size: CGFloat }

    /// Cluster centers as fractions of the canvas — independent of any
    /// fixed pixel dimension. Tuned to look balanced in 16:10 ratios.
    static let clusters: [Cluster] = [
        .init(label: "Volumetric ▸ Aurora", fx: 0.20, fy: 0.20, isCapstone: false),
        .init(label: "Optical ▸ Heat",      fx: 0.65, fy: 0.16, isCapstone: false),
        .init(label: "Particles ▸ Dust",    fx: 0.30, fy: 0.55, isCapstone: false),
        .init(label: "Surface ▸ Water",     fx: 0.72, fy: 0.58, isCapstone: false),
        .init(label: "Skeletal ▸ Body",     fx: 0.48, fy: 0.78, isCapstone: false),
        .init(label: "★ Capstone",          fx: 0.50, fy: 0.36, isCapstone: true)
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

    /// Deterministic per-viz UTF-8 byte sum — stable across launches,
    /// unlike Swift's randomized `hashValue`. Used to scatter dots
    /// around their cluster centers without movement between sessions.
    private static func stableHash(_ s: String) -> Int {
        s.utf8.reduce(0) { $0 &+ Int($1) }
    }

    /// Fractional cluster center for a given category — paired with the
    /// labels above. Slight offsets from the label positions so the
    /// label sits clear of the cloud.
    private static func center(for cat: MKVizCategory) -> CGPoint {
        switch cat {
        case .volumetric: return CGPoint(x: 0.20, y: 0.27)
        case .optical:    return CGPoint(x: 0.65, y: 0.23)
        case .particles:  return CGPoint(x: 0.30, y: 0.62)
        case .surface:    return CGPoint(x: 0.72, y: 0.65)
        case .skeletal:   return CGPoint(x: 0.48, y: 0.84)
        case .capstone:   return CGPoint(x: 0.50, y: 0.43)
        case .featured:   return CGPoint(x: 0.40, y: 0.50)
        }
    }

    /// Compute a per-viz dot in absolute coordinates given the canvas
    /// size. Cluster center + UTF-8-hash-derived polar offset.
    static func dotFor(_ kind: VisualizationKind, size: CGSize) -> Dot {
        let cat = MKVizCategory.category(for: kind)
        let centerFrac = center(for: cat)
        let cx = size.width * centerFrac.x
        let cy = size.height * centerFrac.y
        let h = stableHash(kind.rawValue)
        let radius = min(size.width, size.height) * 0.10
        let angle = CGFloat(h % 360) * .pi / 180
        let dist = CGFloat((h / 360) % 100) / 100 * radius
        let dotSize = CGFloat(5 + (h % 6))
        return Dot(
            x: cx + cos(angle) * dist,
            y: cy + sin(angle) * dist,
            size: dotSize
        )
    }
}

private struct MKGalaxyCard: View {
    let kind: VisualizationKind
    let onPreview: () -> Void
    let onSendToOutput: () -> Void

    var body: some View {
        let cat = MKVizCategory.category(for: kind)
        // Per-category gradient — reflects the dot color so the card
        // visually identifies where it came from.
        let catColor = MKGalaxy.color(for: cat)

        return VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(
                    colors: [catColor.opacity(0.85),
                             catColor.opacity(0.45),
                             Color(red: 0.024, green: 0.024, blue: 0.031)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: 90)
            Text(kind.rawValue)
                .font(MK.Font.label12)
                .foregroundStyle(MK.Color.textPrimary)
            Text("\(cat.label.uppercased()) · k=12 NEAREST")
                .font(MK.Font.mono09).tracking(0.6)
                .foregroundStyle(MK.Color.textTertiary)
            HStack(spacing: 4) {
                Button(action: onPreview) {
                    Text("Preview")
                        .font(MK.Font.label10)
                        .foregroundStyle(MK.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Button(action: onSendToOutput) {
                    Text("Send to Output ⏎")
                        .font(MK.Font.label10).bold()
                        .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(MK.Color.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
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

// MARK: - Presets (real Snapshot list)

/// Replaces the bar-quantized timeline mock with a working preset
/// system: capture the current viz + common params + sparse per-viz
/// values into a named MKSnapshot, recall on demand, persist via
/// MKPersistence. The bar timeline (Ableton Link, cue automation,
/// audio-strip waveform) is Phase 2 — see UI-REDESIGN-SPEC §5 / §9.
struct MKPresetsScreen: View {
    @Bindable var manager: KinectManager
    @Bindable var app: MKAppState
    @State private var selectedID: UUID?
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MK.Color.bgWindow)
    }

    // MARK: Sidebar — list + Save

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("▾ SNAPSHOTS")
                    .font(MK.Font.label09).tracking(0.8)
                    .foregroundStyle(MK.Color.textSecondary)
                Spacer()
                Button(action: saveSnapshot) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Save")
                    }
                    .font(MK.Font.label11).bold()
                    .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(MK.Color.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save current viz + common params as a snapshot (⌘S)")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            Rectangle().fill(MK.Color.hairline).frame(height: 1)

            if app.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(app.snapshots) { snap in
                            row(snap)
                        }
                    }
                    .padding(8)
                }
            }
            Spacer()
        }
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(MK.Color.hairline).frame(width: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No snapshots yet")
                .font(MK.Font.label12).foregroundStyle(MK.Color.textPrimary)
            Text("Tune a visualizer in Library, then come back and press ⌘S to save the look. Snapshots persist across launches.")
                .font(MK.Font.label11)
                .foregroundStyle(MK.Color.textSecondary)
            Button { saveSnapshot() } label: {
                Text("Save current state")
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(MK.Color.accentDim))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func row(_ snap: MKSnapshot) -> some View {
        let isSelected = selectedID == snap.id
        let isRenaming = renamingID == snap.id
        return Button {
            selectedID = snap.id
        } label: {
            HStack(spacing: 10) {
                MKSnapshotThumb(kind: VisualizationKind(rawValue: snap.visualization),
                                hueShift: snap.common.hueShift)
                    .frame(width: 56, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    if isRenaming {
                        TextField("Snapshot name", text: $renameDraft, onCommit: {
                            commitRename(snap)
                        })
                        .textFieldStyle(.plain)
                        .font(MK.Font.label11)
                        .foregroundStyle(MK.Color.textPrimary)
                    } else {
                        Text(snap.name)
                            .font(MK.Font.label11)
                            .foregroundStyle(MK.Color.textPrimary)
                            .lineLimit(1)
                    }
                    Text(snap.visualization.uppercased())
                        .font(MK.Font.mono09).tracking(0.4)
                        .foregroundStyle(MK.Color.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? MK.Color.accent.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? MK.Color.accentDim : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Recall") { recall(snap) }
            Button("Rename") { startRename(snap) }
            Divider()
            Button("Delete", role: .destructive) { delete(snap) }
        }
        .onTapGesture(count: 2) { recall(snap) }
    }

    // MARK: Detail — selection preview

    private var detail: some View {
        Group {
            if let snap = selectedSnapshot {
                snapshotDetail(snap)
            } else {
                placeholderDetail
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholderDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Snapshots")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(MK.Color.textPrimary)
            Text("Save your current viz + common-param tuning to a named snapshot, then recall it any time. Snapshots persist across app launches via MKPersistence.")
                .font(MK.Font.label12)
                .foregroundStyle(MK.Color.textSecondary)
                .frame(maxWidth: 520, alignment: .leading)
            Text("⌘S — Save current state    Double-click any row — Recall    Right-click — Rename / Delete")
                .font(MK.Font.mono10)
                .foregroundStyle(MK.Color.textTertiary)
            Spacer()
        }
    }

    private func snapshotDetail(_ snap: MKSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(MK.Color.textPrimary)
                    Text("\(snap.visualization) · \(snap.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(MK.Font.mono10).tracking(0.4)
                        .foregroundStyle(MK.Color.textTertiary)
                }
                Spacer()
                Button { recall(snap) } label: {
                    Text("Recall ⏎")
                        .font(MK.Font.label12).bold()
                        .foregroundStyle(Color(red: 0, green: 0.06, blue: 0.09))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }

            Rectangle().fill(MK.Color.hairline).frame(height: 1)

            // Read-only common-param preview
            VStack(alignment: .leading, spacing: 10) {
                Text("▾ COMMON PARAMS")
                    .font(MK.Font.label09).tracking(0.8)
                    .foregroundStyle(MK.Color.textSecondary)
                paramRow("Audio reactivity", "\(String(format: "%.2f", snap.common.audioReactivity))")
                paramRow("Speed × ",         "\(String(format: "%.2f", snap.common.speedMul))")
                paramRow("Hue shift",        "\(String(format: "%+.2f", snap.common.hueShift))")
                paramRow("Saturation × ",    "\(String(format: "%.2f", snap.common.saturationMul))")
                paramRow("Brightness × ",    "\(String(format: "%.2f", snap.common.brightnessMul))")
                paramRow("Glow × ",          "\(String(format: "%.2f", snap.common.glowMul))")
            }

            if !snap.perVizParams.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("▾ PER-VIZ")
                        .font(MK.Font.label09).tracking(0.8)
                        .foregroundStyle(MK.Color.textSecondary)
                    ForEach(snap.perVizParams.keys.sorted(), id: \.self) { key in
                        paramRow(key, String(format: "%.3f", snap.perVizParams[key] ?? 0))
                    }
                }
            }

            Spacer()
        }
    }

    private func paramRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(MK.Font.label11).foregroundStyle(MK.Color.textSecondary)
            Spacer()
            Text(value).font(MK.Font.mono11).foregroundStyle(MK.Color.textPrimary)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MK.Color.hairline).frame(height: 1)
        }
    }

    // MARK: Actions

    private var selectedSnapshot: MKSnapshot? {
        guard let id = selectedID else { return nil }
        return app.snapshots.first(where: { $0.id == id })
    }

    private func saveSnapshot() {
        guard let viz = manager.visualization else { return }
        let name = "\(viz.rawValue) · \(app.snapshots.count + 1)"
        let snap = MKSnapshot(
            id: UUID(),
            name: name,
            createdAt: Date(),
            visualization: viz.rawValue,
            common: manager.snapshotCommon(),
            perVizParams: manager.captureActiveVizParams()
        )
        app.snapshots.insert(snap, at: 0)
        selectedID = snap.id
        // Drop into rename mode immediately so the user can re-title it.
        startRename(snap)
    }

    private func recall(_ snap: MKSnapshot) {
        if let kind = VisualizationKind(rawValue: snap.visualization) {
            manager.visualization = kind
        }
        manager.common.audioReactivity = snap.common.audioReactivity
        manager.common.speedMul        = snap.common.speedMul
        manager.common.hueShift        = snap.common.hueShift
        manager.common.saturationMul   = snap.common.saturationMul
        manager.common.brightnessMul   = snap.common.brightnessMul
        manager.common.glowMul         = snap.common.glowMul
        manager.applyActiveVizParams(snap.perVizParams)
    }

    private func startRename(_ snap: MKSnapshot) {
        renamingID = snap.id
        renameDraft = snap.name
    }

    private func commitRename(_ snap: MKSnapshot) {
        guard !renameDraft.isEmpty,
              let i = app.snapshots.firstIndex(where: { $0.id == snap.id }) else {
            renamingID = nil
            return
        }
        app.snapshots[i].name = renameDraft
        renamingID = nil
        renameDraft = ""
    }

    private func delete(_ snap: MKSnapshot) {
        app.snapshots.removeAll { $0.id == snap.id }
        if selectedID == snap.id { selectedID = nil }
    }
}

// MARK: - Snapshot thumbnail (categorical gradient)

private struct MKSnapshotThumb: View {
    let kind: VisualizationKind?
    let hueShift: Float

    var body: some View {
        let cat = kind.map(MKVizCategory.category(for:)) ?? .featured
        let base = MKGalaxy.color(for: cat)
        return RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(
                colors: [base.opacity(0.85),
                         base.opacity(0.45),
                         Color(red: 0.024, green: 0.024, blue: 0.031)],
                startPoint: .top, endPoint: .bottom))
            .hueRotation(.degrees(Double(hueShift) * 360))
    }
}
