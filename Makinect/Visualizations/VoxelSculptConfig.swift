// VoxelSculptConfig — bespoke controls for the voxelised body sculpture.

import Observation

@Observable
final class VoxelSculptConfig {
    /// Voxel scale multiplier (size of each cube).
    var voxelScale: Float = 0.06
    /// Base hue for the gradient.
    var baseHue: Float = 0.55
    /// How much height shifts the hue (vertical gradient strength).
    var hueSpread: Float = 0.15
    /// Saturation of the palette.
    var saturation: Float = 0.85
    /// Audio (bass) coupling on hue shift.
    var audioCoupling: Float = 0.3
}
