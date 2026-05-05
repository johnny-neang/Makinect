// BodyPaintConfig — bespoke controls for the AR body-paint visualizer.

import Observation

@Observable
final class BodyPaintConfig {
    /// Base billboard size for limb joints (NDC).
    var jointSize: Float = 0.06
    /// Size for the head/nose joint (NDC).
    var headSize: Float = 0.10
    /// Onset+RMS pulse multiplier on billboard size.
    var beatBoost: Float = 1.2
    /// Audio coupling on per-billboard intensity (multiplier on band energy).
    var audioCoupling: Float = 4.0
    /// Hue offset added to joint-derived hue.
    var hueOffset: Float = 0.0
    /// Saturation of the joint billboards.
    var saturation: Float = 0.9
    /// Soft falloff exponent — higher = sharper edge.
    var falloff: Float = 1.0
    /// Trail/persistence multiplier (controls accumulated alpha).
    var trail: Float = 1.0
    /// Joint smoothing alpha (lower = smoother, higher = snappier).
    var smoothing: Float = 0.4
}
