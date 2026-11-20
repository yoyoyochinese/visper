import XCTest
@testable import Visper

@MainActor
final class TranscriptionTests: XCTestCase {
    var loads = 0
    var unloads = 0

    func holder(delay: Duration) -> ModelHolder<Int> {
        ModelHolder(load: { self.loads += 1; return self.loads }, unload: { _ in self.unloads += 1 }, delay: { delay })
    }

    // MARK: アンロードのタイマー

    func testUnloadsAfterDelayAndReloadsOnNextUse() async throws {
        let holder = holder(delay: .milliseconds(100))
        try await holder.use { _ in }
        XCTAssertEqual(unloads, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unloads, 1)
        let model = try await holder.use { $0 }
        XCTAssertEqual(model, 2, "解放後の利用で読み直す")
    }

    func testActivityBeforeDelayPostponesUnload() async throws {
        let holder = holder(delay: .milliseconds(300))
        try await holder.use { _ in }
        try await Task.sleep(for: .milliseconds(200))
        try await holder.use { _ in }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(unloads, 0, "2回目の利用の終了から数え直す")
        XCTAssertEqual(loads, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unloads, 1)
    }

    func testNeverUnloadsWhileInUse() async throws {
        let holder = holder(delay: .milliseconds(50))
        try await holder.use { _ in }
        try await holder.use { _ in
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(self.unloads, 0)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(unloads, 1)
    }

    // MARK: ライブの確定判定

    let segments = [
        TranscribedSegment(start: 0, end: 3, text: "一"),
        TranscribedSegment(start: 3, end: 5.5, text: "二"),
        TranscribedSegment(start: 5.5, end: 8, text: "三"),
    ]

    func testSplitKeepsLastSegmentTentative() {
        let split = WhisperEngine.split(segments, bufferSeconds: 8, flush: false)
        XCTAssertEqual(split.confirmed, Array(segments.prefix(2)))
        XCTAssertEqual(split.tentative, "三")
        XCTAssertEqual(split.consumed, 5.5)
    }

    func testSplitWithSingleSegmentConfirmsNothing() {
        let split = WhisperEngine.split([segments[0]], bufferSeconds: 4, flush: false)
        XCTAssertEqual(split.confirmed, [])
        XCTAssertEqual(split.tentative, "一")
        XCTAssertEqual(split.consumed, 0)
    }

    func testSplitFlushConfirmsEverything() {
        let split = WhisperEngine.split(segments, bufferSeconds: 9, flush: true)
        XCTAssertEqual(split.confirmed, segments)
        XCTAssertEqual(split.tentative, "")
        XCTAssertEqual(split.consumed, 9)
    }

    func testSplitWithNoSpeech() {
        XCTAssertEqual(WhisperEngine.split([], bufferSeconds: 6, flush: false).consumed, 0)
        XCTAssertEqual(WhisperEngine.split([], bufferSeconds: 26, flush: true).consumed, 26)
    }
}
