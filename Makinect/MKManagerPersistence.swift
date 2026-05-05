// MKManagerPersistence — KinectManager extensions that bridge between
// the in-memory state graph and the Codable MKPersistedState. Lives in
// its own file so the Phase A/B/C engine code in KinectManager.swift
// stays untouched.
//
// Sparse per-viz capture: we don't conform 38 Config classes to Codable.
// Instead each viz contributes a small dictionary of meaningful keys.
// Unmapped viz get an empty dict — restoring leaves their config alone,
// the universal common params still come back. This keeps the snapshot
// schema stable as more viz get param coverage in future passes.

import Foundation

extension KinectManager {

    // MARK: - Hydration / save

    func hydrate(from p: MKPersistedState) {
        // Source first — flipping triggers connect/disconnect side-effects.
        if let s = InputSource(rawValue: p.source) { source = s }
        segmentationNearMM = p.nearMM
        segmentationFarMM  = p.farMM
        common.audioReactivity = p.common.audioReactivity
        common.speedMul        = p.common.speedMul
        common.hueShift        = p.common.hueShift
        common.saturationMul   = p.common.saturationMul
        common.brightnessMul   = p.common.brightnessMul
        common.glowMul         = p.common.glowMul
        if let v = p.visualization, let kind = VisualizationKind(rawValue: v) {
            visualization = kind
        }
    }

    func snapshotCommon() -> MKPersistedCommon {
        MKPersistedCommon(
            audioReactivity: common.audioReactivity,
            speedMul: common.speedMul,
            hueShift: common.hueShift,
            saturationMul: common.saturationMul,
            brightnessMul: common.brightnessMul,
            glowMul: common.glowMul
        )
    }

    func mergeInto(_ existing: inout MKPersistedState) {
        existing.visualization = visualization?.rawValue
        existing.source = source.rawValue
        existing.nearMM = segmentationNearMM
        existing.farMM  = segmentationFarMM
        existing.common = snapshotCommon()
    }

    // MARK: - Per-viz sparse capture (Tier 2.3)

    /// Capture a small set of meaningful per-viz parameters for the active
    /// visualization. Empty dictionary for viz that haven't been wired yet
    /// — common params alone still cover most "save my look" needs.
    func captureActiveVizParams() -> [String: Double] {
        guard let viz = visualization else { return [:] }
        switch viz {
        case .volumetricAurora:
            return [
                "fallSpeed":     Double(volumetricAurora.fallSpeed),
                "curtainFreq":   Double(volumetricAurora.curtainFreq),
                "dropMagnitude": Double(volumetricAurora.dropMagnitude),
                "starDensity":   Double(volumetricAurora.starDensity),
                "hueA":          Double(volumetricAurora.hueA),
                "hueB":          Double(volumetricAurora.hueB)
            ]
        case .smokeGod:
            return [
                "densityScale":     Double(smokeGod.densityScale),
                "densityThreshold": Double(smokeGod.densityThreshold),
                "litHue":           Double(smokeGod.litHue),
                "shadowHue":        Double(smokeGod.shadowHue),
                "saturation":       Double(smokeGod.saturation),
                "emberStrength":    Double(smokeGod.emberStrength),
                "audioCoupling":    Double(smokeGod.audioCoupling)
            ]
        case .mandelbulbAviary:
            return [
                "fractalPower":   Double(mandelbulbAviary.fractalPower),
                "powerAudioMod":  Double(mandelbulbAviary.powerAudioMod),
                "fractalHue":     Double(mandelbulbAviary.fractalHue),
                "camOrbitSpeed":  Double(mandelbulbAviary.camOrbitSpeed),
                "birdSize":       Double(mandelbulbAviary.birdSize),
                "birdBodyAttract":Double(mandelbulbAviary.birdBodyAttract),
                "birdHue":        Double(mandelbulbAviary.birdHue)
            ]
        default:
            return [:]
        }
    }

    /// Restore previously captured per-viz parameters. Missing keys are
    /// silently ignored — this is intentional so snapshots from older
    /// builds keep working as the schema grows.
    func applyActiveVizParams(_ p: [String: Double]) {
        guard let viz = visualization else { return }
        switch viz {
        case .volumetricAurora:
            if let v = p["fallSpeed"]     { volumetricAurora.fallSpeed     = Float(v) }
            if let v = p["curtainFreq"]   { volumetricAurora.curtainFreq   = Float(v) }
            if let v = p["dropMagnitude"] { volumetricAurora.dropMagnitude = Float(v) }
            if let v = p["starDensity"]   { volumetricAurora.starDensity   = Float(v) }
            if let v = p["hueA"]          { volumetricAurora.hueA          = Float(v) }
            if let v = p["hueB"]          { volumetricAurora.hueB          = Float(v) }
        case .smokeGod:
            if let v = p["densityScale"]     { smokeGod.densityScale     = Float(v) }
            if let v = p["densityThreshold"] { smokeGod.densityThreshold = Float(v) }
            if let v = p["litHue"]           { smokeGod.litHue           = Float(v) }
            if let v = p["shadowHue"]        { smokeGod.shadowHue        = Float(v) }
            if let v = p["saturation"]       { smokeGod.saturation       = Float(v) }
            if let v = p["emberStrength"]    { smokeGod.emberStrength    = Float(v) }
            if let v = p["audioCoupling"]    { smokeGod.audioCoupling    = Float(v) }
        case .mandelbulbAviary:
            if let v = p["fractalPower"]    { mandelbulbAviary.fractalPower    = Float(v) }
            if let v = p["powerAudioMod"]   { mandelbulbAviary.powerAudioMod   = Float(v) }
            if let v = p["fractalHue"]      { mandelbulbAviary.fractalHue      = Float(v) }
            if let v = p["camOrbitSpeed"]   { mandelbulbAviary.camOrbitSpeed   = Float(v) }
            if let v = p["birdSize"]        { mandelbulbAviary.birdSize        = Float(v) }
            if let v = p["birdBodyAttract"] { mandelbulbAviary.birdBodyAttract = Float(v) }
            if let v = p["birdHue"]         { mandelbulbAviary.birdHue         = Float(v) }
        default: break
        }
    }
}
