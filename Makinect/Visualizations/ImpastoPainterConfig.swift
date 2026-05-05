// ImpastoPainterConfig — bespoke controls for the impasto-stroke painter.

import Observation

@Observable
final class ImpastoPainterConfig {
    /// Brush stripe frequency — higher = finer brush hatching.
    var brushFreq: Float = 160
    /// Bass-driven brush frequency growth.
    var bassPump: Float = 80
    /// Base palette hue (added to default 0.55 / van Gogh blue).
    var baseHueShift: Float = 0
    /// Highlight palette hue shift.
    var highlightHueShift: Float = 0
    /// Background desaturation when no body present (0 = full color, 1 = grey).
    var bgDesaturation: Float = 0.35
    /// Audio coupling on stroke brightness.
    var audioCoupling: Float = 0.6
}
