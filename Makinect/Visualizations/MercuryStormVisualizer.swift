// MercuryStormVisualizer — Liquid chrome metaballs orbiting/attracted to body.
// Bass thickens (globs cohere); treble shimmers; onset spawns vortex bursts.
// Chrome reflection shading with hue rotated by surface normal direction —
// procedural cubemap. Inspiration: T-1000, Sachiko Kodama's ferrofluid art,
// Wim Delvoye's chrome sculptures.
//
// User controls (MercuryStormConfig): ball count / orbit radius / ball
// radius / body emit / base hue / streak intensity / specular tightness /
// onset vortex.

import Metal
import MetalKit
import simd

@MainActor
final class MercuryStormVisualizer: Visualizer {
    private struct Params {
        var shape: SIMD4<Float>     // (ballCount, orbitRadius, ballRadius, bodyEmit)
        var chrome: SIMD4<Float>    // (baseHue, streakIntensity, specularTightness, onsetVortex)
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "mercury_storm_fs")
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

        let cfg = inputs.mercuryStorm
        var params = Params(
            shape:  SIMD4<Float>(Float(cfg.ballCount), cfg.orbitRadius, cfg.ballRadius, cfg.bodyEmit),
            chrome: SIMD4<Float>(cfg.baseHue, cfg.streakIntensity, cfg.specularTightness, cfg.onsetVortex)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
