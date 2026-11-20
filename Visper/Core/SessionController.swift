import AVFoundation
import Foundation
import Observation
import SwiftData

/// 録音の開始と停止、ライブ行の保持、最終パスの待ち行列、異常終了からの再開をまとめる。
@MainActor
@Observable
final class SessionController {
    private(set) var isRecording = false
    /// 停止ボタンが押されてから、音声の変換とライブ文字起こしの残りが終わるまで。
    private(set) var isStopping = false
    private(set) var startedAt: Date?
    private(set) var liveLines: [TranscribedSegment] = []
    private(set) var tentative = ""
    /// 最終パスを実行中のセッション。
    private(set) var finalizingID: UUID?
    var lastError: String?

    @ObservationIgnored var onFinalized: (Session) -> Void = { _ in }
    @ObservationIgnored private let audio: AudioCapturing
    @ObservationIgnored private let transcriber: Transcribing
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var current: Session?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// 待ち行列を1つずつ処理するループ。同時に1本だけ。
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// いま実行中の最終パス。中断するときはこれをキャンセルする。
    @ObservationIgnored private var finalizeTask: Task<Void, Never>?

    init(audio: AudioCapturing, transcriber: Transcribing, context: ModelContext, defaults: UserDefaults = .standard) {
        self.audio = audio
        self.transcriber = transcriber
        self.context = context
        self.defaults = defaults
    }

    func start(source: AudioSource, language: TranscriptLanguage) async {
        guard !isRecording else { return }
        isRecording = true
        // ponytail: 実行中の最終パスは中断し、録音後に最初からやり直す。途中再開が要るなら進捗を保存する。
        finalizeTask?.cancel()
        let session = Session(source: source, language: language)
        do {
            let stream = try await audio.start(
                source: source,
                micDeviceUID: defaults.string(forKey: SettingsKey.micDeviceUID),
                recordingTo: session.audioURL)
            // 権限ダイアログの待ち時間を録音時間に含めない。
            session.startedAt = .now
            context.insert(session)
            save()
            current = session
            startedAt = session.startedAt
            liveLines = []
            tentative = ""
            lastError = nil
            // 用語集は最終パスだけに使う（turbo では効果がなく、更新が遅くなったため）。
            let updates = transcriber.live(audio: stream, options: TranscriptionOptions(language: language, glossary: ""))
            liveTask = Task {
                do {
                    for try await update in updates {
                        self.liveLines += update.confirmed
                        self.tentative = update.tentative
                        // 異常終了してもライブ版の本文が残るよう、確定のたびに保存する。
                        session.append(update.confirmed)
                        self.save()
                    }
                } catch {
                    self.lastError = error.localizedDescription
                    // 録音は続ける。読み手のいないストリームに音声が溜まらないよう捨てる。
                    for await _ in stream {}
                }
                // 停止していないのに音声が終わった（デバイスが外れた、書き込みに失敗した）ときは自分で止める。
                if self.current === session, !self.isStopping {
                    Task { await self.stop() }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: session.audioURL)
            isRecording = false
            lastError = error.localizedDescription
            drainFinalQueue()
        }
    }

    func stop() async {
        guard isRecording, !isStopping, let session = current else { return }
        isStopping = true
        let duration = Date.now.timeIntervalSince(session.startedAt)
        var fileName = session.audioFileName
        var stopFailed = false
        do {
            fileName = try await audio.stop().lastPathComponent
        } catch {
            stopFailed = true
            lastError = error.localizedDescription
            // 失敗しても、そこまでの録音が変換済みならそれを使う。
            if let converted = Self.convertedFile(for: fileName) { fileName = converted }
        }
        await liveTask?.value
        if stopFailed, session.segments.isEmpty, fileName == session.audioFileName {
            // 音声も本文も得られなかった（開始直後の停止など）。失敗扱いのセッションを残さない。
            try? FileManager.default.removeItem(at: session.audioURL)
            context.delete(session)
        } else {
            // ファイル名と状態は同時に変える（画面が中間状態を見ないように）。
            session.audioFileName = fileName
            session.duration = duration
            session.status = .pendingFinal
        }
        save()
        current = nil
        startedAt = nil
        tentative = ""
        isRecording = false
        isStopping = false
        drainFinalQueue()
    }

    /// 起動時に1回呼ぶ。録音中のまま残ったセッションを救い、待ち行列を再開する。
    func recoverInterrupted() async {
        let recording = SessionStatus.recording.rawValue
        let stale = (try? context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.statusRaw == recording }))) ?? []
        for session in stale {
            // 変換は済んでいて状態の保存だけが間に合わなかった場合は、変換済みのファイルをそのまま使う。
            var fileName = Self.convertedFile(for: session.audioFileName)
            if fileName == nil {
                fileName = await audio.recover(recordingAt: session.audioURL)?.lastPathComponent
            }
            if let fileName {
                session.audioFileName = fileName
                session.duration = Self.audioDuration(session.audioURL) ?? session.segments.map(\.end).max() ?? 0
                session.status = .pendingFinal
            } else if session.segments.isEmpty {
                try? FileManager.default.removeItem(at: session.audioURL)
                context.delete(session)
            } else {
                session.status = .finalFailed
            }
        }
        save()
        drainFinalQueue()
    }

    func retryFinal(_ session: Session) {
        session.status = .pendingFinal
        save()
        drainFinalQueue()
    }

    func delete(_ session: Session) {
        guard session.id != current?.id else { return }
        if session.id == finalizingID { finalizeTask?.cancel() }
        try? FileManager.default.removeItem(at: session.audioURL)
        context.delete(session)
        save()
    }

    private func drainFinalQueue() {
        guard drainTask == nil else { return }
        drainTask = Task {
            while !isRecording, let session = nextPending() {
                let task = Task { await finalize(session) }
                finalizeTask = task
                await task.value
                finalizeTask = nil
            }
            drainTask = nil
        }
    }

    private func nextPending() -> Session? {
        let pending = SessionStatus.pendingFinal.rawValue
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.statusRaw == pending },
            sortBy: [SortDescriptor(\.startedAt)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func finalize(_ session: Session) async {
        finalizingID = session.id
        defer { finalizingID = nil }
        do {
            let segments = try await transcriber.finalPass(audioFile: session.audioURL, options: options(for: session))
            // 削除を保存した後は isDeleted が false に戻るので、modelContext で判定する。
            guard session.modelContext != nil else { return }
            for old in session.segments { context.delete(old) }
            session.append(segments)
            session.status = .done
            save()
            onFinalized(session)
        } catch {
            // 中断されたものは pendingFinal のまま残し、待ち行列がやり直す。
            guard !Task.isCancelled, session.modelContext != nil else { return }
            session.status = .finalFailed
            lastError = error.localizedDescription
            save()
        }
    }

    /// `name` が .m4a で存在するか、同名の .m4a が既にあればそのファイル名。
    private static func convertedFile(for name: String) -> String? {
        let m4a = (name as NSString).deletingPathExtension + ".m4a"
        return FileManager.default.fileExists(atPath: AudioStore.url(for: m4a).path) ? m4a : nil
    }

    private static func audioDuration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func options(for session: Session) -> TranscriptionOptions {
        TranscriptionOptions(language: session.language, glossary: defaults.string(forKey: SettingsKey.glossary) ?? "")
    }

    private func save() {
        do { try context.save() } catch { lastError = error.localizedDescription }
    }
}
