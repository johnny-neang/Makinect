// LaserGeometryVisualizer — Phase-1 geometric "laser show" visualizer.
//
// Reproduces the language of the INZO "Overthinker" laser show (see
// docs/lightshow/01-video-analysis.md) on an LED/projection surface: beam
// fans, starbursts, tunnels and polygons drawn as crisp additive vector
// geometry. It is driven entirely from the existing AudioEngine feature
// stream across the three sync timescales the reference analysis identified:
//
//   • structural  — palette + pattern family advance on section boundaries
//   • rhythmic     — scan/rotation + beam-count pulse on the BPM grid
//   • transient    — sharp flashes snap on spectral-flux onsets, then decay
//
// Crucially it encodes *restraint*: during quiet passages (high negative-space
// bias) it renders a single dim fan, or nothing at all (true blackout). Firing
// hard on the hit and then getting out of the way is the whole point.

import Foundation
import Metal
import MetalKit
import simd

@MainActor
final class LaserGeometryVisualizer: Visualizer {
    /// Matches `LaserUniforms` in Shaders.metal.
    private struct GPUUniforms {
        var exposure: Float
        var haloSoftness: Float
        var pad0: Float = 0
        var pad1: Float = 0
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private static let maxVertices = 60_000   // ~10k beam quads

    // — choreographer state (persists across frames) —
    private var started = false
    private var lastTime: Float = 0
    private var beatPhase: Float = 0
    private var spin: Float = 0
    private var energySmooth: Float = 0
    private var onsetEnv: Float = 0
    private var sectionIndex = 0
    private var sinceSection: Float = 99

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "laser_beam_vs")
        desc.fragmentFunction = library.makeFunction(name: "laser_beam_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        // Additive blending — beams accumulate light over the black clear.
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc),
              let vb = device.makeBuffer(length: MemoryLayout<LaserVertex>.stride * Self.maxVertices,
                                         options: [.storageModeShared]) else { return nil }
        self.device = device
        self.pipeline = pso
        self.vertexBuffer = vb
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let cfg = inputs.laserGeometry

        // — timing (clamp pauses/seeks so envelopes don't jump)
        let t = inputs.timeSeconds
        if !started { lastTime = t; started = true }
        var dt = t - lastTime
        lastTime = t
        if dt < 0 || dt > 0.1 { dt = 1.0 / 60.0 }

        // — audio features
        let bands = inputs.audio.bands
        func band(_ i: Int) -> Float { bands.indices.contains(i) ? bands[i] : 0 }
        let bass = band(0) + band(1)
        let mid  = band(2) + band(3) + band(4)
        let treb = band(5) + band(6) + band(7)
        let rms  = inputs.audio.rms
        let onset = inputs.audio.onset

        let energy = min(1.5, rms * 1.5 + bass * 0.5)
        energySmooth += (energy - energySmooth) * min(1, dt * 6)
        // Onset envelope: snap to 1 on a hit, decay fast (~0.4 s) so the
        // transient layer fires hard then vanishes.
        onsetEnv = max(onsetEnv * powf(0.0008, dt), onset ? 1 : 0)

        // — rhythmic layer: phase from BPM (fall back to 120 when unknown)
        let bpm = inputs.audio.bpm > 20 ? inputs.audio.bpm : 120
        beatPhase += dt * (bpm / 60.0) * max(0, cfg.scanSpeed)
        spin += dt * (0.25 + bass * 0.8) * max(0, cfg.scanSpeed)

        // — structural layer: advance a section on a strong onset after the
        //   music has lifted, no more often than every ~4 s.
        sinceSection += dt
        if onset && onsetEnv > 0.6 && sinceSection > 4 && energySmooth > 0.2 {
            sectionIndex += 1
            sinceSection = 0
        }

        let baseHue = cfg.baseHue + Float(sectionIndex) * (cfg.paletteSpread / 3.0)
        func hue(_ off: Float) -> LaserColorHSV { LaserColorHSV(h: baseHue + off, s: cfg.saturation, v: 1.0) }

        var canvas = LaserCanvas()

        // — negative-space gate
        let gate = energySmooth - cfg.negativeSpaceBias * 0.35
        if gate < 0 {
            // Restraint: the intro — one slow, dim violet fan (or nothing if
            // the bias is pinned to maximum).
            if cfg.negativeSpaceBias < 0.98 {
                let sway = sinf(t * 0.3) * 0.25
                canvas.add(LaserPrimitive(
                    shape: .fan(apex: SIMD2<Float>(0, -0.95),
                                angle: Float.pi / 2 + sway,
                                spread: 0.5 + 0.2 * sinf(t * 0.2),
                                count: 5, length: 1.8),
                    width: cfg.beamWidth,
                    color: hue(0),
                    intensity: 0.22 + 0.4 * energySmooth))
            }
        } else {
            // Active: pattern family rotates per section; density follows energy.
            let dens = max(0.05, gate) * max(0.1, cfg.densityCeiling)
            let sym = max(4, Int(Float(cfg.symmetry) * (0.6 + dens)))
            let center = SIMD2<Float>(0, 0)

            switch sectionIndex % 4 {
            case 0: // beam fan from the floor — the "build"
                canvas.add(LaserPrimitive(
                    shape: .fan(apex: SIMD2<Float>(0, -1),
                                angle: Float.pi / 2 + sinf(beatPhase * Float.pi) * 0.4,
                                spread: 1.4, count: 4 + Int(dens * 10), length: 2.3),
                    width: cfg.beamWidth, color: hue(0), intensity: 0.5 + dens))
            case 1: // rotating starburst spokes
                canvas.add(LaserPrimitive(
                    shape: .starburst(center: center, count: sym, radius: 2.0, rotation: spin),
                    width: cfg.beamWidth, color: hue(0.05), intensity: 0.5 + dens))
            case 2: // receding tunnel of N-gons
                canvas.add(LaserPrimitive(
                    shape: .tunnel(center: center, rings: 5 + Int(dens * 4),
                                   innerRadius: 0.15,
                                   spacing: 0.18 + 0.04 * sinf(beatPhase * Float.pi),
                                   sides: max(3, sym / 2), rotation: spin * 0.5),
                    width: cfg.beamWidth, color: hue(0.1), intensity: 0.5 + dens))
            default: // crossing matrix: two opposed fans in complementary hues
                let a = sinf(beatPhase * Float.pi) * 0.3
                let cnt = 3 + Int(dens * 6)
                canvas.add(LaserPrimitive(
                    shape: .fan(apex: SIMD2<Float>(-1, 0.6), angle: -0.5 + a, spread: 1.0, count: cnt, length: 2.7),
                    width: cfg.beamWidth, color: hue(0), intensity: 0.5 + dens))
                canvas.add(LaserPrimitive(
                    shape: .fan(apex: SIMD2<Float>(1, 0.6), angle: Float.pi + 0.5 - a, spread: 1.0, count: cnt, length: 2.7),
                    width: cfg.beamWidth, color: hue(0.5), intensity: 0.5 + dens))
            }

            // Mids add a counter-rotating polygon accent.
            if mid > 0.25 {
                canvas.add(LaserPrimitive(
                    shape: .polygon(center: center, sides: max(3, sym / 3),
                                    radius: 0.3 + mid * 0.5, rotation: -spin),
                    width: cfg.beamWidth, color: hue(0.33), intensity: 0.3 + mid))
            }
        }

        // — transient layer: punch a bright starburst on onsets, treble tints
        //   and widens it. Decays with onsetEnv → restraint between hits.
        if onsetEnv > 0.05 && cfg.onsetPunch > 0 {
            canvas.add(LaserPrimitive(
                shape: .starburst(center: SIMD2<Float>(0, 0),
                                  count: max(6, cfg.symmetry),
                                  radius: 1.6 + treb, rotation: spin * 1.7),
                width: cfg.beamWidth * 1.3,
                color: LaserColorHSV(h: baseHue + 0.5, s: cfg.saturation * 0.6, v: 1.0),
                intensity: 1.4 * onsetEnv * cfg.onsetPunch))
        }

        // — tessellate, upload, draw. Empty canvas → offscreen stays black
        //   (an intentional, composed blackout).
        var verts = canvas.vertices(aspect: aspect)
        if verts.count > Self.maxVertices { verts.removeLast(verts.count - Self.maxVertices) }
        guard !verts.isEmpty else { return }
        verts.withUnsafeBytes { raw in
            if let base = raw.baseAddress { vertexBuffer.contents().copyMemory(from: base, byteCount: raw.count) }
        }

        var u = GPUUniforms(exposure: max(0, cfg.exposure), haloSoftness: max(1, cfg.haloSoftness))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }
}
