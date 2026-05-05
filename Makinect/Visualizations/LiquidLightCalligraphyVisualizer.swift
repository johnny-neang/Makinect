// LiquidLightCalligraphyVisualizer — Joints leave ribbons of "ink" that bleed
// and ripple as if dropped in water. Each stroke gets a tiny stable-fluid sim
// running along its length so the brushstrokes themselves diffuse.
//
// Inspiration: TeamLab *Spatial Calligraphy* / *Life Born from Trajectories*,
// Memo Akten *Waves: Serenity*.
//
// Pipeline:
//   1. CPU emits new ink particles at joint tips each frame.
//   2. Compute kernel advects + diffuses ink in an HDR accumulator.
//   3. Compositor adds chromatic bloom + ACES tone-map.

import Metal
import MetalKit
import simd
import Vision

@MainActor
final class LiquidLightCalligraphyVisualizer: Visualizer {
    private static let bufferWidth = 1280
    private static let bufferHeight = 720
    private static let maxEmitters = 24

    private struct LLUniforms {
        var ctrl: SIMD4<Float>     // (time, decay, viscosity, emitCount)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
    }

    private struct LLEmitter {
        var posHueRadius: SIMD4<Float>  // (xNorm, yNorm, hue, radius)
        var velocity: SIMD4<Float>      // (vx, vy, _, _)
    }

    private let stepPSO: MTLComputePipelineState
    private let compositePSO: MTLRenderPipelineState
    private let accumA: MTLTexture
    private let accumB: MTLTexture
    private var prevAccum: MTLTexture
    private var currAccum: MTLTexture
    private var lastJointPositions: [String: SIMD2<Float>] = [:]

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let stepFn = library.makeFunction(name: "ll_step_kernel") else { return nil }
        guard let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        let cdesc = MTLRenderPipelineDescriptor()
        cdesc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        cdesc.fragmentFunction = library.makeFunction(name: "ll_composite_fs")
        cdesc.colorAttachments[0].pixelFormat = colorPixelFormat
        cdesc.depthAttachmentPixelFormat = .depth32Float
        guard let composite = try? device.makeRenderPipelineState(descriptor: cdesc) else { return nil }

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Self.bufferWidth, height: Self.bufferHeight, mipmapped: false
        )
        td.usage = [.shaderRead, .shaderWrite]
        td.storageMode = .private
        guard let a = device.makeTexture(descriptor: td),
              let b = device.makeTexture(descriptor: td) else { return nil }

        self.stepPSO = stepPSO
        self.compositePSO = composite
        self.accumA = a
        self.accumB = b
        self.prevAccum = a
        self.currAccum = b
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)

        let cfg = inputs.liquidLightCalligraphy

        // Build emitter list from current joints (or procedural orbits).
        var emitters: [LLEmitter] = []
        let brush = cfg.brushRadius
        if !inputs.skeletons.isEmpty {
            for skel in inputs.skeletons {
                for j in skel.joints where j.confidence > 0.3 {
                    let key = j.name.rawValue.rawValue
                    let p = SIMD2<Float>(Float(j.position.x), Float(j.position.y))
                    let v: SIMD2<Float> = lastJointPositions[key].map { p - $0 } ?? .zero
                    lastJointPositions[key] = p
                    let hue = cfg.perJointHue ? hueFor(joint: j.name) : cfg.baseHue
                    emitters.append(LLEmitter(
                        posHueRadius: SIMD4<Float>(p.x, p.y, hue, (0.025 + length(v) * 0.25) * brush),
                        velocity: SIMD4<Float>(v.x, v.y, 0, 0)
                    ))
                    if emitters.count >= Self.maxEmitters { break }
                }
                if emitters.count >= Self.maxEmitters { break }
            }
        } else {
            // Synthetic procedural orbits.
            for i in 0..<6 {
                let t = inputs.timeSeconds
                let phase = t * (0.5 + Float(i) * 0.13)
                let r: Float = 0.18 + Float(i % 3) * 0.10
                let p = SIMD2<Float>(0.5 + cos(phase + Float(i)) * r,
                                     0.5 + sin(phase * 0.9 + Float(i) * 1.1) * r)
                let hue = cfg.perJointHue ? Float(i) / 6 : cfg.baseHue
                emitters.append(LLEmitter(
                    posHueRadius: SIMD4<Float>(p.x, p.y, hue, 0.025 * brush),
                    velocity: SIMD4<Float>(0, 0, 0, 0)
                ))
            }
        }
        let emitCount = min(emitters.count, Self.maxEmitters)
        while emitters.count < Self.maxEmitters {
            emitters.append(LLEmitter(
                posHueRadius: SIMD4<Float>(0, 0, 0, 0),
                velocity: SIMD4<Float>(0, 0, 0, 0)
            ))
        }

        var u = LLUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, cfg.trailDecay,
                               cfg.viscosity + bassLow * 0.0008, Float(emitCount)),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb)
        )

        if let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(stepPSO)
            enc.setTexture(prevAccum, index: 0)
            enc.setTexture(currAccum, index: 1)
            enc.setBytes(&u, length: MemoryLayout<LLUniforms>.stride, index: 0)
            enc.setBytes(&emitters, length: MemoryLayout<LLEmitter>.stride * Self.maxEmitters, index: 1)
            let tw = min(stepPSO.threadExecutionWidth, 16)
            let th = min(stepPSO.maxTotalThreadsPerThreadgroup / tw, 16)
            let grid = MTLSize(
                width: (Self.bufferWidth + tw - 1) / tw,
                height: (Self.bufferHeight + th - 1) / th, depth: 1
            )
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            swap(&prevAccum, &currAccum)
        }

        var dl = DepthLavaUniforms()
        dl.time = inputs.timeSeconds; dl.rms = inputs.audio.rms
        dl.onset = inputs.audio.onset ? 1 : 0
        dl.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        if bands.count >= 8 {
            dl.bands = (bands[0], bands[1], bands[2], bands[3], bands[4], bands[5], bands[6], bands[7])
        }
        encoder.setRenderPipelineState(compositePSO)
        encoder.setFragmentTexture(prevAccum, index: 0)
        encoder.setFragmentBytes(&dl, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func hueFor(joint name: VNHumanBodyPoseObservation.JointName) -> Float {
        let s = name.rawValue.rawValue
        var h: UInt32 = 2166136261
        for c in s.utf8 { h = (h ^ UInt32(c)) &* 16777619 }
        return Float(h % 360) / 360.0
    }
}
