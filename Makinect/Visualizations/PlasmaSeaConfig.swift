// PlasmaSeaConfig — bespoke controls for the volumetric-caustics under-water
// visualizer. Knobs cover wave geometry, chromatic dispersion, palette hue
// shifts, body subsurface glow color, and audio coupling.

import Observation

@Observable
final class PlasmaSeaConfig {
    /// Spatial zoom on the wave pattern. Higher = smaller waves.
    var waveScale: Float = 4.0

    /// Animation speed multiplier on the waves.
    var waveSpeed: Float = 1.0

    /// Chromatic dispersion strength — separation between R/G/B caustic
    /// channels (more = real-water fringe).
    var dispersion: Float = 1.0

    /// Hue shift for the deep-water tint (added on top of the iq palette).
    var deepHueShift: Float = 0.0

    /// Hue shift for the lit caustic highlights.
    var litHueShift: Float = 0.0

    /// Body subsurface glow hue (default warm orange).
    var bodyGlowHue: Float = 0.04

    /// Audio coupling on caustic intensity.
    var audioCoupling: Float = 1.2

    /// Overall brightness multiplier.
    var brightness: Float = 1.0
}
