// MagneticIronFilingsVisualizer — A million iron filings aligned along an
// animated magnetic dipole field; the body becomes an extra moving magnet that
// bends and clusters them. Bass triggers polarity flips.
//
// Inspiration: Daniel Shiffman *Nature of Code* ch.6, Faraday-style field
// visualisations, Universal Everything's flow systems.
//
// Pipeline:
//   1. Compute kernel walks each filing along the field gradient (vector field
//      = sum of moving dipoles + body-mass dipole); the filing stores its new
//      position AND alignment angle.
//   2. Render as elongated line segments stretched along the alignment angle.
//   3. Additive HDR + ACES tone-map.

import Metal
import MetalKit
import simd

@MainActor
final class MagneticIronFilingsVisualizer: Visualizer {
    private static let filingCount = 1024 * 192   // ~196k filings

    private struct Filing {
        var posAngle: SIMD4<Float>   // (x, y, angle, life)
    }

    private struct MIFUniforms {
        var ctrl: SIMD4<Float>       // (time, count, polarity, _)
        var audio: SIMD4<Float>      // (rms, onset, bassLow, treb)
        var bandsLow: SIMD4<Float>
    }

    private let initPSO: MTLComputePipelineState
    private let stepPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    private var bufA: MTLBuffer
    private var bufB: MTLBuffer
    private var initialized = false
    private var polarity: Float = 1.0
    private var lastOnset: Float = 0

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let initFn = library.makeFunction(name: "mif_init_kernel"),
              let stepFn = library.makeFunction(name: "mif_step_kernel") else { return nil }
        guard let initPSO = try? device.makeComputePipelineState(function: initFn),
              let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        let dr = MTLRenderPipelineDescriptor()
        dr.vertexFunction = library.makeFunction(name: "mif_vs")
        dr.fragmentFunction = library.makeFunction(name: "mif_fs")
        dr.colorAttachments[0].pixelFormat = colorPixelFormat
        dr.depthAttachmentPixelFormat = .depth32Float
        dr.colorAttachments[0].isBlendingEnabled = true
        dr.colorAttachments[0].rgbBlendOperation = .add
        dr.colorAttachments[0].sourceRGBBlendFactor = .one
        dr.colorAttachments[0].destinationRGBBlendFactor = .one
        dr.colorAttachments[0].sourceAlphaBlendFactor = .one
        dr.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let drawPSO = try? device.makeRenderPipelineState(descriptor: dr) else { return nil }

        let bytes = MemoryLayout<Filing>.stride * Self.filingCount
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
        if inputs.audio.onset && lastOnset < 0.5 { polarity = -polarity }
        lastOnset = inputs.audio.onset ? 1 : 0
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)

        var u = MIFUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, Float(Self.filingCount), polarity, 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            bandsLow: SIMD4<Float>(
                bands.indices.contains(0) ? bands[0] : 0,
                bands.indices.contains(1) ? bands[1] : 0,
                bands.indices.contains(2) ? bands[2] : 0,
                bands.indices.contains(3) ? bands[3] : 0
            )
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        if !initialized, let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let enc = buf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(initPSO)
            enc.setBuffer(bufA, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<MIFUniforms>.stride, index: 1)
            dispatch1D(enc: enc, pso: initPSO, count: Self.filingCount)
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
            enc.setBytes(&u, length: MemoryLayout<MIFUniforms>.stride, index: 2)
            enc.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            dispatch1D(enc: enc, pso: stepPSO, count: Self.filingCount)
            enc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
            swap(&bufA, &bufB)
        }

        encoder.setRenderPipelineState(drawPSO)
        encoder.setVertexBuffer(bufA, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<MIFUniforms>.stride, index: 1)
        // Each filing renders as a 2-vertex line segment.
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Self.filingCount * 2)
    }

    private func dispatch1D(enc: MTLComputeCommandEncoder, pso: MTLComputePipelineState, count: Int) {
        let tw = min(pso.threadExecutionWidth, 64)
        let grid = MTLSize(width: (count + tw - 1) / tw, height: 1, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
    }
}
