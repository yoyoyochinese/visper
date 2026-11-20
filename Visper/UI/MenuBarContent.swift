import SwiftUI

/// メニューバーのポップオーバーの中身（D14）。操作欄と歌詞風ビュー。
struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.lastSource) private var source = AudioSource.mic
    @AppStorage(SettingsKey.lastLanguage) private var language = TranscriptLanguage.ja

    var body: some View {
        let controller = env.controller
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("音声ソース", selection: $source) {
                        ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("sourcePicker")
                    Picker("言語", selection: $language) {
                        ForEach(TranscriptLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("languagePicker")
                    Spacer()
                    Button(controller.isRecording ? "停止" : "開始") {
                        Task {
                            if controller.isRecording {
                                await controller.stop()
                            } else {
                                await controller.start(source: source, language: language)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRecording ? .red : .accentColor)
                    .disabled(!controller.isRecording && env.transcriber.modelState != .ready)
                    .accessibilityIdentifier("startStopButton")
                }
                .labelsHidden()
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if controller.isRecording {
                        Image(systemName: "circle.fill").foregroundStyle(.red).imageScale(.small)
                        Text("録音中").accessibilityIdentifier("recordingState")
                        if let startedAt = controller.startedAt {
                            Text(startedAt, style: .timer).monospacedDigit()
                        }
                    } else {
                        Text("待機中").accessibilityIdentifier("recordingState")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                modelStatus
                if let error = controller.lastError {
                    HStack(alignment: .firstTextBaseline) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("lastError")
                        Spacer()
                        Button("閉じる", systemImage: "xmark") { controller.lastError = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
            }
            .padding()

            Divider()
            if controller.liveLines.isEmpty && controller.tentative.isEmpty {
                Text("開始を押すと、ここに文字起こしが流れます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LyricsView(lines: controller.liveLines.map(\.text), tentative: controller.tentative)
            }
            Divider()

            Button("メインウィンドウを開く", systemImage: "macwindow") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.borderless)
            .padding(10)
            .accessibilityIdentifier("openMainWindow")
        }
        .frame(width: 400, height: 520)
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch env.transcriber.modelState {
        case .ready:
            EmptyView()
        case .notReady:
            ProgressView("モデルを準備中…").controlSize(.small)
        case .downloading(let progress):
            ProgressView("モデルをダウンロード中 \(Int(progress * 100))%", value: progress)
                .accessibilityIdentifier("modelProgress")
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                Label("モデルを準備できませんでした: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("再試行") { Task { await env.transcriber.prepareModels() } }
            }
            .font(.callout)
        }
    }
}

/// メニューバーのアイコン。録音中は赤くして経過時間を出す（D15）。
struct MenuBarLabel: View {
    let controller: SessionController

    // メニューバーはテンプレート画像を単色にしてしまうので、色を固定した画像を使う。
    private static let recordingIcon: NSImage = {
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "録音中")!
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))!
        image.isTemplate = false
        return image
    }()

    @State private var now = Date.now

    var body: some View {
        if controller.isRecording, let startedAt = controller.startedAt {
            // Text(_:style: .timer) や TimelineView はメニューバーでは再描画が止まらなくなるので、
            // 1秒ごとに文字列を作り直す。
            HStack(spacing: 4) {
                Image(nsImage: Self.recordingIcon)
                Text(formatTimestamp(max(0, now.timeIntervalSince(startedAt)))).monospacedDigit()
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        } else {
            Image(systemName: "waveform")
        }
    }
}
