// ParticleStormVisualizer — A million GPU particles flowing through your silhouette
// like wind through a screen door. Inspiration: Memo Akten's "Forms", Universal
// Everything's "Walking City", Onformative's particle systems.
//
// Particles live in two ping-pong MTLBuffers. A compute kernel each frame
// integrates a curl-noise + audio-modulated velocity field; depth becomes an
// attractor / repulsor. Render uses point sprites with additive blending and a
// final tone-mapped composite for HDR bloom.

import Metal
import MetalKit
import simd

@MainActor
final class ParticleStormVisualizer: Visualizer {
    /// Buffer ceiling — the active count comes from
    /// `ParticleStormConfig.particleCount` and is clamped against this.
    private static let maxParticleCount = 1024 * 256  // 262k particles

    private struct Particle {
        // (x, y, z, life)  — z folded out (we render in 2D), life in [0,1]
        var posLife: SIMD4<Float>
        // (vx, vy, vz, age)
        var velAge: SIMD4<Float>
        // (hue, brightness, _, _)
        var color: SIMD4<Float>
    }

    private struct PSUniforms {
        var ctrl: SIMD4<Float>     // (time, dt, count, _)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var bandsLow: SIMD4<Float>
        var bandsHi: SIMD4<Float>
        // — Bespoke user controls (ParticleStormConfig)
        var motion: SIMD4<Float>   // (curlScale, accelGain, damping, bodyPull)
        var burst: SIMD4<Float>    // (onsetBurst, recycleAge, baseHue, hueSpread)
        var paint: SIMD4<Float>    // (pointSizeBase, speedToSize, jitterAmount, saturation)
    }

    private let stepPSO: MTLComputePipelineState
    private let initPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    private var bufA: MTLBuffer
    private var bufB: MTLBuffer
    private var initialized = false

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let stepFn = library.makeFunction(name: "ps_step_kernel"),
              let initFn = library.makeFunction(name: "ps_init_kernel") else { return nil }
        guard let stepPSO = try? device.makeComputePipelineState(function: stepFn),
              let initPSO = try? device.makeComputePipelineState(function: initFn) else { return nil }

        let drawDesc = MTLRenderPipelineDescriptor()
        drawDesc.vertexFunction = library.makeFunction(name: "ps_point_vs")
        drawDesc.fragmentFunction = library.makeFunction(name: "ps_point_fs")
        drawDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        drawDesc.depthAttachmentPixelFormat = .depth32Float
        drawDesc.colorAttachments[0].isBlendingEnabled = true
        drawDesc.colorAttachments[0].rgbBlendOperation = .add
        drawDesc.colorAttachments[0].alphaBlendOperation = .add
        drawDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        drawDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        drawDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        drawDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let drawPSO = try? device.makeRenderPipelineState(descriptor: drawDesc) else { return nil }

        let bytes = MemoryLayout<Particle>.stride * Self.maxParticleCount
        guard let a = device.makeBuffer(length: bytes, options: [.storageModePrivate]),
              let b = device.makeBuffer(length: bytes, options: [.storageModePrivate]) else { return nil }

        self.stepPSO = stepPSO
        self.initPSO = initPSO
        self.drawPSO = drawPSO
        self.bufA = a
        self.bufB = b
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)
        let cfg = inputs.particleStorm
        let count = max(1024, min(Self.maxParticleCount, cfg.particleCount))

        var u = PSUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, 1.0 / 60.0, Float(count), 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            bandsLow: SIMD4<Float>(
                bands.indices.contains(0) ? bands[0] : 0,
                bands.indices.contains(1) ? bands[1] : 0,
                bands.indices.contains(2) ? bands[2] : 0,
                bands.indices.contains(3) ? bands[3] : 0
            ),
            bandsHi: SIMD4<Float>(
                bands.indices.contains(4) ? bands[4] : 0,
                bands.indices.contains(5) ? bands[5] : 0,
                bands.indices.contains(6) ? bands[6] : 0,
                bands.indices.contains(7) ? bands[7] : 0
            ),
            motion: SIMD4<Float>(cfg.curlScale, cfg.accelGain, cfg.damping, cfg.bodyPull),
            burst:  SIMD4<Float>(cfg.onsetBurst, cfg.recycleAge, cfg.baseHue, cfg.hueSpread),
            paint:  SIMD4<Float>(cfg.pointSizeBase, cfg.speedToSize, cfg.jitterAmount, cfg.saturation)
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        // Init pass on first frame — initializes the full max-buffer once
        // so a later particle-count slider increase doesn't reveal
        // uninitialized memory at the new tail.
        if !initialized, let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            var initU = u
            initU.ctrl.z = Float(Self.maxParticleCount)
            enc.setComputePipelineState(initPSO)
            enc.setBuffer(bufA, offset: 0, index: 0)
            enc.setBytes(&initU, length: MemoryLayout<PSUniforms>.stride, index: 1)
            let tw = min(initPSO.threadExecutionWidth, 64)
            let grid = MTLSize(
                width: (Self.maxParticleCount + tw - 1) / tw, height: 1, depth: 1
            )
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            initialized = true
        }

        // Step pass: ping-pong A → B (only active count).
        if let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(stepPSO)
            enc.setBuffer(bufA, offset: 0, index: 0)
            enc.setBuffer(bufB, offset: 0, index: 1)
            enc.setTexture(inputs.textures.registeredDepthTexture, index: 0)
            enc.setBytes(&u, length: MemoryLayout<PSUniforms>.stride, index: 2)
            enc.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            let tw = min(stepPSO.threadExecutionWidth, 64)
            let grid = MTLSize(
                width: (count + tw - 1) / tw, height: 1, depth: 1
            )
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            swap(&bufA, &bufB)
        }

        // Render only the active particle count.
        encoder.setRenderPipelineState(drawPSO)
        encoder.setVertexBuffer(bufA, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<PSUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
    }
}
