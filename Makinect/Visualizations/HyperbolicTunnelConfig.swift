// HyperbolicTunnelConfig — bespoke controls for the H² Poincaré tunnel viz.

import Observation

@Observable
final class HyperbolicTunnelConfig {
    /// Base swirl amount (rotation per fold).
    var swirlBase: Float = 0.10
    /// Bass-driven swirl boost.
    var bassSwirl: Float = 0.30
    /// Fold depth — number of recursive disk folds.
    var foldDepth: Int = 6
    /// Tile sharpness multiplier (seam falloff).
    var tileSharpness: Float = 6.0
    /// Radial frequency for the fold-rotation pattern.
    var radialFreq: Float = 7.0
    /// Onset bloom intensity.
    var onsetGlow: Float = 0.5
    /// Vignette tightness (lower = larger visible area).
    var vignetteScale: Float = 1.0
    /// Hue palette offset (cycles through iridescent glass hues).
    var hueOffset: Float = 0.0
}
