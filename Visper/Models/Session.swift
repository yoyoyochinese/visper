import Foundation
import SwiftData

@Model
final class Session {
    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var sourceRaw: String
    var languageRaw: String
    var statusRaw: String
    /// `AudioStore.directory` 内のファイル名。録音中は .caf、停止後は .m4a。
    var audioFileName: String
    @Relationship(deleteRule: .cascade, inverse: \Segment.session)
    var segments: [Segment] = []

    init(source: AudioSource, language: TranscriptLanguage, startedAt: Date = .now) {
        let id = UUID()
        self.id = id
        self.title = startedAt.formatted(date: .numeric, time: .shortened)
        self.startedAt = startedAt
        self.duration = 0
        self.sourceRaw = source.rawValue
        self.languageRaw = language.rawValue
        self.statusRaw = SessionStatus.recording.rawValue
        self.audioFileName = "\(id.uuidString).caf"
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .done }
        set { statusRaw = newValue.rawValue }
    }

    var language: TranscriptLanguage { TranscriptLanguage(rawValue: languageRaw) ?? .ja }
    var audioURL: URL { AudioStore.url(for: audioFileName) }
    var sortedSegments: [Segment] { segments.sorted { $0.start < $1.start } }

    func append(_ new: [TranscribedSegment]) {
        for s in new {
            segments.append(Segment(start: s.start, end: s.end, text: s.text))
        }
    }
}

@Model
final class Segment {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var session: Session?

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
