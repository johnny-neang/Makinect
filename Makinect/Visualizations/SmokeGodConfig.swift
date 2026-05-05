// SmokeGodConfig — bespoke controls for the body-as-light volumetric fog.
// Knobs cover march quality, density, the lit/shadow two-tone palette,
// saturation, and the onset-ember spark strength.

import Observation

@Observable
final class SmokeGodConfig {
    /// Raymarch step budget. Lower = grainier but cheaper.
    var marchSteps: Int = 32

    /// Density-threshold floor.
    var densityThreshold: Float = 0.40

    /// Density multiplier — overall opacity of the smoke.
    var densityScale: Float = 0.8

    /// Hue for "lit" voxels near the body silhouette (default warm gold).
    var litHue: Float = 0.10

    /// Hue for "shadow" voxels far from the body (default cool blue).
    var shadowHue: Float = 0.58

    /// Saturation of both palettes.
    var saturation: Float = 0.5

    /// Onset ember spark intensity. 0 = no sparks; 3 = explosive embers.
    var emberStrength: Float = 1.0

    /// Audio coupling on density (RMS).
    var audioCoupling: Float = 1.2
}
