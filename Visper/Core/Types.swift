import Foundation

enum AudioSource: String, CaseIterable, Identifiable {
    case mic, system, both
    var id: Self { self }
    var label: String {
        switch self {
        case .mic: "マイク"
        case .system: "システム音声"
        case .both: "両方"
        }
    }
}

enum TranscriptLanguage: String, CaseIterable, Identifiable {
    case ja, en, auto
    var id: Self { self }
    var label: String {
        switch self {
        case .ja: "日本語"
        case .en: "English"
        case .auto: "自動"
        }
    }
    /// Whisper の言語コード。自動判定のときは nil。
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

enum SessionStatus: String {
    /// 録音中。起動時にこの状態が残っていれば異常終了したセッション。
    case recording
    /// 録音済みで、large-v3 の最終パス待ち。本文はライブ版。
    case pendingFinal
    case done
    /// 最終パスに失敗。本文はライブ版のまま。
    case finalFailed
}

struct TranscribedSegment: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct LiveUpdate: Sendable, Equatable {
    /// 前回の更新以降に新しく確定した行（追記する）。
    var confirmed: [TranscribedSegment]
    /// まだ確定していない認識中の文字列（毎回置き換える）。
    var tentative: String
}

struct TranscriptionOptions: Sendable, Equatable {
    var language: TranscriptLanguage
    var glossary: String
}

enum ModelState: Equatable, Sendable {
    case notReady
    case downloading(Double)
    case ready
    case failed(String)
}

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    var uid: String
    var name: String
    var id: String { uid }
}

/// 実機で調整する値はここにまとめる。
enum Tuning {
    /// ライブ文字起こしで1回に処理する音声の区切り（秒）。短いほど遅延は減るが負荷が上がる。
    static let liveChunkSeconds = 2.0
    static let defaultUnloadMinutes = 5
    /// Whisper の initial prompt に入るトークン数の上限。
    static let glossaryTokenLimit = 224
    static let sampleRate = 16_000.0
}

enum SettingsKey {
    static let glossary = "glossary"
    static let unloadMinutes = "unloadMinutes"
    static let micDeviceUID = "micDeviceUID"
    static let lastSource = "lastSource"
    static let lastLanguage = "lastLanguage"
}

enum AudioStore {
    static var directory: URL = URL.applicationSupportDirectory.appending(path: "Audio")

    static func url(for fileName: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: fileName)
    }
}

/// 83 → "00:01:23"
func formatTimestamp(_ seconds: TimeInterval) -> String {
    Duration.seconds(Int(seconds)).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2)))
}
