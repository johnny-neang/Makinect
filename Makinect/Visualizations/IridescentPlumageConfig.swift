// IridescentPlumageConfig — bespoke controls for the procedural feather viz.

import Observation

@Observable
final class IridescentPlumageConfig {
    /// Base feather cell size.
    var featherSize: Float = 0.018
    /// Bass-driven gravity-comb strength (combs feathers downward).
    var bassGravityComb: Float = 1.0
    /// Treble ruffle multiplier (high-freq individual-feather flutter).
    var trebleRuffle: Float = 1.0
    /// Hue offset added to per-cell base hue.
    var hueOffset: Float = 0.0
    /// Highlight hue (secondary thin-film color) offset.
    var highlightHueOffset: Float = 0.55
    /// Onset gust strength (horizontal cut stripe).
    var gustStrength: Float = 1.0
    /// Sub-surface scattering hint multiplier.
    var subSurface: Float = 1.0
    /// Audio glow multiplier (bass + RMS contribution).
    var audioGlow: Float = 1.0
    /// Saturation scale.
    var saturation: Float = 1.0
}
