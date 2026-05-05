// MagneticIronFilingsConfig — bespoke controls for the iron-filing dipole field viz.

import Observation

@Observable
final class MagneticIronFilingsConfig {
    /// Filing line-length scale.
    var lineLength: Float = 1.0
    /// Field-step strength (how strongly filings move per frame).
    var fieldStrength: Float = 1.0
    /// Base hue (0.55 = warm cool default).
    var baseHue: Float = 0.55
    /// Audio coupling on brightness + line length.
    var audioCoupling: Float = 1.0
    /// Bass-driven hue shift strength.
    var bassHueShift: Float = 0.2
    /// Whether onset flips polarity.
    var onsetPolarityFlip: Bool = true
    /// Onset brightness boost.
    var onsetBoost: Float = 1.0
    /// Saturation of the palette.
    var saturation: Float = 0.7
}
