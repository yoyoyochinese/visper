import AVFoundation
import SwiftData
import SwiftUI

@main
struct VisperApp: App {
    @State private var env = AppEnvironment()

    init() {
        // 再生状態（timeControlStatus）を SwiftUI から監視できるようにする。
        AVPlayer.isObservationEnabled = true
        if AppEnvironment.isUITesting { Self.keepWindowsOnMainDisplay() }
    }

    /// UI テスト専用。前回の位置を覚えていて別のディスプレイに出たウィンドウは XCUITest で撮影できないので、
    /// 主ディスプレイの中央へ戻す。
    private static func keepWindowsOnMainDisplay() {
        let names = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow, window.styleMask.contains(.titled),
                      let main = NSScreen.screens.first, window.screen != main else { return }
                let area = main.visibleFrame
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
            }
        }
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
