import AVFoundation
import SwiftData
import SwiftUI

@main
struct VisperApp: App {
    @State private var env = AppEnvironment()

    init() {
        // 再生状態（timeControlStatus）を SwiftUI から監視できるようにする。
        AVPlayer.isObservationEnabled = true
    }

    var body: some Scene {
        Window("Visper", id: "main") {
            MainView()
                .environment(env)
                .modelContainer(env.container)
        }
        MenuBarExtra {
            MenuBarContent()
                .environment(env)
        } label: {
            MenuBarLabel(controller: env.controller)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
                .environment(env)
        }
        // UI テスト専用（D31）。`-uiTesting -lyricsWindow` のときだけ MainView から開く。
        Window("ライブ", id: "lyrics") {
            MenuBarContent()
                .environment(env)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}
