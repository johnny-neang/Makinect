// MKMidiOutputScreens — MIDI Mapping and Output (multi-display) screens
// ported from the Claude Design handoff. Visual-fidelity mocks; real
// MIDI / OSC subsystems and multi-display routing are not yet wired in.

import SwiftUI

// MARK: - MIDI Mapping

struct MKMidiScreen: View {
    var body: some View {
        HStack(spacing: 0) {
            devRail.frame(width: 280)
            mapGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
            rightDetail.frame(width: 320)
        }
        .background(MK.Color.bgWindow)
    }

    // MARK: Device rail

    private var devRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("▾ DEVICES")
                .font(MK.Font.label09).tracking(0.8)
                .foregroundStyle(MK.Color.textSecondary)
                .padding(.bottom, 10)

            devCard("Akai MIDImix",   meta: "● CONNECTED · CH 1 · 8 KNOBS · 8 PADS",
                    metaTone: .live, active: true)
            devCard("Push 2",         meta: "CONNECTED · CH 2 · 64 PADS · 8 ENC")
            devCard("TouchOSC (iPad)", meta: "CONNECTED · OSC · 24 CH")
            devCard("Foot Pedal",     meta: "DISCONNECTED", dim: true)

            Rectangle().fill(MK.Color.hairline).frame(height: 1).padding(.vertical, 12)

            Text("▾ TEMPLATES")
                .font(MK.Font.label09).tracking(0.8)
                .foregroundStyle(MK.Color.textSecondary)
                .padding(.bottom, 10)

            devCard("Default · Aurora", meta: "14 MAPPINGS")
            devCard("Show 1 set",       meta: "22 MAPPINGS")
            devCard("Smoke God only",   meta: "8 MAPPINGS")

            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(MK.Color.hairline).frame(width: 1)
        }
    }

    private func devCard(_ name: String, meta: String,
                         metaTone: DevMetaTone = .normal,
                         active: Bool = false, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(MK.Font.label12).foregroundStyle(MK.Color.textPrimary)
            Text(meta)
                .font(MK.Font.mono09).tracking(0.4)
                .foregroundStyle(metaTone == .live ? MK.Color.success : MK.Color.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? MK.Color.accent.opacity(0.05) : MK.Color.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? MK.Color.accent : MK.Color.hairline, lineWidth: 1))
        .opacity(dim ? 0.5 : 1)
        .padding(.bottom, 8)
    }

    private enum DevMetaTone { case normal, live }

    // MARK: Map grid (8 knobs + 8 pads + table)

    private var mapGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("▾ AKAI MIDIMIX · LIVE LAYOUT")
                .font(MK.Font.mono09).tracking(0.8)
                .foregroundStyle(MK.Color.textTertiary)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    knob(0, cc: 16, target: "Hue A",        value: ".32")
                    knob(1, cc: 17, target: "Hue B",        value: ".85")
                    knob(2, cc: 18, target: "Curtain Freq", value: ".50")
                    knob(3, cc: 19, target: "LEARNING…",    value: "●", armed: true)
                    knob(4, cc: 74, target: "Drop Mag",     value: ".80")
                    knob(5, cc: 21, target: "Audio Gain",   value: ".66")
                    knob(6, cc: 22, target: "— unmapped",   value: ".50", unmapped: true)
                    knob(7, cc: 23, target: "— unmapped",   value: ".50", unmapped: true)
                }

                HStack(spacing: 6) {
                    pad("SCENE 1", note: 36, scene: true)
                    pad("SCENE 2", note: 37, scene: true)
                    pad("SCENE 3", note: 38, scene: true)
                    pad("STROBE",  note: 39, mapped: true)
                    pad("FREEZE",  note: 40, mapped: true)
                    pad("STAR ↑",  note: 41, mapped: true)
                    pad("—",       note: 42)
                    pad("—",       note: 43)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(MK.Color.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(MK.Color.hairline, lineWidth: 1))

            mapTable
            Spacer()
        }
        .padding(16)
    }

    private func knob(_ idx: Int, cc: Int, target: String, value: String,
                      armed: Bool = false, unmapped: Bool = false) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(unmapped ? MK.Color.textTertiary.opacity(0.3)
                                     : (armed ? MK.Color.magenta : MK.Color.accent),
                            lineWidth: 3)
                    .frame(width: 38, height: 38)
                Text(value)
                    .font(MK.Font.mono09)
                    .foregroundStyle(armed ? MK.Color.magenta : MK.Color.textTertiary)
            }
            .shadow(color: armed ? MK.Color.magenta : .clear, radius: 6)
            Text("CC \(cc)")
                .font(MK.Font.mono09).foregroundStyle(MK.Color.textTertiary)
            Text(target)
                .font(MK.Font.mono09)
                .foregroundStyle(armed ? MK.Color.magenta
                              : (unmapped ? MK.Color.textTertiary : MK.Color.accent))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func pad(_ name: String, note: Int,
                     scene: Bool = false, mapped: Bool = false) -> some View {
        let color: Color = scene ? MK.Color.accentWarm
                          : (mapped ? MK.Color.accent : MK.Color.textSecondary)
        let fill: Color = scene ? MK.Color.accentWarm.opacity(0.10)
                        : (mapped ? MK.Color.accent.opacity(0.10) : Color.white.opacity(0.04))
        let border: Color = scene ? MK.Color.accentWarm
                          : (mapped ? MK.Color.accent : MK.Color.hairline)
        return VStack(spacing: 2) {
            Text(name)
                .font(MK.Font.label10)
                .foregroundStyle(color)
            Text("N \(note)")
                .font(MK.Font.mono09)
                .foregroundStyle(MK.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
    }

    private var mapTable: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                tableHead("SOURCE",  width: 120)
                tableHead("TARGET",  width: nil)
                tableHead("RANGE",   width: 80)
                tableHead("CURVE",   width: 80)
                Color.clear.frame(width: 24)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(MK.Color.hairline).frame(height: 1) }

            tableRow(srcDot: MK.Color.accent, src: "CC 16",
                     target: "Aurora · Hue A", range: "0.0–1.0", curve: "linear")
            tableRow(srcDot: MK.Color.accent, src: "CC 17",
                     target: "Aurora · Hue B", range: "0.0–1.0", curve: "linear")
            tableRow(srcDot: MK.Color.magenta, src: "CC 74",
                     target: "Aurora · Drop Magnitude", range: "0.0–1.0", curve: "exp 2.0")
            tableRow(srcDot: MK.Color.magenta, src: "CC 19 (learning)",
                     target: "move target slider…", range: "—", curve: "—",
                     armed: true)
            tableRow(srcDot: MK.Color.accent, src: "Note 36",
                     target: "Scene 1 · Aurora", range: "trigger", curve: "velocity")
        }
    }

    private func tableHead(_ label: String, width: CGFloat?) -> some View {
        Group {
            if let w = width {
                Text(label).frame(width: w, alignment: .leading)
            } else {
                Text(label).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(MK.Font.label09).tracking(0.6).foregroundStyle(MK.Color.textTertiary)
    }

    private func tableRow(srcDot: Color, src: String, target: String,
                          range: String, curve: String, armed: Bool = false) -> some View {
        HStack {
            HStack(spacing: 4) {
                Circle().fill(srcDot).frame(width: 6, height: 6)
                Text(src)
            }
            .frame(width: 120, alignment: .leading)
            Group {
                if armed { Text(target).italic() }
                else      { Text(target) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(range).frame(width: 80, alignment: .leading)
            Text(curve).frame(width: 80, alignment: .leading)
            if armed {
                Text("ESC")
                    .font(MK.Font.mono10)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(MK.Color.hairline, lineWidth: 1))
                    .frame(width: 36)
            } else {
                Text("⋯").foregroundStyle(MK.Color.textTertiary).frame(width: 36, alignment: .trailing)
            }
        }
        .font(MK.Font.label11)
        .foregroundStyle(MK.Color.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(armed ? MK.Color.magenta.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(MK.Color.hairline).frame(height: 1) }
    }

    // MARK: Right detail

    private var rightDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("⏺  MIDI LEARN MODE")
                .font(MK.Font.label12).bold()
                .foregroundStyle(Color(red: 0.10, green: 0, blue: 0.05))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.magenta))

            Text("▾ ACTIVE MAPPING")
                .font(MK.Font.label09).tracking(0.8)
                .foregroundStyle(MK.Color.textSecondary)
            Text("CC 74 → Drop Magnitude")
                .font(MK.Font.title16).foregroundStyle(MK.Color.textPrimary)
            Text("AURORA · EXP CURVE · 2.0")
                .font(MK.Font.mono09).tracking(0.6)
                .foregroundStyle(MK.Color.textTertiary)

            // Curve canvas
            curveCanvas
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(MK.Color.bgElevated))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MK.Color.hairline, lineWidth: 1))

            mockSlider2(label: "Min",         value: "0.0",   frac: 0.0)
            mockSlider2(label: "Max",         value: "1.0",   frac: 1.0)
            mockSlider2(label: "Curve · exp", value: "2.0",   frac: 0.6,
                        tint: MK.Color.magenta)
            mockSlider2(label: "Smoothing",   value: "25 ms", frac: 0.25)

            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .leading) { Rectangle().fill(MK.Color.hairline).frame(width: 1) }
    }

    private var curveCanvas: some View {
        GeometryReader { geo in
            let w = geo.size.width - 24
            let h = geo.size.height - 24
            ZStack(alignment: .topLeading) {
                // Axes
                Path { p in
                    p.move(to: CGPoint(x: 12, y: 12))
                    p.addLine(to: CGPoint(x: 12, y: h + 12))
                    p.addLine(to: CGPoint(x: w + 12, y: h + 12))
                }
                .stroke(MK.Color.hairline, lineWidth: 0.5)

                // Curve — exp 2.0
                Path { p in
                    p.move(to: CGPoint(x: 12, y: h + 12))
                    p.addQuadCurve(
                        to: CGPoint(x: w + 12, y: 12),
                        control: CGPoint(x: 12 + w * 0.6, y: h + 12)
                    )
                }
                .stroke(MK.Color.magenta, lineWidth: 1.5)

                Circle()
                    .fill(MK.Color.magenta)
                    .frame(width: 6, height: 6)
                    .position(x: 12 + w * 0.8, y: 12 + h * 0.3)
            }
        }
        .padding(12)
    }
}

// MARK: - Output (multi-display)

struct MKOutputScreen: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("▾ DISPLAY ARRANGEMENT · drag to position · 8 px = 1 m")
                .font(MK.Font.mono09).tracking(0.8)
                .foregroundStyle(MK.Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            layoutStage
                .frame(maxHeight: .infinity)

            dispList
                .frame(maxHeight: 320)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MK.Color.bgWindow)
    }

    // Top-down venue layout
    private var layoutStage: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black

                // 40px grid overlay
                gridOverlay

                Text("VENUE · TOP DOWN")
                    .font(MK.Font.mono09).tracking(0.8)
                    .foregroundStyle(MK.Color.textTertiary)
                    .position(x: geo.size.width * 0.5, y: 22)

                // Macbook
                displayCard(role: "CONTROL", roleColor: MK.Color.textSecondary,
                            title: "MACBOOK", titleColor: MK.Color.textPrimary,
                            res: "2560×1664 · BUILT-IN",
                            preview: LinearGradient(
                                colors: [Color(hue: 0.62, saturation: 0.4, brightness: 0.30),
                                         Color(red: 0.024, green: 0.024, blue: 0.031)],
                                startPoint: .top, endPoint: .bottom),
                            border: MK.Color.hairline, glow: false)
                    .frame(width: geo.size.width * 0.22, height: geo.size.height * 0.28)
                    .position(x: geo.size.width * 0.16, y: geo.size.height * 0.50)

                // Main projector — active
                displayCard(role: "PROGRAM", roleColor: MK.Color.accent,
                            title: "DISPLAY 2 · MAIN PROJECTOR", titleColor: MK.Color.accent,
                            res: "3840×2160 @ 60 · HDMI 1 · 8m throw",
                            preview: LinearGradient(
                                colors: [Color(hue: 0.55, saturation: 0.6, brightness: 0.85),
                                         Color(hue: 0.78, saturation: 0.6, brightness: 0.45),
                                         Color(red: 0.024, green: 0.024, blue: 0.031)],
                                startPoint: .top, endPoint: .bottom),
                            border: MK.Color.accent, glow: true)
                    .frame(width: geo.size.width * 0.38, height: geo.size.height * 0.60)
                    .position(x: geo.size.width * 0.50, y: geo.size.height * 0.38)

                // Side wall
                displayCard(role: "PROGRAM-MIRROR", roleColor: MK.Color.accentWarm,
                            title: "DISPLAY 3 · SIDE WALL", titleColor: MK.Color.accentWarm,
                            res: "1920×1080 · HDMI 2",
                            preview: RadialGradient(
                                colors: [Color(hue: 0.10, saturation: 0.6, brightness: 0.78),
                                         Color(red: 0.024, green: 0.024, blue: 0.031)],
                                center: .center, startRadius: 0, endRadius: 200),
                            border: MK.Color.accentWarm, glow: false)
                    .frame(width: geo.size.width * 0.22, height: geo.size.height * 0.38)
                    .position(x: geo.size.width * 0.86, y: geo.size.height * 0.32)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(MK.Color.hairline, lineWidth: 1))
        }
    }

    private var gridOverlay: some View {
        Canvas { ctx, size in
            let step: CGFloat = 40
            let gridColor = Color.white.opacity(0.04)
            var x: CGFloat = 0
            while x < size.width {
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: 24)); p.addLine(to: CGPoint(x: x, y: size.height - 24))
                }, with: .color(gridColor), lineWidth: 1)
                x += step
            }
            var y: CGFloat = 24
            while y < size.height {
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 24, y: y)); p.addLine(to: CGPoint(x: size.width - 24, y: y))
                }, with: .color(gridColor), lineWidth: 1)
                y += step
            }
        }
        .padding(24)
    }

    private func displayCard<P: ShapeStyle>(role: String, roleColor: Color,
                                            title: String, titleColor: Color,
                                            res: String,
                                            preview: P,
                                            border: Color, glow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(MK.Font.mono09).tracking(0.6).foregroundStyle(titleColor)
            Text(res).font(MK.Font.mono09).foregroundStyle(.white.opacity(0.6))
            Rectangle()
                .fill(preview)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(maxHeight: .infinity)
                .padding(.top, 6)
            Text(role)
                .font(.system(size: 8, weight: .bold)).tracking(0.6)
                .foregroundStyle(role == "CONTROL" ? MK.Color.bgWindow : Color(red: 0, green: 0.06, blue: 0.09))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(roleColor)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(12)
        .background(MK.Color.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: glow ? 2 : 1))
        .shadow(color: glow ? border.opacity(0.4) : .clear, radius: 16)
    }

    // Bottom card list

    private var dispList: some View {
        HStack(spacing: 12) {
            dispCard(title: "Built-in Display", titleColor: MK.Color.textPrimary,
                     meta: "2560×1664 · MACBOOK PRO 16",
                     rows: [("Role", "Control + Preview", MK.Color.textPrimary),
                            ("Refresh", "120 Hz", MK.Color.textPrimary),
                            ("Color", "P3 Display", MK.Color.textPrimary),
                            ("Latency", "0 ms", MK.Color.textPrimary)],
                     border: MK.Color.hairline)
            dispCard(title: "Display 2 · Main Projector", titleColor: MK.Color.accent,
                     meta: "3840×2160 @ 60 · CHRISTIE LWU620",
                     rows: [("Role", "PROGRAM", MK.Color.accent),
                            ("Connector", "HDMI 1 → CalDigit TS4", MK.Color.textPrimary),
                            ("Color", "Rec. 709 · Manual cal", MK.Color.textPrimary),
                            ("Bezel inset", "12 / 12 / 18 / 12 px", MK.Color.textPrimary),
                            ("Latency", "16 ms · OK", MK.Color.success)],
                     border: MK.Color.accent, showWarp: true)
            dispCard(title: "Display 3 · Side Wall", titleColor: MK.Color.accentWarm,
                     meta: "1920×1080 · BARCO F70",
                     rows: [("Role", "PROGRAM-MIRROR", MK.Color.accentWarm),
                            ("Connector", "HDMI 2", MK.Color.textPrimary),
                            ("Color match", "→ Display 2", MK.Color.textPrimary),
                            ("Crop", "center 16:9", MK.Color.textPrimary),
                            ("Latency", "22 ms · acceptable", MK.Color.warning)],
                     border: MK.Color.accentWarm.opacity(0.4))
        }
    }

    private func dispCard(title: String, titleColor: Color, meta: String,
                          rows: [(String, String, Color)],
                          border: Color, showWarp: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(MK.Font.label12).foregroundStyle(titleColor)
            Text(meta).font(MK.Font.mono09).tracking(0.6).foregroundStyle(MK.Color.textTertiary)
                .padding(.bottom, 8)
            ForEach(0..<rows.count, id: \.self) { i in
                let row = rows[i]
                HStack {
                    Text(row.0).foregroundStyle(MK.Color.textSecondary)
                    Spacer()
                    Text(row.1).font(MK.Font.mono10).foregroundStyle(row.2)
                }
                .font(MK.Font.label10)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    if i < rows.count - 1 {
                        Rectangle().fill(MK.Color.hairline).frame(height: 1)
                    }
                }
            }
            if showWarp {
                warpGrid
                    .frame(height: 80)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(MK.Color.hairline, lineWidth: 1))
                    .padding(.top, 12)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MK.Color.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
    }

    private var warpGrid: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // 4-pt keystone outline (slight skew)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 8, y: 8))
                    p.addLine(to: CGPoint(x: w - 5, y: 4))
                    p.addLine(to: CGPoint(x: w - 8, y: h - 4))
                    p.addLine(to: CGPoint(x: 6, y: h - 10))
                    p.closeSubpath()
                }
                .stroke(MK.Color.accent, lineWidth: 1)

                // Diagonals
                Path { p in
                    p.move(to: CGPoint(x: 8, y: 8))
                    p.addLine(to: CGPoint(x: w - 8, y: h - 4))
                    p.move(to: CGPoint(x: w - 5, y: 4))
                    p.addLine(to: CGPoint(x: 6, y: h - 10))
                }
                .stroke(MK.Color.accentDim, lineWidth: 0.5)

                // Corner handles
                ForEach(0..<4) { i in
                    let pt: CGPoint = {
                        switch i {
                        case 0: return CGPoint(x: 8, y: 8)
                        case 1: return CGPoint(x: w - 5, y: 4)
                        case 2: return CGPoint(x: w - 8, y: h - 4)
                        default: return CGPoint(x: 6, y: h - 10)
                        }
                    }()
                    Circle().fill(MK.Color.accent).frame(width: 6, height: 6).position(pt)
                }

                Text("KEYSTONE · 4 PT")
                    .font(MK.Font.mono09)
                    .foregroundStyle(MK.Color.accentDim)
                    .position(x: w / 2, y: h / 2)
            }
        }
    }
}

// MARK: - Shared mock slider for MIDI right pane

@ViewBuilder
private func mockSlider2(label: String, value: String, frac: CGFloat,
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
    .padding(.bottom, 6)
}
