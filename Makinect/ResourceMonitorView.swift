// ResourceMonitorView — compact CPU / memory / FPS readout for the SidePanel.
//
// Three rows of stats, each with a numeric value and (where useful) a colored
// bar. Designed to live alongside the Audio Monitor as a "system status"
// section, so a VJ can see at a glance whether they have headroom or are
// approaching frame drops.

import SwiftUI

struct ResourceMonitorView: View {
    @Bindable var monitor: ResourceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // — FPS — colored: green ≥55, yellow 30..55, red <30
            HStack(spacing: 8) {
                Text("FPS")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                Text(String(format: "%.0f", monitor.fps))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(fpsColor(monitor.fps))
                Spacer()
                Text("60 target")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // — CPU — bar scales 0..(coreCount × 100) but we display as % of total
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("CPU")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                    Text(String(format: "%.0f%%", min(100.0, monitor.cpuPercent / monitor.coreCount)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Spacer()
                    Text(String(format: "%.0f%% total · %d cores",
                                monitor.cpuPercent,
                                Int(monitor.coreCount)))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                GeometryReader { geo in
                    let frac = min(1.0, monitor.cpuPercent / (monitor.coreCount * 100.0))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.1))
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.green, .yellow, .red],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(frac))
                    }
                }
                .frame(height: 4)
                .cornerRadius(2)
            }

            // — Memory
            HStack(spacing: 8) {
                Text("MEM")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                Text(String(format: "%.0f MB", monitor.memoryMB))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Text(String(format: "%.2f GB", monitor.memoryMB / 1024.0))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fpsColor(_ fps: Double) -> Color {
        if fps >= 55 { return .green }
        if fps >= 30 { return .yellow }
        return .red
    }
}
