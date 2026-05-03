// OpticalFlowVisualizer — Optical-flow-driven painting. Inspiration: Memo Akten's
// "Learning to See", Casey Reas' generative paint systems.
//
// Each frame: estimate per-pixel motion from the depth buffer (depth differences
// between current and previous frame), then advect a color "paint" texture along
// the flow vectors with a tiny viscosity term. New paint splats where motion is
// strong; the FFT bands rotate the palette.
//
// Three textures: prevDepth (R32Float), paintA / paintB (RGBA16F ping-pong).

import Metal
import MetalKit
import simd

@MainActor
final class OpticalFlowVisualizer: Visualizer {
    private static let simWidth = 640
    private static let simHeight = 360

    private struct OFUniforms {
        var ctrl: SIMD4<Float>     // (time, dt, viscosity, motionGate)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
        var palette: SIMD4<Float>  // (hueA, hueB, sat, val)
    }

    private let advectPSO: MTLComputePipelineState
    private let copyDepthPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    private var prevDepth: MTLTexture
    private var paintA: MTLTexture
    private var paintB: MTLTexture
    private var startTime = Date()

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let advFn = library.makeFunction(name: "of_advect_kernel"),
              let cpyFn = library.makeFunction(name: "of_copy_depth_kernel") else { return nil }
        guard let advPSO = try? device.makeComputePipelineState(function: advFn),
              let cpyPSO = try? device.makeComputePipelineState(function: cpyFn) else { return nil }

        let dr = MTLRenderPipelineDescriptor()
        dr.vertexFunction = library.makeFunction(name: "passthrough_vs")
        dr.fragmentFunction = library.makeFunction(name: "of_draw_fs")
        dr.colorAttachments[0].pixelFormat = colorPixelFormat
        dr.depthAttachmentPixelFormat = .depth32Float
        guard let drawPSO = try? device.makeRenderPipelineState(descriptor: dr) else { return nil }

        func make(_ fmt: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: Self.simWidth, height: Self.simHeight, mipmapped: false
            )
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let pd = make(.r32Float),
              let pA = make(.rgba16Float),
              let pB = make(.rgba16Float) else { return nil }

        self.advectPSO = advPSO
        self.copyDepthPSO = cpyPSO
        self.drawPSO = drawPSO
        self.prevDepth = pd
        self.paintA = pA
        self.paintB = pB
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)
        let now = Float(Date().timeIntervalSince(startTime))
        var u = OFUniforms(
            ctrl: SIMD4<Float>(now, 1.0, 0.985 - inputs.audio.rms * 0.03, 0.0008),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            palette: SIMD4<Float>(
                fmod(0.55 + now * 0.04 + bassLow * 0.4, 1.0),
                fmod(0.05 + now * 0.06 + treb * 0.5, 1.0),
                0.7 + treb * 0.2,
                0.6 + inputs.audio.rms * 0.5
            )
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        if let buf = inputs.textures.commandQueue.makeCommandBuffer() {
            // Advect paint along motion derived from (currDepth - prevDepth).
            if let enc = buf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(advectPSO)
                enc.setTexture(paintA, index: 0)            // read prev paint
                enc.setTexture(paintB, index: 1)            // write next paint
                enc.setTexture(inputs.textures.registeredDepthTexture, index: 2)
                enc.setTexture(prevDepth, index: 3)
                enc.setBytes(&u, length: MemoryLayout<OFUniforms>.stride, index: 0)
                enc.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                let tw = min(advectPSO.threadExecutionWidth, 16)
                let th = min(advectPSO.maxTotalThreadsPerThreadgroup / tw, 16)
                let grid = MTLSize(
                    width: (Self.simWidth + tw - 1) / tw,
                    height: (Self.simHeight + th - 1) / th, depth: 1
                )
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
                enc.endEncoding()
            }
            // Copy current depth → prevDepth for next frame.
            if let enc = buf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(copyDepthPSO)
                enc.setTexture(inputs.textures.registeredDepthTexture, index: 0)
                enc.setTexture(prevDepth, index: 1)
                let tw = min(copyDepthPSO.threadExecutionWidth, 16)
                let th = min(copyDepthPSO.maxTotalThreadsPerThreadgroup / tw, 16)
                let grid = MTLSize(
                    width: (Self.simWidth + tw - 1) / tw,
                    height: (Self.simHeight + th - 1) / th, depth: 1
                )
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
                enc.endEncoding()
            }
            buf.commit()
            buf.waitUntilCompleted()
            swap(&paintA, &paintB)
        }

        var dl = DepthLavaUniforms()
        dl.time = inputs.timeSeconds
        dl.rms = inputs.audio.rms
        dl.onset = inputs.audio.onset ? 1 : 0
        dl.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        if bands.count >= 8 {
            dl.bands = (bands[0], bands[1], bands[2], bands[3], bands[4], bands[5], bands[6], bands[7])
        }
        encoder.setRenderPipelineState(drawPSO)
        encoder.setFragmentTexture(paintA, index: 0)
        encoder.setFragmentBytes(&dl, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
