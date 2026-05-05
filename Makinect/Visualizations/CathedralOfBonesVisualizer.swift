// CathedralOfBonesVisualizer — Procedural anatomical X-ray. Skull, ribcage,
// spine, pelvis, femurs all rendered as SDF distance lines, region-selected by
// vertical position within the body silhouette. Heart pulses with bass; nerve
// filaments flicker on treble; full-frame strobe on onset. Wet-plate collodion
// palette.  Inspiration: Andreas Vesalius's *De humani corporis fabrica*, Daito
// Manabe's *Pulse*, X-ray photography.

import Metal
import MetalKit

@MainActor
final class CathedralOfBonesVisualizer: Visualizer {
    private struct Params {
        /// (heartSize, heartPulse, nerveIntensity, boneTint)
        var cfg: SIMD4<Float>
        /// (strobeIntensity, plateWarmth, visceraGlow, boneThickness)
        var misc: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "cathedral_bones_fs")
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

        let cfg = inputs.cathedralOfBones
        var params = Params(
            cfg: SIMD4<Float>(cfg.heartSize, cfg.heartPulse, cfg.nerveIntensity, cfg.boneTint),
            misc: SIMD4<Float>(cfg.strobeIntensity, cfg.plateWarmth, cfg.visceraGlow, cfg.boneThickness)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
