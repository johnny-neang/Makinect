// VelvetPetalFieldConfig — bespoke controls for the velvet-petal field viz.

import Observation

@Observable
final class VelvetPetalFieldConfig {
    /// Number of concentric rings of petal centres.
    var ringCount: Int = 4
    /// Number of petals per ring.
    var divisions: Int = 14
    /// Bass-driven bloom boost.
    var bassBloom: Float = 1.0
    /// Base hue (jewel-velvet anchor).
    var baseHue: Float = 0.85
    /// Saturation of velvet petals.
    var saturation: Float = 0.85
    /// Per-petal size scale.
    var petalScale: Float = 1.0
    /// Stem-sway amplitude (audio-coupled).
    var stemSway: Float = 1.0
    /// Onset bloom-glow intensity.
    var onsetGlow: Float = 1.0
}
