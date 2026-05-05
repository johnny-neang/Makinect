// ContentView — top-level shell for the redesigned Makinect UI.
// Title bar + nav toolbar + screen router driven by MKAppState.tab.
// Each tab is a fully realized screen (Performance, Library, Audio,
// Settings) or a stub for the upcoming roadmap (Galaxy, Presets, MIDI,
// Output). Visual design ported from the Claude Design handoff bundle.

import SwiftUI

struct ContentView: View {
    @State private var manager = KinectManager()
    @State private var app = MKAppState()

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
                    MKStubScreen.galaxy()
                case .presets:
                    MKStubScreen.presets()
                case .midi:
                    MKStubScreen.midi()
                case .output:
                    MKStubScreen.output()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MK.Color.bgWindow)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 720)
    }

    private var titleBarText: String {
        let prefix = "Makinect — \(app.tab.label)"
        if app.tab == .performance { return "\(prefix) · Show 1" }
        return prefix
    }
}

#Preview {
    ContentView()
        .frame(width: 1280, height: 800)
}
