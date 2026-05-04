// MandelbulbAviaryConfig — bespoke controls for the raymarched fractal +
// procedural-flock visualizer. Controls cover fractal shape (power +
// audio modulation depth + raymarch quality), camera motion, palette,
// and the bird flock (count + orbit + body coupling + size + color).

import Observation

@Observable
final class MandelbulbAviaryConfig {
    // — Fractal
    /// Base Mandelbulb power exponent. 8 = classic. <8 → blockier, simpler;
    /// >9 → more complex bristly geometry.
    var fractalPower: Float = 8.0

    /// How much bass modulates the fractal power. 0 = static; 3 = breathes
    /// dramatically with kicks.
    var powerAudioMod: Float = 2.0

    /// Raymarch step budget. 30 = grainier silhouette but cheap; 80 = clean
    /// surface but heavier. 60 is a good default.
    var raymarchSteps: Int = 60

    /// Base hue for the iridescent fractal palette.
    var fractalHue: Float = 0.55

    // — Camera
    /// Slow Y-axis orbit speed (rad/s).
    var camOrbitSpeed: Float = 0.10

    // — Flock
    /// Number of procedural birds (20–120).
    var birdCount: Int = 80

    /// Bird point size in NDC units.
    var birdSize: Float = 0.005

    /// Strength of body-COM attractor on birds. 0 = ignore body; 1 = drift
    /// strongly toward body center.
    var birdBodyAttract: Float = 0.20

    /// Bird trail/body color hue.
    var birdHue: Float = 0.02
}
