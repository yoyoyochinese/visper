import WhisperKit
import XCTest
@testable import Visper

/// 実モデルでの確認。モデルのダウンロード（約 4.7GB）が要るので、通常のテストでは走らせない。
/// `TEST_RUNNER_VISPER_MODEL_TESTS=1 xcodebuild ... test -only-testing:VisperTests/TranscriptionModelTests`
@MainActor
final class TranscriptionModelTests: XCTestCase {
    static let speech = "それでは今日のゼミを始めます。トランズモン量子ビットのデコヒーレンスについて話します。"
        + "T1は約100マイクロ秒、T2エコーはその半分程度でした。次に surface code の論理エラー率を見ていきます。"
        + "符号距離を3から5に上げるとエラー率が下がります。質問があればどうぞ。"
    static let questions = "次の質問です。この結果は再現できますか？はい、三回測って同じ値でした。ほかに質問はありますか？なければ終わります。"
    static let glossary = "今日のゼミではトランズモン量子ビットのデコヒーレンス、T1、T2エコー、surface code、符号距離について話します。"

    func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    func clip(_ name: String, _ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let aiff = directory.appending(path: "\(name).aiff"), m4a = directory.appending(path: "\(name).m4a")
        try run("/usr/bin/say", "-v", "Kyoko", "-o", aiff.path, text)
        try run("/usr/bin/afconvert", "-f", "m4af", "-d", "aac", aiff.path, m4a.path)
        return m4a
    }

    func log(_ message: String) { print("VISPER: \(message)") }

    func lines(_ segments: [TranscribedSegment]) -> String {
        segments.map { String(format: "[%.1f-%.1f] %@", $0.start, $0.end, $0.text) }.joined(separator: " / ")
    }

    /// `realTime` のときは実時間と同じ速さで 0.1 秒ずつ流す。
    func live(
        _ engine: WhisperEngine, _ samples: [Float], language: TranscriptLanguage = .ja, glossary: String, realTime: Bool
    ) async throws -> [TranscribedSegment] {
        let (stream, input) = AsyncStream<[Float]>.makeStream()
        let clock = ContinuousClock(), began = clock.now
        let feeder = Task {
            for start in stride(from: 0, to: samples.count, by: 1600) {
                input.yield(Array(samples[start..<min(start + 1600, samples.count)]))
                if realTime { try await Task.sleep(for: .milliseconds(100)) }
            }
            input.finish()
        }
        var confirmed: [TranscribedSegment] = []
        for try await update in engine.live(audio: stream, options: .init(language: language, glossary: glossary)) {
            confirmed += update.confirmed
            let wall = (clock.now - began) / .seconds(1)
            log(String(format: "live t=%.2f confirmed=[%@] tentative=%@", wall, lines(update.confirmed), update.tentative))
        }
        try await feeder.value
        log(String(format: "live done realTime=%@ glossary=%@ elapsed=%.2f", "\(realTime)", "\(!glossary.isEmpty)", (clock.now - began) / .seconds(1)))
        return confirmed
    }

    func testRealModels() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VISPER_MODEL_TESTS"] == "1")
        let m4a = try clip("visper-speech", Self.speech)
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: m4a.path)
        let questionSamples = try AudioProcessor.loadAudioAsFloatArray(fromPath: clip("visper-questions", Self.questions).path)
        let duration = Double(samples.count) / Tuning.sampleRate
        log(String(format: "audio %.1fs", duration))

        let engine = WhisperEngine()
        let clock = ContinuousClock()
        var began = clock.now
        await engine.prepareModels()
        XCTAssertEqual(engine.modelState, .ready)
        log("prepareModels \(clock.now - began)")

        let tokens = await engine.tokenCount(of: Self.glossary)
        log("glossary tokens \(tokens)")
        XCTAssertGreaterThan(tokens, 5)
        XCTAssertLessThan(tokens, Self.glossary.count * 2)

        // ライブ: 1回目はモデルの読み込みを含む。
        _ = try await live(engine, samples, glossary: "", realTime: false)
        let plain = try await live(engine, samples, glossary: "", realTime: false)
        let realTime = try await live(engine, samples, glossary: Self.glossary, realTime: true)
        let auto = try await live(engine, samples, language: .auto, glossary: "", realTime: false)
        for (name, result) in [("plain", plain), ("realTime", realTime), ("auto", auto)] {
            log("live \(name): \(lines(result))")
            let text = result.map(\.text).joined()
            XCTAssertTrue(text.contains("ゼミ"), name)
            XCTAssertFalse(text.contains("<|"), name)
            XCTAssertGreaterThan(result.count, 2, "用語集があっても文ごとに確定する: \(name)")
            XCTAssertEqual(result.map(\.start), result.map(\.start).sorted(), name)
            XCTAssertLessThanOrEqual(result.last?.end ?? .infinity, duration + 1, name)
            XCTAssertTrue(text.contains("どうぞ"), "末尾が欠けない: \(name)")
        }
        // 「？」で終わる文でも、用語集つきで文ごとに確定する。
        let questions = try await live(engine, questionSamples, glossary: Self.glossary, realTime: false)
        log("live questions: \(lines(questions))")
        XCTAssertGreaterThanOrEqual(questions.count, 4)
        XCTAssertTrue(questions.last?.text.contains("終わ") == true)

        // 最終パス: 1回目はモデルの読み込みを含む。
        for glossary in ["", Self.glossary] {
            began = clock.now
            let result = try await engine.finalPass(audioFile: m4a, options: .init(language: .ja, glossary: glossary))
            let elapsed = (clock.now - began) / .seconds(1)
            log(String(format: "final glossary=%@ elapsed=%.2f rtf=%.3f: %@", "\(!glossary.isEmpty)", elapsed, elapsed / duration, lines(result)))
            let text = result.map(\.text).joined()
            XCTAssertTrue(text.contains("ゼミ"))
            XCTAssertFalse(text.contains("<|"))
        }

        // キャンセル
        let task = Task { try await engine.finalPass(audioFile: m4a, options: .init(language: .ja, glossary: "")) }
        try await Task.sleep(for: .seconds(1))
        began = clock.now
        task.cancel()
        let outcome = await task.result
        log("cancel responded in \(clock.now - began)")
        XCTAssertThrowsError(try outcome.get())
        XCTAssertLessThan((clock.now - began) / .seconds(1), 2)
    }
}
