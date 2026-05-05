// MocapConstellationConfig — bespoke controls for the joint-trail constellation
// visualizer. Each emitted "star" represents a joint position over time, with
// expanding shockwaves marking when each appeared. Knobs cover emission
// cadence, star lifespan / size / decay, shockwave geometry, and palette.

import Observation

@Observable
final class MocapConstellationConfig {
    /// Seconds between successive emission cycles. 0.02 = dense trail
    /// (every frame); 0.3 = sparse stars.
    var emissionRate: Float = 0.05

    /// Maximum age before a star disappears (seconds). Longer = more
    /// persistent constellation.
    var starLifespan: Float = 8.0

    /// Size of each star's bright twinkle core. 500 = big halos;
    /// 3000 = tight pinpoints. Smaller numbers = larger visible stars.
    var starCoreSize: Float = 1500

    /// How fast the expanding shockwave ring grows (NDC units per second).
    var ringGrowth: Float = 0.18

    /// Width of the expanding shockwave ring.
    var ringWidth: Float = 0.012

    /// How much audio RMS amplifies the star core brightness (0..2).
    var audioCoupling: Float = 0.6

    /// Base hue used for stars when `randomizeHue` is off. 0..1.
    var baseHue: Float = 0.55

    /// When true, each joint type gets its own deterministic hue so different
    /// limbs draw with different colors. When false, all stars share `baseHue`.
    var randomizeHue: Bool = true
}
