// StrandVeilConfig — bespoke controls for the curl-noise strand-hair veil.
// Knobs cover strand count, flow shape, gravity, palette spread, and the
// audio coupling that pumps strand brightness on rms.

import Observation

@Observable
final class StrandVeilConfig {
    /// Number of independent strands. 1000 = sparse veil; 16000 = dense
    /// curtain.
    var strandCount: Int = 8000

    /// Curl-noise spatial frequency. Lower = sweeping currents; higher =
    /// turbulent eddies.
    var flowScale: Float = 0.6

    /// How much bass amplifies the flow scale. 0 = ignore audio.
    var flowAudioMod: Float = 0.8

    /// Downward pull on each strand (NDC units per step). 0 = float;
    /// 1 = heavy curtain.
    var gravity: Float = 0.4

    /// Strand length multiplier — affects how far each strand extends from
    /// its head along the flow.
    var strandLength: Float = 1.0

    /// Base hue for the strand palette (0..1).
    var baseHue: Float = 0.55

    /// Hue spread across strands — 0 = monochrome veil; 1 = full rainbow.
    var hueSpread: Float = 1.0

    /// Audio coupling (RMS amplifies strand brightness).
    var audioCoupling: Float = 0.7
}
