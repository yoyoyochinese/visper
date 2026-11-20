import Foundation
import Observation
import SwiftData
import UserNotifications

/// 部品の組み立て。実装とテスト用の偽物の切り替えはここだけで行う。
@MainActor
@Observable
final class AppEnvironment {
    /// UI テストから `-uiTesting` 付きで起動されたとき。固定データと偽のエンジンで動く。
    static let isUITesting = CommandLine.arguments.contains("-uiTesting")
    static let isUnitTesting = NSClassFromString("XCTestCase") != nil

    let container: ModelContainer
    let audio: AudioCapturing
    let transcriber: Transcribing
    let controller: SessionController

    init() {
        let fake = Self.isUITesting || Self.isUnitTesting
        container = try! ModelContainer(
            for: Session.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: fake))
        // 統合時に実装へ差し替える: SystemAudioCapture / WhisperEngine
        audio = FakeAudioCapture()
        transcriber = ScriptedTranscriber(liveScript: Self.longScript, finalScript: Self.demoScript, lineInterval: 1, finalDelay: 1)
        controller = SessionController(audio: audio, transcriber: transcriber, context: container.mainContext)

        if Self.isUITesting {
            AudioStore.directory = FileManager.default.temporaryDirectory.appending(path: "VisperUITest")
            seed()
        }
        guard !fake else { return }
        controller.onFinalized = { session in
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "文字起こしが完了しました"
            content.body = session.title
            Task {
                guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
                try? await center.add(UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil))
            }
        }
        Task {
            await controller.recoverInterrupted()
            await transcriber.prepareModels()
        }
    }

    static let demoScript = [
        "それでは今日のゼミを始めます。",
        "トランズモン量子ビットのデコヒーレンスについて話します。",
        "T1 は約 100 マイクロ秒、T2 エコーはその半分程度でした。",
        "次に surface code の論理エラー率を見ていきます。",
        "符号距離を 3 から 5 に上げるとエラー率が下がります。",
        "質問があればどうぞ。",
    ]

    /// 自動スクロールを確かめられる長さ（30行）。
    static let longScript = Array(repeating: demoScript, count: 5).flatMap { $0 }

    private func seed() {
        let day: TimeInterval = 86_400
        for (i, title) in ["量子誤り訂正の輪講", "超伝導量子ビットの進捗報告"].enumerated() {
            let session = Session(source: .mic, language: .ja, startedAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(i) * day))
            session.title = title
            session.duration = 30
            session.status = .done
            container.mainContext.insert(session)
            session.append(Self.demoScript.enumerated().map {
                TranscribedSegment(start: Double($0) * 5, end: Double($0) * 5 + 5, text: i == 0 ? $1 : "報告 \($0 + 1): \($1)")
            })
        }
        try? container.mainContext.save()
    }
}
