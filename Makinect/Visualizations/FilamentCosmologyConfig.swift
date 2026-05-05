// FilamentCosmologyConfig — bespoke controls for the cosmic-filament raymarcher.

import Observation

@Observable
final class FilamentCosmologyConfig {
    /// Raymarch step budget (12..72).
    var marchSteps: Int = 36
    /// Worley filament threshold — lower = more cosmic web, higher = sparser.
    var filamentThreshold: Float = 0.55
    /// Body lensing strength — how much body pulls rays toward it.
    var lensStrength: Float = 0.4
    /// Base hue for the iq_palette (added to default 0.62 / cosmic teal).
    var hueShift: Float = 0.0
    /// Audio coupling on density.
    var audioCoupling: Float = 1.5
    /// Spatial frequency of the worley field.
    var worleyScale: Float = 1.4
}
