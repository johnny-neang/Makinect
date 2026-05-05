// StainedCathedralConfig — bespoke controls for the rosette window viz.

import Observation

@Observable
final class StainedCathedralConfig {
    /// Number of radial sectors (rosette petals).
    var sectorCount: Int = 12
    /// Number of concentric rings.
    var ringCount: Int = 8
    /// Lead tracery line width multiplier.
    var traceryWidth: Float = 1.0
    /// Inner halo glow multiplier.
    var innerGlow: Float = 1.5
    /// God-ray dim multiplier (how much body silhouette dims rays).
    var godRayStrength: Float = 1.0
    /// Atmospheric dust mote intensity.
    var dustIntensity: Float = 0.20
    /// Onset organ-pulse flash strength.
    var onsetFlash: Float = 0.40
    /// Body halo hue shift.
    var bodyHaloHue: Float = 0.0
}
