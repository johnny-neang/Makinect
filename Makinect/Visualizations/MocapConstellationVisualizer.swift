// MocapConstellationVisualizer — Each joint position from the last few seconds
// becomes a "star" in a constellation; new positions emit gravitational
// shockwaves that ripple outward. In synthetic mode (no skeleton), procedural
// orbital paths populate the field.
//
// Inspiration: TeamLab *Spatial Calligraphy* and *Life Born from Trajectories*,
// Klaus Obermaier's choreography. The work isn't where the body IS — it's the
// trail of where it WAS.

import Metal
import MetalKit
import simd
import Vision

@MainActor
final class MocapConstellationVisualizer: Visualizer {
    private static let starCapacity = 1024  // ~17s of skeletal history at 30 Hz × 2 skeletons × 8 joints

    private struct StarGPU {
        var posBirthHue: SIMD4<Float>   // (x, y, birthTime, hue)
        var energy:      SIMD4<Float>   // (energy, _, _, _)
    }

    private struct MCUniforms {
        var ctrl: SIMD4<Float>     // (time, count, aspect, _)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var visual: SIMD4<Float>   // (starCoreSize, ringGrowth, ringWidth, audioCoupling)
    }

    private let pipeline: MTLRenderPipelineState
    private let starBuffer: MTLBuffer
    private var stars: [StarGPU] = []
    private var head = 0
    private var lastEmit: Float = 0
    private var startTime = Date()

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "mocap_constellation_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso

        guard let buf = device.makeBuffer(
            length: MemoryLayout<StarGPU>.stride * Self.starCapacity,
            options: [.storageModeShared]
        ) else { return nil }
        self.starBuffer = buf

        stars = Array(repeating: StarGPU(
            posBirthHue: SIMD4<Float>(0, 0, -1000, 0),
            energy: SIMD4<Float>(0, 0, 0, 0)
        ), count: Self.starCapacity)
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let now = Float(Date().timeIntervalSince(startTime))
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)
        let cfg = inputs.mocapConstellation

        // Emit new stars at the user-configured cadence.
        if now - lastEmit > cfg.emissionRate {
            lastEmit = now
            if !inputs.skeletons.isEmpty {
                for skel in inputs.skeletons {
                    for j in skel.joints where j.confidence > 0.3 {
                        let h = cfg.randomizeHue ? hueFor(joint: j.name) : cfg.baseHue
                        addStar(x: Float(j.position.x),
                                y: Float(j.position.y),
                                hue: h,
                                now: now,
                                energy: 1.0 + (inputs.audio.onset ? 1.5 : 0))
                    }
                }
            } else {
                // Synthetic: 4 orbiting joint-like points trace a body figure.
                for i in 0..<4 {
                    let phase = now * (0.4 + Float(i) * 0.13)
                    let r: Float = 0.18 + Float(i % 2) * 0.12
                    let cx = 0.5 + cos(phase + Float(i) * 1.4) * r
                    let cy = 0.5 + sin(phase * 0.9 + Float(i) * 1.1) * r
                    let h = cfg.randomizeHue ? Float(i) / 4 : cfg.baseHue
                    addStar(x: cx, y: cy, hue: h, now: now,
                            energy: 1.0 + (inputs.audio.onset ? 1.5 : 0))
                }
            }
        }

        // — Lifespan-based purge: stars older than `cfg.starLifespan` get
        //   their birth time pushed past the shader's age limit so they
        //   stop drawing immediately when the slider tightens.
        let cutoff = now - cfg.starLifespan
        for i in 0..<stars.count where stars[i].posBirthHue.z > -100 && stars[i].posBirthHue.z < cutoff {
            stars[i].posBirthHue.z = -1000
        }

        // Upload buffer.
        let ptr = starBuffer.contents().bindMemory(to: StarGPU.self, capacity: Self.starCapacity)
        for i in 0..<Self.starCapacity { ptr[i] = stars[i] }

        var u = MCUniforms(
            ctrl: SIMD4<Float>(now, Float(Self.starCapacity),
                               Float(view.drawableSize.width / max(1, view.drawableSize.height)), 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            visual: SIMD4<Float>(cfg.starCoreSize, cfg.ringGrowth, cfg.ringWidth, cfg.audioCoupling)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(starBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<MCUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func addStar(x: Float, y: Float, hue: Float, now: Float, energy: Float) {
        stars[head] = StarGPU(
            posBirthHue: SIMD4<Float>(x, y, now, hue),
            energy: SIMD4<Float>(energy, 0, 0, 0)
        )
        head = (head + 1) % Self.starCapacity
    }

    private func hueFor(joint name: VNHumanBodyPoseObservation.JointName) -> Float {
        let s = name.rawValue.rawValue
        var h: UInt32 = 2166136261
        for c in s.utf8 { h = (h ^ UInt32(c)) &* 16777619 }
        return Float(h % 360) / 360.0
    }
}
