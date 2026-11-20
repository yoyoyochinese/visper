import Foundation

extension Session {
    var markdown: String {
        let lines = sortedSegments.map { "- [\(formatTimestamp($0.start))] \($0.text)" }
        return """
        # \(title)

        - 日時: \(startedAt.formatted(date: .numeric, time: .shortened))
        - 長さ: \(formatTimestamp(duration))

        \(lines.joined(separator: "\n"))

        """
    }
}
