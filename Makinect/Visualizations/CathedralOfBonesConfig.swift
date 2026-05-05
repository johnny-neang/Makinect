// CathedralOfBonesConfig — bespoke controls for the X-ray anatomy visualizer.

import Observation

@Observable
final class CathedralOfBonesConfig {
    /// Heart base radius (chest center).
    var heartSize: Float = 0.025
    /// Bass-driven heart-radius pulse strength.
    var heartPulse: Float = 1.0
    /// Treble-driven nerve-flicker strength.
    var nerveIntensity: Float = 1.0
    /// Bone tint hue shift (0=warm silver, 0.5=cool blue).
    var boneTint: Float = 0.0
    /// Onset radiograph strobe intensity.
    var strobeIntensity: Float = 1.0
    /// Background plate warmth (0=cool film, 1=warm wet-plate).
    var plateWarmth: Float = 1.0
    /// Visceral red glow multiplier.
    var visceraGlow: Float = 1.0
    /// Bone line thickness multiplier.
    var boneThickness: Float = 1.0
}
