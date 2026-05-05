// PixelStormConfig — bespoke controls for the pixel-sort cascade.

import Observation

@Observable
final class PixelStormConfig {
    /// Sort sample count per column (4..16) — more = denser streamers.
    var sampleCount: Int = 8
    /// Streamer fall speed multiplier.
    var fallSpeed: Float = 1.0
    /// Brightness threshold offset — lower = more pixels qualify as streamers.
    var thresholdOffset: Float = 0.0
    /// Body protection: 1 = body always pristine, 0 = body gets sorted too.
    var bodyProtect: Float = 1.0
    /// Hue tint added to sorted streamers (0..1).
    var hueTint: Float = 0.6
}
