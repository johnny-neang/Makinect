// ParametricSwarmConfig — observable user-controllable knobs for the
// Parametric Swarm visualizer, exposed in SidePanel.
//
// Lives on KinectManager and is passed through VisualizerInputs so that
// changes in the SidePanel propagate to the shader on the very next frame.
//
// Reference: https://particles.casberry.in/ exposes Particle Count, Sim Speed,
// Glow Intensity, 8 Visual Styles, and Local Formations (Sphere/Cube/Helix/
// Donut). This config follows that template, adapted to Makinect's audio +
// Kinect inputs (body attraction strength, audio modulation depth, etc.).

import Observation

/// Parametric Swarm formation choice. `.auto` lets onsets cycle through
/// formations; the others lock to a specific one.
enum SwarmFormation: Int, CaseIterable, Identifiable {
    case auto      = -1
    case sphere    = 0
    case torus     = 1
    case helix     = 2
    case cube      = 3
    case lissajous = 4
    case attractor = 5
    case galaxy    = 6
    case orbital   = 7

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .auto:      return "Auto-cycle"
        case .sphere:    return "Geodesic Sphere"
        case .torus:     return "Torus"
        case .helix:     return "Double Helix"
        case .cube:      return "Cube Lattice"
        case .lissajous: return "Lissajous Knot"
        case .attractor: return "Aizawa Attractor"
        case .galaxy:    return "Galaxy Spiral"
        case .orbital:   return "Atomic Orbital"
        }
    }
}

/// Visual style preset — a named bundle of palette + glow settings the user
/// can pick as a starting point, then fine-tune with the sliders.
enum SwarmStyle: String, CaseIterable, Identifiable {
    case plasma = "Plasma"   // Casberry default — neon green + soft glow
    case spark  = "Spark"    // tiny bright white pinpoints, low spread
    case cyber  = "Cyber"    // magenta/cyan, high saturation, large glow
    case ember  = "Ember"    // warm orange/red, soft halo
    case vector = "Vector"   // tight green geometric, no jitter
    case glass  = "Glass"    // translucent ice-blue, big halo

    var id: String { rawValue }

    /// (baseHue, hueSpread, saturation, value)
    var palette: (Float, Float, Float, Float) {
        switch self {
        case .plasma: return (0.33, 0.04, 0.95, 0.85)
        case .spark:  return (0.10, 0.02, 0.30, 1.20)  // near-white, very low sat
        case .cyber:  return (0.85, 0.18, 1.00, 0.95)  // magenta with broad spread
        case .ember:  return (0.04, 0.05, 0.95, 1.00)  // orange-red
        case .vector: return (0.33, 0.00, 1.00, 0.80)  // pure green, no spread
        case .glass:  return (0.55, 0.06, 0.55, 0.95)  // ice-blue
        }
    }

    /// Default glow intensity for this style (multiplied with point sprite size).
    var defaultGlow: Float {
        switch self {
        case .plasma: return 1.8
        case .spark:  return 1.2
        case .cyber:  return 2.4
        case .ember:  return 1.6
        case .vector: return 1.0
        case .glass:  return 2.6
        }
    }
}

@Observable
final class ParametricSwarmConfig {
    // — Shape
    var formation: SwarmFormation = .auto

    // — Style preset (sets palette + glow defaults; sliders fine-tune from there)
    var style: SwarmStyle = .plasma {
        didSet { applyStylePreset() }
    }

    // — Particle simulation
    /// Effective particle count, clamped to [1024, 65536]. Powers of 2 are
    /// kindest to the dispatch grid but any value works.
    var particleCount: Int = 24576
    /// Multiplier on the base point-sprite size. Range ~0.4..6.0.
    var particleSize: Float = 3.0
    /// Multiplier on the HDR overdrive in the fragment shader. ~0.5..3.0.
    var glowIntensity: Float = 1.8

    // — Color
    /// Base hue in [0, 1] (0=red, 0.33=green, 0.66=blue).
    var baseHue: Float = 0.33
    /// How much hue varies across particles. 0 = monochrome, 0.5 = wide rainbow.
    var hueSpread: Float = 0.04
    /// HSV saturation. 0 = greyscale, 1 = full neon.
    var saturation: Float = 0.95
    /// HSV value (HDR overdrive welcomed). Typical 0.6..1.4.
    var value: Float = 0.85

    // — Audio depth (how much each input modulates the swarm)
    /// 0 = ignore audio entirely; 1 = full audio modulation.
    var audioReactivity: Float = 1.0

    // — Body integration
    /// Strength of the swarm-toward-body-COM attraction when a Kinect skeleton
    /// is detected. 0 = swarm stays at origin even with a body present;
    /// 1 = swarm fully follows; >1 amplifies.
    var bodyAttraction: Float = 1.0

    // — Camera
    /// Auto-orbit yaw speed (radians/second). 0 = static, 0.18 = ~10°/s.
    var rotateSpeed: Float = 0.18

    /// Apply the style preset's palette + glow defaults. Called from the
    /// `style` didSet so flipping styles is "one click" — sliders snap to the
    /// preset, then the user can fine-tune.
    private func applyStylePreset() {
        let (h, s, sat, v) = style.palette
        baseHue = h
        hueSpread = s
        saturation = sat
        value = v
        glowIntensity = style.defaultGlow
    }
}
