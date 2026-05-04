// ParametricSwarmVisualizer — Casberry-faithful 3D geodesic swarm.
//
// 24,576 GPU particles whose positions are computed by a parametric formula on
// each particle's index. Six formations cycle and smooth-morph: Fibonacci
// geodesic sphere (default — the iconic Casberry look) → 2D-grid torus →
// double helix → hollow cube lattice → Lissajous knot → Aizawa-style audio-
// warped strange attractor.
//
// Pipeline shape mirrors ParticleStormVisualizer:
//   1. Compute kernel `psw_step_kernel` writes world-space xyz per particle.
//   2. Vertex `psw_vs` projects through view+proj, sets HDR colour + point size.
//   3. Fragment `psw_fs` Gaussian point sprite with ACES tone-map; additive blend.
//
// Audio mapping:
//   • bass/audio.rms  → formation scale + point-size pump + camera yaw nudge
//   • treble          → per-particle hue spread + jitter amplitude
//   • onset           → debounced step through formations + outward shockwave
//
// Body integration: when a Kinect skeleton is detected, the swarm's centre is
// translated toward the body's centre of mass (averaged 0..1 joints) with a
// strength that ramps in/out over a few frames so a one-frame Vision dropout
// doesn't snap the swarm.
//
// Reference: https://particles.casberry.in/ — geodesic point-cloud aesthetic.
//
// Plan: /Users/chisus/.claude/plans/casberry-faithful-swarm.md (returned by
// the critical Plan agent; this implementation follows §2–§7 exactly).

import Metal
import MetalKit
import simd

@MainActor
final class ParametricSwarmVisualizer: Visualizer {
    /// Maximum particle count the buffer can hold. The active count comes from
    /// `ParametricSwarmConfig.particleCount` and is clamped to this ceiling.
    private static let maxParticleCount = 64 * 1024  // 65,536
    private static let formationCount: Float = 8

    private struct PSWParticle {
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
        var userParams: SIMD4<Float>    // (formationOverride, audioReactivity, glowIntensity, _)
    }

    private let stepPSO: MTLComputePipelineState
    private let renderPSO: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer

    // CPU-side state — survives across draw() calls.
    private var morphPhase: Float = 0
    private var lastOnsetWasHigh = false
    private var bodyCOM = SIMD3<Float>(0, 0, 0)
    private var bodyStrength: Float = 0
    private var startTime = Date()

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        guard let stepFn = library.makeFunction(name: "psw_step_kernel") else { return nil }
        guard let stepPSO = try? device.makeComputePipelineState(function: stepFn) else { return nil }

        let rdesc = MTLRenderPipelineDescriptor()
        rdesc.vertexFunction = library.makeFunction(name: "psw_vs")
        rdesc.fragmentFunction = library.makeFunction(name: "psw_fs")
        rdesc.colorAttachments[0].pixelFormat = colorPixelFormat
        rdesc.depthAttachmentPixelFormat = .depth32Float
        // Additive blend — overlapping point sprites accumulate into bloom.
        rdesc.colorAttachments[0].isBlendingEnabled = true
        rdesc.colorAttachments[0].rgbBlendOperation = .add
        rdesc.colorAttachments[0].alphaBlendOperation = .add
        rdesc.colorAttachments[0].sourceRGBBlendFactor = .one
        rdesc.colorAttachments[0].destinationRGBBlendFactor = .one
        rdesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        rdesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let renderPSO = try? device.makeRenderPipelineState(descriptor: rdesc) else { return nil }

        let bytes = MemoryLayout<PSWParticle>.stride * Self.maxParticleCount
        guard let buf = device.makeBuffer(length: bytes, options: [.storageModePrivate]) else { return nil }

        self.stepPSO = stepPSO
        self.renderPSO = renderPSO
        self.particleBuffer = buf
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let now = Float(Date().timeIntervalSince(startTime))
        let cfg = inputs.parametricSwarm
        let count = max(256, min(Self.maxParticleCount, cfg.particleCount))

        // — Onset → debounced morph step. Slow auto-drift covers quiet rooms.
        //   Skipped entirely when the user has locked a specific formation
        //   (cfg.formation != .auto) — morphPhase only matters for the auto cycle.
        if cfg.formation == .auto {
            if inputs.audio.onset && !lastOnsetWasHigh {
                morphPhase += 1.0
                if morphPhase >= Self.formationCount { morphPhase -= Self.formationCount }
            }
            morphPhase += 0.003 + inputs.audio.rms * 0.004 * cfg.audioReactivity
            if morphPhase >= Self.formationCount { morphPhase -= Self.formationCount }
        }
        lastOnsetWasHigh = inputs.audio.onset

        let bands = inputs.audio.bands
        func b(_ i: Int) -> Float { bands.indices.contains(i) ? bands[i] : 0 }
        let bassLow = b(0) + b(1) * 0.5
        let treb = b(6) + b(7)

        // — Body COM from skeleton joints (smoothed). Vision normalized 0..1
        //   with origin bottom-left → map to world [-1.2, 1.2] × [-0.9, 0.9].
        if let skel = inputs.skeletons.first, !skel.joints.isEmpty {
            let confident = skel.joints.filter { $0.confidence > 0.30 }
            if !confident.isEmpty {
                let n = Float(confident.count)
                var sx: Float = 0, sy: Float = 0
                for j in confident {
                    sx += Float(j.position.x)
                    sy += Float(j.position.y)
                }
                let cx = (sx / n - 0.5) * 2.4
                let cy = (sy / n - 0.5) * 1.8
                bodyCOM = SIMD3<Float>(cx, cy, 0)
                bodyStrength = min(1.0, bodyStrength + 0.05)
            } else {
                bodyStrength = max(0.0, bodyStrength - 0.05)
            }
        } else {
            bodyStrength = max(0.0, bodyStrength - 0.05)
        }
        let effectiveBodyStrength = bodyStrength * cfg.bodyAttraction

        // — Camera: slow Y-axis orbit; audio.rms nudges the rate.
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let yaw = now * cfg.rotateSpeed + inputs.audio.rms * 0.30 * cfg.audioReactivity
        let dist: Float = 2.6
        let pitch: Float = 0.05
        let eye = SIMD3<Float>(
            sin(yaw) * dist * cos(pitch),
            sin(pitch) * dist,
            cos(yaw) * dist * cos(pitch)
        )
        let viewMat = lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0))
        let proj = perspective(fovYRadians: .pi / 4.0, aspect: aspect, near: 0.05, far: 50.0)
        let viewProj = proj * viewMat

        var u = PSWUniforms(
            viewProj: viewProj,
            ctrl: SIMD4<Float>(now, Float(count), morphPhase, cfg.particleSize),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            bandsLow: SIMD4<Float>(b(0), b(1), b(2), b(3)),
            bandsHi:  SIMD4<Float>(b(4), b(5), b(6), b(7)),
            bodyAttract: SIMD4<Float>(bodyCOM.x, bodyCOM.y, bodyCOM.z, effectiveBodyStrength),
            palette: SIMD4<Float>(cfg.baseHue, cfg.hueSpread, cfg.saturation, cfg.value),
            userParams: SIMD4<Float>(
                Float(cfg.formation.rawValue),     // -1 = auto, 0..7 = locked
                cfg.audioReactivity,
                cfg.glowIntensity,
                0
            )
        )

        // — Compute pass: writes one position per particle.
        if let cbuf = inputs.textures.commandQueue.makeCommandBuffer(),
           let cenc = cbuf.makeComputeCommandEncoder() {
            cenc.setComputePipelineState(stepPSO)
            cenc.setBuffer(particleBuffer, offset: 0, index: 0)
            cenc.setBytes(&u, length: MemoryLayout<PSWUniforms>.stride, index: 1)
            let tw = min(stepPSO.threadExecutionWidth, 64)
            let grid = MTLSize(
                width: (count + tw - 1) / tw,
                height: 1, depth: 1
            )
            cenc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
            cenc.endEncoding()
            cbuf.commit()
            cbuf.waitUntilCompleted()
        }

        // — Render pass: point sprites, additive blend, no background scrim.
        encoder.setRenderPipelineState(renderPSO)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<PSWUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
    }

    // — Camera matrix helpers — pattern matching VoxelSculptVisualizer /
    //   PointCloudVisualizer (kept local; the helpers in those files are file-
    //   scoped private and not visible here).
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
