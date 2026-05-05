// MakinectApp — top-level scene + state ownership.
//
// State (KinectManager + MKAppState) is hoisted up to the App so that
// `.commands { … }` keyboard shortcuts can route to `app.tab` without
// tunneling Bindings through the View hierarchy. ContentView still owns
// the visual shell.

import SwiftUI
import AppKit

@main
struct MakinectApp: App {
    @State private var manager = KinectManager()
    @State private var app     = MKAppState()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager, app: app)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .toolbar) {
                navCommands
            }
        }
    }

    @ViewBuilder
    private var navCommands: some View {
        // Top-of-list shortcuts: ⌘P / ⌘L / ⌘G / ⌘, mirror the spec's
        // "go to that tab" hotkeys regardless of focus.
        Button("Performance") { app.tab = .performance }
            .keyboardShortcut("p", modifiers: .command)
        Button("Library") { app.tab = .library }
            .keyboardShortcut("l", modifiers: .command)
        Button("Galaxy") { app.tab = .galaxy }
            .keyboardShortcut("g", modifiers: .command)

        Divider()

        // ⌘1 … ⌘8 walk the tab order. Hidden labels keep the menu tidy.
        ForEach(Array(MKTab.allCases.enumerated()), id: \.element) { idx, tab in
            Button(tab.label) { app.tab = tab }
                .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))),
                                  modifiers: .command)
        }
    }
}
