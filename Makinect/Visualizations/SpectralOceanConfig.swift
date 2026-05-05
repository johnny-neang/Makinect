// SpectralOceanConfig — bespoke controls for the audio-history ring viz.

import Observation

@Observable
final class SpectralOceanConfig {
    /// Base ring outward-scroll speed.
    var ringSpeed: Float = 1.0
    /// Bass-driven ring-speed boost.
    var bassRingSpeed: Float = 1.0
    /// Ring density (higher = more rings visible).
    var ringDensity: Float = 30.0
    /// Crest sharpness (peak falloff exponent).
    var crestSharpness: Float = 1.5
    /// Deep hue (teal end of the gradient).
    var deepHue: Float = 0.55
    /// Warm hue (coral end of the gradient).
    var warmHue: Float = 0.05
    /// Body silhouette halo hue (gold default).
    var bodyHaloHue: Float = 0.13
    /// Onset wave-crash flash intensity.
    var onsetWave: Float = 0.40
}
