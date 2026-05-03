// SkeletonRibbonsVisualizer — Candidate #3: glowing trails follow joints.

import Metal
import MetalKit
import simd
import Vision

private struct RibbonVertex {
    var position: SIMD2<Float>
    var age: Float
    var jointID: Float
}

private struct RibbonUniformsSwift {
    var aspect: Float = 1
    var time: Float = 0
    var rms: Float = 0
    var onset: Float = 0
    var bands: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
}

@MainActor
final class SkeletonRibbonsVisualizer: Visualizer {
    private let colorPipeline: MTLRenderPipelineState
    private let ribbonPipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private var vertexBuffer: MTLBuffer
    private var capacity: Int = 4096
    private var trailLength: Int = 32

    // ringBuffers[jointID] = circular buffer of last N positions (normalized [0..1], top-left origin)
    private var trails: [Int: [SIMD2<Float>]] = [:]

    // We render a strip per joint by emitting two verts per trail step (left/right offset)
    private let watchedJoints: [VNHumanBodyPoseObservation.JointName] = [
        .leftWrist, .rightWrist, .leftAnkle, .rightAnkle, .nose
    ]

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        self.device = device

        let colorDesc = MTLRenderPipelineDescriptor()
        colorDesc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        colorDesc.fragmentFunction = library.makeFunction(name: "color_passthrough_fs")
        colorDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        colorDesc.depthAttachmentPixelFormat = .depth32Float
        guard let pso1 = try? device.makeRenderPipelineState(descriptor: colorDesc) else { return nil }
        self.colorPipeline = pso1

        let ribbonDesc = MTLRenderPipelineDescriptor()
        ribbonDesc.vertexFunction = library.makeFunction(name: "ribbon_vs")
        ribbonDesc.fragmentFunction = library.makeFunction(name: "ribbon_fs")
        ribbonDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        ribbonDesc.depthAttachmentPixelFormat = .depth32Float
        let ca = ribbonDesc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        ca.destinationAlphaBlendFactor = .one
        guard let pso2 = try? device.makeRenderPipelineState(descriptor: ribbonDesc) else { return nil }
        self.ribbonPipeline = pso2

        let bytes = capacity * MemoryLayout<RibbonVertex>.stride
        guard let buf = device.makeBuffer(length: bytes, options: [.storageModeShared]) else { return nil }
        self.vertexBuffer = buf
    }

    private func updateTrails(_ skeletons: [DetectedSkeleton]) {
        guard let skel = skeletons.first else { return }
        for (idx, jointName) in watchedJoints.enumerated() {
            guard let joint = skel.joints.first(where: { $0.name == jointName }), joint.confidence > 0.3 else { continue }
            let pos = SIMD2<Float>(Float(joint.position.x), 1.0 - Float(joint.position.y))  // flip Y to top-left
            var trail = trails[idx] ?? []
            trail.append(pos)
            if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
            trails[idx] = trail
        }
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        // 1) Draw color background
        encoder.setRenderPipelineState(colorPipeline)
        encoder.setFragmentTexture(inputs.textures.colorTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2) Update + draw ribbons
        updateTrails(inputs.skeletons)

        var verts: [RibbonVertex] = []
        let halfWidth: Float = 0.012
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        for (idx, trail) in trails {
            guard trail.count >= 2 else { continue }
            for i in 0..<(trail.count - 1) {
                let a = trail[i]
                let b = trail[i + 1]
                let age0 = Float(trail.count - 1 - i) / Float(trailLength)
                let age1 = Float(trail.count - 2 - i) / Float(trailLength)
                let dir = simd_normalize(b - a + SIMD2<Float>(0.0001, 0))
                let normal = SIMD2<Float>(-dir.y, dir.x / aspect)
                let widthA = halfWidth * (1.0 - age0)
                let widthB = halfWidth * (1.0 - age1)
                let p1 = a + normal * widthA
                let p2 = a - normal * widthA
                let p3 = b + normal * widthB
                let p4 = b - normal * widthB
                let jid = Float(idx)
                verts.append(RibbonVertex(position: p1, age: age0, jointID: jid))
                verts.append(RibbonVertex(position: p2, age: age0, jointID: jid))
                verts.append(RibbonVertex(position: p3, age: age1, jointID: jid))
                verts.append(RibbonVertex(position: p2, age: age0, jointID: jid))
                verts.append(RibbonVertex(position: p4, age: age1, jointID: jid))
                verts.append(RibbonVertex(position: p3, age: age1, jointID: jid))
            }
        }
        guard !verts.isEmpty else { return }

        let needed = verts.count * MemoryLayout<RibbonVertex>.stride
        if needed > vertexBuffer.length {
            capacity = max(verts.count * 2, capacity * 2)
            if let buf = device.makeBuffer(length: capacity * MemoryLayout<RibbonVertex>.stride, options: [.storageModeShared]) {
                vertexBuffer = buf
            }
        }
        _ = verts.withUnsafeBytes { src in
            memcpy(vertexBuffer.contents(), src.baseAddress!, needed)
        }

        var u = RibbonUniformsSwift()
        u.aspect = aspect
        u.time = inputs.timeSeconds
        u.rms = inputs.audio.rms
        u.onset = inputs.audio.onset ? 1 : 0
        let b = inputs.audio.bands
        if b.count >= 8 {
            u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
        }

        encoder.setRenderPipelineState(ribbonPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<RibbonUniformsSwift>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }
}
