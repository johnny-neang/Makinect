// Visualizer — protocol all GPU visualizers conform to.
// A single MetalKinectView swaps the active Visualizer when the user changes mode.

import Metal
import MetalKit
import simd

struct VisualizerInputs {
    let textures: KinectMetalTextures
    let audio: AudioEngine
    let skeletons: [DetectedSkeleton]
    let timeSeconds: Float
    let segmentationNearMM: Float
    let segmentationFarMM: Float
}

@MainActor
protocol Visualizer: AnyObject {
    init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat)
    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs)
    func handleScroll(deltaX: CGFloat, deltaY: CGFloat)
    func handleDrag(deltaX: CGFloat, deltaY: CGFloat)
    func handleMagnify(_ delta: CGFloat)
}

extension Visualizer {
    func handleScroll(deltaX: CGFloat, deltaY: CGFloat) {}
    func handleDrag(deltaX: CGFloat, deltaY: CGFloat) {}
    func handleMagnify(_ delta: CGFloat) {}
}

enum VisualizationKind: String, CaseIterable, Identifiable {
    case depthLava = "Depth Lava"
    case skeletonRibbons = "Skeleton Ribbons"
    case halftone = "Halftone NPR"
    case postFX = "Audio PostFX"
    case pointCloud = "3D Point Cloud"
    case heightField = "Height Field"
    case bodyPaint = "AR Body Paint"
    case shaderSandbox = "Hot-Reload Shader"

    var id: String { rawValue }
}
