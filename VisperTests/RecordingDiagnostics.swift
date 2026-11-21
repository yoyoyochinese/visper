import AVFoundation
import WhisperKit
import XCTest
@testable import Visper

/// 実データの調査用（読み取り専用）。テストホストはアプリと同じコンテナで動くので、保存済みの録音を調べられる。
/// `TEST_RUNNER_VISPER_DIAG=1 xcodebuild test -only-testing:VisperTests/RecordingDiagnostics`
final class RecordingDiagnostics: XCTestCase {
    /// 実際のシステム音声を8秒取り込み、長さ・途中の無音・周波数を出す。実行中に別プロセスで 1 kHz の音を鳴らしておく
    /// （例: `afplay tone.wav`）。サンプルレートを取り違えると、周波数がずれて周期的な無音が入る。
    func testCaptureSystemTone() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VISPER_DIAG"] == "1")
        let capture = SystemAudioCapture()
        let url = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString).caf")
        let stream = try await capture.start(source: .system, micDeviceUID: nil, recordingTo: url)
        let collector = Task { () -> [Float] in
            var all: [Float] = []
            for await chunk in stream { all += chunk }
            return all
        }
        try await Task.sleep(for: .seconds(8))
        try? FileManager.default.removeItem(at: try await capture.stop())
        let x = await collector.value
        guard let first = x.firstIndex(where: { $0 != 0 }), let last = x.lastIndex(where: { $0 != 0 }) else {
            return XCTFail("音が取れていない（1 kHz の音を鳴らしながら実行する）")
        }
        var gaps = 0, run = 0, crossings = 0, voiced = 0
        for i in first + 1...last {
            if x[i] == 0 { run += 1; continue }
            if run >= 32 { gaps += 1 }
            run = 0
            voiced += 1
            if (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        }
        let hz = Double(crossings) / 2 / (Double(voiced) / Tuning.sampleRate)
        print(String(format: "DIAG capture %.2fs sound %.2fs gaps %d freq %.0f Hz", Double(x.count) / 16000, Double(voiced) / 16000, gaps, hz))
        XCTAssertEqual(gaps, 0, "音の途中に無音が入っている")
        XCTAssertEqual(hz, 1000, accuracy: 20, "1 kHz の音の周波数がずれている")
    }

    /// 保存済みの録音ごとに、音の途中にある短い無音（2〜300 ms）の数と位置を出す。
    func testShortGapsInRecordings() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VISPER_DIAG"] == "1")
        let files = try FileManager.default.contentsOfDirectory(at: AudioStore.directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let x = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            var gaps: [(at: Int, length: Int)] = []
            var run = 0
            for (i, v) in x.enumerated() {
                if abs(v) < 3e-4 { run += 1; continue }
                if run >= 32, run <= 4800, i - run > 0 { gaps.append((i - run, run)) }
                run = 0
            }
            let ms = { (n: Int) in Double(n) / 16.0 }
            let buckets = [2.0, 5, 10, 20, 50, 100, 300].map { lo in gaps.filter { ms($0.length) >= lo }.count }
            print(String(format: "DIAG %@ %@ %.1fs gaps>=2/5/10/20/50/100/300ms: %@",
                         url.lastPathComponent, date.formatted(date: .numeric, time: .shortened), Double(x.count) / 16000, "\(buckets)"))
            print("DIAG   first: " + gaps.prefix(40).map { String(format: "%.2fs/%.0fms", Double($0.at) / 16000, ms($0.length)) }.joined(separator: " "))
        }
    }
}
