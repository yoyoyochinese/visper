import AVFoundation
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case micDenied
    case deviceMissing(String)
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    case deviceChanged
    case conversionFailed
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
        case .unsupportedFormat(let detail):
            "この音声デバイスの構成には対応していません（\(detail)）。"
        case .deviceChanged:
            "録音中に音声デバイスが切断されたか、形式が変わったため、録音を終了しました。"
        case .conversionFailed:
            "音声の変換に失敗したため、録音を終了しました。"
        case .notRecording:
            "録音が開始されていません。"
        case .empty:
            "録音に音声が含まれていません。"
        }
    }
}

/// マイクは入力デバイスの IOProc、システム音声はプロセスタップを載せた集約デバイスの IOProc で取る。
/// IOProc（`ioQueue`）ではバッファを写すだけにし、変換・ミックス・書き出しは `queue` で行う。
final class SystemAudioCapture: AudioCapturing {
    /// IOProc に渡されるバッファ列のうち、取り込む1チャンネルの位置。
    struct ChannelRef: Equatable {
        var buffer: Int
        var offset: Int
        var stride: Int
    }

    /// 取り込み元1つぶんの構成。録音中に変わったら失敗として扱う。
    struct Source: Equatable {
        var device: AudioObjectID
        var sampleRate: Double
        /// IOProc に渡されるはずのバッファ数。
        var bufferCount: Int
        var channels: [ChannelRef]
        var format: AVAudioFormat {
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count))!
        }
    }

    static let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Tuning.sampleRate, channels: 1)!
    /// 「両方」で遅れている入力を待つ上限（サンプル数）。これを超えた分は無音として出す。
    static let maxBacklog = Int(Tuning.sampleRate * 0.5)
    /// 入力の途切れとみなす長さ（サンプル数）。これより空いたら無音で埋めて実時間に合わせる。`maxBacklog` より短くすること。
    static let maxGap = Int(Tuning.sampleRate * 0.25)

    let ioQueue = DispatchQueue(label: "com.elverum.visper.audio.io")
    private let queue = DispatchQueue(label: "com.elverum.visper.audio")

    // `queue` 上で扱う状態
    private var converters: [AVAudioConverter] = []
    private var pending: [[Float]] = []
    /// これまでに出したサンプル数。出力上の位置は録音開始からの実時間に対応する。
    private var written = 0
    private var file: AVAudioFile?
    private var url: URL?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var failure: Error?
    private var startUptime: UInt64 = 0

    // start / stop を呼ぶ側のスレッドで扱う状態
    private var procs: [(device: AudioObjectID, proc: AudioDeviceIOProcID)] = []
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)

    func inputDevices() -> [AudioInputDevice] { inputs().map(\.device) }

    func start(source: AudioSource, micDeviceUID: String?, recordingTo url: URL) async throws -> AsyncStream<[Float]> {
        if source != .system, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw AudioCaptureError.micDenied
        }
        do {
            var sources: [(source: Source, describe: () throws -> Source)] = []
            if source != .system {
                let device = try micDevice(uid: micDeviceUID)
                let describe = { try self.micSource(device) }
                sources.append((try describe(), describe))
            }
            if source != .mic {
                try createTap()
                sources.append((try tapSource(), tapSource))
            }
            let stream = try begin(formats: sources.map(\.source.format), recordingTo: url)
            for (index, entry) in sources.enumerated() {
                try attach(entry.source, describe: entry.describe, index: index)
            }
            return stream
        } catch {
            detach()
            queue.sync { teardown() }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() async throws -> URL {
        // IOProc は ioQueue へ同期で配送されるので、キューの上で止めるとデッドロックする。必ず外で止める。
        detach()
        let (url, failure) = queue.sync { () -> (URL?, Error?) in
            emit(pending.map(\.count).max() ?? 0)
            defer { teardown() }
            return (self.url, self.failure)
        }
        guard let url else { throw AudioCaptureError.notRecording }
        // 途中で失敗していても、そこまでの録音は .m4a にしてから失敗を伝える。
        let converted = Result { try Self.convertToM4A(url) }
        if let failure { throw failure }
        return try converted.get()
    }

    func recover(recordingAt url: URL) async -> URL? {
        try? Self.convertToM4A(url)
    }

    // MARK: - 変換とミックス（デバイスに依存しない部分。テストはここを直接使う）

    /// 入力ごとの形式を受け取り、録音ファイルとストリームを用意する。
    func begin(formats: [AVAudioFormat], recordingTo url: URL) throws -> AsyncStream<[Float]> {
        let converters = try formats.map {
            guard let converter = AVAudioConverter(from: $0, to: Self.outputFormat) else {
                throw AudioCaptureError.unsupportedFormat("\($0)")
            }
            converter.downmix = true
            return converter
        }
        // CAF は書き込み中でもヘッダが有効なので、強制終了されても読める（D35）。
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Tuning.sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        queue.sync {
            self.converters = converters
            self.pending = formats.map { _ in [] }
            self.written = 0
            self.failure = nil
            self.file = file
            self.url = url
            self.continuation = continuation
            self.startUptime = DispatchTime.now().uptimeNanoseconds
        }
        return stream
    }

    /// IOProc の中身。必要なチャンネルだけ写して `queue` に渡す。`ioQueue` 上で呼ばれる。
    func receive(_ list: UnsafeMutableAudioBufferListPointer, from source: Source, input index: Int) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- startUptime) / 1e9
        guard list.count == source.bufferCount, let buffer = Self.copy(list, source: source) else {
            queue.async { self.fail(AudioCaptureError.deviceChanged) }
            return
        }
        queue.async { self.feed(buffer, input: index, at: elapsed) }
    }

    /// バッファ列から `source.channels` のチャンネルを取り出す（HAL の IOProc は Float32）。
    static func copy(_ list: UnsafeMutableAudioBufferListPointer, source: Source) -> AVAudioPCMBuffer? {
        guard let first = source.channels.first, first.buffer < list.count else { return nil }
        let frames = Int(list[first.buffer].mDataByteSize) / MemoryLayout<Float>.size / first.stride
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(max(frames, 1))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (c, ref) in source.channels.enumerated() {
            let from = list[ref.buffer]
            guard let data = from.mData, Int(from.mDataByteSize) >= frames * ref.stride * MemoryLayout<Float>.size else { return nil }
            let samples = data.assumingMemoryBound(to: Float.self)
            let to = buffer.floatChannelData![c]
            for i in 0..<frames { to[i] = samples[ref.offset + i * ref.stride] }
        }
        return buffer
    }

    /// バッファごとのチャンネル数 `streams` のうち `range` のバッファから、取り込むチャンネルを決める。
    /// 3チャンネル以上の機器（オーディオインターフェースなど）は先頭の1チャンネルだけを使う。
    static func channelRefs(streams: [Int], range: Range<Int>) -> [ChannelRef] {
        let all = range.flatMap { b in (0..<streams[b]).map { ChannelRef(buffer: b, offset: $0, stride: streams[b]) } }
        return all.count > 2 ? Array(all.prefix(1)) : all
    }

    /// 集約デバイスの入力のうちタップのバッファ位置。出力デバイス自身の入力の後ろにタップが並ぶ前提で、
    /// 実際の並びがそれと合わなければ、違うバッファを読まないようエラーにする。
    static func tapBufferRange(streams: [Int], deviceInputs: [Int], tapChannels: Int, interleaved: Bool) throws -> Range<Int> {
        let tapStreams = interleaved ? [tapChannels] : Array(repeating: 1, count: tapChannels)
        guard tapChannels > 0, streams == deviceInputs + tapStreams else {
            throw AudioCaptureError.unsupportedFormat("システム音声の入力の並びが想定と異なります: \(streams)、想定 \(deviceInputs + tapStreams)")
        }
        return deviceInputs.count..<streams.count
    }

    /// `index` 番目の入力のバッファを 16 kHz モノラルにして取り込む。`elapsed` は録音開始からの秒数（バッファ末尾の時刻）。
    /// 実行時は `queue` 上で呼ばれる。
    func feed(_ buffer: AVAudioPCMBuffer, input index: Int, at elapsed: TimeInterval) {
        guard file != nil, failure == nil, index < converters.count, buffer.frameLength > 0 else { return }
        let ratio = Tuning.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var consumed = false
        var error: NSError?
        let status = converters[index].convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if status == .error { return fail(error ?? AudioCaptureError.conversionFailed) }
        let count = Int(out.frameLength)

        // 出力は実時間に沿わせる。この入力が途切れていた（まだ始まっていなかった）なら、
        // このバッファの時刻まで（他の入力があればその分を、なければ無音を）先に出してから置く。
        let position = Int(elapsed * Tuning.sampleRate) - count
        if position - (written + pending[index].count) > Self.maxGap {
            emit(position - written)
        }
        pending[index] += UnsafeBufferPointer(start: out.floatChannelData![0], count: count)

        // 全入力がそろった分だけ出す。遅れている入力は maxBacklog を超えたら無音として扱う。
        // ponytail: 入力どうしのクロックのずれは補正しない。ずれが maxBacklog に達すると遅い側に細かい無音が入る。
        // 問題になるならマイクも集約デバイスに入れてドリフト補正を使う。
        let counts = pending.map(\.count)
        emit(max(counts.min()!, counts.max()! - Self.maxBacklog))
    }

    /// 先頭 `n` サンプルをミックスしてファイルとストリームに出す。足りない入力は無音。
    private func emit(_ n: Int) {
        var remaining = n
        while remaining > 0, failure == nil, let file {
            let k = min(remaining, Int(Tuning.sampleRate))
            guard let mixed = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: AVAudioFrameCount(k)) else { return }
            mixed.frameLength = AVAudioFrameCount(k)
            let samples = UnsafeMutableBufferPointer(start: mixed.floatChannelData![0], count: k)
            samples.update(repeating: 0)
            for i in pending.indices {
                let m = min(k, pending[i].count)
                for j in 0..<m { samples[j] += pending[i][j] }
                pending[i].removeFirst(m)
            }
            do { try file.write(from: mixed) } catch { return fail(error) }
            continuation?.yield(Array(samples))
            written += k
            remaining -= k
        }
    }

    /// 取り込みや書き込みの最初の失敗を覚えてストリームを終える。`stop()` がそこまでの録音を変換してから投げる。
    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        continuation?.finish()
        continuation = nil
    }

    private func teardown() {
        continuation?.finish()
        continuation = nil
        file?.close()
        file = nil
        url = nil
        failure = nil
        converters = []
        pending = []
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

    /// IOProc・監視・集約デバイス・タップを片付ける。`queue` / `ioQueue` の外から呼ぶこと。
    private func detach() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, queue, listener.block)
        }
        listeners = []
        for (device, proc) in procs {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        procs = []
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        // 配送済みの IOProc を流し切る。
        ioQueue.sync {}
    }

    /// Mac の出力全体のタップと、それを読むための非公開の集約デバイスを作る（D12, D32）。
    private func createTap() throws {
        let output = try defaultOutput()
        let outputUID = try string(output, kAudioDevicePropertyDeviceUID)

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject())
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

    private func micSource(_ device: AudioObjectID) throws -> Source {
        let asbd = try property(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput,
                                AudioStreamBasicDescription(), "マイクの形式の取得")
        try checkFloat(asbd)
        guard try property(device, kAudioDevicePropertyDeviceIsAlive, UInt32(0), "マイクの状態の取得") != 0 else {
            throw AudioCaptureError.deviceMissing("マイク")
        }
        let streams = try streamChannels(device)
        guard let first = streams.first, first > 0 else { throw AudioCaptureError.deviceMissing("マイクの入力チャンネル") }
        let rate = try property(device, kAudioDevicePropertyNominalSampleRate, Float64(0), "マイクのサンプルレートの取得")
        return Source(device: device, sampleRate: rate, bufferCount: streams.count,
                      channels: Self.channelRefs(streams: streams, range: 0..<1))
    }

    private func tapSource() throws -> Source {
        let asbd = try property(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription(), "システム音声の形式の取得")
        try checkFloat(asbd)
        let streams = try streamChannels(aggregate)
        let range = try Self.tapBufferRange(
            streams: streams, deviceInputs: try streamChannels(defaultOutput()),
            tapChannels: Int(asbd.mChannelsPerFrame),
            interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        return Source(device: aggregate, sampleRate: asbd.mSampleRate, bufferCount: streams.count,
                      channels: Self.channelRefs(streams: streams, range: range))
    }

    private func attach(_ source: Source, describe: @escaping () throws -> Source, index: Int) throws {
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, source.device, ioQueue) { [weak self] _, input, _, _, _ in
            self?.receive(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), from: source, input: index)
        }, "音声の取り込みの準備")
        guard let proc else { throw AudioCaptureError.coreAudio("音声の取り込みの準備", -1) }
        procs.append((source.device, proc))

        // 切断や形式の変更を監視する。通知が来たら構成を読み直し、開始時と違えば失敗にする（自動で付け直しはしない）。
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if (try? describe()) != source { self?.fail(AudioCaptureError.deviceChanged) }
        }
        var watched: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (source.device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (source.device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (source.device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        if source.device == aggregate { watched.append((tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal)) }
        for (object, selector, scope) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "音声デバイスの監視")
            listeners.append((object, address, block))
        }
        try check(AudioDeviceStart(source.device, proc), "音声の取り込みの開始")
    }

    /// 録音中に Visper で過去の録音を再生しても拾わないよう、自分のプロセスをタップから除外する。
    private func ownProcessObject() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private func defaultOutput() throws -> AudioObjectID {
        let output = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                  AudioObjectID(kAudioObjectUnknown), "出力デバイスの取得")
        guard output != kAudioObjectUnknown else { throw AudioCaptureError.deviceMissing("出力デバイス") }
        return output
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
            guard id != aggregate, let streams = try? streamChannels(id), !streams.isEmpty,
                  let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  let name = try? string(id, kAudioObjectPropertyName) else { return nil }
            return (id, AudioInputDevice(uid: uid, name: name))
        }
    }

    /// デバイスの入力側の、IOProc に渡されるバッファごとのチャンネル数。
    private func streamChannels(_ device: AudioObjectID) throws -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "入力構成の取得")
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "入力構成の取得")
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    private func checkFloat(_ asbd: AudioStreamBasicDescription) throws {
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else {
            throw AudioCaptureError.unsupportedFormat("Float32 の PCM ではありません")
        }
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
