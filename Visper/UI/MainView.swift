import AVFoundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// メインウィンドウ（D18）。左にセッション一覧、右にタイムスタンプ付きの本文。
struct MainView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @State private var selection: UUID?
    @State private var query = ""

    // ponytail: 検索はメモリ上の総当たり。セッションが数千件になったら述語での検索にする。
    private var filtered: [Session] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedStandardContains(query)
                || session.segments.contains { $0.text.localizedStandardContains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .lineLimit(1)
                        .accessibilityIdentifier("sessionTitle")
                    HStack {
                        Text(session.startedAt.formatted(date: .numeric, time: .shortened))
                        if let hint = statusHint(session) {
                            Spacer()
                            Text(hint)
                                .foregroundStyle(session.status == .finalFailed ? .red : .orange)
                                .accessibilityIdentifier("sessionStatus")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "タイトルと本文を検索")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let session = sessions.first(where: { $0.id == selection }) {
                SessionDetail(session: session) {
                    // 消えたモデルを描画しないよう、先に選択を外す。
                    selection = nil
                    env.controller.delete(session)
                }
                .id(session.id)
            } else {
                ContentUnavailableView("セッションを選択してください", systemImage: "text.quote")
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if env.controller.lastError != nil {
                ErrorBanner(controller: env.controller)
                    .padding(10)
                    .background(.bar)
            }
        }
        .task {
            if AppEnvironment.isUITesting, CommandLine.arguments.contains("-lyricsWindow") {
                openWindow(id: "lyrics")
            }        }
    }

    private func statusHint(_ session: Session) -> String? {
        switch session.status {
        case .recording: "録音中"
        case .pendingFinal: env.controller.finalizingID == session.id ? "仕上げ中" : "仕上げ待ち"
        case .finalFailed: "仕上げ失敗"
        case .done: nil
        }
    }
}

private struct SessionDetail: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var session: Session
    let onDelete: () -> Void

    @State private var player = AVPlayer()
    @State private var confirmingDelete = false
    @State private var exporting = false
    @State private var exportDocument: MarkdownFile?

    private var hasAudio: Bool {
        session.status != .recording && FileManager.default.fileExists(atPath: session.audioURL.path)
    }

    private var isPlaying: Bool { player.timeControlStatus != .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("タイトル", text: $session.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .accessibilityIdentifier("titleField")
                Text("\(session.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "ja_JP"))))・\(formatTimestamp(session.duration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                notice
            }
            .padding()
            Divider()
            TranscriptList(sessionID: session.persistentModelID, play: play(from:))
        }
        .toolbar {
            Button(isPlaying ? "一時停止" : "再生", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                if isPlaying {
                    player.pause()
                } else {
                    if let item = player.currentItem, player.currentTime() >= item.duration {
                        player.seek(to: .zero)
                    }
                    player.play()
                }
            }
            .disabled(!hasAudio)
            .accessibilityIdentifier("playButton")
            Button("コピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sortedSegments.map(\.text).joined(separator: "\n"), forType: .string)
            }
            .help("本文をコピー")
            .accessibilityIdentifier("copyButton")
            Button("Markdown で書き出す", systemImage: "square.and.arrow.up") {
                exportDocument = MarkdownFile(text: session.markdown)
                exporting = true
            }
                .help("Markdown で書き出す")
                .accessibilityIdentifier("exportButton")
            Button("削除", systemImage: "trash") { confirmingDelete = true }
                .disabled(session.status == .recording)
                .help("セッションを削除")
                .accessibilityIdentifier("deleteButton")
        }
        .confirmationDialog("「\(session.title)」を削除しますか？", isPresented: $confirmingDelete) {
            Button("削除", role: .destructive, action: onDelete)
                .accessibilityIdentifier("confirmDelete")
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("本文と音声が削除されます。この操作は取り消せません。")
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: MarkdownFile.type,
            defaultFilename: session.title.replacing(/[\/:]/, with: "-")
        ) { result in
            if case .failure(let error) = result { env.controller.lastError = error.localizedDescription }
        }
        // 停止時に .caf から .m4a へ変わり、状態も変わる。どちらが変わっても読み込み直す。
        .task(id: [session.statusRaw, session.audioFileName]) {
            player.replaceCurrentItem(with: hasAudio ? AVPlayerItem(url: session.audioURL) : nil)
        }
        .onDisappear { player.pause() }
    }

    @ViewBuilder
    private var notice: some View {
        switch session.status {
        case .recording, .pendingFinal:
            Label("暫定の文字起こしです。仕上げが終わると置き換わります。", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("provisionalNotice")
        case .finalFailed:
            HStack {
                let audioExists = FileManager.default.fileExists(atPath: session.audioURL.path)
                Label(
                    audioExists ? "仕上げに失敗しました。本文は暫定版です。" : "仕上げに失敗しました。音声ファイルがないため再試行できません。",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if audioExists {
                    Button("再試行") { env.controller.retryFinal(session) }
                        .accessibilityIdentifier("retryButton")
                }
            }
        case .done:
            EmptyView()
        }
    }

    private func play(from start: TimeInterval) {
        guard hasAudio else { return }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

/// 本文の一覧。並べ替えはデータベースに任せ、行が変わったときだけ描き直す。
private struct TranscriptList: View {
    @Query private var segments: [Segment]
    let play: (TimeInterval) -> Void

    init(sessionID: PersistentIdentifier, play: @escaping (TimeInterval) -> Void) {
        _segments = Query(filter: #Predicate<Segment> { $0.session?.persistentModelID == sessionID }, sort: \.start)
        self.play = play
    }

    var body: some View {
        List(segments) { segment in
            Button {
                play(segment.start)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(formatTimestamp(segment.start))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(segment.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transcriptLine")
        }
    }
}

private struct MarkdownFile: FileDocument {
    static let type = UTType(filenameExtension: "md") ?? .plainText
    static let readableContentTypes = [type]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
