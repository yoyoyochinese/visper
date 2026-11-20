import CoreML
import Foundation
import Observation
import WhisperKit

/// WhisperKit による文字起こし（D2, D3）。
@MainActor
@Observable
final class WhisperEngine: Transcribing {
    /// ライブ用。OpenAI の large-v3-turbo（2024-09-30 版）の量子化なし。
    static let liveVariant = "openai_whisper-large-v3-v20240930"
    /// 最終パス用。large-v3 の量子化なし。
    static let finalVariant = "openai_whisper-large-v3"
    /// 確定できないまま音声がこの秒数たまったら、全部確定して捨てる（Whisper の窓は30秒）。
    static let maxLiveBufferSeconds = 25.0
    /// これより小さい振幅しかないバッファは無音として認識にかけない。
    static let silencePeak: Float = 0.001
    /// サンドボックスのコンテナ内。
    static let downloadBase = URL.applicationSupportDirectory.appending(path: "Models")

    private(set) var modelState: ModelState = .notReady

    @ObservationIgnored private let liveModel = WhisperEngine.holder(liveVariant)
    @ObservationIgnored private let finalModel = WhisperEngine.holder(finalVariant)
    @ObservationIgnored private var tokenizer: (any WhisperTokenizer)?

    func prepareModels() async {
        do {
            let variants = [Self.liveVariant, Self.finalVariant]
            for (i, variant) in variants.enumerated() {
                // 途中で切れたダウンロードを完了と見なさないよう、完了の印を置く。
                let marker = Self.folder(variant).appending(path: ".visper-complete")
                guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
                // ponytail: 進捗は2モデルを半分ずつに割る（実サイズは 1.6GB と 3.1GB）。気になれば重み付けする。
                modelState = .downloading(Double(i) / 2)
                _ = try await WhisperKit.download(variant: variant, downloadBase: Self.downloadBase) { progress in
                    Task { @MainActor in
                        guard case .downloading = self.modelState else { return }
                        self.modelState = .downloading((Double(i) + progress.fractionCompleted) / 2)
                    }
                }
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            }
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func live(audio: AsyncStream<[Float]>, options: TranscriptionOptions) -> AsyncThrowingStream<LiveUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.liveModel.use { kit in
                        // ライブは遅延を抑えるため、温度を上げた再試行を1回までにする。
                        let decode = await self.decodingOptions(options, fallbacks: 1)
                        let chunk = Int(Tuning.liveChunkSeconds * Tuning.sampleRate)
                        var buffer: [Float] = []  // まだ確定していない音声だけを持つ
                        var dropped = 0           // バッファより前に捨てたサンプル数
                        var fresh = 0, needed = chunk
                        var lastTentative = ""

                        @MainActor func step(final: Bool) async throws {
                            let seconds = Double(buffer.count) / Tuning.sampleRate
                            let silent = !buffer.contains { abs($0) > Self.silencePeak }
                            let segments = silent ? [] : try await kit.transcribe(audioArray: buffer, decodeOptions: decode)
                                .flatMap(\.segments).compactMap(Self.segment)
                            let split = Self.split(segments, bufferSeconds: seconds, flush: final || seconds >= Self.maxLiveBufferSeconds)
                            let offset = Double(dropped) / Tuning.sampleRate
                            let confirmed = split.confirmed.map {
                                TranscribedSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text)
                            }
                            let consumed = min(buffer.count, Int(split.consumed * Tuning.sampleRate))
                            buffer.removeFirst(consumed)
                            dropped += consumed
                            if !confirmed.isEmpty || split.tentative != lastTentative {
                                continuation.yield(LiveUpdate(confirmed: confirmed, tentative: split.tentative))
                            }
                            lastTentative = split.tentative
                        }

                        for await samples in audio {
                            buffer += samples
                            fresh += samples.count
                            guard fresh >= needed else { continue }
                            let began = ContinuousClock.now
                            try await step(final: false)
                            fresh = 0
                            // 処理が追いつかないときは、その間にたまった分をまとめて次の1回にかける。
                            needed = max(chunk, Int((ContinuousClock.now - began) / .seconds(1) * Tuning.sampleRate))
                        }
                        try await step(final: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finalPass(audioFile: URL, options: TranscriptionOptions) async throws -> [TranscribedSegment] {
        try await finalModel.use { kit in
            let decode = await self.decodingOptions(options, fallbacks: 5)
            // 2時間の録音を一度にメモリへ載せないよう、少しずつ読みながら処理する。
            let results = try await kit.transcribe(
                audioPath: audioFile.path,
                audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                decodeOptions: decode)
            try Task.checkCancellation()
            return results.flatMap(\.segments).compactMap(Self.segment)
        }
    }

    func tokenCount(of text: String) async -> Int {
        // ponytail: トークナイザーを取得できないとき（初回起動がオフライン）は文字数で代用する。
        await promptTokens(text)?.count ?? text.count
    }

    /// ライブ1回分の認識結果（時刻はバッファ先頭から）を確定行と未確定に分ける。
    /// 最後の区間は続きが来て変わりうるので未確定に残す。`consumed` はバッファ先頭から捨ててよい秒数。
    static func split(_ segments: [TranscribedSegment], bufferSeconds: Double, flush: Bool)
        -> (confirmed: [TranscribedSegment], tentative: String, consumed: Double)
    {
        // ponytail: flush が音声の途中（25秒たまった時）だと文の途中で切れることがある。
        if flush { return (segments, "", bufferSeconds) }
        let confirmed = Array(segments.dropLast())
        return (confirmed, segments.last?.text ?? "", confirmed.last?.end ?? 0)
    }

    private static func segment(_ s: TranscriptionSegment) -> TranscribedSegment? {
        let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : TranscribedSegment(start: Double(s.start), end: Double(s.end), text: text)
    }

    private static func folder(_ variant: String) -> URL {
        HubApiWrapper(downloadBase: downloadBase)
            .localRepoLocation(.init(id: "argmaxinc/whisperkit-coreml"))
            .appending(path: variant)
    }

    private static func load(_ variant: String) async throws -> WhisperKit {
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder(variant).path, tokenizerFolder: downloadBase,
            verbose: false, load: true, download: false))
        if let tokenizer = kit.tokenizer {
            kit.textDecoder.logitsFilters = [PromptTimestampFilter(tokenizer: tokenizer)]
        }
        return kit
    }

    private static func holder(_ variant: String) -> ModelHolder<WhisperKit> {
        ModelHolder(load: { try await load(variant) }, unload: { await $0.unloadModels() })
    }

    private func decodingOptions(_ options: TranscriptionOptions, fallbacks: Int) async -> DecodingOptions {
        let language = options.language.whisperCode
        return DecodingOptions(
            language: language,
            temperatureFallbackCount: fallbacks,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            promptTokens: await promptTokens(options.glossary))
    }

    /// 用語集を initial prompt 用のトークン列にする（D4）。トークナイザーがないときは nil。
    private func promptTokens(_ text: String) async -> [Int]? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if tokenizer == nil {
            // 2つのモデルは同じトークナイザーを使う。なければ Hugging Face から取得する（数 MB）。
            tokenizer = try? await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: Self.downloadBase)
        }
        guard let tokenizer else { return nil }
        return text.isEmpty ? [] : tokenizer.encode(text: " " + text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }
}


/// prompt（用語集）を付けると large-v3-turbo は文ごとの時刻を出さなくなり、ライブで確定行を切れない。
/// prompt があるときだけ、文末の直後に時刻トークンを強制して区間を切らせる。
/// あわせて WhisperKit 1.1.1 の `TimestampRulesFilter` は prompt があると働かない（先頭3トークンに task を
/// 探すため）ので、prompt を除いたトークン列でかけ直す。
struct PromptTimestampFilter: LogitsFiltering {
    let specialTokens: SpecialTokens
    private var sentenceEnds = Set<Int>(), dots = Set<Int>(), digits = Set<Int>()

    init(tokenizer: any WhisperTokenizer) {
        specialTokens = tokenizer.specialTokens
        for id in 0..<specialTokens.specialTokenBegin {
            let text = tokenizer.decode(tokens: [id])
            guard let last = text.last else { continue }
            if "。？！?!.".contains(last) { sentenceEnds.insert(id) }
            if last == "." { dots.insert(id) }
            if last.isNumber { digits.insert(id) }
        }
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        // 先頭の4つ（<|startoftranscript|> 言語 task <|0.00|>）より後ろが生成された部分。
        guard tokens.first == specialTokens.startOfPreviousToken,
              let start = tokens.firstIndex(of: specialTokens.startOfTranscriptToken), tokens.count > start + 4
        else { return logits }
        let last = tokens[tokens.count - 1], previous = tokens[tokens.count - 2]
        // ponytail: "0.5" の小数点は直前が数字かどうかで除く。"e.g." などの略語では余分に切れる。
        if sentenceEnds.contains(last), !(dots.contains(last) && digits.contains(previous)) {
            logits.fillLastDimension(indexes: 0..<specialTokens.timeTokenBegin, with: -.infinity)
        }
        return TimestampRulesFilter(specialTokens: specialTokens, sampleBegin: 4, maxInitialTimestampIndex: nil, isModelMultilingual: true)
            .filterLogits(logits, withTokens: Array(tokens[start...]))
    }
}
