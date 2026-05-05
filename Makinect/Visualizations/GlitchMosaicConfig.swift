// GlitchMosaicConfig — bespoke controls for the holographic-mirror tile mosaic.

import Observation

@Observable
final class GlitchMosaicConfig {
    /// Base tile size (NDC). Higher = bigger blocks.
    var tileSize: Float = 0.018
    /// Bass-driven tile size growth on kicks.
    var bassPump: Float = 0.025
    /// Probability threshold for datamosh tiles (lower = more glitch).
    var glitchProbability: Float = 0.85
    /// RGB channel separation — chromatic aberration on each tile.
    var rgbSeparation: Float = 0.005
    /// Holographic rainbow rim intensity.
    var rimIntensity: Float = 0.3
    /// Strobe inversion strength on onset.
    var onsetStrobe: Float = 1.0
}
