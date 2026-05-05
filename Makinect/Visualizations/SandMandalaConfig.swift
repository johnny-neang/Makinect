// SandMandalaConfig — bespoke controls for the spring-driven mandala grain
// system. Knobs cover grain count + density, mandala geometry (symmetry,
// ring scale, rotation), motion physics (spring stiffness, damping), and
// the onset re-pattern behavior.

import Observation

@Observable
final class SandMandalaConfig {
    /// Number of mandala grains. 1024 = sparse outline; 262144 = solid mandala.
    var grainCount: Int = 1024 * 256

    /// Spring constant pulling each grain to its target. 0.005 = liquid drift;
    /// 0.05 = snappy lock-in.
    var springK: Float = 0.022

    /// Velocity damping per frame. Lower = more wobble; higher = settled.
    var damping: Float = 0.91

    /// Rotational symmetry — number of "petals" / fold count of the mandala.
    var symmetry: Float = 8

    /// Innermost ring radius (NDC units, 0..1). Higher = larger ring offset.
    var ringScale: Float = 0.45

    /// Auto-rotation rate (radians added per frame).
    var rotationSpeed: Float = 0.0015

    /// Onset behavior: 0 = ignore beats; 1 = onsets re-pattern the mandala
    /// (rotate by 30° + new morph seed).
    var onsetMorph: Float = 1.0

    // Note: per-mandala baseHue intentionally NOT included here — the
    // universal Common Params "Hue Shift" slider rotates the entire output
    // (Tibetan palette and all). For local hue swaps, prefer the universal
    // post-process control.
}
