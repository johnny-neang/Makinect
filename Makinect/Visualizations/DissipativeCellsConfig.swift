// DissipativeCellsConfig — bespoke controls for the Voronoi cell visualizer.

import Observation

@Observable
final class DissipativeCellsConfig {
    /// Cell lifespan in frames. Lower = faster turnover.
    var cellLifespan: Float = 600
    /// Brownian drift force magnitude.
    var driftStrength: Float = 0.0008
    /// Velocity damping per frame.
    var damping: Float = 0.95
    /// Minimum alive cells before re-seeding kicks in.
    var minCells: Int = 12
    /// Base radius for newly-spawned cells.
    var initialRadius: Float = 0.18
    /// Mitosis on onset (true = beats split cells).
    var mitosisOnOnset: Bool = true
}
