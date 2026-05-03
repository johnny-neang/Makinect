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

/// Shared "everything you need" uniform struct used by most fragment-only
/// visualizers. Layout matches the `Uniforms` struct in Shaders.metal.
/// Total: 60 bytes (Metal pads to 64). Keep field order in sync with the .metal side.
struct DepthLavaUniforms {
    var time: Float = 0
    var rms: Float = 0
    var onset: Float = 0
    var aspect: Float = 1
    var bands: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var nearMM: Float = 500
    var farMM: Float = 4000
    var pad0: Float = 0
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
    case pointCloud = "3D Point Cloud"
    case bodyPaint = "AR Body Paint"
    case nebula = "Volumetric Nebula"
    case opticalFlow = "Optical-Flow Painter"
    case particleStorm = "GPU Particle Storm"
    case stableFluids = "Stable Fluids"
    case voxelSculpt = "Voxel Sculpt"
    // — placeholders awaiting research-grounded implementations —
    case iridescentPlumage = "Iridescent Plumage"
    case cathedralOfBones = "Cathedral of Bones"
    case pixelStorm = "Pixel Storm"
    case bodyOfPetals = "Body of Petals"
    case mandelbulbAviary = "Mandelbulb Aviary"
    case smokeGod = "Smoke God"
    case stainedCathedral = "Stained Cathedral"
    case volumetricAurora = "Volumetric Aurora"
    case glassOcean = "Glass Ocean"
    case mercuryStorm = "Mercury Storm"
    case origamiBody = "Origami Body"
    case spectralOcean = "Spectral Ocean"
    case forestOfLight = "Forest of Light"
    case memoryPalace = "Memory Palace"

    var id: String { rawValue }
}
