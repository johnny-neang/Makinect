// FilamentCosmologyVisualizer — Cosmic-web filaments raymarched through a
// Worley-noise density field; body acts as a gravitational lens.
//
// User controls (FilamentCosmologyConfig): march steps + filament threshold +
// lens strength + audio coupling + hue shift + Worley scale.

import Metal
import MetalKit
import simd

@MainActor
final class FilamentCosmologyVisualizer: Visualizer {
    private struct Params {
        var cfg: SIMD4<Float>     // (marchSteps, threshold, lensStrength, audioCoupling)
        var misc: SIMD4<Float>    // (hueShift, worleyScale, _, _)
    }

    private let pipeline: MTLRenderPipelineState
    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "filament_cosmology_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        var u = DepthLavaUniforms()
        u.time = inputs.timeSeconds; u.rms = inputs.audio.rms; u.onset = inputs.audio.onset ? 1 : 0
        u.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        u.nearMM = inputs.segmentationNearMM; u.farMM = inputs.segmentationFarMM
        let b = inputs.audio.bands
        if b.count >= 8 { u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]) }

        let cfg = inputs.filamentCosmology
        var params = Params(
            cfg:  SIMD4<Float>(Float(cfg.marchSteps), cfg.filamentThreshold,
                               cfg.lensStrength, cfg.audioCoupling),
            misc: SIMD4<Float>(cfg.hueShift, cfg.worleyScale, 0, 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
