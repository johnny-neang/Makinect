// ForestOfLightConfig — bespoke controls for the vertical-pillar field viz.

import Observation

@Observable
final class ForestOfLightConfig {
    /// Pillar spacing (smaller = more pillars).
    var pillarSpacing: Float = 0.025
    /// Wind-sway amplitude multiplier.
    var swayAmount: Float = 1.0
    /// Pillar core-glow multiplier.
    var coreGlow: Float = 1.0
    /// Volumetric scatter haze intensity.
    var scatterAmount: Float = 1.0
    /// Base hue starting point.
    var baseHue: Float = 0.55
    /// Per-band saturation boost (multiplier).
    var bandSaturation: Float = 1.0
    /// Onset full-row flash brightness.
    var onsetFlash: Float = 0.30
    /// Audio coupling on band response.
    var audioCoupling: Float = 1.0
}
