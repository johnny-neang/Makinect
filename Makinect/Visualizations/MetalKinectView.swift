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
            case .depthLava:        return DepthLavaVisualizer(device: device, library: library, colorPixelFormat: format)
            case .skeletonRibbons:  return SkeletonRibbonsVisualizer(device: device, library: library, colorPixelFormat: format)
            case .halftone:         return HalftoneVisualizer(device: device, library: library, colorPixelFormat: format)
            case .postFX:           return PostFXVisualizer(device: device, library: library, colorPixelFormat: format)
            case .pointCloud:       return PointCloudVisualizer(device: device, library: library, colorPixelFormat: format)
            case .heightField:      return HeightFieldVisualizer(device: device, library: library, colorPixelFormat: format)
            case .bodyPaint:        return BodyPaintVisualizer(device: device, library: library, colorPixelFormat: format)
            case .shaderSandbox:    return ShaderSandboxVisualizer(device: device, library: library, colorPixelFormat: format)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let viz = visualizer,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = textures.commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

            let inputs = VisualizerInputs(
                textures: textures,
                audio: manager.audio,
                skeletons: manager.poseDetector.skeletons,
                timeSeconds: Float(Date().timeIntervalSince(startTime)),
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
