// ContentView — top-level shell for the redesigned Makinect UI.
// Title bar + nav toolbar + screen router driven by MKAppState.tab.
// State (manager + app) is owned by MakinectApp and passed in so the
// `.commands { … }` keyboard shortcuts can mutate the same instances.
//
// Persistence: hydrate once from MKPersistence.load() on appear, then
// flush on a 5-second cadence and on willTerminateNotification.

import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var manager: KinectManager
    @Bindable var app: MKAppState

    // Periodic save tick — drives a single JSONEncoder pass every 5 s
    // when *anything* in the persisted payload has changed since last
    // flush. Cheaper than .onChange on every observable property.
    @State private var lastFlushHash: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            MKTitleBar(title: titleBarText)
            MKToolbar(app: app)

            ZStack {
                switch app.tab {
                case .performance:
                    MKPerformanceView(manager: manager, app: app)
                case .library:
                    MKLibraryView(manager: manager)
                case .audio:
                    MKAudioScreen(manager: manager)
                case .settings:
                    MKSettingsScreen(manager: manager)
                case .galaxy:
                    MKGalaxyScreen(manager: manager)
                case .presets:
                    MKPresetsScreen()
                case .midi:
                    MKMidiScreen()
                case .output:
                    MKOutputScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MK.Color.bgWindow)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear { hydrateOnce() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            flushIfDirty()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)
        ) { _ in
            flushIfDirty(force: true)
        }
    }

    private var titleBarText: String {
        let prefix = "Makinect — \(app.tab.label)"
        if app.tab == .performance { return "\(prefix) · Show 1" }
        return prefix
    }

    // MARK: - Persistence lifecycle

    @State private var hydrated: Bool = false
    private func hydrateOnce() {
        guard !hydrated else { return }
        hydrated = true
        let payload = MKPersistence.load() ?? .initial
        manager.hydrate(from: payload)
        app.hydrate(from: payload)
        lastFlushHash = currentPayload(seed: payload).hashable
    }

    private func flushIfDirty(force: Bool = false) {
        let p = currentPayload(seed: MKPersistence.load() ?? .initial)
        let h = p.hashable
        guard force || h != lastFlushHash else { return }
        MKPersistence.save(p)
        lastFlushHash = h
    }

    private func currentPayload(seed: MKPersistedState) -> MKPersistedState {
        var p = seed
        manager.mergeInto(&p)
        app.mergeInto(&p)
        return p
    }
}

// MARK: - Hashing helper for change detection

private extension MKPersistedState {
    /// Cheap structural fingerprint used to skip writes when nothing
    /// material has changed. Hash is unstable across launches by design;
    /// only the diff-against-previous-tick matters.
    var hashable: Int {
        var h = Hasher()
        h.combine(lastTab)
        h.combine(visualization)
        h.combine(source)
        h.combine(nearMM)
        h.combine(farMM)
        h.combine(common.audioReactivity)
        h.combine(common.speedMul)
        h.combine(common.hueShift)
        h.combine(common.saturationMul)
        h.combine(common.brightnessMul)
        h.combine(common.glowMul)
        h.combine(sceneBar.joined(separator: ","))
        h.combine(snapshots.count)
        for s in snapshots {
            h.combine(s.id)
            h.combine(s.name)
            h.combine(s.visualization)
        }
        h.combine(manualBPM)
        h.combine(didOnboard)
        return h.finalize()
    }
}

#Preview {
    ContentView(manager: KinectManager(), app: MKAppState())
        .frame(width: 1280, height: 800)
}
