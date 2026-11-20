import SwiftData
import SwiftUI

@main
struct VisperApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        Window("Visper", id: "main") {
            Text("Visper")
                .frame(minWidth: 600, minHeight: 400)
                .environment(env)
                .modelContainer(env.container)
        }
        MenuBarExtra("Visper", systemImage: "waveform") {
            Text("Visper")
                .padding()
                .environment(env)
        }
        .menuBarExtraStyle(.window)
    }
}
