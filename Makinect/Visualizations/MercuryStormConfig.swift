// MercuryStormConfig — bespoke controls for the chrome-metaball visualizer.
// Knobs cover ball-field shape (count / orbit / radius), body coupling,
// chrome shading (palette / streak / specular tightness), and onset bursts.

import Observation

@Observable
final class MercuryStormConfig {
    /// Number of orbiting metaballs (4–16). More = denser chrome blobs.
    var ballCount: Int = 8

    /// Average distance from screen center each ball orbits at (NDC units).
    var orbitRadius: Float = 0.25

    /// Base radius of each metaball — controls glob density at the iso-surface.
    var ballRadius: Float = 0.10

    /// Strength of the body-as-source emission. 0 = body has no effect on the
    /// metaball field; 3 = body cells dominate the visible chrome blob.
    var bodyEmit: Float = 1.5

    /// Base hue for the chrome reflection palette. The chrome is iridescent
    /// (varies with normal direction) but this is the central hue.
    var baseHue: Float = 0.55

    /// Anisotropic streak intensity — the chrome's "brushed metal" highlight.
    /// 0 = mirror smooth; 1 = aggressive streaks.
    var streakIntensity: Float = 0.4

    /// Specular highlight tightness. 8 = soft, 128 = pinpoint hot dot.
    var specularTightness: Float = 64

    /// Onset vortex magnitude. 0 = no beat shockwave; 1 = full vortex burst.
    var onsetVortex: Float = 1.0
}
