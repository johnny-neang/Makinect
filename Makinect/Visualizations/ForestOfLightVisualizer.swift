// ForestOfLightVisualizer — Vertical light pillar field. Each screen column has
// a pillar; height = depth at that column; color = mapped FFT band. Volumetric
// god-ray scatter through the colonnade. Body silhouette repels pillars to
// create person-shaped negative space the viewer can walk through. Inspiration:
// United Visual Artists' *Our Time*, Bruce Munro's *Field of Light*.

import Metal
import MetalKit

@MainActor
final class ForestOfLightVisualizer: Visualizer {
    private struct Params {
        /// (pillarSpacing, swayAmount, coreGlow, scatterAmount)
        var cfg: SIMD4<Float>
        /// (baseHue, bandSaturation, onsetFlash, audioCoupling)
        var misc: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "forest_of_light_fs")
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

        let cfg = inputs.forestOfLight
        var params = Params(
            cfg: SIMD4<Float>(cfg.pillarSpacing, cfg.swayAmount, cfg.coreGlow, cfg.scatterAmount),
            misc: SIMD4<Float>(cfg.baseHue, cfg.bandSaturation, cfg.onsetFlash, cfg.audioCoupling)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
