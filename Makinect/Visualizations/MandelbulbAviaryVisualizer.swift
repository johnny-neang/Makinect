// MandelbulbAviaryVisualizer — A flock of vermilion procedural birds orbits the
// surface of an audio-distorted Mandelbulb fractal, occasionally diverted toward
// the body silhouette. Camera orbits slowly; bands modulate the fractal's power
// exponent so the geometry warps with the music. Inspiration: Inigo Quilez's
// raymarched fractals, Memo Akten's flock-of-birds work.
//
// User controls (MandelbulbAviaryConfig): fractal power + audio mod + raymarch
// step budget + fractal hue + camera orbit speed + bird count + bird size +
// body attractor strength + bird hue.

import Metal
import MetalKit
import simd

@MainActor
final class MandelbulbAviaryVisualizer: Visualizer {
    private struct Params {
        var fractal: SIMD4<Float>   // (power, audioMod, steps, hue)
        var flock: SIMD4<Float>     // (camOrbitSpeed, birdCount, birdSize, birdBodyAttract)
        var misc: SIMD4<Float>      // (birdHue, _, _, _)
    }

    private let pipeline: MTLRenderPipelineState

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "mandelbulb_aviary_fs")
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

        let cfg = inputs.mandelbulbAviary
        var params = Params(
            fractal: SIMD4<Float>(cfg.fractalPower, cfg.powerAudioMod, Float(cfg.raymarchSteps), cfg.fractalHue),
            flock:   SIMD4<Float>(cfg.camOrbitSpeed, Float(cfg.birdCount), cfg.birdSize, cfg.birdBodyAttract),
            misc:    SIMD4<Float>(cfg.birdHue, 0, 0, 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
