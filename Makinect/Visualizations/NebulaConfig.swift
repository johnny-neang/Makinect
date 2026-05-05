// NebulaConfig — bespoke controls for the volumetric fbm-noise raymarched
// nebula. Knobs cover march quality, density / threshold, palette, body
// silhouette void, audio coupling, and noise spatial scale.

import Observation

@Observable
final class NebulaConfig {
    /// Raymarch step budget (16..64). More = clean volume; fewer = grainier
    /// but cheaper.
    var marchSteps: Int = 32

    /// Density-threshold floor. Smoke voxels below this are transparent.
    /// 0.3 = denser nebula; 0.6 = lacy wisps.
    var densityThreshold: Float = 0.45

    /// Density multiplier — overall opacity of the cloud.
    var densityScale: Float = 1.5

    /// Base hue for the emission palette (0..1). Hue varies with depth on top.
    var baseHue: Float = 0.5

    /// Saturation of the emission. 0 = grey nebula; 1 = neon.
    var saturation: Float = 0.55

    /// How much the body silhouette suppresses density (creates the
    /// "person-shaped void" look). 0 = body has no effect; 1 = full void.
    var bodyVoid: Float = 0.95

    /// Spatial frequency of the noise field — smaller = wide structures,
    /// larger = turbulent texture.
    var noiseScale: Float = 1.0

    /// Audio RMS multiplier on density. 0 = static cloud; 2 = pulses with sound.
    var audioCoupling: Float = 1.5
}
