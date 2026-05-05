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
             .impastoPainter:
            return .optical

        case .bodyPaint, .bodyOfPetals, .voxelSculpt:
            return .skeletal

        case .pointCloud:
            return .capstone
        }
    }

    static let featuredKinds: [VisualizationKind] = [
        .volumetricAurora, .smokeGod, .mandelbulbAviary, .plasmaSea,
        .glassOcean, .filamentCosmology, .kineticWireframe, .nebula
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

    // Scene arming — armed scene becomes live on next downbeat (or click).
    var armedKind: VisualizationKind?

    // Panic — flash to black for ~600ms.
    var isPanicking: Bool = false
    func firePanic() {
        isPanicking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.isPanicking = false
        }
    }
}
