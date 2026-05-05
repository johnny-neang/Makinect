// AudioMonitorView — full DSP audio analyzer (Phase B).
//
// Sub-views (top to bottom in the SidePanel GroupBox):
//   1. Waveform — last ~2k samples, drawn as a Path.
//   2. FFT bars — 8 logarithmic bands w/ peak-hold.
//   3. Spectrogram waterfall — 256 × 64 scrolling magnitude grid.
//   4. Numerical readouts — Pitch, Chord, Key, BPM (with tap-tempo button).
//   5. Levels — RMS / peak / LUFS.
//   6. Onset LED — flashes on detected onset.
//
// All data comes from AudioEngine's `@Observable` properties; the UI just
// re-renders when they change.

import SwiftUI

struct AudioMonitorView: View {
    @Bindable var audio: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // — Permission + flow diagnostic. If `tapCallbackCount` stays at
            //   0 after the engine starts, audio isn't reaching us — most
            //   commonly because the user hasn't granted mic permission,
            //   or because a silent device (Kinect) is selected.
            if audio.permission != .authorized {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: audio.permission == .denied ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(audio.permission == .denied ? .red : .yellow)
                        Text("Mic: \(audio.permission.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Button("Request") { audio.requestPermission() }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                        Button("Open Settings") { audio.openMicrophoneSettings() }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(audio.tapCallbackCount > 0 ? .green : .secondary)
                    Text("Buffers: \(audio.tapCallbackCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let err = audio.lastEngineError {
                        Spacer()
                        Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                    Spacer()
                }
            }

            WaveformView(samples: audio.waveform)
                .frame(height: 50)

            FFTBarsView(bands: audio.bands)
                .frame(height: 60)

            SpectrogramWaterfallView(latestColumn: audio.spectrumColumn)
                .frame(height: 90)

            HStack(spacing: 10) {
                NumericReadout(label: "Pitch",
                               value: audio.pitchHz > 0
                                ? String(format: "%@ (%.0f Hz)", audio.pitchNoteName, audio.pitchHz)
                                : "—",
                               confidence: audio.pitchConfidence)
                NumericReadout(label: "Chord",
                               value: audio.chordName,
                               confidence: audio.chordConfidence)
            }
            HStack(spacing: 10) {
                NumericReadout(label: "Key",
                               value: audio.keyName,
                               confidence: audio.keyConfidence)
                BPMReadout(audio: audio)
            }

            LevelsView(rms: audio.rms, rmsPeak: audio.rmsPeak, lufs: audio.lufs)

            HStack(spacing: 8) {
                OnsetLED(active: audio.onset)
                Text(audio.onset ? "Onset" : "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// — Waveform view: simple Path drawn across the buffer.
private struct WaveformView: View {
    let samples: [Float]
    var body: some View {
        Canvas { ctx, size in
            guard !samples.isEmpty else { return }
            // Draw zero baseline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)

            // Draw the waveform as a polyline.
            var path = Path()
            let step = max(1, samples.count / Int(size.width))
            for i in stride(from: 0, to: samples.count, by: step) {
                let x = CGFloat(i) / CGFloat(samples.count) * size.width
                let y = size.height / 2 - CGFloat(samples[i]) * size.height * 0.5
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else      { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path,
                       with: .color(.green.opacity(0.85)),
                       lineWidth: 1.2)
        }
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
    }
}

// — 8-band FFT bar meter with peak-hold animation.
private struct FFTBarsView: View {
    let bands: [Float]
    @State private var peaks: [Float] = Array(repeating: 0, count: 8)

    var body: some View {
        GeometryReader { geo in
            let n = max(1, bands.count)
            let barW = (geo.size.width - CGFloat(n - 1) * 2) / CGFloat(n)
            HStack(spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    let v = CGFloat(min(1.0, bands[i] * 6))
                    let p = CGFloat(min(1.0, peaks[i] * 6))
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.05))
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.green, .yellow, .red],
                                startPoint: .bottom, endPoint: .top))
                            .frame(height: max(2, geo.size.height * v))
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(height: 1.5)
                            .offset(y: -max(2, geo.size.height * p))
                    }
                    .frame(width: barW)
                }
            }
            .onChange(of: bands) { _, new in
                for i in 0..<min(peaks.count, new.count) {
                    if new[i] > peaks[i] { peaks[i] = new[i] }
                    else { peaks[i] *= 0.95 }
                }
            }
        }
        .background(Color.black.opacity(0.4))
        .cornerRadius(4)
    }
}

// — Spectrogram waterfall: maintain a local ring of recent columns and
//   draw as a horizontally-scrolling 2D grid of color-mapped magnitudes.
private struct SpectrogramWaterfallView: View {
    let latestColumn: [Float]

    @State private var history: [[Float]] = Array(
        repeating: Array(repeating: 0, count: AudioEngine.spectrogramBins),
        count: 256)
    @State private var lastColumnHash: Int = 0

    var body: some View {
        Canvas { ctx, size in
            guard !history.isEmpty, !history[0].isEmpty else { return }
            let cols = history.count
            let rows = history[0].count
            let cellW = size.width / CGFloat(cols)
            let cellH = size.height / CGFloat(rows)
            for c in 0..<cols {
                let col = history[c]
                for r in 0..<rows {
                    let v = min(1.0, col[r] * 7)
                    if v < 0.02 { continue }
                    // Magma-ish colour ramp: black → indigo → magenta → yellow → white.
                    let color: Color
                    if v < 0.25 { color = Color(hue: 0.75, saturation: 0.9, brightness: Double(v) * 4 * 0.7) }
                    else if v < 0.55 { color = Color(hue: 0.92, saturation: 0.95, brightness: 0.7 + Double(v - 0.25) * 1.0) }
                    else if v < 0.80 { color = Color(hue: 0.10, saturation: 0.95, brightness: 0.85 + Double(v - 0.55)) }
                    else            { color = Color(hue: 0.18, saturation: 0.30, brightness: 1.0) }
                    let rect = CGRect(
                        x: CGFloat(c) * cellW,
                        y: size.height - CGFloat(r + 1) * cellH,
                        width: cellW + 0.5,    // tiny overlap to avoid seams
                        height: cellH + 0.5
                    )
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .background(Color.black)
        .cornerRadius(4)
        .onChange(of: latestColumn) { _, newCol in
            // Append latest column, drop the oldest. Also dedup
            // identical successive columns so a paused audio stream doesn't
            // overwrite history.
            var hashSeed: Int = 0
            for v in newCol { hashSeed = hashSeed &* 31 &+ Int(v * 1000) }
            guard hashSeed != lastColumnHash else { return }
            lastColumnHash = hashSeed
            history.removeFirst()
            history.append(newCol)
        }
    }
}

// — Numeric readout pill (label + value + tiny confidence bar).
private struct NumericReadout: View {
    let label: String
    let value: String
    let confidence: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ConfidenceBar(value: confidence)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.black.opacity(0.4))
        .cornerRadius(4)
    }
}

// — BPM readout with a tap-tempo button.
private struct BPMReadout: View {
    @Bindable var audio: AudioEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("BPM")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Tap") { audio.tapTempo() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(audio.bpm > 0 ? String(format: "%.1f", audio.bpm) : "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
            ConfidenceBar(value: audio.bpmConfidence)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.black.opacity(0.4))
        .cornerRadius(4)
    }
}

private struct ConfidenceBar: View {
    let value: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.1))
                Rectangle().fill(Color.green.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, value))))
            }
        }
        .cornerRadius(1)
    }
}

// — Levels: RMS bar with peak hold and LUFS readout.
private struct LevelsView: View {
    let rms: Float
    let rmsPeak: Float
    let lufs: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LEVELS").font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "RMS %.3f · Peak %.3f", rms, rmsPeak))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.1))
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.green, .yellow, .red],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(1.0, rms * 5)))
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(min(1.0, rmsPeak * 5)) - 1)
                }
            }
            .frame(height: 6)
            .cornerRadius(2)

            HStack {
                Text("LUFS").font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f LUFS", lufs))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let lufsNormalized = (lufs + 70) / 70  // -70..0 → 0..1
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.1))
                    Rectangle()
                        .fill(Color.cyan.opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(min(1.0, max(0, lufsNormalized))))
                }
            }
            .frame(height: 4)
            .cornerRadius(2)
        }
    }
}

// — Onset LED with brief glow.
private struct OnsetLED: View {
    let active: Bool
    var body: some View {
        Circle()
            .fill(active ? Color.red : Color.red.opacity(0.2))
            .overlay(
                Circle().stroke(Color.red.opacity(active ? 0.8 : 0.3), lineWidth: 1)
            )
            .frame(width: 10, height: 10)
            .shadow(color: active ? .red : .clear, radius: active ? 4 : 0)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}
