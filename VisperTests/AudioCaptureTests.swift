import AVFoundation
import XCTest
@testable import Visper

final class AudioCaptureTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 440 Hz の正弦波。`chunk` 秒ごとのバッファに分けて返す。
    func sine(_ format: AVAudioFormat, seconds: Double, amplitude: Float = 0.25, chunk: Double = 0.1) -> [AVAudioPCMBuffer] {
        let perChunk = Int(format.sampleRate * chunk)
        return (0..<Int(seconds / chunk)).map { c in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(perChunk))!
            buffer.frameLength = AVAudioFrameCount(perChunk)
            for ch in 0..<Int(format.channelCount) {
                for i in 0..<perChunk {
                    let t = Double(c * perChunk + i) / format.sampleRate
                    buffer.floatChannelData![ch][i] = amplitude * Float(sin(2 * .pi * 440 * t))
                }
            }
            return buffer
        }
    }

    func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    func testResamplesAndMixesTo16kMono() async throws {
        let capture = SystemAudioCapture()
        let stereo48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let mono44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let stream = try capture.begin(formats: [stereo48, mono44], recordingTo: directory.appending(path: "a.caf"))
        for (a, b) in zip(sine(stereo48, seconds: 2), sine(mono44, seconds: 2)) {
            capture.feed(a, input: 0)
            capture.feed(b, input: 1)
        }
        let m4a = try await capture.stop()

        var samples: [Float] = []
        for await chunk in stream { samples += chunk }
        // 変換器の遅延ぶんだけ末尾が欠ける。
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
        // 同位相で振幅 0.25 の2入力が足されて 0.5 前後になる。
        XCTAssertEqual(Double(samples[8_000...].max()!), 0.5, accuracy: 0.05)

        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertEqual(try duration(of: m4a), 2, accuracy: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "a.caf").path))
    }

    func testStalledInputDoesNotBlockTheOther() throws {
        let capture = SystemAudioCapture()
        let format = SystemAudioCapture.outputFormat
        let stream = try capture.begin(formats: [format, format], recordingTo: directory.appending(path: "b.caf"))
        for buffer in sine(format, seconds: 3) { capture.feed(buffer, input: 0) }
        _ = stream
        // 片方だけ 3 秒流すと、1 秒ぶんの待ちを残して 2 秒が書かれる。
        let copy = directory.appending(path: "b-copy.caf")
        try FileManager.default.copyItem(at: directory.appending(path: "b.caf"), to: copy)
        XCTAssertEqual(try duration(of: copy), 2, accuracy: 0.2)
    }

    func testRecoverConvertsUnclosedCAF() async throws {
        let capture = SystemAudioCapture()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let caf = directory.appending(path: "c.caf")
        _ = try capture.begin(formats: [format], recordingTo: caf)
        for buffer in sine(format, seconds: 3) { capture.feed(buffer, input: 0) }

        // 閉じる前のディスク上の状態を写し取る（SIGKILL された時点のファイルに相当）。
        let crashed = directory.appending(path: "crashed.caf")
        try FileManager.default.copyItem(at: caf, to: crashed)

        let recovered = await SystemAudioCapture().recover(recordingAt: crashed)
        let m4a = try XCTUnwrap(recovered)
        XCTAssertEqual(m4a.lastPathComponent, "crashed.m4a")
        XCTAssertEqual(try duration(of: m4a), 3, accuracy: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.path))
    }

    func testRecoverReturnsNilForMissingOrEmptyFile() async {
        let capture = SystemAudioCapture()
        let missing = await capture.recover(recordingAt: directory.appending(path: "none.caf"))
        XCTAssertNil(missing)

        let empty = directory.appending(path: "empty.caf")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let fromEmpty = await capture.recover(recordingAt: empty)
        XCTAssertNil(fromEmpty)
    }
}
