import Foundation
import Observation
import SwiftData

/// 録音の開始と停止、ライブ行の保持、最終パスの待ち行列、異常終了からの再開をまとめる。
@MainActor
@Observable
final class SessionController {
    private(set) var isRecording = false
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
    @ObservationIgnored private var finalTask: Task<Void, Never>?

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
        finalTask?.cancel()
        let session = Session(source: source, language: language)
        do {
            let stream = try await audio.start(
                source: source,
                micDeviceUID: defaults.string(forKey: SettingsKey.micDeviceUID),
                recordingTo: session.audioURL)
            context.insert(session)
            save()
            current = session
            startedAt = session.startedAt
            liveLines = []
            tentative = ""
            let updates = transcriber.live(audio: stream, options: options(for: session))
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
                }
            }
        } catch {
            isRecording = false
            lastError = error.localizedDescription
            drainFinalQueue()
        }
    }

    func stop() async {
        guard isRecording, let session = current else { return }
        current = nil
        session.duration = Date.now.timeIntervalSince(session.startedAt)
        do {
            session.audioFileName = try await audio.stop().lastPathComponent
        } catch {
            lastError = error.localizedDescription
        }
        await liveTask?.value
        session.status = .pendingFinal
        save()
        startedAt = nil
        tentative = ""
        isRecording = false
        drainFinalQueue()
    }

    /// 起動時に1回呼ぶ。録音中のまま残ったセッションを救い、待ち行列を再開する。
    func recoverInterrupted() async {
        let recording = SessionStatus.recording.rawValue
        let stale = (try? context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.statusRaw == recording }))) ?? []
        for session in stale {
            if let url = await audio.recover(recordingAt: session.audioURL) {
                session.audioFileName = url.lastPathComponent
                session.duration = session.segments.map(\.end).max() ?? 0
                session.status = .pendingFinal
            } else if session.segments.isEmpty {
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
        if session.id == finalizingID { finalTask?.cancel() }
        try? FileManager.default.removeItem(at: session.audioURL)
        context.delete(session)
        save()
        drainFinalQueue()
    }

    private func drainFinalQueue() {
        let previous = finalTask
        finalTask = Task {
            await previous?.value
            while !isRecording, !Task.isCancelled, let session = nextPending() {
                await finalize(session)
            }
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
            guard !session.isDeleted else { return }
            for old in session.segments { context.delete(old) }
            session.segments = []
            session.append(segments)
            session.status = .done
            save()
            onFinalized(session)
        } catch {
            // 中断されたものは pendingFinal のまま残し、次の drain でやり直す。
            guard !Task.isCancelled, !session.isDeleted else { return }
            session.status = .finalFailed
            lastError = error.localizedDescription
            save()
        }
    }

    private func options(for session: Session) -> TranscriptionOptions {
        TranscriptionOptions(language: session.language, glossary: defaults.string(forKey: SettingsKey.glossary) ?? "")
    }

    private func save() {
        do { try context.save() } catch { lastError = error.localizedDescription }
    }
}
