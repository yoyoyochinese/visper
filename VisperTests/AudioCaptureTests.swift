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

    /// 440 Hz の正弦波を 0.1 秒ごとのバッファに分けて返す。
    func sine(_ format: AVAudioFormat, seconds: Double, amplitude: Float = 0.25) -> [AVAudioPCMBuffer] {
        let perChunk = Int(format.sampleRate * 0.1)
        return (0..<Int((seconds * 10).rounded())).map { c in
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

    /// `c` 番目（0 始まり）の 0.1 秒バッファが届く時刻。`offset` は入力が始まった時刻。
    func time(_ c: Int, offset: Double = 0) -> TimeInterval { offset + Double(c + 1) * 0.1 }

    func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    func collect(_ stream: AsyncStream<[Float]>) async -> [Float] {
        var samples: [Float] = []
        for await chunk in stream { samples += chunk }
        return samples
    }

    func testResamplesAndMixesTo16kMono() async throws {
        let capture = SystemAudioCapture()
        let stereo48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let mono44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let stream = try capture.begin(formats: [stereo48, mono44], recordingTo: directory.appending(path: "a.caf"))
        for (c, (a, b)) in zip(sine(stereo48, seconds: 2), sine(mono44, seconds: 2)).enumerated() {
            capture.feed(a, input: 0, at: time(c))
            capture.feed(b, input: 1, at: time(c))
        }
        let m4a = try await capture.stop()

        let samples = await collect(stream)
        // 変換器の遅延ぶんだけ末尾が欠ける。
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
        // 同位相で振幅 0.25 の2入力が足されて 0.5 前後になる。
        XCTAssertEqual(Double(samples[8_000...].max()!), 0.5, accuracy: 0.05)

        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertEqual(try duration(of: m4a), 2, accuracy: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "a.caf").path))
    }

    /// 片方の入力が無音のまま止めても、もう片方の末尾が欠けない。
    func testStopFlushesTailWhenOtherInputIsSilent() async throws {
        let capture = SystemAudioCapture()
        let format = SystemAudioCapture.outputFormat
        let stream = try capture.begin(formats: [format, format], recordingTo: directory.appending(path: "b.caf"))
        for (c, buffer) in sine(format, seconds: 3).enumerated() { capture.feed(buffer, input: 0, at: time(c)) }
        let m4a = try await capture.stop()

        let samples = await collect(stream)
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 400)
        XCTAssertEqual(try duration(of: m4a), 3, accuracy: 0.2)
    }

    /// 入力が1つのとき、最初のバッファが届くまでの時間は無音になる（タップは音が鳴るまで呼ばれない）。
    func testInitialGapBecomesSilence() async throws {
        let capture = SystemAudioCapture()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let stream = try capture.begin(formats: [format], recordingTo: directory.appending(path: "g.caf"))
        for (c, buffer) in sine(format, seconds: 1).enumerated() { capture.feed(buffer, input: 0, at: time(c, offset: 2)) }
        let m4a = try await capture.stop()

        let samples = await collect(stream)
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 400)
        XCTAssertEqual(samples[..<31_000].map(abs).max(), 0)
        XCTAssertGreaterThan(samples[33_000...].max()!, 0.2)
        XCTAssertEqual(try duration(of: m4a), 3, accuracy: 0.2)
    }

    /// 「両方」で遅れて始まった入力は、先頭ではなく実時間の位置に置かれる。
    func testLateInputIsAlignedToWallClock() async throws {
        let capture = SystemAudioCapture()
        let format = SystemAudioCapture.outputFormat
        let stream = try capture.begin(formats: [format, format], recordingTo: directory.appending(path: "l.caf"))
        let silence = sine(format, seconds: 3, amplitude: 0)
        let late = sine(format, seconds: 1)
        for c in 0..<30 {
            capture.feed(silence[c], input: 0, at: time(c))
            if c >= 20 { capture.feed(late[c - 20], input: 1, at: time(c)) }
        }
        _ = try await capture.stop()

        let samples = await collect(stream)
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 400)
        let firstSound = try XCTUnwrap(samples.firstIndex { abs($0) > 0.05 })
        XCTAssertEqual(Double(firstSound), 32_000, accuracy: 800)
        // 遅れて始まった入力も欠けずに 1 秒ぶん入っている。
        let lastSound = try XCTUnwrap(samples.lastIndex { abs($0) > 0.05 })
        XCTAssertEqual(Double(lastSound - firstSound), 16_000, accuracy: 800)
    }

    /// 途中で失敗したらストリームが終わり、stop はそこまでの録音を .m4a にしてから失敗を投げる。
    func testFailureFinishesStreamAndStopThrowsAfterConverting() async throws {
        struct DiskFull: Error {}
        let capture = SystemAudioCapture()
        let format = SystemAudioCapture.outputFormat
        let caf = directory.appending(path: "f.caf")
        let stream = try capture.begin(formats: [format], recordingTo: caf)
        let buffers = sine(format, seconds: 2)
        for c in 0..<10 { capture.feed(buffers[c], input: 0, at: time(c)) }
        capture.fail(DiskFull())
        for c in 10..<20 { capture.feed(buffers[c], input: 0, at: time(c)) }

        // stop を待たずにストリームが終わる。
        let samples = await collect(stream)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 400)
        do {
            _ = try await capture.stop()
            XCTFail("stop should throw the stored error")
        } catch {
            XCTAssertTrue(error is DiskFull)
        }
        XCTAssertEqual(try duration(of: directory.appending(path: "f.m4a")), 1, accuracy: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: caf.path))
    }

    func testChannelSelection() throws {
        typealias Ref = SystemAudioCapture.ChannelRef
        // モノラル、ステレオはそのまま。3チャンネル以上は先頭だけ。
        XCTAssertEqual(SystemAudioCapture.channelRefs(streams: [1], range: 0..<1), [Ref(buffer: 0, offset: 0, stride: 1)])
        XCTAssertEqual(SystemAudioCapture.channelRefs(streams: [2, 2], range: 0..<1),
                       [Ref(buffer: 0, offset: 0, stride: 2), Ref(buffer: 0, offset: 1, stride: 2)])
        XCTAssertEqual(SystemAudioCapture.channelRefs(streams: [8], range: 0..<1), [Ref(buffer: 0, offset: 0, stride: 8)])

        // タップは出力デバイス自身の入力の後ろ。インターリーブでもそうでなくても取れる。
        XCTAssertEqual(try SystemAudioCapture.tapBufferRange(streams: [2], deviceInputs: [], tapChannels: 2, interleaved: true), 0..<1)
        XCTAssertEqual(try SystemAudioCapture.tapBufferRange(streams: [1, 2], deviceInputs: [1], tapChannels: 2, interleaved: true), 1..<2)
        XCTAssertEqual(try SystemAudioCapture.tapBufferRange(streams: [1, 1, 1], deviceInputs: [1], tapChannels: 2, interleaved: false), 1..<3)
        XCTAssertEqual(SystemAudioCapture.channelRefs(streams: [1, 1, 1], range: 1..<3),
                       [Ref(buffer: 1, offset: 0, stride: 1), Ref(buffer: 2, offset: 0, stride: 1)])
        // 想定と違う並びはエラー。
        XCTAssertThrowsError(try SystemAudioCapture.tapBufferRange(streams: [2, 1], deviceInputs: [1], tapChannels: 2, interleaved: true))
        XCTAssertThrowsError(try SystemAudioCapture.tapBufferRange(streams: [2], deviceInputs: [1], tapChannels: 2, interleaved: true))
    }

    /// 8チャンネルのインターリーブ入力を1つ持つ、IOProc に渡される形のバッファ列。先頭チャンネルだけ 0.5。
    func eightChannelList(frames: Int) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 8)
        for i in 0..<frames * 8 { data[i] = i % 8 == 0 ? 0.5 : -1 }
        list[0] = AudioBuffer(mNumberChannels: 8, mDataByteSize: UInt32(frames * 8 * 4), mData: data)
        return list
    }

    var eightChannelSource: SystemAudioCapture.Source {
        .init(device: 0, sampleRate: 48_000, bufferCount: 1, channels: SystemAudioCapture.channelRefs(streams: [8], range: 0..<1))
    }

    func testCopiesFirstChannelOfMultichannelDevice() throws {
        let list = eightChannelList(frames: 480)
        let buffer = try XCTUnwrap(SystemAudioCapture.copy(list, source: eightChannelSource))
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.format.sampleRate, 48_000)
        XCTAssertEqual(buffer.frameLength, 480)
        XCTAssertTrue(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 480).allSatisfy { $0 == 0.5 })
    }

    /// IOProc と同じ経路（ioQueue への同期配送 → 作業キュー）で流し続けている最中に stop を繰り返しても固まらない。
    /// 実機の AudioDeviceStop との組み合わせまでは確かめられない。
    func testStopWhileIOThreadKeepsDelivering() async throws {
        let capture = SystemAudioCapture()
        let list = eightChannelList(frames: 480)
        let source = eightChannelSource
        for i in 0..<30 {
            let stream = try capture.begin(formats: [source.format], recordingTo: directory.appending(path: "s\(i).caf"))
            let running = ManagedAtomicFlag()
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                while running.value {
                    capture.ioQueue.sync { capture.receive(list, from: source, input: 0) }
                    usleep(500)
                }
                finished.signal()
            }
            try await Task.sleep(for: .milliseconds(20 + i))
            let m4a = try await capture.stop()
            running.value = false
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { finished.wait(); continuation.resume() }
            }
            let samples = await collect(stream)
            XCTAssertGreaterThan(samples.count, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))
        }
    }

    func testRecoverConvertsUnclosedCAF() async throws {
        let capture = SystemAudioCapture()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let caf = directory.appending(path: "c.caf")
        _ = try capture.begin(formats: [format], recordingTo: caf)
        for (c, buffer) in sine(format, seconds: 3).enumerated() { capture.feed(buffer, input: 0, at: time(c)) }

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

/// テスト用の、スレッド間で読む停止フラグ。
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
