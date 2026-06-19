// LaserGeometryConfig — bespoke controls for the "Laser Beams" visualizer,
// the Phase-1 geometric projection look. Mirrors the @Observable per-viz
// config pattern used across the slate (e.g. ParametricSwarmConfig).

import Observation

@Observable
final class LaserGeometryConfig {
    /// Base palette hue (0..1). Section changes rotate around this.
    /// Default ≈ violet, matching the INZO "Overthinker" intro.
    var baseHue: Float = 0.75
    /// How far the palette wanders across sections (fraction of the hue wheel).
    var paletteSpread: Float = 0.55
    /// Beam colour saturation.
    var saturation: Float = 0.9

    /// Upper bound on on-screen density at full energy (scales beam/spoke counts).
    var densityCeiling: Float = 1.0
    /// Negative-space bias (0..1). Higher = more blackouts and single-fan
    /// restraint during quiet passages — the core lesson of the reference show.
    var negativeSpaceBias: Float = 0.5
    /// How hard onsets punch a transient flash (0 = ignore transients).
    var onsetPunch: Float = 1.0

    /// Beam half-width in clip-Y units. Thin = more "laser".
    var beamWidth: Float = 0.004
    /// Additive exposure / core brightness.
    var exposure: Float = 1.4
    /// Halo tightness (higher = tighter, more razor-like; lower = softer glow).
    var haloSoftness: Float = 26.0
    /// Scan / rotation speed multiplier for the rhythmic layer.
    var scanSpeed: Float = 1.0
    /// Base spoke / polygon side count for the symmetric patterns.
    var symmetry: Int = 12
}
