import AVFoundation
import WhisperKit
import XCTest
@testable import Visper

/// システム音声のように無音（0 の連続）を挟んだ録音で、最終パスが実在しない文を出さないこと。
/// 実モデルが要るので `TEST_RUNNER_VISPER_MODEL_TESTS=1` のときだけ走る。
@MainActor
final class TranscriptionSilenceTests: XCTestCase {
    func testFinalPassWithSilence() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VISPER_MODEL_TESTS"] == "1")
        let helper = TranscriptionModelTests()
        let a = try AudioProcessor.loadAudioAsFloatArray(fromPath: helper.clip("repro-a", TranscriptionModelTests.speech).path)
        let b = try AudioProcessor.loadAudioAsFloatArray(fromPath: helper.clip("repro-b", TranscriptionModelTests.questions).path)
        let silence = { (s: Double) in [Float](repeating: 0, count: Int(s * 16_000)) }
        let samples = silence(12) + a + silence(40) + b + silence(15)
        let directory = FileManager.default.temporaryDirectory
        let caf = directory.appending(path: "repro.caf"), m4a = directory.appending(path: "repro.m4a")
        try? FileManager.default.removeItem(at: caf)
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: caf, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        try helper.run("/usr/bin/afconvert", "-f", "m4af", "-d", "aac", caf.path, m4a.path)
        print("VISPER: repro audio \(Double(samples.count) / 16_000)s; speech A at 12.0-\(12 + Double(a.count) / 16_000), B at \(52 + Double(a.count) / 16_000)-")

        let engine = WhisperEngine()
        await engine.prepareModels()
        XCTAssertEqual(engine.modelState, .ready)
        let duration = Double(samples.count) / 16_000
        for glossary in ["", TranscriptionModelTests.glossary] {
            let began = ContinuousClock.now
            let result = try await engine.finalPass(audioFile: m4a, options: .init(language: .ja, glossary: glossary))
            print("VISPER: final glossary=\(!glossary.isEmpty) elapsed=\(ContinuousClock.now - began): \(helper.lines(result))")
            let text = result.map(\.text).joined()
            XCTAssertFalse(text.contains("ご視聴"), "無音での幻聴")
            XCTAssertFalse(text.contains("ありがとうございました"), "無音での幻聴")
            XCTAssertTrue(text.contains("ゼミ") && text.contains("終わ"), "無音の前後の発話は残る")
            XCTAssertTrue(result.allSatisfy { $0.end <= duration }, "時刻が録音の長さを超えない")
            XCTAssertTrue(result.allSatisfy { $0.end < 35.5 || $0.start > 73 }, "無音の区間に行がない")
        }
        let live = try await helper.live(engine, samples, glossary: "", realTime: false)
        print("VISPER: live: \(helper.lines(live))")
    }
}
