import Foundation
import Observation

/// テスト用。音声は流さず、空の録音ファイルだけ作る。
final class FakeAudioCapture: AudioCapturing {
    var recoverable = true
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var url: URL?

    func inputDevices() -> [AudioInputDevice] { [AudioInputDevice(uid: "fake", name: "テスト用マイク")] }

    func start(source: AudioSource, micDeviceUID: String?, recordingTo url: URL) async throws -> AsyncStream<[Float]> {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        self.url = url
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async throws -> URL {
        continuation?.finish()
        return url!
    }

    /// デバイスが外れたときのように、停止を待たずにストリームを終える。
    func endStream() { continuation?.finish() }

    func recover(recordingAt url: URL) async -> URL? {
        recoverable && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// テスト用。台本どおりの行を一定間隔で流す。
@MainActor
@Observable
final class ScriptedTranscriber: Transcribing {
    var modelState: ModelState = .ready
    var liveScript: [String]
    var finalScript: [String]
    var lineInterval: TimeInterval
    var finalDelay: TimeInterval
    private(set) var finalCalls: [URL] = []

    init(liveScript: [String], finalScript: [String], lineInterval: TimeInterval = 0, finalDelay: TimeInterval = 0) {
        self.liveScript = liveScript
        self.finalScript = finalScript
        self.lineInterval = lineInterval
        self.finalDelay = finalDelay
    }

    func prepareModels() async {}

    func live(audio: AsyncStream<[Float]>, options: TranscriptionOptions) -> AsyncThrowingStream<LiveUpdate, Error> {
        let script = liveScript, interval = lineInterval
        return AsyncThrowingStream { continuation in
            let producer = Task {
                for (i, line) in script.enumerated() {
                    continuation.yield(LiveUpdate(confirmed: [], tentative: line))
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { return }
                    let start = Double(i) * max(interval, 1)
                    continuation.yield(LiveUpdate(
                        confirmed: [TranscribedSegment(start: start, end: start + max(interval, 1), text: line)],
                        tentative: ""))
                }
            }
            Task {
                for await _ in audio {}
                producer.cancel()
                await producer.value
                continuation.finish()
            }
        }
    }

    func finalPass(audioFile: URL, options: TranscriptionOptions) async throws -> [TranscribedSegment] {
        try await Task.sleep(for: .seconds(finalDelay))
        finalCalls.append(audioFile)
        return finalScript.enumerated().map { TranscribedSegment(start: Double($0) * 5, end: Double($0) * 5 + 5, text: $1) }
    }

    func tokenCount(of text: String) async -> Int { text.count }
}
