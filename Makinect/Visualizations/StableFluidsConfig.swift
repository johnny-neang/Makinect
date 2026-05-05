// StableFluidsConfig — bespoke controls for the Navier-Stokes ink simulation.

import Observation

@Observable
final class StableFluidsConfig {
    /// Dye dissipation per frame. Higher = ink lingers longer.
    var dissipation: Float = 0.992
    /// Velocity diffusion / kinematic viscosity. Higher = more drag.
    var viscosity: Float = 0.0001
    /// Hue A (one of two dye colors).
    var hueA: Float = 0.55
    /// Hue B (the second dye).
    var hueB: Float = 0.05
    /// Saturation of the dye palette.
    var saturation: Float = 0.85
    /// Value/brightness of the dye palette.
    var value: Float = 1.0
    /// 0 = lock hues to the user-set values; 1 = let time + audio drift them
    /// (legacy auto-cycle behavior).
    var autoHueDrift: Float = 1.0
}
