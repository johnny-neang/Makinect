// MemoryPalaceConfig — bespoke controls for the 3×3 capstone mosaic.

import Observation

@Observable
final class MemoryPalaceConfig {
    /// Onset-shuffle rate (0 = lock the layout, higher = re-shuffle faster).
    var shuffleRate: Float = 1.0
    /// Pane-border gutter width multiplier.
    var gutterWidth: Float = 1.0
    /// Per-pane EQ-band spread (audio coupling).
    var bandSpread: Float = 1.0
    /// Cross-pane bleed strength.
    var paneBleed: Float = 1.0
    /// Onset additive flash intensity.
    var onsetFlash: Float = 0.30
    /// Master pane palette hue offset.
    var hueOffset: Float = 0.0
    /// Saturation for pane colors.
    var saturation: Float = 0.7
    /// Vignette tightness.
    var vignette: Float = 1.0
}
