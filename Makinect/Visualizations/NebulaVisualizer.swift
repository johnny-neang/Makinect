// NebulaVisualizer — Volumetric raymarched nebula. Inspiration: Refik Anadol
// data pigments, Inigo Quilez's cloud shadertoys, the Interstellar gargantua look.
//
// Single fullscreen fragment that raymarches a 3D fbm density field. Depth (when
// present) carves negative-density regions so a body becomes a hole in the cloud.
// Audio bands modulate density, color palette, and noise frequency.

import Metal
import MetalKit

@MainActor
final class NebulaVisualizer: Visualizer {
    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "nebula_fs")
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
