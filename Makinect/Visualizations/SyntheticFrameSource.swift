// SyntheticFrameSource — fills the same MTLTextures the Kinect bridge would,
// using audio-reactive compute kernels. Lets the visualizers run with no device
// attached. Encoded into the visualizer's command buffer in MetalKinectView so
// it shares the 60 Hz draw cadence — no separate timer.
//
// The SynthUniforms struct here MUST stay layout-compatible with the matching
// struct in Shaders.metal: float4 slots only, 16-byte aligned, no scalar arrays.
// (Lesson from commit 3f5f308: scattered scalars + fixed-size arrays cause
// Metal/Swift padding to disagree and `setBytes` underruns the buffer.)

import Metal
import MetalKit
import simd

@MainActor
final class SyntheticFrameSource {
    private struct SynthUniforms {
        var bands: SIMD4<Float>           // FFT bands 0..3
        var bandsHi: SIMD4<Float>         // FFT bands 4..7
        var rmsTimeOnsetPad: SIMD4<Float> // (rms, time, onset, _)
    }

    private let depthPSO: MTLComputePipelineState
    private let colorPSO: MTLComputePipelineState

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let depthFn = library.makeFunction(name: "synth_depth_kernel"),
              let colorFn = library.makeFunction(name: "synth_color_kernel") else {
            return nil
        }
        do {
            self.depthPSO = try device.makeComputePipelineState(function: depthFn)
            self.colorPSO = try device.makeComputePipelineState(function: colorFn)
        } catch {
            return nil
        }
    }

    /// Encode three compute dispatches (depth, registered depth, color) onto the
    /// caller's command buffer. The visualizer's render pass then reads from the
    /// same MTLTextures on the same buffer — Metal serialises the compute→render
    /// dependency automatically since we never use untracked resources.
    func encode(
        into commandBuffer: MTLCommandBuffer,
        textures: KinectMetalTextures,
        audio: AudioEngine,
        timeSeconds: Float
    ) {
        let uniforms = makeUniforms(audio: audio, timeSeconds: timeSeconds)

        encodeDepth(commandBuffer: commandBuffer, output: textures.depthTexture, uniforms: uniforms)
        encodeDepth(commandBuffer: commandBuffer, output: textures.registeredDepthTexture, uniforms: uniforms)
        encodeColor(commandBuffer: commandBuffer, output: textures.colorTexture, uniforms: uniforms)
    }

    private func makeUniforms(audio: AudioEngine, timeSeconds: Float) -> SynthUniforms {
        let b = audio.bands
        let bands = SIMD4<Float>(
            b.indices.contains(0) ? b[0] : 0,
            b.indices.contains(1) ? b[1] : 0,
            b.indices.contains(2) ? b[2] : 0,
            b.indices.contains(3) ? b[3] : 0
        )
        let bandsHi = SIMD4<Float>(
            b.indices.contains(4) ? b[4] : 0,
            b.indices.contains(5) ? b[5] : 0,
            b.indices.contains(6) ? b[6] : 0,
            b.indices.contains(7) ? b[7] : 0
        )
        return SynthUniforms(
            bands: bands,
            bandsHi: bandsHi,
            rmsTimeOnsetPad: SIMD4<Float>(audio.rms, timeSeconds, audio.onset ? 1 : 0, 0)
        )
    }

    private func encodeDepth(commandBuffer: MTLCommandBuffer, output: MTLTexture, uniforms: SynthUniforms) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(depthPSO)
        encoder.setTexture(output, index: 0)
        var u = uniforms
        encoder.setBytes(&u, length: MemoryLayout<SynthUniforms>.stride, index: 0)
        dispatch(encoder: encoder, pso: depthPSO, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    private func encodeColor(commandBuffer: MTLCommandBuffer, output: MTLTexture, uniforms: SynthUniforms) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(colorPSO)
        encoder.setTexture(output, index: 0)
        var u = uniforms
        encoder.setBytes(&u, length: MemoryLayout<SynthUniforms>.stride, index: 0)
        dispatch(encoder: encoder, pso: colorPSO, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    private func dispatch(encoder: MTLComputeCommandEncoder, pso: MTLComputePipelineState, width: Int, height: Int) {
        let tgWidth = min(pso.threadExecutionWidth, 16)
        let tgHeight = min(pso.maxTotalThreadsPerThreadgroup / tgWidth, 16)
        let tgSize = MTLSize(width: tgWidth, height: tgHeight, depth: 1)
        let grid = MTLSize(
            width: (width + tgWidth - 1) / tgWidth,
            height: (height + tgHeight - 1) / tgHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tgSize)
    }
}
