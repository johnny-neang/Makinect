// MemoryPalaceVisualizer — The capstone. 3×3 mosaic showing nine different
// aesthetic modes simultaneously, all driven by the same depth+audio inputs
// but each pane routed to a different EQ slice. Each pane uses a distinct
// effect family (radial, plasma, scanlines, caustics, kaleidoscope, lava, stars,
// echo, rainbow). Onset triggers pane re-shuffle. The grand finale: viewer is
// a curator standing in their own gallery. Inspiration: Bill Viola's *The
// Crossing*, Pipilotti Rist's multi-channel installations.

import Metal
import MetalKit

@MainActor
final class MemoryPalaceVisualizer: Visualizer {
    private struct Params {
        /// (shuffleRate, gutterWidth, bandSpread, paneBleed)
        var cfg: SIMD4<Float>
        /// (onsetFlash, hueOffset, saturation, vignette)
        var misc: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "memory_palace_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        var u = DepthLavaUniforms()
        u.time = inputs.timeSeconds
        u.rms = inputs.audio.rms
        u.onset = inputs.audio.onset ? 1 : 0
        u.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        u.nearMM = inputs.segmentationNearMM
        u.farMM = inputs.segmentationFarMM
        let b = inputs.audio.bands
        if b.count >= 8 {
            u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
        }

        let cfg = inputs.memoryPalace
        var params = Params(
            cfg: SIMD4<Float>(cfg.shuffleRate, cfg.gutterWidth, cfg.bandSpread, cfg.paneBleed),
            misc: SIMD4<Float>(cfg.onsetFlash, cfg.hueOffset, cfg.saturation, cfg.vignette)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentTexture(inputs.textures.colorTexture, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
