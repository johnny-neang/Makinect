// MKAppState — UI-side state for the redesigned shell. Tab routing, scene
// arming, tap-tempo, panic, and viz categorization for the Library.

import SwiftUI
import Observation

enum MKTab: String, CaseIterable, Identifiable {
    case library, galaxy, presets, midi, audio, performance, output, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .library:     return "Library"
        case .galaxy:      return "Galaxy"
        case .presets:     return "Presets"
        case .midi:        return "MIDI"
        case .audio:       return "Audio"
        case .performance: return "Performance"
        case .output:      return "Output"
        case .settings:    return "Settings"
        }
    }

    var num: String {
        guard let i = MKTab.allCases.firstIndex(of: self) else { return "" }
        return String(format: "%02d", i + 1)
    }
}

enum MKVizCategory: String, CaseIterable {
    case featured, particles, volumetric, surface, optical, skeletal, capstone

    var label: String {
        switch self {
        case .featured:   return "Featured"
        case .particles:  return "Particles"
        case .volumetric: return "Volumetric"
        case .surface:    return "Surface"
        case .optical:    return "Optical"
        case .skeletal:   return "Skeletal"
        case .capstone:   return "Capstone"
        }
    }

    /// Categorization of the 38 visualizers. Featured is curated.
    static func category(for kind: VisualizationKind) -> MKVizCategory {
        switch kind {
        case .particleStorm, .mercuryStorm, .parametricSwarm,
             .boidsMurmuration, .magneticIronFilings, .sandMandala,
             .mocapConstellation, .filamentCosmology, .strandVeil:
            return .particles

        case .nebula, .smokeGod, .volumetricAurora, .plasmaSea,
             .vortexRingSmoke, .mandelbulbAviary, .hyperbolicTunnel:
            return .volumetric

        case .glassOcean, .kineticWireframe, .liquidChromeBody,
             .iridescentPlumage, .cathedralOfBones, .memoryPalace,
             .origamiBody, .forestOfLight, .stainedCathedral,
             .velvetPetalField, .spectralOcean:
            return .surface

        case .stableFluids, .dissipativeCells, .opticalFlow,
             .liquidLightCalligraphy, .pixelStorm, .glitchMosaic,
             .impastoPainter, .laserBeams:
            return .optical

        case .bodyPaint, .bodyOfPetals, .voxelSculpt:
            return .skeletal

        case .pointCloud:
            return .capstone
        }
    }

    static let featuredKinds: [VisualizationKind] = [
        .laserBeams, .volumetricAurora, .smokeGod, .mandelbulbAviary,
        .plasmaSea, .glassOcean, .filamentCosmology, .kineticWireframe
    ]
}

@Observable
final class MKAppState {
    var tab: MKTab = .performance

    // Tap tempo
    private var taps: [Date] = []
    var manualBPM: Float = 124.0
    var hasManualBPM: Bool = false

    func tap() {
        let now = Date()
        taps.append(now)
        taps = taps.filter { now.timeIntervalSince($0) < 3.0 }
        guard taps.count >= 2 else { return }
        var deltas: [TimeInterval] = []
        for i in 1..<taps.count { deltas.append(taps[i].timeIntervalSince(taps[i - 1])) }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        if avg > 0.2, avg < 2.0 {
            manualBPM = Float(60.0 / avg)
            hasManualBPM = true
        }
    }

    // Scene arming — armed scene becomes live on next click commit.
    var armedKind: VisualizationKind?

    // Customizable scene bar — 8 quick-access viz. Persisted; defaults to
    // the curated Featured 8 instead of the first 8 enum cases.
    var sceneBar: [VisualizationKind] = MKVizCategory.featuredKinds

    // Beat-grid jog — the user can click a beat cell to re-anchor the
    // visual playhead. nowBeatIndex subtracts this from wall-clock phase.
    var beatPhaseOffset: TimeInterval = 0

    // Panic — multi-cycle flash. The phase int is driven by a Timer in
    // firePanic(); MKPerformanceView reads it to gate Color.black opacity.
    // Spec: 200 ms × 3 cycles ≈ 600 ms total.
    var panicPhase: Int = 0
    private var panicTimer: Timer?

    func firePanic() {
        panicTimer?.invalidate()
        var phase = 0
        // 6 toggles × 100 ms = 3 cycles in 600 ms
        panicTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            phase += 1
            self.panicPhase = (phase % 2 == 1) ? 1 : 0
            if phase >= 6 {
                t.invalidate()
                self.panicPhase = 0
            }
        }
    }

    /// Convenience: any-flash for the canvas. Performance still reads
    /// `panicPhase` (0/1) directly; this is a read-only mirror for views
    /// that just need a boolean.
    var isPanicking: Bool { panicPhase != 0 }

    // Onboarding gate
    var didOnboard: Bool = false

    // Saved snapshots — user-named looks. Owned by MKAppState so all
    // tabs see the same list without a separate model object.
    var snapshots: [MKSnapshot] = []

    // MARK: - Persistence bridge

    /// Hydrate from a persisted payload. Best-effort: missing or unknown
    /// VisualizationKind values silently revert to defaults.
    func hydrate(from p: MKPersistedState) {
        if let t = MKTab(rawValue: p.lastTab) { tab = t }
        manualBPM = p.manualBPM
        hasManualBPM = false       // tap evidence resets each session
        sceneBar = p.sceneBar.compactMap { VisualizationKind(rawValue: $0) }
        if sceneBar.count != 8 { sceneBar = MKVizCategory.featuredKinds }
        snapshots = p.snapshots
        didOnboard = p.didOnboard
    }

    /// Capture the parts of state we own into a fresh persisted payload,
    /// using `existing` as a starting point so we don't clobber fields
    /// owned by KinectManager (visualization, source, common, ranges).
    func mergeInto(_ existing: inout MKPersistedState) {
        existing.lastTab = tab.rawValue
        existing.manualBPM = manualBPM
        existing.sceneBar = sceneBar.map(\.rawValue)
        existing.snapshots = snapshots
        existing.didOnboard = didOnboard
    }
}
