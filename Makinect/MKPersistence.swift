// MKPersistence — UserDefaults-backed JSON persistence for the redesigned
// Makinect shell. One Codable payload, two static methods, no service
// locator. Hydrated on app launch from ContentView.onAppear, flushed on
// a 5-second timer + NSApplication.willTerminateNotification.
//
// Schema version is encoded into the UserDefaults key. Bump the suffix
// (V1 → V2) when introducing breaking changes; old payloads are dropped.

import Foundation

// MARK: - Codable payloads

struct MKPersistedCommon: Codable, Equatable {
    var audioReactivity: Float
    var speedMul: Float
    var hueShift: Float
    var saturationMul: Float
    var brightnessMul: Float
    var glowMul: Float

    static let defaults = MKPersistedCommon(
        audioReactivity: 1.0,
        speedMul: 1.0,
        hueShift: 0,
        saturationMul: 1.0,
        brightnessMul: 1.0,
        glowMul: 1.0
    )
}

/// One named user snapshot — a viz + its common params + sparse per-viz
/// values captured by KinectManager.captureActiveVizParams().
struct MKSnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var visualization: String           // VisualizationKind.rawValue
    var common: MKPersistedCommon
    var perVizParams: [String: Double]  // sparse — see KinectManager extension
}

struct MKPersistedState: Codable {
    var lastTab: String
    var visualization: String?
    var source: String
    var nearMM: Float
    var farMM: Float
    var common: MKPersistedCommon
    var sceneBar: [String]              // 8 viz rawValues
    var snapshots: [MKSnapshot]
    var manualBPM: Float
    var didOnboard: Bool

    /// Default seed for a fresh install — Synthetic source with the first
    /// featured viz already running so the user sees pixels on launch.
    static let initial = MKPersistedState(
        lastTab: MKTab.performance.rawValue,
        visualization: VisualizationKind.volumetricAurora.rawValue,
        source: InputSource.synthetic.rawValue,
        nearMM: 500,
        farMM: 2000,
        common: .defaults,
        sceneBar: MKVizCategory.featuredKinds.map(\.rawValue),
        snapshots: [],
        manualBPM: 124.0,
        didOnboard: false
    )
}

// MARK: - Persistence facade

enum MKPersistence {
    static let key = "MakinectStateV1"

    static func load() -> MKPersistedState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MKPersistedState.self, from: data)
    }

    static func save(_ state: MKPersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Wipes the persisted state. Useful for "Reset Onboarding" debug menu
    /// items or testing first-run flow without rebuilding the bundle.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
