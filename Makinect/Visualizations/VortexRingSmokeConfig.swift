// VortexRingSmokeConfig — bespoke controls for the smoke-ring visualizer.

import Observation

@Observable
final class VortexRingSmokeConfig {
    /// Seconds between automatic ring spawns when audio is loud.
    var spawnInterval: Float = 1.2
    /// Per-frame upward drift speed of each ring.
    var riseSpeed: Float = 0.0018
    /// Vortex curl frequency inside each ring band (4..16 visible loops).
    var swirlFreq: Float = 8.0
    /// Saturation of the ring palette.
    var saturation: Float = 0.5
    /// Body silhouette amplification.
    var bodyBoost: Float = 1.2
}
