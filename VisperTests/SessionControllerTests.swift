import SwiftData
import XCTest
@testable import Visper

@MainActor
final class SessionControllerTests: XCTestCase {
    var container: ModelContainer!
    var audio: FakeAudioCapture!
    var transcriber: ScriptedTranscriber!
    var controller: SessionController!

    override func setUp() async throws {
        AudioStore.directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        container = try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        audio = FakeAudioCapture()
        transcriber = ScriptedTranscriber(liveScript: ["a", "b"], finalScript: ["A", "B", "C"])
        controller = SessionController(
            audio: audio, transcriber: transcriber, context: container.mainContext,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func sessions() throws -> [Session] {
        try container.mainContext.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    func wait(_ what: String, until condition: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out: \(what)")
    }

    func record() async throws {
        await controller.start(source: .mic, language: .ja)
        try await wait("live lines") { controller.liveLines.count == 2 }
        await controller.stop()
    }

    func testFinalPassReplacesLiveText() async throws {
        transcriber.finalDelay = 0.2
        try await record()
        let session = try XCTUnwrap(sessions().first)
        XCTAssertEqual(session.status, .pendingFinal)
        XCTAssertEqual(session.sortedSegments.map(\.text), ["a", "b"])
        try await wait("final") { session.status == .done }
        XCTAssertEqual(session.sortedSegments.map(\.text), ["A", "B", "C"])
        XCTAssertNil(controller.finalizingID)
    }

    func testFinalPassWaitsWhileRecording() async throws {
        transcriber.finalDelay = 0.2
        try await record()
        await controller.start(source: .mic, language: .ja)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try sessions().first?.status, .pendingFinal, "録音中は最終パスを進めない")
        XCTAssertTrue(transcriber.finalCalls.isEmpty)
        await controller.stop()
        try await wait("both final") { try sessions().allSatisfy { $0.status == .done } }
        XCTAssertEqual(transcriber.finalCalls.map(\.lastPathComponent), try sessions().map(\.audioFileName), "古い順に1つずつ")
    }

    func testRecoversInterruptedSession() async throws {
        let withAudio = Session(source: .mic, language: .ja)
        withAudio.append([TranscribedSegment(start: 0, end: 7, text: "live")])
        FileManager.default.createFile(atPath: withAudio.audioURL.path, contents: Data())
        let empty = Session(source: .mic, language: .ja, startedAt: .now.addingTimeInterval(1))
        container.mainContext.insert(withAudio)
        container.mainContext.insert(empty)

        await controller.recoverInterrupted()
        try await wait("recovered") { try sessions().first?.status == .done }
        let all = try sessions()
        XCTAssertEqual(all.count, 1, "音声も本文もないセッションは消す")
        XCTAssertEqual(all[0].duration, 7)
        XCTAssertEqual(all[0].sortedSegments.map(\.text), ["A", "B", "C"])
    }

    func testFailedFinalPassKeepsLiveText() async throws {
        let session = Session(source: .mic, language: .ja)
        session.append([TranscribedSegment(start: 0, end: 1, text: "live")])
        container.mainContext.insert(session)
        audio.recoverable = false
        await controller.recoverInterrupted()
        XCTAssertEqual(session.status, .finalFailed)
        XCTAssertEqual(session.sortedSegments.map(\.text), ["live"])
    }

    func testMarkdown() {
        let session = Session(source: .mic, language: .ja)
        session.title = "輪講"
        session.duration = 3725
        session.append([
            TranscribedSegment(start: 83, end: 90, text: "二行目"),
            TranscribedSegment(start: 0, end: 5, text: "一行目"),
        ])
        let md = session.markdown
        XCTAssertTrue(md.hasPrefix("# 輪講\n"))
        XCTAssertTrue(md.contains("- 長さ: 01:02:05"))
        XCTAssertTrue(md.contains("- [00:00:00] 一行目\n- [00:01:23] 二行目"))
    }
}
