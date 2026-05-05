// GlassOceanConfig — bespoke controls for the underwater-refraction viz.

import Observation

@Observable
final class GlassOceanConfig {
    /// Refraction-strength multiplier on body-glass surface.
    var refractionStrength: Float = 1.0
    /// Caustics intensity multiplier on the reef floor.
    var causticsIntensity: Float = 1.0
    /// Coral hue (procedural reef color).
    var coralHue: Float = 0.95
    /// Number of drifting jellies.
    var jellyCount: Int = 8
    /// Base jelly size.
    var jellySize: Float = 0.04
    /// Body fresnel-rim brightness.
    var rimStrength: Float = 1.0
    /// Chromatic aberration amount.
    var aberration: Float = 1.0
    /// Onset ripple flash strength.
    var onsetRipple: Float = 0.30
}
