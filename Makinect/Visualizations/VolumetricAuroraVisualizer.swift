// VolumetricAuroraVisualizer — Aurora borealis curtain falling across the
// scene with greens / magentas / deep teals. Curl-noise advected medium; bass
// triggers vertical "drops"; treble shimmers a sparkle layer. Body silhouette
// becomes super-bright (the aurora intensifies around it). Inspiration: real
// Norwegian aurora photography, James Turrell's color planes.
//
// User controls (VolumetricAuroraConfig): fall speed + curtain frequency +
// drop magnitude + star density + three-tone palette + body boost +
// treble shimmer.

import Metal
import MetalKit
import simd

@MainActor
final class VolumetricAuroraVisualizer: Visualizer {
    private struct Params {
        var motion: SIMD4<Float>     // (fallSpeed, curtainFreq, dropMagnitude, starDensity)
        var palette: SIMD4<Float>    // (hueA, hueB, hueC, bodyBoost)
        var misc: SIMD4<Float>       // (trebleShimmer, _, _, _)
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "aurora_fs")
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

        let cfg = inputs.volumetricAurora
        var params = Params(
            motion:  SIMD4<Float>(cfg.fallSpeed, cfg.curtainFreq, cfg.dropMagnitude, cfg.starDensity),
            palette: SIMD4<Float>(cfg.hueA, cfg.hueB, cfg.hueC, cfg.bodyBoost),
            misc:    SIMD4<Float>(cfg.trebleShimmer, 0, 0, 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
