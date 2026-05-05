// PlasmaSeaVisualizer — Volumetric caustics raymarched through a wave-displaced
// refractive surface, with chromatic dispersion. Body sits "underwater" so the
// caustics dance across the silhouette.
//
// Inspiration:
//   - Inigo Quilez "Sphere soft shadow" + raymarching articles (iquilezles.org)
//   - Joanie Lemercier — La Pluie, Constellations
//   - Memo Akten — Waves: Serenity (fxhash)
//
// User controls (PlasmaSeaConfig): wave scale + speed + dispersion + audio
// coupling, deep/lit hue shifts, body subsurface glow color, brightness.

import Metal
import MetalKit
import simd

@MainActor
final class PlasmaSeaVisualizer: Visualizer {
    private struct Params {
        var wave: SIMD4<Float>      // (waveScale, waveSpeed, dispersion, audioCoupling)
        var palette: SIMD4<Float>   // (deepHueShift, litHueShift, bodyGlowHue, brightness)
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "plasma_sea_fs")
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

        let cfg = inputs.plasmaSea
        var params = Params(
            wave:    SIMD4<Float>(cfg.waveScale, cfg.waveSpeed, cfg.dispersion, cfg.audioCoupling),
            palette: SIMD4<Float>(cfg.deepHueShift, cfg.litHueShift, cfg.bodyGlowHue, cfg.brightness)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
