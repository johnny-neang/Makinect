// LiquidLightCalligraphyConfig — bespoke controls for the joint-trail
// liquid-ink visualizer.

import Observation

@Observable
final class LiquidLightCalligraphyConfig {
    /// Trail decay (0.90..0.999). Higher = ink lingers longer.
    var trailDecay: Float = 0.97
    /// Viscosity / advection coupling.
    var viscosity: Float = 0.0008
    /// Brush radius scale (multiplied with velocity-based size).
    var brushRadius: Float = 1.0
    /// Use deterministic per-joint hue (true) or single user hue (false).
    var perJointHue: Bool = true
    /// Single hue used when perJointHue is false.
    var baseHue: Float = 0.55
}
