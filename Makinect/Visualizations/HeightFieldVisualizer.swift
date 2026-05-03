// HeightFieldVisualizer — Candidate #6: depth becomes a deforming color-mapped terrain.

import Metal
import MetalKit
import simd

private struct HeightFieldUniforms {
    var viewProj: float4x4 = matrix_identity_float4x4
    var time: Float = 0
    var rms: Float = 0
    var onset: Float = 0
    var bands: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var depthW: Float = 256
    var depthH: Float = 212
    var nearMM: Float = 500
    var farMM: Float = 4000
}

@MainActor
final class HeightFieldVisualizer: Visualizer {
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let gridW = 256
    private let gridH = 212

    private var yaw: Float = 0
    private var pitch: Float = 0.4
    private var distance: Float = 2.0

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "heightfield_vs")
        desc.fragmentFunction = library.makeFunction(name: "heightfield_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso

        let dDesc = MTLDepthStencilDescriptor()
        dDesc.depthCompareFunction = .less
        dDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dDesc) else { return nil }
        self.depthState = ds

        var indices: [UInt32] = []
        indices.reserveCapacity(gridW * gridH * 6)
        for y in 0..<(gridH - 1) {
            for x in 0..<(gridW - 1) {
                let i0 = UInt32(y * gridW + x)
                let i1 = UInt32(y * gridW + x + 1)
                let i2 = UInt32((y + 1) * gridW + x)
                let i3 = UInt32((y + 1) * gridW + x + 1)
                indices.append(contentsOf: [i0, i1, i2, i2, i1, i3])
            }
        }
        self.indexCount = indices.count
        guard let ib = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else { return nil }
        self.indexBuffer = ib
    }

    func handleDrag(deltaX: CGFloat, deltaY: CGFloat) {
        yaw += Float(deltaX) * 0.01
        pitch = max(-0.2, min(1.4, pitch - Float(deltaY) * 0.01))
    }

    func handleMagnify(_ delta: CGFloat) {
        distance = max(0.5, min(8.0, distance * Float(1.0 - delta)))
    }

    func handleScroll(deltaX: CGFloat, deltaY: CGFloat) {
        distance = max(0.5, min(8.0, distance + Float(deltaY) * 0.005))
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        var u = HeightFieldUniforms()
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let eye = SIMD3<Float>(
            cos(pitch) * sin(yaw) * distance,
            sin(pitch) * distance + 0.5,
            cos(pitch) * cos(yaw) * distance
        )
        let view4 = lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0))
        let proj = perspective(fovYRadians: .pi / 3.5, aspect: aspect, near: 0.01, far: 50)
        u.viewProj = proj * view4
        u.time = inputs.timeSeconds
        u.rms = inputs.audio.rms
        u.onset = inputs.audio.onset ? 1 : 0
        u.depthW = Float(gridW)
        u.depthH = Float(gridH)
        u.nearMM = inputs.segmentationNearMM
        u.farMM = inputs.segmentationFarMM
        let b = inputs.audio.bands
        if b.count >= 8 {
            u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexTexture(inputs.textures.depthTexture, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<HeightFieldUniforms>.size, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount,
            indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0
        )
    }
}
