// BodyOfPetalsConfig — bespoke controls for the cherry-blossom petal cascade.
// Knobs cover petal density / size / fall speed, the three-tone palette,
// sub-surface scattering, body avoidance, and the onset bouquet behavior.

import Observation

@Observable
final class BodyOfPetalsConfig {
    // — Density & size
    /// Spatial cell size — smaller = denser petals.
    var petalSize: Float = 0.040

    /// 0 = sparse petals (lots of empty cells), 1 = solid petal field.
    var density: Float = 0.70

    // — Motion
    /// Base scroll speed (petals fall downward). 0 = static; 0.5 = blizzard.
    var fallSpeed: Float = 0.05

    /// How much bass accelerates the fall.
    var bassFall: Float = 0.10

    // — Palette (three-tone, randomly assigned per cell)
    /// Soft pink hue.
    var hueA: Float = 0.96   // ~pinkish
    /// Crimson hue.
    var hueB: Float = 0.98
    /// Cream / pale yellow hue.
    var hueC: Float = 0.13

    /// Saturation of the palette.
    var saturation: Float = 0.55

    // — Surface
    /// Strength of sub-surface glow (bright petal centers).
    var subSurface: Float = 0.6

    // — Body & beats
    /// 0 = body has no effect; 1 = body region dims petals; 2 = body voids them.
    var bodyAvoidance: Float = 1.0

    /// Onset bouquet — extra petals burst from screen center on each onset.
    /// 0 = off; 1 = full bouquet.
    var onsetBouquet: Float = 1.0
}
