// HyperbolicTunnelVisualizer — H² Poincaré-disk tessellation centred on the body;
// tiles drift outward with audio-modulated curvature.
//
// Inspiration: M.C. Escher Circle Limit III, iquilezles.org/articles/voronoise.

import Metal
import MetalKit

@MainActor
final class HyperbolicTunnelVisualizer: Visualizer {
    private struct Params {
        /// (swirlBase, bassSwirl, tileSharpness, radialFreq)
        var cfg: SIMD4<Float>
        /// (foldDepth, onsetGlow, vignetteScale, hueOffset)
        var misc: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState
    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "hyperbolic_tunnel_fs")
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

        let cfg = inputs.hyperbolicTunnel
        var params = Params(
            cfg: SIMD4<Float>(cfg.swirlBase, cfg.bassSwirl, cfg.tileSharpness, cfg.radialFreq),
            misc: SIMD4<Float>(Float(cfg.foldDepth), cfg.onsetGlow, cfg.vignetteScale, cfg.hueOffset)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
