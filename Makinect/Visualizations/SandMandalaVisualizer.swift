// SandMandalaVisualizer — A million coloured grains forming a precise mandala
// pattern that explodes as you move and slowly self-heals.
//
// Inspiration: Tibetan sand-mandala practice, Onformative *Pattern Studies*,
// the meditative ephemerality at the heart of TeamLab's *Co-Creative* series.
//
// Each grain has (current_position, target_position, velocity). Spring force
// pulls toward target. Body presence acts as a repulsor. Onset triggers a
// pattern-morph: the targets are recomputed from a new mandala parameterisation
// (rotation, mirror, n-fold symmetry), and grains migrate to the new positions.

import Metal
import MetalKit
import simd

@MainActor
final class SandMandalaVisualizer: Visualizer {
    private static let grainCount = 1024 * 256   // ~262k grains

    private struct Grain {
        var current: SIMD4<Float>   // (x, y, hue, life)
        var target:  SIMD4<Float>   // (x, y, _, _)
        var velocity: SIMD4<Float>  // (vx, vy, _, _)
    }

    private struct SMUniforms {
        var ctrl: SIMD4<Float>     // (time, count, springK, damping)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var pattern: SIMD4<Float>  // (rotation, symmetry, ringScale, morphSeed)
    }

    private let initPSO: MTLComputePipelineState
    private let stepPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    private var bufA: MTLBuffer
    private var bufB: MTLBuffer
    private var initialized = false
    private var morphSeed: Float = 0
    private var lastOnset: Float = 0
    private var rotationAccum: Float = 0

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let initFn = library.makeFunction(name: "sm_init_kernel"),
              let stepFn = library.makeFunction(name: "sm_step_kernel") else { return nil }
        guard let initPSO = try? device.makeComputePipelineState(function: initFn),
              let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        let dr = MTLRenderPipelineDescriptor()
        dr.vertexFunction = library.makeFunction(name: "sm_point_vs")
        dr.fragmentFunction = library.makeFunction(name: "sm_point_fs")
        dr.colorAttachments[0].pixelFormat = colorPixelFormat
        dr.depthAttachmentPixelFormat = .depth32Float
        dr.colorAttachments[0].isBlendingEnabled = true
        dr.colorAttachments[0].rgbBlendOperation = .add
        dr.colorAttachments[0].sourceRGBBlendFactor = .one
        dr.colorAttachments[0].destinationRGBBlendFactor = .one
        dr.colorAttachments[0].sourceAlphaBlendFactor = .one
        dr.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let drawPSO = try? device.makeRenderPipelineState(descriptor: dr) else { return nil }

        let bytes = MemoryLayout<Grain>.stride * Self.grainCount
        guard let a = device.makeBuffer(length: bytes, options: [.storageModePrivate]),
              let b = device.makeBuffer(length: bytes, options: [.storageModePrivate]) else { return nil }

        self.initPSO = initPSO
        self.stepPSO = stepPSO
        self.drawPSO = drawPSO
        self.bufA = a
        self.bufB = b
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        // On every onset: shuffle pattern (slight rotation + new morph seed).
        if inputs.audio.onset && lastOnset < 0.5 {
            morphSeed = Float.random(in: 0..<1)
            rotationAccum += .pi / 6
        }
        lastOnset = inputs.audio.onset ? 1 : 0
        rotationAccum += 0.0015

        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)

        var u = SMUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, Float(Self.grainCount), 0.022, 0.91 - inputs.audio.rms * 0.02),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            pattern: SIMD4<Float>(rotationAccum, 8.0 + bassLow * 4.0, 0.45, morphSeed)
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        if !initialized, let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(initPSO)
            enc.setBuffer(bufA, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<SMUniforms>.stride, index: 1)
            dispatch1D(enc: enc, pso: initPSO, count: Self.grainCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            initialized = true
        }

        if let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(stepPSO)
            enc.setBuffer(bufA, offset: 0, index: 0)
            enc.setBuffer(bufB, offset: 0, index: 1)
            enc.setTexture(inputs.textures.registeredDepthTexture, index: 0)
            enc.setBytes(&u, length: MemoryLayout<SMUniforms>.stride, index: 2)
            enc.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            dispatch1D(enc: enc, pso: stepPSO, count: Self.grainCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            swap(&bufA, &bufB)
        }

        encoder.setRenderPipelineState(drawPSO)
        encoder.setVertexBuffer(bufA, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<SMUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.grainCount)
    }

    private func dispatch1D(enc: MTLComputeCommandEncoder, pso: MTLComputePipelineState, count: Int) {
        let tw = min(pso.threadExecutionWidth, 64)
        let grid = MTLSize(width: (count + tw - 1) / tw, height: 1, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
    }
}
