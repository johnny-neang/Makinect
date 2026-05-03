// VoxelSculptVisualizer — Low-poly faceted "voxel sculpture" of the body.
// Inspiration: Quayola's "Captives" / "Strata", Universal Everything's "Future
// You", the cover of Aphex Twin's "Drukqs".
//
// Marching cubes is overkill — instead we render a regular 64×48 grid of
// instanced cubes, each placed at the depth value at its grid cell. Cells with
// no body get culled to a NaN position. The whole scene orbits slowly while
// audio modulates per-voxel scale and color palette. Onsets trigger a brief
// "explode-and-reform" pulse that radially shoves the voxels outward and lets
// them snap back.

import Metal
import MetalKit
import simd

@MainActor
final class VoxelSculptVisualizer: Visualizer {
    private static let gridX = 64
    private static let gridY = 48
    private static var voxelCount: Int { gridX * gridY }

    private struct VSUniforms {
        var viewProj: float4x4
        var bandsLow: SIMD4<Float>
        var bandsHi: SIMD4<Float>
        var ctrl: SIMD4<Float>     // (time, rms, onset, voxelScale)
        var range: SIMD4<Float>    // (nearMM, farMM, gridX, gridY)
        var cameraExplode: SIMD4<Float>  // (camY, explodePulse, _, _)
    }

    private let pipeline: MTLRenderPipelineState

    // Camera state — orbits with a slow yaw, slight tilt with bass.
    private var explodePulse: Float = 0
    private var startTime = Date()

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "voxel_sculpt_vs")
        desc.fragmentFunction = library.makeFunction(name: "voxel_sculpt_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true
        // depth-stencil state is set per-encoder by visualizers that need it; we
        // declare it inline at draw time below since visualizers don't share state.
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let now = Float(Date().timeIntervalSince(startTime))

        // Onset triggers an explode-pulse that decays each frame.
        if inputs.audio.onset { explodePulse = 1.0 }
        explodePulse *= 0.92

        // Camera: slow orbit; tilt with bass.
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let yaw = now * 0.20
        let camDist: Float = 5.5
        let camY: Float = 1.0 + 0.4 * sin(now * 0.15) + bassLow * 0.6
        let eye = SIMD3<Float>(sin(yaw) * camDist, camY, cos(yaw) * camDist)
        let target = SIMD3<Float>(0, 0.5, 0)
        let view4 = lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
        let proj = perspective(fovYRadians: .pi / 3, aspect: aspect, near: 0.1, far: 50)
        let viewProj = proj * view4

        var u = VSUniforms(
            viewProj: viewProj,
            bandsLow: SIMD4<Float>(
                bands.indices.contains(0) ? bands[0] : 0,
                bands.indices.contains(1) ? bands[1] : 0,
                bands.indices.contains(2) ? bands[2] : 0,
                bands.indices.contains(3) ? bands[3] : 0
            ),
            bandsHi: SIMD4<Float>(
                bands.indices.contains(4) ? bands[4] : 0,
                bands.indices.contains(5) ? bands[5] : 0,
                bands.indices.contains(6) ? bands[6] : 0,
                bands.indices.contains(7) ? bands[7] : 0
            ),
            ctrl: SIMD4<Float>(now, inputs.audio.rms, inputs.audio.onset ? 1 : 0,
                               0.06 + bassLow * 0.04),
            range: SIMD4<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM,
                                Float(Self.gridX), Float(Self.gridY)),
            cameraExplode: SIMD4<Float>(camY, explodePulse, 0, 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<VSUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VSUniforms>.stride, index: 0)
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0,
            vertexCount: 36, instanceCount: Self.voxelCount
        )
    }

    // Minimal matrix helpers — kept local so this file is self-contained.
    private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return float4x4(
            SIMD4<Float>( s.x,  u.x, -f.x, 0),
            SIMD4<Float>( s.y,  u.y, -f.y, 0),
            SIMD4<Float>( s.z,  u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        )
    }

    private func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let f = 1.0 / tan(fovYRadians * 0.5)
        let zr = far - near
        return float4x4(
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zr, -1),
            SIMD4<Float>(0, 0, -(2 * far * near) / zr, 0)
        )
    }
}
