import CoreML
import WhisperKit
import XCTest
@testable import Visper

@MainActor
final class TranscriptionTests: XCTestCase {
    var loads = 0
    var unloads = 0

    func holder(delay: Duration, loadTime: Duration = .zero) -> ModelHolder<Int> {
        ModelHolder(
            load: {
                try? await Task.sleep(for: loadTime)
                self.loads += 1
                return self.loads
            },
            unload: { _ in self.unloads += 1 },
            delay: { delay })
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

    func testCancelDuringLoadSkipsBodyAndStillUnloads() async throws {
        let holder = holder(delay: .milliseconds(100), loadTime: .seconds(5))
        var bodyRan = false
        let task = Task { try await holder.use { _ in bodyRan = true } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(bodyRan)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unloads, 1, "利用数が戻り、読み込んだモデルはタイマーで解放される")
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

    func testSplitFlushConfirmsEverythingUpToLastSegmentEnd() {
        let split = WhisperEngine.split(segments, bufferSeconds: 9, flush: true)
        XCTAssertEqual(split.confirmed, segments)
        XCTAssertEqual(split.tentative, "")
        XCTAssertEqual(split.consumed, 8, "最後の区間より後ろの音声は残す")
    }

    func testSplitWithNoSpeech() {
        XCTAssertEqual(WhisperEngine.split([], bufferSeconds: 6, flush: false).consumed, 0)
        XCTAssertEqual(WhisperEngine.split([], bufferSeconds: 26, flush: true).consumed, 26)
    }

    // MARK: ライブの本体（偽の認識結果を流す）

    func speech(_ seconds: Double) -> [Float] { [Float](repeating: 0.1, count: Int(seconds * Tuning.sampleRate)) }
    func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Tuning.sampleRate)) }
    func segment(_ start: Double, _ end: Double, _ text: String) -> TranscribedSegment {
        TranscribedSegment(start: start, end: end, text: text)
    }

    /// `chunks` を順に流して終了する。`transcribe` には何回目の呼び出しかとバッファの秒数を渡す。
    func runLive(
        _ chunks: [[Float]], transcribe: @escaping @MainActor (_ call: Int, _ seconds: Double) -> [TranscribedSegment]
    ) async throws -> [LiveUpdate] {
        let (stream, input) = AsyncStream<[Float]>.makeStream()
        chunks.forEach { input.yield($0) }
        input.finish()
        var updates: [LiveUpdate] = [], call = 0
        try await WhisperEngine.runLive(
            audio: stream,
            transcribe: { buffer in
                call += 1
                XCTAssertTrue(buffer.contains { $0 != 0 }, "無音だけのバッファは認識にかけない")
                return transcribe(call, Double(buffer.count) / Tuning.sampleRate)
            },
            yield: { updates.append($0) })
        return updates
    }

    func testEndOfStreamConfirmsTentativeWhenRemainderYieldsNothing() async throws {
        let updates = try await runLive([speech(2), speech(2)]) { call, seconds in
            switch call {
            case 1: return [self.segment(0, 2, "一")]
            case 2: return [self.segment(0, 3, "一"), self.segment(3, 4, "二")]
            default:
                XCTAssertEqual(seconds, 1)
                return []
            }
        }
        XCTAssertEqual(updates, [
            LiveUpdate(confirmed: [], tentative: "一"),
            LiveUpdate(confirmed: [segment(0, 3, "一")], tentative: "二"),
            LiveUpdate(confirmed: [segment(3, 4, "二")], tentative: ""),
        ])
    }

    func testEndOfStreamConfirmsFinalTranscriptionOfRemainder() async throws {
        let updates = try await runLive([speech(2), speech(2)]) { call, _ in
            switch call {
            case 1: return [self.segment(0, 2, "一")]
            case 2: return [self.segment(0, 3, "一"), self.segment(3, 4, "に")]
            default: return [self.segment(0, 0.8, "二")]
            }
        }
        XCTAssertEqual(updates.last, LiveUpdate(confirmed: [segment(3, 3.8, "二")], tentative: ""))
    }

    func testForcedFlushKeepsAudioAfterLastSegment() async throws {
        var finalSeconds = 0.0
        // 区切れないまま 26 秒たまる。認識結果は毎回、末尾 0.5 秒を残した1区間。
        let updates = try await runLive(Array(repeating: speech(2), count: 13)) { call, seconds in
            if call == 14 {
                finalSeconds = seconds
                return [self.segment(0, 0.5, "尾")]
            }
            return [self.segment(0, seconds - 0.5, "長")]
        }
        XCTAssertEqual(updates, [
            LiveUpdate(confirmed: [], tentative: "長"),
            LiveUpdate(confirmed: [segment(0, 25.5, "長")], tentative: ""),
            LiveUpdate(confirmed: [segment(25.5, 26, "尾")], tentative: ""),
        ])
        XCTAssertEqual(finalSeconds, 0.5, "強制確定で末尾の音声を捨てない")
    }

    func testSilenceIsDroppedAndKeepsStreamTime() async throws {
        var bufferSeconds: [Double] = []
        let updates = try await runLive([silence(2), silence(2), speech(2)]) { call, seconds in
            bufferSeconds.append(seconds)
            return call == 1 ? [self.segment(0, 1, "一"), self.segment(1, 2, "二")] : [self.segment(0, 1, "二")]
        }
        XCTAssertEqual(bufferSeconds, [2, 1], "無音はためない")
        XCTAssertEqual(updates, [
            LiveUpdate(confirmed: [segment(4, 5, "一")], tentative: "二"),
            LiveUpdate(confirmed: [segment(5, 6, "二")], tentative: ""),
        ])
    }

    // MARK: prompt 付きのときの時刻トークン強制（偽の語彙）

    /// 0…8 が文字、10…17 が特殊トークン、20 以降が時刻（<|0.00|>…<|30.00|>）。
    /// 2・3・4 は全角「？」のバイト断片で、3つそろって初めて文字になる。
    static let words = ["です", "か", "①", "②", "③", "。", ".", "5", "a"]
    static let special = SpecialTokens(
        endToken: 10, englishToken: 17, noSpeechToken: 16, noTimestampsToken: 15, specialTokenBegin: 10,
        startOfPreviousToken: 12, startOfTranscriptToken: 11, timeTokenBegin: 20, transcribeToken: 13,
        translateToken: 14, whitespaceToken: 9)
    static let lastTime = 20 + 1500
    let filter = PromptTimestampFilter(specialTokens: TranscriptionTests.special) { ids in
        ids.map { TranscriptionTests.words[$0] }.joined()
            .replacingOccurrences(of: "①②③", with: "？")
            .replacingOccurrences(of: "[①②③]", with: "\u{FFFD}", options: .regularExpression)
    }
    /// 用語集（a）つきの先頭部分: <|startofprev|> a <|startoftranscript|> 言語 task <|0.00|>
    let prompted = [12, 8, 11, 17, 13, 20]

    /// フィルターをかけた後の logits。時刻トークンは最初から十分低くしておく。
    func filtered(_ tokens: [Int]) throws -> MLMultiArray {
        let logits = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.lastTime + 1)], dataType: .float16, initialValue: FloatType(0))
        logits.fillLastDimension(indexes: 20..<(Self.lastTime + 1), with: -20)
        return filter.filterLogits(logits, withTokens: tokens)
    }

    func forcesTimestamp(_ sampled: [Int]) throws -> Bool {
        try filtered(prompted + sampled)[8].floatValue == -.infinity
    }

    func testFilterForcesTimestampAfterSentenceEnd() throws {
        XCTAssertTrue(try forcesTimestamp([0, 5]), "です。")
        XCTAssertFalse(try forcesTimestamp([0, 1]), "ですか")
        XCTAssertTrue(try forcesTimestamp([8, 6]), "a.")
        XCTAssertFalse(try forcesTimestamp([7, 6]), "5. は小数点かもしれない")
    }

    func testFilterDetectsFullWidthQuestionMarkSplitAcrossTokens() throws {
        XCTAssertTrue(try forcesTimestamp([0, 1, 2, 3, 4]), "ですか？")
        XCTAssertFalse(try forcesTimestamp([0, 1, 2, 3]), "文字の途中")
    }

    func testFilterAppliesTimestampRulesAtFirstSampledPosition() throws {
        XCTAssertEqual(try filtered(prompted)[15].floatValue, -.infinity, "<|notimestamps|> を禁止する")
    }

    func testFilterNeverSuppressesEverything() throws {
        // 最後の時刻 <|30.00|> の後に文末が来ても、文字のトークンは残す。
        XCTAssertFalse(try forcesTimestamp([0, Self.lastTime, Self.lastTime, 0, 5]))
    }

    func testFilterLeavesUnpromptedDecodingAlone() throws {
        let logits = try filtered([11, 17, 13, 20, 0, 5])
        XCTAssertEqual(logits[8].floatValue, 0)
        XCTAssertEqual(logits[15].floatValue, 0)
    }
}

/// 最終パスで認識にかける区間の決め方。
final class SpeechRegionTests: XCTestCase {
    func regions(_ pattern: String) -> [Range<Int>] {
        WhisperEngine.speechRegions(peaks: pattern.map { $0 == "x" ? 0.5 : 0 })
    }

    func testLongSilenceSplitsAndIsSkipped() {
        // 先頭の無音、短い間（2秒）は区間に含め、3秒以上の無音で区切り、末尾の無音は捨てる。
        XCTAssertEqual(regions("....xx..xx....xxx....."), [4..<10, 14..<17])
    }

    func testAllSilentGivesNothing() {
        XCTAssertEqual(regions("........"), [])
        XCTAssertEqual(regions(""), [])
    }

    func testLongRegionIsCutAtQuietestSecond() {
        // 600秒鳴りっぱなしで、280秒目だけ静か（無音ではない）。
        var peaks = [Float](repeating: 0.5, count: 600)
        peaks[280] = 0.01
        let result = WhisperEngine.speechRegions(peaks: peaks)
        XCTAssertEqual(result.first, 0..<281)
        XCTAssertEqual(result.map(\.count).reduce(0, +), 600, "切っても音のある秒は落とさない")
        XCTAssertTrue(result.allSatisfy { $0.count <= WhisperEngine.maxRegionSeconds })
    }
}
