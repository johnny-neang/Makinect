// MetalKinectView — NSViewRepresentable hosting an MTKView that delegates frame
// rendering to the active Visualizer.

import SwiftUI
import MetalKit

struct MetalKinectView: NSViewRepresentable {
    @Bindable var manager: KinectManager
    let kind: VisualizationKind

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager, kind: kind)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = InteractiveMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.setKind(kind)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let manager: KinectManager
        let device: MTLDevice
        let library: MTLLibrary
        let textures: KinectMetalTextures
        let synthetic: SyntheticFrameSource?
        var visualizer: Visualizer?
        var currentKind: VisualizationKind
        weak var view: MTKView?
        private var startTime = Date()

        // Offscreen render target — the visualizer renders here, then a final
        // post-process pass applies the universal Common Params (hue / sat /
        // val / glow) and writes the result into the drawable. One extra
        // pass per frame, ~0.1ms — buys universal colour controls with zero
        // per-visualizer shader changes.
        private var offscreenColor: MTLTexture?
        private var offscreenDepth: MTLTexture?
        private var offscreenSize: CGSize = .zero
        private let postPSO: MTLRenderPipelineState

        init(manager: KinectManager, kind: VisualizationKind) {
            self.manager = manager
            self.currentKind = kind
            guard let dev = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal device unavailable")
            }
            self.device = dev
            // Default library lives in the app bundle (compiled from .metal sources)
            guard let lib = try? dev.makeDefaultLibrary(bundle: .main) else {
                fatalError("Default Metal library missing — ensure Shaders.metal is in the target")
            }
            self.library = lib
            guard let tx = KinectMetalTextures(device: dev) else {
                fatalError("Failed to allocate Kinect textures")
            }
            self.textures = tx

            // Common-params post-process pipeline.
            //
            // CRITICAL: must match the MTKView's depth attachment format
            // (.depth32Float) even though we don't use depth in the post pass.
            // Metal asserts on pipeline-vs-framebuffer pixel-format mismatch
            // when the encoder is created against the drawable's render pass
            // (which has a depth attachment attached). Without this, the
            // app froze with:
            //   "For depth attachment, the render pipeline's pixelFormat
            //    (MTLPixelFormatInvalid) does not match the framebuffer's
            //    pixelFormat (MTLPixelFormatDepth32Float)."
            let pdesc = MTLRenderPipelineDescriptor()
            pdesc.vertexFunction = lib.makeFunction(name: "passthrough_vs")
            pdesc.fragmentFunction = lib.makeFunction(name: "common_post_fs")
            pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pdesc.depthAttachmentPixelFormat = .depth32Float
            guard let pso = try? dev.makeRenderPipelineState(descriptor: pdesc) else {
                fatalError("Failed to build common_post pipeline — Shaders.metal must compile")
            }
            self.postPSO = pso

            // Optional — if the synth kernels failed to load, synthetic mode just
            // shows zeroed textures (visualizers still render, just blank).
            self.synthetic = SyntheticFrameSource(device: dev, library: lib)
            super.init()
            manager.attachVisualizationTextures(textures)
            setKind(kind)
        }

        /// Allocate (or reallocate after resize) the offscreen color + depth
        /// textures the visualizer renders into. Pixel formats match the
        /// drawable so visualizer pipelines compiled against the view's
        /// formats work without changes.
        private func ensureOffscreen(size: CGSize, colorFormat: MTLPixelFormat) {
            let w = max(1, Int(size.width))
            let h = max(1, Int(size.height))
            if let tex = offscreenColor, tex.width == w, tex.height == h { return }

            let cdesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorFormat, width: w, height: h, mipmapped: false
            )
            cdesc.usage = [.renderTarget, .shaderRead]
            cdesc.storageMode = .private
            offscreenColor = device.makeTexture(descriptor: cdesc)

            let ddesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: w, height: h, mipmapped: false
            )
            ddesc.usage = [.renderTarget]
            ddesc.storageMode = .private
            offscreenDepth = device.makeTexture(descriptor: ddesc)
            offscreenSize = size
        }

        func setKind(_ kind: VisualizationKind) {
            currentKind = kind
            visualizer = makeVisualizer(kind)
        }

        private func makeVisualizer(_ kind: VisualizationKind) -> Visualizer? {
            let format = view?.colorPixelFormat ?? .bgra8Unorm
            switch kind {
            case .pointCloud:        return PointCloudVisualizer(device: device, library: library, colorPixelFormat: format)
            case .bodyPaint:         return BodyPaintVisualizer(device: device, library: library, colorPixelFormat: format)
            case .nebula:            return NebulaVisualizer(device: device, library: library, colorPixelFormat: format)
            case .opticalFlow:       return OpticalFlowVisualizer(device: device, library: library, colorPixelFormat: format)
            case .particleStorm:     return ParticleStormVisualizer(device: device, library: library, colorPixelFormat: format)
            case .stableFluids:      return StableFluidsVisualizer(device: device, library: library, colorPixelFormat: format)
            case .voxelSculpt:       return VoxelSculptVisualizer(device: device, library: library, colorPixelFormat: format)
            case .iridescentPlumage: return IridescentPlumageVisualizer(device: device, library: library, colorPixelFormat: format)
            case .cathedralOfBones:  return CathedralOfBonesVisualizer(device: device, library: library, colorPixelFormat: format)
            case .pixelStorm:        return PixelStormVisualizer(device: device, library: library, colorPixelFormat: format)
            case .bodyOfPetals:      return BodyOfPetalsVisualizer(device: device, library: library, colorPixelFormat: format)
            case .mandelbulbAviary:  return MandelbulbAviaryVisualizer(device: device, library: library, colorPixelFormat: format)
            case .smokeGod:          return SmokeGodVisualizer(device: device, library: library, colorPixelFormat: format)
            case .stainedCathedral:  return StainedCathedralVisualizer(device: device, library: library, colorPixelFormat: format)
            case .volumetricAurora:  return VolumetricAuroraVisualizer(device: device, library: library, colorPixelFormat: format)
            case .glassOcean:        return GlassOceanVisualizer(device: device, library: library, colorPixelFormat: format)
            case .mercuryStorm:      return MercuryStormVisualizer(device: device, library: library, colorPixelFormat: format)
            case .origamiBody:       return OrigamiBodyVisualizer(device: device, library: library, colorPixelFormat: format)
            case .spectralOcean:     return SpectralOceanVisualizer(device: device, library: library, colorPixelFormat: format)
            case .forestOfLight:     return ForestOfLightVisualizer(device: device, library: library, colorPixelFormat: format)
            case .memoryPalace:      return MemoryPalaceVisualizer(device: device, library: library, colorPixelFormat: format)
            // — research-grounded replacements —
            case .plasmaSea:             return PlasmaSeaVisualizer(device: device, library: library, colorPixelFormat: format)
            case .strandVeil:            return StrandVeilVisualizer(device: device, library: library, colorPixelFormat: format)
            case .boidsMurmuration:      return BoidsMurmurationVisualizer(device: device, library: library, colorPixelFormat: format)
            case .sandMandala:           return SandMandalaVisualizer(device: device, library: library, colorPixelFormat: format)
            case .liquidLightCalligraphy: return LiquidLightCalligraphyVisualizer(device: device, library: library, colorPixelFormat: format)
            case .magneticIronFilings:   return MagneticIronFilingsVisualizer(device: device, library: library, colorPixelFormat: format)
            case .liquidChromeBody:      return LiquidChromeBodyVisualizer(device: device, library: library, colorPixelFormat: format)
            case .mocapConstellation:    return MocapConstellationVisualizer(device: device, library: library, colorPixelFormat: format)
            case .dissipativeCells:      return DissipativeCellsVisualizer(device: device, library: library, colorPixelFormat: format)
            case .vortexRingSmoke:       return VortexRingSmokeVisualizer(device: device, library: library, colorPixelFormat: format)
            case .hyperbolicTunnel:      return HyperbolicTunnelVisualizer(device: device, library: library, colorPixelFormat: format)
            case .filamentCosmology:     return FilamentCosmologyVisualizer(device: device, library: library, colorPixelFormat: format)
            case .velvetPetalField:      return VelvetPetalFieldVisualizer(device: device, library: library, colorPixelFormat: format)
            case .glitchMosaic:          return GlitchMosaicVisualizer(device: device, library: library, colorPixelFormat: format)
            case .kineticWireframe:      return KineticWireframeVisualizer(device: device, library: library, colorPixelFormat: format)
            case .impastoPainter:        return ImpastoPainterVisualizer(device: device, library: library, colorPixelFormat: format)
            // — Casberry-inspired parametric swarm —
            case .parametricSwarm:       return ParametricSwarmVisualizer(device: device, library: library, colorPixelFormat: format)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Drop the offscreen textures so they're rebuilt at the new size on
            // the next draw call. (Don't recreate eagerly — the new drawable
            // size may not be live yet.)
            offscreenColor = nil
            offscreenDepth = nil
        }

        func draw(in view: MTKView) {
            guard let viz = visualizer,
                  let drawable = view.currentDrawable,
                  let drawablePass = view.currentRenderPassDescriptor,
                  let commandBuffer = textures.commandQueue.makeCommandBuffer() else { return }

            // — FPS sample for the resource monitor (free; just records a timestamp).
            manager.resourceMonitor.registerFrame()

            // — Universal common params: pre-scale time and route audio
            //   reactivity into the AudioEngine so every visualizer reads
            //   already-scaled values without per-viz changes.
            let common = manager.common
            let baseTime = Float(Date().timeIntervalSince(startTime))
            let timeSeconds = baseTime * common.speedMul
            manager.audio.outputMultiplier = common.audioReactivity

            // — Allocate the offscreen target if needed.
            ensureOffscreen(size: view.drawableSize, colorFormat: view.colorPixelFormat)

            // — Synthetic compute pass (if in synthetic mode) goes onto the
            //   same command buffer as the visualizer/post passes.
            if manager.source == .synthetic, let synth = synthetic {
                synth.encode(
                    into: commandBuffer,
                    textures: textures,
                    audio: manager.audio,
                    timeSeconds: timeSeconds
                )
            }

            // — Pass 1: visualizer renders into the offscreen texture.
            let offDesc = MTLRenderPassDescriptor()
            offDesc.colorAttachments[0].texture = offscreenColor
            offDesc.colorAttachments[0].loadAction = .clear
            offDesc.colorAttachments[0].storeAction = .store
            offDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            offDesc.depthAttachment.texture = offscreenDepth
            offDesc.depthAttachment.loadAction = .clear
            offDesc.depthAttachment.storeAction = .dontCare
            offDesc.depthAttachment.clearDepth = 1.0

            guard let offEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: offDesc) else {
                commandBuffer.commit()
                return
            }

            let inputs = VisualizerInputs(
                textures: textures,
                audio: manager.audio,
                skeletons: manager.poseDetector.skeletons,
                timeSeconds: timeSeconds,
                segmentationNearMM: manager.segmentationNearMM,
                segmentationFarMM: manager.segmentationFarMM,
                common: common,
                parametricSwarm: manager.parametricSwarm,
                particleStorm: manager.particleStorm,
                mercuryStorm: manager.mercuryStorm,
                mandelbulbAviary: manager.mandelbulbAviary,
                bodyOfPetals: manager.bodyOfPetals,
                mocapConstellation: manager.mocapConstellation,
                sandMandala: manager.sandMandala,
                strandVeil: manager.strandVeil,
                nebula: manager.nebula,
                smokeGod: manager.smokeGod,
                volumetricAurora: manager.volumetricAurora,
                plasmaSea: manager.plasmaSea,
                vortexRingSmoke: manager.vortexRingSmoke,
                filamentCosmology: manager.filamentCosmology
            )

            viz.draw(in: view, encoder: offEncoder, inputs: inputs)
            offEncoder.endEncoding()

            // — Pass 2: post-process applies hue/sat/val/glow modifiers and
            //   writes the result into the drawable.
            guard let postEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawablePass) else {
                commandBuffer.commit()
                return
            }
            postEncoder.setRenderPipelineState(postPSO)
            postEncoder.setFragmentTexture(offscreenColor, index: 0)
            var postUniforms = SIMD4<Float>(
                common.hueShift,
                common.saturationMul,
                common.brightnessMul,
                common.glowMul
            )
            postEncoder.setFragmentBytes(&postUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            postEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            postEncoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MTKView subclass that forwards mouse/scroll/magnify gestures to the active visualizer
final class InteractiveMTKView: MTKView {
    weak var coordinator: MetalKinectView.Coordinator?
    private var lastDragPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { lastDragPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { lastDragPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint else { return }
        let p = event.locationInWindow
        Task { @MainActor in
            self.coordinator?.visualizer?.handleDrag(deltaX: p.x - last.x, deltaY: p.y - last.y)
        }
        lastDragPoint = p
    }
    override func scrollWheel(with event: NSEvent) {
        Task { @MainActor in
            self.coordinator?.visualizer?.handleScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        }
    }
    override func magnify(with event: NSEvent) {
        Task { @MainActor in
            self.coordinator?.visualizer?.handleMagnify(event.magnification)
        }
    }
}
