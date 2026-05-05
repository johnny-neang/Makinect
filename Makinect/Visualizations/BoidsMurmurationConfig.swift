// BoidsMurmurationConfig — bespoke controls for the boid flock viz.

import Observation

@Observable
final class BoidsMurmurationConfig {
    /// Base separation force (avoid neighbours).
    var separation: Float = 0.05
    /// Base alignment force (match neighbour heading).
    var alignment: Float = 0.04
    /// Base cohesion force (steer toward flock centre).
    var cohesion: Float = 0.012
    /// Predator-strength baseline (body repulsion).
    var predator: Float = 0.10
    /// Bass-driven separation boost.
    var bassSeparationBoost: Float = 0.04
    /// Treble-driven cohesion boost.
    var trebleCohesionBoost: Float = 0.02
    /// Onset-driven predator-strength boost.
    var onsetPredatorBoost: Float = 0.30
    /// Bird sprite scale.
    var birdSize: Float = 1.0
    /// Wing flap rate multiplier.
    var flapRate: Float = 1.0
}
