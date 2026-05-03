// PointCloudVisualizer — Candidate #2: 3D point cloud from registered depth.

import Metal
import MetalKit
import simd

private struct PointCloudUniforms {
    var viewProj: float4x4 = matrix_identity_float4x4
    var time: Float = 0
    var pointSize: Float = 4
    var rms: Float = 0
    var onset: Float = 0
    var bands: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var fx: Float = 365.5
    var fy: Float = 365.5
    var cx: Float = 260.0
    var cy: Float = 209.0
    var depthW: Float = 256
    var depthH: Float = 212
}

@MainActor
final class PointCloudVisualizer: Visualizer {
    private let pipeline: MTLRenderPipelineState

    // Camera state (orbit around origin in front of cloud)
    private var yaw: Float = 0
    private var pitch: Float = -0.1
    private var distance: Float = 3.5
    private let pointGridW = 256
    private let pointGridH = 212

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "pointcloud_vs")
        desc.fragmentFunction = library.makeFunction(name: "pointcloud_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        if let ca = desc.colorAttachments[0] {
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.sourceAlphaBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso
    }

    func handleDrag(deltaX: CGFloat, deltaY: CGFloat) {
        yaw += Float(deltaX) * 0.01
        pitch = max(-1.5, min(1.5, pitch - Float(deltaY) * 0.01))
    }

    func handleMagnify(_ delta: CGFloat) {
        distance = max(0.5, min(10.0, distance * Float(1.0 - delta)))
    }

    func handleScroll(deltaX: CGFloat, deltaY: CGFloat) {
        distance = max(0.5, min(10.0, distance + Float(deltaY) * 0.01))
    }

    private func makeViewProj(aspect: Float) -> float4x4 {
        let eyeX = cos(pitch) * sin(yaw) * distance
        let eyeY = sin(pitch) * distance
        let eyeZ = cos(pitch) * cos(yaw) * distance - 2.0
        let eye = SIMD3<Float>(eyeX, eyeY, eyeZ)
        let center = SIMD3<Float>(0, 0, -2.0)
        let up = SIMD3<Float>(0, 1, 0)
        let view = lookAt(eye: eye, center: center, up: up)
        let proj = perspective(fovYRadians: .pi / 3.5, aspect: aspect, near: 0.05, far: 50)
        return proj * view
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        var u = PointCloudUniforms()
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        u.viewProj = makeViewProj(aspect: aspect)
        u.time = inputs.timeSeconds
        u.rms = inputs.audio.rms
        u.onset = inputs.audio.onset ? 1 : 0
        u.pointSize = 3.5 + Float(view.drawableSize.height) / 1080.0 * 1.5
        u.depthW = Float(pointGridW)
        u.depthH = Float(pointGridH)
        let b = inputs.audio.bands
        if b.count >= 8 {
            u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexTexture(inputs.textures.depthTexture, index: 0)
        encoder.setVertexTexture(inputs.textures.colorTexture, index: 1)
        encoder.setVertexBytes(&u, length: MemoryLayout<PointCloudUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointGridW * pointGridH)
    }
}

// MARK: - Matrix helpers

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let yScale = 1.0 / tan(fovYRadians * 0.5)
    let xScale = yScale / aspect
    let zRange = far - near
    let zScale = -(far + near) / zRange
    let wzScale = -2.0 * far * near / zRange
    return float4x4(columns: (
        SIMD4<Float>(xScale, 0, 0, 0),
        SIMD4<Float>(0, yScale, 0, 0),
        SIMD4<Float>(0, 0, zScale, -1),
        SIMD4<Float>(0, 0, wzScale, 0)
    ))
}
