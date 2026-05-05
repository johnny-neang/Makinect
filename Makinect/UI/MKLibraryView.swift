// MKLibraryView — viz browser. Left rail (categories + viz list with
// gradient thumbs), hero canvas in the middle, right inspector with the
// existing per-viz bespoke controls, bottom transport.

import SwiftUI

struct MKLibraryView: View {
    @Bindable var manager: KinectManager
    @State private var selectedCategory: MKVizCategory = .featured
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftRail.frame(width: MK.Metrics.leftRailWidth)
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                rightRail.frame(width: MK.Metrics.rightRailWidth)
            }
            transport.frame(height: MK.Metrics.transportHeight)
        }
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MKVizCategory.allCases, id: \.self) { cat in
                    catRow(cat)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MK.Color.textTertiary)
                        .font(.system(size: 10))
                    TextField("Filter library", text: $query)
                        .textFieldStyle(.plain)
                        .font(MK.Font.label11)
                        .foregroundStyle(MK.Color.textPrimary)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
                .padding(.top, 12)

                Rectangle().fill(MK.Color.hairline).frame(height: 1).padding(.vertical, 12)
            }
            .padding(12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredKinds, id: \.self) { kind in
                        vizRow(kind)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(MK.Color.hairline).frame(width: 1)
        }
    }

    private func catRow(_ cat: MKVizCategory) -> some View {
        let active = selectedCategory == cat
        let count = countFor(cat)
        return Button { selectedCategory = cat } label: {
            HStack(spacing: 6) {
                if active { Text("●").foregroundStyle(MK.Color.accent) }
                Text(cat.label)
                    .font(MK.Font.label12)
                    .foregroundStyle(active ? MK.Color.textPrimary : MK.Color.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(MK.Font.mono10)
                    .foregroundStyle(MK.Color.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(active ? MK.Color.accent.opacity(0.10) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func vizRow(_ kind: VisualizationKind) -> some View {
        let active = manager.visualization == kind
        return Button { manager.visualization = kind } label: {
            HStack(spacing: 10) {
                MKVizThumb(kind: kind)
                    .frame(width: 56, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.rawValue)
                        .font(MK.Font.label11)
                        .foregroundStyle(MK.Color.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(MKVizCategory.category(for: kind).label.uppercased())
                            .font(MK.Font.mono09)
                            .tracking(0.4)
                            .foregroundStyle(MK.Color.textTertiary)
                        if active {
                            Text("● ACTIVE")
                                .font(MK.Font.mono09)
                                .foregroundStyle(MK.Color.accent)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? MK.Color.accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? MK.Color.accentDim : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
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

            // Cyan scanline along the top
            VStack {
                Rectangle()
                    .fill(MK.Color.accent)
                    .frame(height: 1)
                    .shadow(color: MK.Color.accent, radius: 4)
                    .opacity(0.7)
                Spacer()
            }
            .allowsHitTesting(false)

            // Tag — top-left
            HStack {
                if let viz = manager.visualization {
                    HStack(spacing: 4) {
                        Text(MKVizCategory.category(for: viz).label.uppercased())
                            .foregroundStyle(MK.Color.accent)
                        Text("·").foregroundStyle(MK.Color.textTertiary)
                        Text(viz.rawValue).foregroundStyle(MK.Color.textPrimary)
                    }
                    .font(MK.Font.label11)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.5))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))
                }
                Spacer()
            }
            .padding(16)
        }
    }

    // MARK: - Right rail
    // Common params on top (fixed height), then the existing SidePanel below
    // (brings its own ScrollView with all bespoke per-viz controls intact —
    // no nested-scroll conflict).

    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("▾ ACTIVE VIZ")
                        .font(MK.Font.label09).tracking(0.8)
                        .foregroundStyle(MK.Color.textSecondary)
                    Text(manager.visualization?.rawValue ?? "—")
                        .font(MK.Font.title16)
                        .foregroundStyle(MK.Color.textPrimary)
                    if let viz = manager.visualization {
                        Text(MKVizCategory.category(for: viz).label.uppercased())
                            .font(MK.Font.mono09).tracking(0.4)
                            .foregroundStyle(MK.Color.textTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("▾ COMMON")
                        .font(MK.Font.label09).tracking(0.8)
                        .foregroundStyle(MK.Color.textSecondary)
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
                        onChange: { manager.common.hueShift = Float($0) - 0.5 }
                    )
                }
            }
            .padding(16)

            Rectangle().fill(MK.Color.hairline).frame(height: 1)

            // Per-viz bespoke controls — preserves Phase C's 38 control sets.
            // `compact: true` skips Stream Mode / Depth Range / Audio Input /
            // Audio Monitor / System (those live in Settings + Audio tabs now).
            SidePanel(manager: manager, compact: true)
                .frame(maxHeight: .infinity)
        }
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(MK.Color.hairline).frame(width: 1)
        }
    }

    // MARK: - Transport (bottom 44pt)

    private var transport: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                MKPip(color: manager.isConnected ? MK.Color.success : MK.Color.textTertiary)
                Text(manager.source == .kinect ? "Kinect Live ▾" : "Synthetic ▾")
                    .font(MK.Font.mono11)
                    .foregroundStyle(MK.Color.textPrimary)
            }

            HStack(spacing: 6) {
                Text("BPM").foregroundStyle(MK.Color.textSecondary)
                Text(manager.audio.bpm > 1
                     ? String(format: "%.1f", manager.audio.bpm)
                     : "—")
                    .foregroundStyle(MK.Color.accentWarm).bold()
            }
            .font(MK.Font.mono11)

            MKBarMeter(bands: manager.audio.bands)

            if manager.audio.onset {
                Circle().fill(MK.Color.danger).frame(width: 8, height: 8)
                    .shadow(color: MK.Color.danger, radius: 6)
            }

            Text(String(format: "%.1f LUFS", manager.audio.lufs))
                .font(MK.Font.mono11)
                .foregroundStyle(MK.Color.textSecondary)

            Spacer()

            Text(String(format: "● %.0f fps", manager.resourceMonitor.fps))
                .font(MK.Font.mono11)
                .foregroundStyle(MK.Color.success)

            Text(String(format: "CPU %.0f%% · %.1f GB",
                        manager.resourceMonitor.cpuPercent / max(1, manager.resourceMonitor.coreCount),
                        manager.resourceMonitor.memoryMB / 1024))
                .font(MK.Font.mono11)
                .foregroundStyle(MK.Color.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(MK.Color.hairline).frame(height: 1)
        }
    }

    // MARK: - Helpers

    private var allKinds: [VisualizationKind] { VisualizationKind.allCases }

    private var filteredKinds: [VisualizationKind] {
        let inCat: [VisualizationKind] = {
            if selectedCategory == .featured {
                return MKVizCategory.featuredKinds
            }
            return allKinds.filter { MKVizCategory.category(for: $0) == selectedCategory }
        }()
        if query.isEmpty { return inCat }
        return inCat.filter { $0.rawValue.localizedCaseInsensitiveContains(query) }
    }

    private func countFor(_ cat: MKVizCategory) -> Int {
        if cat == .featured { return MKVizCategory.featuredKinds.count }
        return allKinds.filter { MKVizCategory.category(for: $0) == cat }.count
    }
}

// MARK: - Gradient thumbnails (oklch-inspired approximations)

private struct MKVizThumb: View {
    let kind: VisualizationKind

    var body: some View {
        let cat = MKVizCategory.category(for: kind)
        let (a, b) = paletteFor(cat: cat, kind: kind)
        return ZStack {
            LinearGradient(colors: [a, b, Color(red: 0.024, green: 0.024, blue: 0.031)],
                           startPoint: .top, endPoint: .bottom)
            // subtle scanline overlay
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .blendMode(.multiply)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func paletteFor(cat: MKVizCategory, kind: VisualizationKind) -> (Color, Color) {
        // Hand-tuned to roughly mirror the design's oklch swatches.
        switch cat {
        case .volumetric: return (Color(hue: 0.55, saturation: 0.6, brightness: 0.85),
                                  Color(hue: 0.78, saturation: 0.6, brightness: 0.50))
        case .particles:  return (Color(hue: 0.62, saturation: 0.5, brightness: 0.70),
                                  Color(hue: 0.92, saturation: 0.5, brightness: 0.45))
        case .surface:    return (Color(hue: 0.45, saturation: 0.5, brightness: 0.80),
                                  Color(hue: 0.60, saturation: 0.4, brightness: 0.40))
        case .optical:    return (Color(hue: 0.08, saturation: 0.7, brightness: 0.78),
                                  Color(hue: 0.02, saturation: 0.6, brightness: 0.40))
        case .skeletal:   return (Color(hue: 0.85, saturation: 0.5, brightness: 0.65),
                                  Color(hue: 0.90, saturation: 0.5, brightness: 0.30))
        case .featured, .capstone:
                          return (Color(hue: 0.55, saturation: 0.55, brightness: 0.80),
                                  Color(hue: 0.72, saturation: 0.55, brightness: 0.45))
        }
    }
}
