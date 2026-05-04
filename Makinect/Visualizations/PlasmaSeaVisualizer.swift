// PlasmaSeaVisualizer — Volumetric caustics raymarched through a wave-displaced
// refractive surface, with chromatic dispersion. Body sits "underwater" so the
// caustics dance across the silhouette.
//
// Inspiration:
//   - Inigo Quilez "Sphere soft shadow" + raymarching articles (iquilezles.org)
//   - Joanie Lemercier — La Pluie, Constellations
//   - Memo Akten — Waves: Serenity (fxhash)
//
// Why it beats the old caustic_waves: that one summed sines on a 2D plane.
// This raymarches a full 3D refractive volume per pixel, splits R/G/B by
// wavelength for real chromatic dispersion, and accumulates with HDR + ACES
// tone-mapping. It's a volumetric integral, not a surface trick.

import Metal
import MetalKit

@MainActor
final class PlasmaSeaVisualizer: Visualizer {
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
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
