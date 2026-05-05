// VortexRingSmokeVisualizer — Body silhouette emits true vortex rings (Lamb-
// Oseen profile); rings drift, distort each other, and chase across the frame.
//
// Inspiration: smoke-ring physics, Universal Everything *Walking City*,
// classical Houdini smoke sims.
//
// CPU keeps a fixed-size ring pool. Each frame we tick rings (advect by self-
// induced velocity + neighbour influence + audio bias), spawn new rings on
// onset, kill ones that aged out. Fragment shader composites the rings as
// volumetric tori in the depth-aware foreground.

import Metal
import MetalKit
import simd

@MainActor
final class VortexRingSmokeVisualizer: Visualizer {
    private static let maxRings = 24

    private struct Ring {
        var x: Float
        var y: Float
        var radius: Float
        var coreSize: Float
        var strength: Float
        var hue: Float
        var age: Float
        var alive: Bool
    }

    private struct RingGPU {
        var posSize: SIMD4<Float>     // (x, y, radius, coreSize)
        var hueAge: SIMD4<Float>      // (hue, age, strength, alive)
    }

    private struct VRUniforms {
        var ctrl: SIMD4<Float>     // (time, count, aspect, _)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var style: SIMD4<Float>    // (swirlFreq, saturation, bodyBoost, _)
    }

    private let pipeline: MTLRenderPipelineState
    private let ringBuffer: MTLBuffer
    private var rings: [Ring] = []
    private var lastOnset: Float = 0
    private var lastSpawn: Float = 0

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "vortex_ring_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso

        let bytes = MemoryLayout<RingGPU>.stride * Self.maxRings
        guard let buf = device.makeBuffer(length: bytes, options: [.storageModeShared]) else { return nil }
        self.ringBuffer = buf
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)
        let cfg = inputs.vortexRingSmoke

        // Tick — rise speed user-controlled.
        for i in rings.indices where rings[i].alive {
            rings[i].y -= cfg.riseSpeed + bassLow * 0.0035
            rings[i].x += sin(rings[i].age * 0.05) * 0.0008
            rings[i].radius += 0.00045 + treb * 0.0008
            rings[i].age += 1
            if rings[i].age > 280 || rings[i].radius > 0.6 {
                rings[i].alive = false
            }
        }

        // Spawn rings on onset OR periodically while loud (interval tunable).
        let shouldSpawn = (inputs.audio.onset && lastOnset < 0.5) ||
                         (inputs.timeSeconds - lastSpawn > cfg.spawnInterval && inputs.audio.rms > 0.05)
        if shouldSpawn {
            lastSpawn = inputs.timeSeconds
            spawnRing(audio: inputs.audio)
        }
        lastOnset = inputs.audio.onset ? 1 : 0

        // Upload to GPU.
        let ptr = ringBuffer.contents().bindMemory(to: RingGPU.self, capacity: Self.maxRings)
        var uploaded = 0
        for (i, r) in rings.prefix(Self.maxRings).enumerated() {
            if r.alive {
                let lifeT: Float = r.age / 280.0
                let strength = r.strength * (1.0 - lifeT)
                ptr[i] = RingGPU(
                    posSize: SIMD4<Float>(r.x, r.y, r.radius, r.coreSize),
                    hueAge: SIMD4<Float>(r.hue, r.age, strength, 1)
                )
                uploaded += 1
            } else {
                ptr[i] = RingGPU(
                    posSize: SIMD4<Float>(0, 0, 0, 0),
                    hueAge: SIMD4<Float>(0, 0, 0, 0)
                )
            }
        }

        var u = VRUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, Float(uploaded),
                               Float(view.drawableSize.width / max(1, view.drawableSize.height)), 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            style: SIMD4<Float>(cfg.swirlFreq, cfg.saturation, cfg.bodyBoost, 0)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBuffer(ringBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VRUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func spawnRing(audio: AudioEngine) {
        let r = Ring(
            x: Float.random(in: 0.25...0.75),
            y: Float.random(in: 0.78...0.95),  // emit from bottom (Vision origin)
            radius: 0.04 + Float.random(in: 0..<0.025),
            coreSize: 0.03,
            strength: 1.0 + Float(audio.onset ? 0.6 : 0),
            hue: Float.random(in: 0..<1),
            age: 0,
            alive: true
        )
        if let dead = rings.firstIndex(where: { !$0.alive }) {
            rings[dead] = r
        } else if rings.count < Self.maxRings {
            rings.append(r)
        }
    }
}
