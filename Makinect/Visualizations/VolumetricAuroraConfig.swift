// VolumetricAuroraConfig — bespoke controls for the falling aurora curtain.
// Knobs cover descent speed, curtain frequency, three-tone palette,
// star density, body coupling, and the onset drop behavior.

import Observation

@Observable
final class VolumetricAuroraConfig {
    /// Vertical fall speed of the curtain (NDC units per second).
    var fallSpeed: Float = 0.08

    /// Curtain wobble frequency — higher = more vertical bands.
    var curtainFreq: Float = 8.0

    /// Drop compression magnitude on each onset. 0 = no drop; 1 = full plunge.
    var dropMagnitude: Float = 1.0

    /// Star field density (0 = no stars; 1 = dense).
    var starDensity: Float = 1.0

    // — Three-tone aurora palette (rotated/blended across the curtain)
    /// Primary aurora hue (default green ~0.32).
    var hueA: Float = 0.32
    /// Accent aurora hue (default magenta ~0.85).
    var hueB: Float = 0.85
    /// Mid-tone hue (default teal ~0.50).
    var hueC: Float = 0.50

    /// How much the body silhouette boosts aurora intensity near it.
    var bodyBoost: Float = 1.5

    /// Treble shimmer intensity (high-frequency sparkle layer).
    var trebleShimmer: Float = 0.8
}
