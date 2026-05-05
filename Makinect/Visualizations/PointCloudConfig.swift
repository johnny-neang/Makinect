// PointCloudConfig — bespoke controls for the 3D point cloud visualizer.

import Observation

@Observable
final class PointCloudConfig {
    /// Base point sprite size.
    var pointSize: Float = 4.0
    /// Hue at the nearest depth (depthN=0).
    var baseHue: Float = 0.60
    /// Hue gradient across depth (negative = nearer is bluer).
    var hueGradient: Float = -0.50
    /// Saturation of the palette.
    var saturation: Float = 0.85
    /// Bass-driven radial displacement strength.
    var bassDisplacement: Float = 0.05
}
