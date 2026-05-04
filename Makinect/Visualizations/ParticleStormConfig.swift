// ParticleStormConfig — bespoke per-viz controls for the GPU Particle Storm
// visualizer. ~256k curl-noise advected particles with body-silhouette
// attraction + onset shockwaves. Knobs cover density, motion field, body
// coupling, color palette, and point-sprite styling — everything a VJ might
// want to dial in real-time.

import Observation

@Observable
final class ParticleStormConfig {
    /// Active particle count, dispatched against the 256k buffer ceiling.
    /// Step is 4096 so the slider has visibly distinct positions across the
    /// 1k–256k range.
    var particleCount: Int = 1024 * 200       // 200k

    // — Motion field
    /// Spatial frequency of the curl-noise field — higher = tighter eddies,
    /// lower = sweeping currents.
    var curlScale: Float = 1.4

    /// Multiplier on the curl-noise force vector. 0 = no curl motion;
    /// 2 = aggressive flow.
    var accelGain: Float = 1.0

    /// Velocity damping per frame. 0.85 = quick stop; 0.99 = drifty.
    var damping: Float = 0.93

    /// Body-COM attractor strength. 0 = body has no effect on particles;
    /// 1 = particles drift toward body cells; 2 = strong pull.
    var bodyPull: Float = 1.0

    /// Outward burst strength on each onset. 0 = no shockwave; 5 = explosive.
    var onsetBurst: Float = 2.0

    /// Recycle age — particles older than this respawn. Lower = faster
    /// turnover (more chaos); higher = particles linger.
    var recycleAge: Float = 320

    // — Color
    /// Base hue. 0..1.
    var baseHue: Float = 0.55

    /// How widely hue varies across the swarm. 0 = monochrome,
    /// 1 = full rainbow.
    var hueSpread: Float = 1.0

    /// Saturation of the particle palette. 0 = greyscale, 1 = neon.
    var saturation: Float = 0.85

    // — Point sprite styling
    /// Base point-sprite radius (in screen px before audio pump).
    var pointSizeBase: Float = 2.0

    /// How much velocity scales the point size — speed-to-size mapping.
    /// 0 = uniform size; 30 = fast particles dominate.
    var speedToSize: Float = 8.0

    /// Per-particle high-frequency jitter on treble. 0 = clean motion,
    /// 1 = jittery shimmer.
    var jitterAmount: Float = 0.5
}
