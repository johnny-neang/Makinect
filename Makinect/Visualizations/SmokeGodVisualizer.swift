// SmokeGodVisualizer — Body acts as a hidden light source in a raymarched
// volumetric fog. Per pixel marches through space accumulating FBM density;
// rays passing near body silhouette light up with crepuscular gold; onset
// triggers ember sparks throughout the volume. Inspiration: Caravaggio's
// chiaroscuro, Joon Park's smoke renders, Disney's Hyperion.
//
// User controls (SmokeGodConfig): march steps + density threshold + density
// scale + audio coupling + lit/shadow two-tone hues + saturation + ember
// strength.

import Metal
import MetalKit
import simd

@MainActor
final class SmokeGodVisualizer: Visualizer {
    private struct Params {
        var march: SIMD4<Float>     // (steps, threshold, densityScale, audioCoupling)
        var palette: SIMD4<Float>   // (litHue, shadowHue, saturation, emberStrength)
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "smoke_god_fs")
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

        let cfg = inputs.smokeGod
        var params = Params(
            march:   SIMD4<Float>(Float(cfg.marchSteps), cfg.densityThreshold,
                                  cfg.densityScale, cfg.audioCoupling),
            palette: SIMD4<Float>(cfg.litHue, cfg.shadowHue, cfg.saturation, cfg.emberStrength)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
