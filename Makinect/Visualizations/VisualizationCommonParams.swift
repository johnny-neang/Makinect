// VisualizationCommonParams — universal modifiers applied across every
// visualizer in the slate. Six knobs that change feel without touching
// individual visualizer-specific configs (those layer on top via per-viz
// Config classes like ParametricSwarmConfig).
//
// Implementation strategy (Phase A):
//   • `audioReactivity`  → AudioEngine.outputMultiplier (every viz reads
//                          scaled audio without per-viz changes).
//   • `speedMul`         → MetalKinectView pre-scales `timeSeconds` before
//                          packing VisualizerInputs (every viz reads scaled
//                          time without per-viz changes).
//   • `hueShift / satMul / valMul / glowMul` → applied as a single screen-
//                          space POST-PROCESS pass after the visualizer
//                          renders to an offscreen texture. No per-viz
//                          shader changes required (`common_post_fs` in
//                          Shaders.metal does the work).

import Observation

@Observable
final class VisualizationCommonParams {
    /// Global audio multiplier. 0 = visuals run silent (no audio response on
    /// any visualizer). 1 = normal. 1.5 = exaggerated. Per-viz audio configs
    /// (e.g. ParametricSwarmConfig.audioReactivity) compose multiplicatively
    /// on top of this — set this to 0 and ALL audio response stops.
    var audioReactivity: Float = 1.0

    /// Animation speed multiplier. 0 = freeze; 1 = normal; 3 = frenetic.
    /// Applied to the `timeSeconds` value visualizers see, so any term that
    /// reads `time` automatically scales (sine/cosine animations, drifting
    /// noise, slow rotations, etc.).
    var speedMul: Float = 1.0

    // — Output-stage colour modifiers (applied in common_post_fs after the
    //   visualizer has rendered into the offscreen texture).

    /// Rotates the output hue. -0.5 .. +0.5 covers a full rotation each way.
    /// 0 = pass-through.
    var hueShift: Float = 0.0

    /// Multiplied with the output saturation (after RGB→HSV). 1 = pass-through.
    /// 0 = grayscale, 2 = oversaturated.
    var saturationMul: Float = 1.0

    /// Multiplied with the output value/brightness. 1 = pass-through.
    var brightnessMul: Float = 1.0

    /// Multiplied with the output before tone-mapping — drives bloom/glow
    /// across all viz uniformly. 1 = pass-through. >1 pushes into the
    /// fragment-stage ACES tone curve, producing more bloom.
    var glowMul: Float = 1.0

    /// Convenience: the audio-reactive toggle is just `audioReactivity > 0`.
    /// Toggle target writes 0 (off) or 1 (on); the slider can fine-tune.
    var audioReactiveOn: Bool {
        get { audioReactivity > 0.01 }
        set { audioReactivity = newValue ? 1.0 : 0.0 }
    }
}
