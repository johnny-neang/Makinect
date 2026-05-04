// StrandVeilVisualizer — A million curl-noise advected hair-like strands cascade
// over the body. Each strand is rendered as an instanced multi-segment line
// with anisotropic Disney-inspired hair shading.
//
// Inspiration: Disney "Strand-based Hair" rendering, Refik Anadol *Living
// Memory: Messi*, Universal Everything's flow systems.

import Metal
import MetalKit
import simd

@MainActor
final class StrandVeilVisualizer: Visualizer {
    private static let strandCount = 8000
    private static let segmentsPerStrand = 24
    private static var verticesPerStrand: Int { segmentsPerStrand * 2 }

    private struct StrandHead {
        var posPhase: SIMD4<Float>   // (x, y, phase, length)
        var velocityHue: SIMD4<Float>  // (vx, vy, hue, _)
    }

    private struct SVUniforms {
        var ctrl: SIMD4<Float>     // (time, count, segments, _)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var aspectFlow: SIMD4<Float>  // (aspect, flowScale, gravity, _)
    }

    private let initPSO: MTLComputePipelineState
    private let stepPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    private var headsA: MTLBuffer
    private var headsB: MTLBuffer
    private var initialized = false

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let initFn = library.makeFunction(name: "sv_init_kernel"),
              let stepFn = library.makeFunction(name: "sv_step_kernel") else { return nil }
        guard let initPSO = try? device.makeComputePipelineState(function: initFn),
              let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        let dr = MTLRenderPipelineDescriptor()
        dr.vertexFunction = library.makeFunction(name: "sv_strand_vs")
        dr.fragmentFunction = library.makeFunction(name: "sv_strand_fs")
        dr.colorAttachments[0].pixelFormat = colorPixelFormat
        dr.depthAttachmentPixelFormat = .depth32Float
        dr.colorAttachments[0].isBlendingEnabled = true
        dr.colorAttachments[0].rgbBlendOperation = .add
        dr.colorAttachments[0].sourceRGBBlendFactor = .one
        dr.colorAttachments[0].destinationRGBBlendFactor = .one
        dr.colorAttachments[0].sourceAlphaBlendFactor = .one
        dr.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let drawPSO = try? device.makeRenderPipelineState(descriptor: dr) else { return nil }

        let bytes = MemoryLayout<StrandHead>.stride * Self.strandCount
        guard let a = device.makeBuffer(length: bytes, options: [.storageModePrivate]),
              let b = device.makeBuffer(length: bytes, options: [.storageModePrivate]) else { return nil }

        self.initPSO = initPSO
        self.stepPSO = stepPSO
        self.drawPSO = drawPSO
        self.headsA = a
        self.headsB = b
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)

        var u = SVUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, Float(Self.strandCount), Float(Self.segmentsPerStrand), 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            aspectFlow: SIMD4<Float>(
                Float(view.drawableSize.width / max(1, view.drawableSize.height)),
                0.6 + bassLow * 0.8, 0.4, 0
            )
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        if !initialized, let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(initPSO)
            enc.setBuffer(headsA, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<SVUniforms>.stride, index: 1)
            dispatch1D(enc: enc, pso: initPSO, count: Self.strandCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            initialized = true
        }

        if let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(stepPSO)
            enc.setBuffer(headsA, offset: 0, index: 0)
            enc.setBuffer(headsB, offset: 0, index: 1)
            enc.setTexture(inputs.textures.registeredDepthTexture, index: 0)
            enc.setBytes(&u, length: MemoryLayout<SVUniforms>.stride, index: 2)
            enc.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            dispatch1D(enc: enc, pso: stepPSO, count: Self.strandCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            swap(&headsA, &headsB)
        }

        encoder.setRenderPipelineState(drawPSO)
        encoder.setVertexBuffer(headsA, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<SVUniforms>.stride, index: 1)
        // Each strand is rendered as a strip of (segmentsPerStrand) line segments.
        encoder.drawPrimitives(
            type: .lineStrip,
            vertexStart: 0,
            vertexCount: Self.segmentsPerStrand,
            instanceCount: Self.strandCount
        )
    }

    private func dispatch1D(enc: MTLComputeCommandEncoder, pso: MTLComputePipelineState, count: Int) {
        let tw = min(pso.threadExecutionWidth, 64)
        let grid = MTLSize(width: (count + tw - 1) / tw, height: 1, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
    }
}
