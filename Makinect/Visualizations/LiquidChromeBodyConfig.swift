// LiquidChromeBodyConfig — bespoke controls for the chrome-raymarch viz.

import Observation

@Observable
final class LiquidChromeBodyConfig {
    /// Surface wobble base amount (audio-detuned).
    var wobbleBase: Float = 0.5
    /// Bass coupling on environment color.
    var bassEnvBoost: Float = 1.0
    /// Treble coupling on environment color.
    var trebleEnvBoost: Float = 1.0
    /// Fresnel-mix between matte base and environment reflection.
    var fresnelMix: Float = 0.65
    /// Onset specular-spike intensity.
    var onsetSpike: Float = 1.0
    /// Environment hue shift.
    var envHueShift: Float = 0.0
    /// Base tone hue offset (shifts the matte fallback color).
    var baseTone: Float = 0.0
}
