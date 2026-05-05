// KineticWireframeConfig — bespoke controls for the wireframe-mesh viz.

import Observation

@Observable
final class KineticWireframeConfig {
    /// Base line thickness (NDC).
    var lineThickness: Float = 0.0014
    /// Onset explosion magnitude.
    var explosionMagnitude: Float = 0.16
    /// Hue shift on the iq_palette base (when not body).
    var baseHueShift: Float = 0
    /// Body region tint hue (warm gold default).
    var bodyTintHue: Float = 0.10
    /// Bass coupling on explosion + thickness.
    var audioCoupling: Float = 1.0
}
