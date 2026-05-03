// StableFluidsVisualizer — Real-time Navier-Stokes ink simulation. Inspiration:
// Jos Stam's "Stable Fluids" (1999), Memo Akten's MSAFluid, Daito Manabe.
//
// Pipeline (per frame, all on GPU):
//   1. Inject — body silhouette adds velocity bursts; onsets drop dye blobs.
//   2. Advect velocity along itself.
//   3. Diffuse + apply slight viscosity damping.
//   4. Compute divergence.
//   5. Pressure-Poisson Jacobi iterations.
//   6. Subtract pressure gradient → divergence-free velocity.
//   7. Advect dye along the corrected velocity.
//   8. Render dye to screen.
//
// Two ping-pong RG16Float velocity textures, one R16Float pressure ping-pong,
// one RGBA16F dye ping-pong. 256² grid keeps it cheap.

import Metal
import MetalKit
import simd

@MainActor
final class StableFluidsVisualizer: Visualizer {
    private static let gridSize = 256
    private static let pressureIterations = 24

    private struct SFUniforms {
        // (time, dt, dissipation, viscosity)
        var ctrl: SIMD4<Float>
        // (rms, onset, bassLow, treb)
        var audio: SIMD4<Float>
        // (hueA, hueB, sat, val)
        var palette: SIMD4<Float>
    }

    private let injectPSO: MTLComputePipelineState
    private let advectVPSO: MTLComputePipelineState
    private let advectDyePSO: MTLComputePipelineState
    private let divPSO: MTLComputePipelineState
    private let jacobiPSO: MTLComputePipelineState
    private let subGradPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState

    private var velA: MTLTexture
    private var velB: MTLTexture
    private var presA: MTLTexture
    private var presB: MTLTexture
    private var divTex: MTLTexture
    private var dyeA: MTLTexture
    private var dyeB: MTLTexture
    private var startTime = Date()

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        func mkComp(_ name: String) -> MTLComputePipelineState? {
            guard let f = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: f)
        }
        guard let inj = mkComp("sf_inject_kernel"),
              let avV = mkComp("sf_advect_velocity_kernel"),
              let avD = mkComp("sf_advect_dye_kernel"),
              let dv = mkComp("sf_divergence_kernel"),
              let jc = mkComp("sf_jacobi_kernel"),
              let sg = mkComp("sf_subgrad_kernel") else { return nil }

        let drawDesc = MTLRenderPipelineDescriptor()
        drawDesc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        drawDesc.fragmentFunction = library.makeFunction(name: "sf_draw_fs")
        drawDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        drawDesc.depthAttachmentPixelFormat = .depth32Float
        guard let dr = try? device.makeRenderPipelineState(descriptor: drawDesc) else { return nil }

        func mkTex(_ fmt: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: Self.gridSize, height: Self.gridSize, mipmapped: false
            )
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let vA = mkTex(.rg16Float), let vB = mkTex(.rg16Float),
              let pA = mkTex(.r16Float),  let pB = mkTex(.r16Float),
              let dv2 = mkTex(.r16Float),
              let yA = mkTex(.rgba16Float), let yB = mkTex(.rgba16Float) else { return nil }

        self.injectPSO = inj
        self.advectVPSO = avV
        self.advectDyePSO = avD
        self.divPSO = dv
        self.jacobiPSO = jc
        self.subGradPSO = sg
        self.drawPSO = dr

        self.velA = vA; self.velB = vB
        self.presA = pA; self.presB = pB
        self.divTex = dv2
        self.dyeA = yA; self.dyeB = yB
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let now = Float(Date().timeIntervalSince(startTime))
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)
        var u = SFUniforms(
            ctrl: SIMD4<Float>(now, 1.0, 0.992, 0.0001),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb),
            palette: SIMD4<Float>(
                fmod(0.55 + now * 0.05 + bassLow * 0.4, 1.0),
                fmod(0.05 + now * 0.07 + treb * 0.4, 1.0),
                0.85, 1.0
            )
        )
        var range = SIMD2<Float>(inputs.segmentationNearMM, inputs.segmentationFarMM)

        if let buf = inputs.textures.commandQueue.makeCommandBuffer() {
            // 1. Inject from body silhouette + onset dye drops.
            dispatchKernel(buf: buf, pso: injectPSO, write: { e in
                e.setTexture(self.velA, index: 0)
                e.setTexture(self.dyeA, index: 1)
                e.setTexture(inputs.textures.registeredDepthTexture, index: 2)
                e.setBytes(&u, length: MemoryLayout<SFUniforms>.stride, index: 0)
                e.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            })

            // 2. Advect velocity (velA → velB).
            dispatchKernel(buf: buf, pso: advectVPSO, write: { e in
                e.setTexture(self.velA, index: 0)
                e.setTexture(self.velB, index: 1)
                e.setBytes(&u, length: MemoryLayout<SFUniforms>.stride, index: 0)
            })
            swap(&velA, &velB)

            // 3. Compute divergence of velA → divTex.
            dispatchKernel(buf: buf, pso: divPSO, write: { e in
                e.setTexture(self.velA, index: 0)
                e.setTexture(self.divTex, index: 1)
            })

            // 4. Jacobi pressure solve. Initialise pressure to 0 by reading divergence as the rhs.
            // We don't bother explicitly clearing — pressure is overwritten each iter.
            for _ in 0..<Self.pressureIterations {
                dispatchKernel(buf: buf, pso: jacobiPSO, write: { e in
                    e.setTexture(self.presA, index: 0)
                    e.setTexture(self.divTex, index: 1)
                    e.setTexture(self.presB, index: 2)
                })
                swap(&presA, &presB)
            }

            // 5. Subtract pressure gradient.
            dispatchKernel(buf: buf, pso: subGradPSO, write: { e in
                e.setTexture(self.velA, index: 0)
                e.setTexture(self.presA, index: 1)
                e.setTexture(self.velB, index: 2)
            })
            swap(&velA, &velB)

            // 6. Advect dye along the divergence-free velocity.
            dispatchKernel(buf: buf, pso: advectDyePSO, write: { e in
                e.setTexture(self.dyeA, index: 0)
                e.setTexture(self.velA, index: 1)
                e.setTexture(self.dyeB, index: 2)
                e.setBytes(&u, length: MemoryLayout<SFUniforms>.stride, index: 0)
            })
            swap(&dyeA, &dyeB)

            buf.commit()
            buf.waitUntilCompleted()
        }

        encoder.setRenderPipelineState(drawPSO)
        encoder.setFragmentTexture(dyeA, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<SFUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func dispatchKernel(buf: MTLCommandBuffer,
                                pso: MTLComputePipelineState,
                                write: (MTLComputeCommandEncoder) -> Void) {
        guard let enc = buf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        write(enc)
        let tw = min(pso.threadExecutionWidth, 16)
        let th = min(pso.maxTotalThreadsPerThreadgroup / tw, 16)
        let grid = MTLSize(
            width: (Self.gridSize + tw - 1) / tw,
            height: (Self.gridSize + th - 1) / th, depth: 1
        )
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }
}
