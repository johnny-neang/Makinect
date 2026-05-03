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
            // Optional — if the synth kernels failed to load, synthetic mode just
            // shows zeroed textures (visualizers still render, just blank).
            self.synthetic = SyntheticFrameSource(device: dev, library: lib)
            super.init()
            manager.attachVisualizationTextures(textures)
            setKind(kind)
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

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let viz = visualizer,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = textures.commandQueue.makeCommandBuffer() else { return }

            let timeSeconds = Float(Date().timeIntervalSince(startTime))

            // In synthetic mode, fill the same MTLTextures the Kinect bridge would
            // before the visualizer's render pass reads them. Same command buffer
            // → Metal handles the compute→render dependency automatically.
            if manager.source == .synthetic, let synth = synthetic {
                synth.encode(
                    into: commandBuffer,
                    textures: textures,
                    audio: manager.audio,
                    timeSeconds: timeSeconds
                )
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                commandBuffer.commit()
                return
            }

            let inputs = VisualizerInputs(
                textures: textures,
                audio: manager.audio,
                skeletons: manager.poseDetector.skeletons,
                timeSeconds: timeSeconds,
                segmentationNearMM: manager.segmentationNearMM,
                segmentationFarMM: manager.segmentationFarMM
            )

            viz.draw(in: view, encoder: encoder, inputs: inputs)
            encoder.endEncoding()
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
