// MKTokens — design tokens for the Makinect UI redesign.
// Mirrors mk.css from the Claude Design handoff bundle.

import SwiftUI

enum MK {

    // MARK: Colors

    enum Color {
        static let bgWindow      = SwiftUI.Color(red: 0x0B/255, green: 0x0B/255, blue: 0x10/255)
        static let bgSidebar     = SwiftUI.Color(red: 0x15/255, green: 0x15/255, blue: 0x1C/255)
        static let bgElevated    = SwiftUI.Color(red: 0x1F/255, green: 0x1F/255, blue: 0x28/255)
        static let bgVibrancy    = SwiftUI.Color(red: 0x1C/255, green: 0x1C/255, blue: 0x24/255).opacity(0.72)

        static let hairline       = SwiftUI.Color.white.opacity(0.06)
        static let hairlineStrong = SwiftUI.Color.white.opacity(0.12)

        static let textPrimary   = SwiftUI.Color(red: 0xF2/255, green: 0xF2/255, blue: 0xF7/255)
        static let textSecondary = SwiftUI.Color(red: 0x9C/255, green: 0x9C/255, blue: 0xB0/255)
        static let textTertiary  = SwiftUI.Color(red: 0x5C/255, green: 0x5C/255, blue: 0x70/255)

        static let accent     = SwiftUI.Color(red: 0x7A/255, green: 0xE7/255, blue: 0xFF/255)   // cyan
        static let accentDim  = accent.opacity(0.18)
        static let accentWarm = SwiftUI.Color(red: 0xFF/255, green: 0xB0/255, blue: 0x66/255)   // amber
        static let magenta    = SwiftUI.Color(red: 0xE8/255, green: 0x79/255, blue: 0xF9/255)
        static let success    = SwiftUI.Color(red: 0x5B/255, green: 0xD8/255, blue: 0x9F/255)
        static let warning    = SwiftUI.Color(red: 0xFF/255, green: 0xD6/255, blue: 0x6B/255)
        static let danger     = SwiftUI.Color(red: 0xFF/255, green: 0x6F/255, blue: 0x84/255)

        // Traffic-light colors for the simulated title bar.
        static let lightRed    = SwiftUI.Color(red: 1.0, green: 0x5F/255, blue: 0x57/255)
        static let lightYellow = SwiftUI.Color(red: 0xFE/255, green: 0xBC/255, blue: 0x2E/255)
        static let lightGreen  = SwiftUI.Color(red: 0x28/255, green: 0xC8/255, blue: 0x40/255)
    }

    // MARK: Fonts

    enum Font {
        static let mono09 = SwiftUI.Font.system(size: 9, design: .monospaced)
        static let mono10 = SwiftUI.Font.system(size: 10, design: .monospaced)
        static let mono11 = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let mono12 = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let mono14 = SwiftUI.Font.system(size: 14, design: .monospaced)
        static let mono22 = SwiftUI.Font.system(size: 22, weight: .semibold, design: .monospaced)
        static let mono24 = SwiftUI.Font.system(size: 24, weight: .semibold, design: .monospaced)

        static let label09 = SwiftUI.Font.system(size: 9, weight: .semibold)
        static let label10 = SwiftUI.Font.system(size: 10, weight: .medium)
        static let label11 = SwiftUI.Font.system(size: 11, weight: .medium)
        static let label12 = SwiftUI.Font.system(size: 12, weight: .medium)
        static let label13 = SwiftUI.Font.system(size: 13, weight: .semibold)

        static let title16 = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let title18 = SwiftUI.Font.system(size: 18, weight: .semibold)
    }

    // MARK: Layout

    enum Metrics {
        static let titleBarHeight: CGFloat       = 32
        static let toolbarHeight: CGFloat        = 44
        static let chromeHeight: CGFloat         = 76         // titlebar + toolbar
        static let leftRailWidth: CGFloat        = 240
        static let rightRailWidth: CGFloat       = 320
        static let transportHeight: CGFloat      = 44         // Library
        static let transportPerfHeight: CGFloat  = 60         // Performance
        static let cornerRadius: CGFloat         = 8
    }
}

// MARK: - Reusable atoms

/// Glass overlay used by Performance HUDs.
struct MKGlass<Content: View>: View {
    var radius: CGFloat = 8
    var dashed: Bool = false
    var dashColor: Color = MK.Color.accentWarm
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.black.opacity(0.55))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(
                        dashed ? AnyShapeStyle(dashColor) : AnyShapeStyle(MK.Color.hairline),
                        style: dashed
                            ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                            : StrokeStyle(lineWidth: 1)
                    )
            )
    }
}

/// Pip — small glow dot used for status indicators.
struct MKPip: View {
    var color: Color = MK.Color.success
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color, radius: size * 0.6)
    }
}

/// HUD pill used at the top-left of the Performance canvas.
struct MKHudPill<Content: View>: View {
    enum Tone { case neutral, warm, live, danger }
    var tone: Tone = .neutral
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .font(MK.Font.mono11)
            .foregroundStyle(foreground)
            .background(
                Capsule().fill(Color.black.opacity(0.55))
                    .background(.ultraThinMaterial, in: Capsule())
            )
            .overlay(Capsule().stroke(border, lineWidth: 1))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return MK.Color.textSecondary
        case .warm:    return MK.Color.accentWarm
        case .live:    return MK.Color.success
        case .danger:  return MK.Color.danger
        }
    }
    private var border: Color {
        switch tone {
        case .warm:   return MK.Color.accentWarm.opacity(0.3)
        case .danger: return MK.Color.danger.opacity(0.3)
        default:      return MK.Color.hairline
        }
    }
}

/// Slider styled like the design: thin track, magenta-mapped state, mono value readout.
struct MKKnobRow: View {
    let label: String
    let value: Double
    let formatted: String
    let range: ClosedRange<Double>
    var tint: Color = MK.Color.accent
    var midiTag: String? = nil
    var onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(label).font(MK.Font.label11).foregroundStyle(MK.Color.textSecondary)
                    if let tag = midiTag {
                        Text("● \(tag)")
                            .font(MK.Font.mono09)
                            .foregroundStyle(MK.Color.magenta)
                    }
                }
                Spacer()
                Text(formatted).font(MK.Font.mono11).foregroundStyle(MK.Color.textPrimary)
            }
            MKThinSlider(value: value, range: range, tint: tint, onChange: onChange)
        }
    }
}

/// 4-pt slider track with white thumb, matching the design.
struct MKThinSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var tint: Color = MK.Color.accent
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let frac = max(0, min(1, (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint).frame(width: geo.size.width * CGFloat(frac))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .offset(x: geo.size.width * CGFloat(frac) - 7)
            }
            .frame(height: 4)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, g.location.x / geo.size.width))
                        let v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        onChange(v)
                    }
            )
        }
        .frame(height: 16)
    }
}
