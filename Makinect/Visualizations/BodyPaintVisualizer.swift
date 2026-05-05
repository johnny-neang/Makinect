// BodyPaintVisualizer — Candidate #8: glowing AR billboards locked to skeleton joints.

import Metal
import MetalKit
import Vision
import simd

private struct PaintInstance {
    var position: SIMD2<Float>
    var size: Float
    var jointID: Float
    var intensity: Float
}

private struct PaintUniformsSwift {
    var aspect: Float = 1
    var time: Float = 0
    var rms: Float = 0
    var onset: Float = 0
    var bands: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var colorWidth: Float = 1920
    var colorHeight: Float = 1080
    var pad0: Float = 0
}

private struct PaintParams {
    /// (beatBoost, audioCoupling, hueOffset, saturation)
    var cfg: SIMD4<Float> = .zero
    /// (falloff, trail, _, _)
    var misc: SIMD4<Float> = .zero
}

@MainActor
final class BodyPaintVisualizer: Visualizer {
    private let colorPipeline: MTLRenderPipelineState
    private let paintPipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int = 64

    // Smoothed joint positions for stable billboards (top-left origin)
    private var smoothed: [VNHumanBodyPoseObservation.JointName: SIMD2<Float>] = [:]

    private let watchedJoints: [VNHumanBodyPoseObservation.JointName] = [
        .leftWrist, .rightWrist, .leftAnkle, .rightAnkle, .nose,
        .leftElbow, .rightElbow, .leftKnee, .rightKnee
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

        let paintDesc = MTLRenderPipelineDescriptor()
        paintDesc.vertexFunction = library.makeFunction(name: "paint_vs")
        paintDesc.fragmentFunction = library.makeFunction(name: "paint_fs")
        paintDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        paintDesc.depthAttachmentPixelFormat = .depth32Float
        if let ca = paintDesc.colorAttachments[0] {
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
        }
        guard let pso2 = try? device.makeRenderPipelineState(descriptor: paintDesc) else { return nil }
        self.paintPipeline = pso2

        guard let buf = device.makeBuffer(length: instanceCapacity * MemoryLayout<PaintInstance>.stride, options: [.storageModeShared]) else { return nil }
        self.instanceBuffer = buf
    }

    private func updateInstances(
        skeletons: [DetectedSkeleton],
        audio: AudioEngine,
        cfg: BodyPaintConfig
    ) -> [PaintInstance] {
        guard let skel = skeletons.first else { return [] }
        var out: [PaintInstance] = []
        let alpha: Float = max(0.05, min(1, cfg.smoothing))
        for (idx, name) in watchedJoints.enumerated() {
            guard let j = skel.joints.first(where: { $0.name == name }), j.confidence > 0.3 else { continue }
            let raw = SIMD2<Float>(Float(j.position.x), 1.0 - Float(j.position.y))
            let smoothedPos = smoothed[name].map { $0 + (raw - $0) * alpha } ?? raw
            smoothed[name] = smoothedPos
            let bandIdx = idx % 8
            let intensity = 0.5 + audio.bands[bandIdx] * cfg.audioCoupling + (audio.onset ? 0.6 : 0)
            let baseSize: Float = (name == .nose) ? cfg.headSize : cfg.jointSize
            out.append(PaintInstance(position: smoothedPos, size: baseSize, jointID: Float(idx), intensity: min(intensity, 2.5)))
        }
        return out
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        // 1) Color background
        encoder.setRenderPipelineState(colorPipeline)
        encoder.setFragmentTexture(inputs.textures.colorTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2) Paint instances over color
        let cfg = inputs.bodyPaint
        let instances = updateInstances(skeletons: inputs.skeletons, audio: inputs.audio, cfg: cfg)
        guard !instances.isEmpty else { return }

        let needed = instances.count * MemoryLayout<PaintInstance>.stride
        if needed > instanceBuffer.length {
            instanceCapacity = max(instances.count * 2, instanceCapacity * 2)
            if let buf = device.makeBuffer(length: instanceCapacity * MemoryLayout<PaintInstance>.stride, options: [.storageModeShared]) {
                instanceBuffer = buf
            }
        }
        _ = instances.withUnsafeBytes { src in
            memcpy(instanceBuffer.contents(), src.baseAddress!, needed)
        }

        var u = PaintUniformsSwift()
        u.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        u.time = inputs.timeSeconds
        u.rms = inputs.audio.rms
        u.onset = inputs.audio.onset ? 1 : 0
        let b = inputs.audio.bands
        if b.count >= 8 {
            u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
        }

        var params = PaintParams(
            cfg: SIMD4<Float>(cfg.beatBoost, cfg.audioCoupling, cfg.hueOffset, cfg.saturation),
            misc: SIMD4<Float>(cfg.falloff, cfg.trail, 0, 0)
        )

        encoder.setRenderPipelineState(paintPipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<PaintUniformsSwift>.size, index: 1)
        encoder.setVertexBytes(&params, length: MemoryLayout<PaintParams>.stride, index: 2)
        encoder.setFragmentBytes(&u, length: MemoryLayout<PaintUniformsSwift>.size, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<PaintParams>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
    }
}
