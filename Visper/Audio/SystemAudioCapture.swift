import AVFoundation
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case micDenied
    case deviceMissing(String)
    case coreAudio(String, OSStatus)
    case notRecording
    case empty

    var errorDescription: String? {
        switch self {
        case .micDenied:
            "マイクの使用が許可されていません。システム設定の「プライバシーとセキュリティ > マイク」で Visper を許可してください。"
        case .deviceMissing(let what):
            "\(what)が見つかりません。接続と設定を確認してください。"
        case .coreAudio(let what, let status):
            "\(what)に失敗しました（Core Audio エラー \(status)）。システム音声の場合は「プライバシーとセキュリティ > 画面収録とシステムオーディオ録音」の許可を確認してください。"
        case .notRecording:
            "録音が開始されていません。"
        case .empty:
            "録音に音声が含まれていません。"
        }
    }
}

/// マイクは入力デバイスの IOProc、システム音声はプロセスタップを載せた集約デバイスの IOProc で取る。
/// どちらも 16 kHz モノラルに変換し、`queue` 上でミックスしてストリームと .caf に流す。
final class SystemAudioCapture: AudioCapturing {
    static let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Tuning.sampleRate, channels: 1)!
    /// 「両方」で片方が遅れたり止まったりしたとき、もう片方を待たせる上限（サンプル数）。
    private static let maxBacklog = Int(Tuning.sampleRate)

    private let queue = DispatchQueue(label: "com.elverum.visper.audio")
    private var converters: [AVAudioConverter] = []
    private var pending: [[Float]] = []
    private var file: AVAudioFile?
    private var url: URL?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var procs: [(device: AudioObjectID, proc: AudioDeviceIOProcID)] = []
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)

    func inputDevices() -> [AudioInputDevice] { inputs().map(\.device) }

    func start(source: AudioSource, micDeviceUID: String?, recordingTo url: URL) async throws -> AsyncStream<[Float]> {
        if source != .system, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw AudioCaptureError.micDenied
        }
        do {
            var sources: [(device: AudioObjectID, format: AVAudioFormat, isTap: Bool)] = []
            if source != .system {
                let device = try micDevice(uid: micDeviceUID)
                let asbd = try property(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput,
                                        AudioStreamBasicDescription(), "マイクの形式の取得")
                sources.append((device, try format(asbd), false))
            }
            if source != .mic {
                try createTap()
                let asbd = try property(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription(), "システム音声の形式の取得")
                sources.append((aggregate, try format(asbd), true))
            }
            let stream = try begin(formats: sources.map(\.format), recordingTo: url)
            for (index, source) in sources.enumerated() {
                try attach(source.device, format: source.format, isTap: source.isTap, index: index)
            }
            return stream
        } catch {
            queue.sync { teardown() }
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let url else { throw AudioCaptureError.notRecording }
        queue.sync { teardown() }
        return try Self.convertToM4A(url)
    }

    func recover(recordingAt url: URL) async -> URL? {
        try? Self.convertToM4A(url)
    }

    // MARK: - 変換とミックス（デバイスに依存しない部分。テストはここを直接使う）

    /// 入力ごとの形式を受け取り、録音ファイルとストリームを用意する。
    func begin(formats: [AVAudioFormat], recordingTo url: URL) throws -> AsyncStream<[Float]> {
        converters = try formats.map {
            guard let converter = AVAudioConverter(from: $0, to: Self.outputFormat) else {
                throw AudioCaptureError.deviceMissing("対応していない音声形式のため、変換方法")
            }
            converter.downmix = true
            return converter
        }
        pending = formats.map { _ in [] }
        // CAF は書き込み中でもヘッダが有効なので、強制終了されても読める（D35）。
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Tuning.sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        self.url = url
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        return stream
    }

    /// `index` 番目の入力のバッファを 16 kHz モノラルにして取り込む。実行時は `queue` 上で呼ばれる。
    func feed(_ buffer: AVAudioPCMBuffer, input index: Int) {
        guard file != nil, buffer.frameLength > 0 else { return }
        let converter = converters[index]
        let ratio = Tuning.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var consumed = false
        converter.convert(to: out, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        pending[index] += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))

        // 全入力がそろった分だけ出す。遅れている入力は maxBacklog を超えたら無音として扱う。
        let counts = pending.map(\.count)
        let n = max(counts.min()!, counts.max()! - Self.maxBacklog)
        guard n > 0, let mixed = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        mixed.frameLength = AVAudioFrameCount(n)
        let samples = UnsafeMutableBufferPointer(start: mixed.floatChannelData![0], count: n)
        samples.update(repeating: 0)
        for i in pending.indices {
            let k = min(n, pending[i].count)
            for j in 0..<k { samples[j] += pending[i][j] }
            pending[i].removeFirst(k)
        }
        try? file?.write(from: mixed)
        continuation?.yield(Array(samples))
    }

    /// .caf を同じ場所の .m4a（AAC）に変換し、.caf を消す。
    private static func convertToM4A(_ caf: URL) throws -> URL {
        let input = try AVAudioFile(forReading: caf)
        guard input.length > 0 else { throw AudioCaptureError.empty }
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        let output = try AVAudioFile(forWriting: m4a, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000)!
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        output.close()
        try FileManager.default.removeItem(at: caf)
        return m4a
    }

    // MARK: - Core Audio

    private func teardown() {
        for (device, proc) in procs {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        procs = []
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        continuation?.finish()
        continuation = nil
        file?.close()
        file = nil
        url = nil
        converters = []
        pending = []
    }

    /// Mac の出力全体のタップと、それを読むための非公開の集約デバイスを作る（D12, D32）。
    private func createTap() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output = try property(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown), "出力デバイスの取得")
        guard output != kAudioObjectUnknown else { throw AudioCaptureError.deviceMissing("出力デバイス") }
        let outputUID = try string(output, kAudioDevicePropertyDeviceUID)

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tap), "システム音声の取り込みの開始")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Visper",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "システム音声用デバイスの作成")
    }

    private func attach(_ device: AudioObjectID, format: AVAudioFormat, isTap: Bool, index: Int) throws {
        // 1つのストリームが占めるバッファ数。集約デバイスでは出力デバイス自身の入力が前に並ぶので、タップは末尾から取る。
        let n = format.isInterleaved ? 1 : Int(format.channelCount)
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard all.count >= n else { return }
            let list = AudioBufferList.allocate(maximumBuffers: n)
            defer { free(list.unsafeMutablePointer) }
            let offset = isTap ? all.count - n : 0
            for i in 0..<n { list[i] = all[offset + i] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
            self?.feed(buffer, input: index)
        }, "音声の取り込みの準備")
        guard let proc else { throw AudioCaptureError.coreAudio("音声の取り込みの準備", -1) }
        queue.sync { procs.append((device, proc)) }
        try check(AudioDeviceStart(device, proc), "音声の取り込みの開始")
    }

    private func micDevice(uid: String?) throws -> AudioObjectID {
        if let uid {
            guard let found = inputs().first(where: { $0.device.uid == uid }) else {
                throw AudioCaptureError.deviceMissing("選択したマイク")
            }
            return found.id
        }
        let device = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                  AudioObjectID(kAudioObjectUnknown), "既定のマイクの取得")
        guard device != kAudioObjectUnknown else { throw AudioCaptureError.deviceMissing("マイク") }
        return device
    }

    private func inputs() -> [(id: AudioObjectID, device: AudioInputDevice)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard id != aggregate,
                  AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0,
                  let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  let name = try? string(id, kAudioObjectPropertyName) else { return nil }
            return (id, AudioInputDevice(uid: uid, name: name))
        }
    }

    private func format(_ asbd: AudioStreamBasicDescription) throws -> AVAudioFormat {
        var asbd = asbd
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioCaptureError.deviceMissing("対応している音声形式")
        }
        return format
    }

    private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ initial: T, _ what: String) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), what)
        return value
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try property(object, selector, nil, "デバイス情報の取得")
        guard let value else { throw AudioCaptureError.deviceMissing("デバイス情報") }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioCaptureError.coreAudio(what, status) }
    }
}
