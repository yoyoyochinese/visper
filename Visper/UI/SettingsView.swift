import ServiceManagement
import SwiftUI

/// 設定は4項目だけ（D26）。
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(SettingsKey.glossary) private var glossary = ""
    @AppStorage(SettingsKey.unloadMinutes) private var unloadMinutes = Tuning.defaultUnloadMinutes
    @AppStorage(SettingsKey.micDeviceUID) private var micDeviceUID: String?
    @State private var devices: [AudioInputDevice] = []
    @State private var tokenCount = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("用語集") {
                TextEditor(text: $glossary)
                    .font(.body)
                    .frame(height: 120)
                    .accessibilityLabel("用語集")
                    .accessibilityIdentifier("glossaryEditor")
                Text("\(tokenCount) / \(Tuning.glossaryTokenLimit) トークン")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("glossaryCount")
                if tokenCount > Tuning.glossaryTokenLimit {
                    Label("上限を超えています。用語を減らしてください。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("glossaryWarning")
                }
            }
            Section {
                Stepper("モデルをアンロードするまで: \(unloadMinutes) 分", value: $unloadMinutes, in: 1...120)
                    .accessibilityIdentifier("unloadStepper")
                Toggle("ログイン時に起動", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    .accessibilityIdentifier("launchAtLoginToggle")
                if let launchError {
                    Text(launchError).foregroundStyle(.red)
                }
                Picker("マイク入力デバイス", selection: $micDeviceUID) {
                    Text("システムの既定").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    // 保存済みのデバイスが外れていても、選択が見えるようにする（既定には切り替えない）。
                    if let uid = micDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                        Text("\(uid)（未接続）").tag(String?.some(uid))
                    }
                }
                .accessibilityIdentifier("micDevicePicker")
                .onAppear { devices = env.audio.inputDevices() }
                // 設定ウィンドウを開き直したときにも一覧を取り直す。
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    devices = env.audio.inputDevices()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: glossary) {
            tokenCount = await env.transcriber.tokenCount(of: glossary)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
