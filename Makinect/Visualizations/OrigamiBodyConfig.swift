// OrigamiBodyConfig — bespoke controls for the paper-folded body viz.

import Observation

@Observable
final class OrigamiBodyConfig {
    /// Base triangular grid size (smaller = more polygons).
    var gridSize: Float = 0.045
    /// Fold-animation speed multiplier.
    var foldSpeed: Float = 1.0
    /// Onset refold burst strength.
    var onsetRefold: Float = 1.0
    /// Palette balance: 0 favors sumi-amber, 0.5 balanced, 1 favors vermillion.
    var paletteBalance: Float = 0.5
    /// Paper warmth (cool washi → warm kraft).
    var paperWarmth: Float = 1.0
    /// Ink-bleed strength on fold edges.
    var inkBleed: Float = 1.0
    /// Audio coupling on fold animation + grid.
    var audioCoupling: Float = 1.0
    /// Calligraphy stroke contrast (background brushstroke).
    var brushContrast: Float = 1.0
}
