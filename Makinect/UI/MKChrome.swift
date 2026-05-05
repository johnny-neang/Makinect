// MKChrome — title bar + toolbar nav for the redesigned shell.

import SwiftUI

struct MKTitleBar: View {
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(MK.Color.lightRed).frame(width: 12, height: 12)
                Circle().fill(MK.Color.lightYellow).frame(width: 12, height: 12)
                Circle().fill(MK.Color.lightGreen).frame(width: 12, height: 12)
            }
            Spacer()
            Text(title).font(MK.Font.label12).foregroundStyle(MK.Color.textSecondary)
            Spacer()
            Color.clear.frame(width: 52)
        }
        .padding(.horizontal, 16)
        .frame(height: MK.Metrics.titleBarHeight)
        .background(MK.Color.bgSidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MK.Color.hairline).frame(height: 1)
        }
    }
}

struct MKToolbar: View {
    @Bindable var app: MKAppState
    var outputLabel: String = "Output · Internal"

    var body: some View {
        HStack(spacing: 8) {
            // App icon — conic-gradient mark
            Circle()
                .fill(AngularGradient(
                    colors: [MK.Color.accent, MK.Color.magenta, MK.Color.accentWarm, MK.Color.accent],
                    center: .center))
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("Makinect").font(MK.Font.label13).foregroundStyle(MK.Color.textPrimary)
                .padding(.trailing, 8)

            ForEach(MKTab.allCases) { tab in
                MKNavTab(tab: tab, isOn: app.tab == tab) {
                    app.tab = tab
                }
            }

            Spacer()

            HStack(spacing: 6) {
                MKPip(color: MK.Color.success)
                Text(outputLabel)
                    .font(MK.Font.label11)
                    .foregroundStyle(MK.Color.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: MK.Metrics.toolbarHeight)
        .background(MK.Color.bgVibrancy.background(.ultraThinMaterial))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MK.Color.hairline).frame(height: 1)
        }
    }
}

private struct MKNavTab: View {
    let tab: MKTab
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(tab.num)
                    .font(MK.Font.mono09)
                    .foregroundStyle(isOn ? MK.Color.accent : MK.Color.textTertiary)
                Text(tab.label)
                    .font(MK.Font.label11)
                    .foregroundStyle(isOn ? MK.Color.textPrimary : MK.Color.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? MK.Color.accentDim : (hovered ? Color.white.opacity(0.04) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
