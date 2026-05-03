// ParametricSwarmVisualizer — 65k GPU particles arranged via parametric
// formulas on each particle's index (Fibonacci sphere, torus, double helix,
// cube lattice, Lissajous knot, audio-warped attractor). Onsets step the
// formation; bass twists/scales; treble shimmers per-particle hue; body's
// center of mass attracts the swarm. Plasma additive-glow rendering, neon
// palette that drifts with bass.
//
// Reference: https://particles.casberry.in/ — Casberry's geodesic point-cloud
// aesthetic, ported to Metal + Kinect + audio reactivity.

import Metal
import MetalKit
import simd

@MainActor
final class ParametricSwarmVisualizer: Visualizer {
    private static let particleCount = 65_536  // 2^16

    private struct Particle {
        var posPad: SIMD4<Float> = .zero
    }

    private struct PSWUniforms {
        var viewProj: float4x4
        var ctrl: SIMD4<Float>          // (time, count, morphPhase, particleSize)
        var audio: SIMD4<Float>         // (rms, onset, bassLow, treb)
        var bandsLow: SIMD4<Float>
        var bandsHi: SIMD4<Float>
        var bodyAttract: SIMD4<Float>   // (cx, cy, cz, strength)
        var palette: SIMD4<Float>       // (baseHue, hueSpread, sat, val)
    }

    private let stepPSO: MTLComputePipelineState
    private let renderPSO: MTLRenderPipelineState
    private let bgPSO: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer
    private var morphPhase: Float = 0
    private var lastMorphTrigger: Float = -10
    private var startTime = Date()

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let stepFn = library.makeFunction(name: "psw_step_kernel") else { return nil }
        guard let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        // Particle render pipeline — additive blend for plasma glow.
        let rdesc = MTLRenderPipelineDescriptor()
        rdesc.vertexFunction = library.makeFunction(name: "psw_vs")
        rdesc.fragmentFunction = library.makeFunction(name: "psw_fs")
        rdesc.colorAttachments[0].pixelFormat = colorPixelFormat
        rdesc.depthAttachmentPixelFormat = .depth32Float
        rdesc.colorAttachments[0].isBlendingEnabled = true
        rdesc.colorAttachments[0].rgbBlendOperation = .add
        rdesc.colorAttachments[0].alphaBlendOperation = .add
        rdesc.colorAttachments[0].sourceRGBBlendFactor = .one
        rdesc.colorAttachments[0].destinationRGBBlendFactor = .one
        rdesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        rdesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let renderPSO = try? device.makeRenderPipelineState(descriptor: rdesc) else { return nil }

        // Background pipeline (drawn first, no blend).
        let bdesc = MTLRenderPipelineDescriptor()
        bdesc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        bdesc.fragmentFunction = library.makeFunction(name: "psw_bg_fs")
        bdesc.colorAttachments[0].pixelFormat = colorPixelFormat
        bdesc.depthAttachmentPixelFormat = .depth32Float
        guard let bgPSO = try? device.makeRenderPipelineState(descriptor: bdesc) else { return nil }

        // Particle buffer — initialized with zeros; the compute kernel writes every frame.
        let bytes = MemoryLayout<Particle>.stride * Self.particleCount
        guard let buf = device.makeBuffer(length: bytes, options: [.storageModePrivate]) else { return nil }

        self.stepPSO = stepPSO
        self.renderPSO = renderPSO
        self.bgPSO = bgPSO
        self.particleBuffer = buf
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let now = Float(Date().timeIntervalSince(startTime))

        // Onset triggers a discrete morph step (debounced to one trigger / 0.5s).
        if inputs.audio.onset && now - lastMorphTrigger > 0.5 {
            morphPhase += 1.0
            lastMorphTrigger = now
        }
        // Plus a slow continuous drift so even quiet music keeps morphing.
        morphPhase += 0.0010 + inputs.audio.rms * 0.0040

        let bands = inputs.audio.bands
        func b(_ i: Int) -> Float { bands.indices.contains(i) ? bands[i] : 0 }
        let bassLow = b(0) + b(1) * 0.5
        let treb = b(6) + b(7)

        // Camera — slow Y-axis orbit, audio nudges yaw.
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let yaw = now * 0.18 + inputs.audio.rms * 0.4
        let camDist: Float = 2.6
        let camY: Float = 0.20 + 0.10 * sin(now * 0.13)
        let eye = SIMD3<Float>(sin(yaw) * camDist, camY, cos(yaw) * camDist)
        let target = SIMD3<Float>(0, 0, 0)
        let viewMat = lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
        let proj = perspective(fovYRadians: .pi / 3.2, aspect: aspect, near: 0.05, far: 50)
        let viewProj = proj * viewMat

        // Body center attractor — average normalized joint position projected to
        // world space [-1, 1]. When no skeleton, strength stays 0.
        var bodyCenterX: Float = 0
        var bodyCenterY: Float = 0
        var bodyStrength: Float = 0
        if let skel = inputs.skeletons.first {
            var sx: Float = 0, sy: Float = 0, n: Float = 0
            for j in skel.joints where j.confidence > 0.30 {
                sx += Float(j.position.x)
                sy += Float(j.position.y)
                n += 1
            }
            if n > 0 {
                bodyCenterX = (sx / n - 0.5) * 1.6
                bodyCenterY = (sy / n - 0.5) * 1.4  // Vision origin is bottom-left
                bodyStrength = 0.20 + inputs.audio.rms * 0.40
            }
        }

        // Palette — Casberry-default neon green, hue drifts with bass into
        // cyan / magenta on heavy beats.
        let baseHue: Float = 0.32 + bassLow * 0.10
        let hueSpread: Float = 0.04 + treb * 0.05
        let sat: Float = 0.55 + treb * 0.20
        let val: Float = 0.85 + inputs.audio.rms * 0.20

        var u = PSWUniforms(
            viewProj: viewProj,
            ctrl: SIMD4<Float>(now, Float(Self.particleCount), morphPhase, 2.0 + bassLow * 2.0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            bandsLow: SIMD4<Float>(b(0), b(1), b(2), b(3)),
            bandsHi:  SIMD4<Float>(b(4), b(5), b(6), b(7)),
            bodyAttract: SIMD4<Float>(bodyCenterX, bodyCenterY, 0, bodyStrength),
            palette: SIMD4<Float>(baseHue, hueSpread, sat, val)
        )

        // Compute pass — runs on its own buffer, blocked on completion before
        // we render so the latest particle positions are visible.
        if let buf = inputs.textures.commandQueue.makeCommandBuffer(),
           let cenc = buf.makeComputeCommandEncoder() {
            cenc.setComputePipelineState(stepPSO)
            cenc.setBuffer(particleBuffer, offset: 0, index: 0)
            cenc.setBytes(&u, length: MemoryLayout<PSWUniforms>.stride, index: 1)
            let tw = min(stepPSO.threadExecutionWidth, 64)
            let grid = MTLSize(
                width: (Self.particleCount + tw - 1) / tw,
                height: 1, depth: 1
            )
            cenc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
            cenc.endEncoding()
            buf.commit()
            buf.waitUntilCompleted()
        }

        // — Background scrim
        var bgU = DepthLavaUniforms()
        bgU.time = now
        bgU.rms = inputs.audio.rms
        bgU.onset = inputs.audio.onset ? 1 : 0
        bgU.aspect = aspect
        if bands.count >= 8 {
            bgU.bands = (bands[0], bands[1], bands[2], bands[3], bands[4], bands[5], bands[6], bands[7])
        }
        encoder.setRenderPipelineState(bgPSO)
        encoder.setFragmentBytes(&bgU, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // — Particle render
        encoder.setRenderPipelineState(renderPSO)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<PSWUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.particleCount)
    }

    // — Camera matrix helpers (kept local; same pattern as VoxelSculptVisualizer).
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
