// OpticalFlowConfig — bespoke controls for the motion-painter visualizer.

import Observation

@Observable
final class OpticalFlowConfig {
    /// Paint persistence (viscosity). Higher = trails linger longer.
    var viscosity: Float = 0.985
    /// Motion gate threshold — minimum motion magnitude to splat new paint.
    var motionGate: Float = 0.0008
    /// Hue A.
    var hueA: Float = 0.55
    /// Hue B.
    var hueB: Float = 0.05
    /// Saturation.
    var saturation: Float = 0.7
    /// Value/brightness.
    var value: Float = 0.6
    /// 0 = lock hues; 1 = let time + audio drift them.
    var autoHueDrift: Float = 1.0
}
