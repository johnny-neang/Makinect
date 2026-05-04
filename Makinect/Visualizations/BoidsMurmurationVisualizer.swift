// BoidsMurmurationVisualizer — Starling murmuration of 32k birds where the
// body is a peregrine the flock rivers around. Bass triggers the famous
// shape-shifting turn waves seen in real murmurations.
//
// Inspiration: Three.js gpgpu/birds, Craig Reynolds boids (1987), BBC Earth
// murmuration footage, Sophy Hollington's "Liminal" still photography.
//
// Pipeline:
//   1. Compute kernel: each bird samples K nearest neighbours (we use a coarse
//      spatial hash via 32×32 bins) and applies separation/alignment/cohesion.
//   2. Body acts as a predator the flock turns away from.
//   3. Render as small directional wing billboards, additively blended.

import Metal
import MetalKit
import simd

@MainActor
final class BoidsMurmurationVisualizer: Visualizer {
    private static let birdCount = 1024 * 32   // 32k birds

    private struct Bird {
        var posSpeed: SIMD4<Float>     // (x, y, speed, _)
        var velocity: SIMD4<Float>     // (vx, vy, _, _)
    }

    private struct BMUniforms {
        var ctrl: SIMD4<Float>     // (time, count, dt, _)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var weights: SIMD4<Float>  // (separation, alignment, cohesion, predator)
    }

    private let initPSO: MTLComputePipelineState
    private let stepPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    private var birdsA: MTLBuffer
    private var birdsB: MTLBuffer
    private var initialized = false

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let initFn = library.makeFunction(name: "bm_init_kernel"),
              let stepFn = library.makeFunction(name: "bm_step_kernel") else { return nil }
        guard let initPSO = try? device.makeComputePipelineState(function: initFn),
              let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        let dr = MTLRenderPipelineDescriptor()
        dr.vertexFunction = library.makeFunction(name: "bm_bird_vs")
        dr.fragmentFunction = library.makeFunction(name: "bm_bird_fs")
        dr.colorAttachments[0].pixelFormat = colorPixelFormat
        dr.depthAttachmentPixelFormat = .depth32Float
        dr.colorAttachments[0].isBlendingEnabled = true
        dr.colorAttachments[0].rgbBlendOperation = .add
        dr.colorAttachments[0].sourceRGBBlendFactor = .one
        dr.colorAttachments[0].destinationRGBBlendFactor = .one
        dr.colorAttachments[0].sourceAlphaBlendFactor = .one
        dr.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let drawPSO = try? device.makeRenderPipelineState(descriptor: dr) else { return nil }

        let bytes = MemoryLayout<Bird>.stride * Self.birdCount
        guard let a = device.makeBuffer(length: bytes, options: [.storageModePrivate]),
              let b = device.makeBuffer(length: bytes, options: [.storageModePrivate]) else { return nil }

        self.initPSO = initPSO
        self.stepPSO = stepPSO
        self.drawPSO = drawPSO
        self.birdsA = a
        self.birdsB = b
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)

        var u = BMUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, Float(Self.birdCount), 1.0 / 60.0, 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            weights: SIMD4<Float>(
                0.05 + bassLow * 0.04,    // separation
                0.04,                      // alignment
                0.012 + treb * 0.02,       // cohesion
                inputs.audio.onset ? 0.30 : 0.10  // predator strength
            )
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        if !initialized, let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(initPSO)
            enc.setBuffer(birdsA, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<BMUniforms>.stride, index: 1)
            dispatch1D(enc: enc, pso: initPSO, count: Self.birdCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            initialized = true
        }

        if let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(stepPSO)
            enc.setBuffer(birdsA, offset: 0, index: 0)
            enc.setBuffer(birdsB, offset: 0, index: 1)
            enc.setTexture(inputs.textures.registeredDepthTexture, index: 0)
            enc.setBytes(&u, length: MemoryLayout<BMUniforms>.stride, index: 2)
            enc.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            dispatch1D(enc: enc, pso: stepPSO, count: Self.birdCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            swap(&birdsA, &birdsB)
        }

        encoder.setRenderPipelineState(drawPSO)
        encoder.setVertexBuffer(birdsA, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<BMUniforms>.stride, index: 1)
        // Each bird is a 4-vertex quad (triangle strip) → bird wings.
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0, vertexCount: 4,
            instanceCount: Self.birdCount
        )
    }

    private func dispatch1D(enc: MTLComputeCommandEncoder, pso: MTLComputePipelineState, count: Int) {
        let tw = min(pso.threadExecutionWidth, 64)
        let grid = MTLSize(width: (count + tw - 1) / tw, height: 1, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
    }
}
