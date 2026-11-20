import AppKit
import XCTest

/// 固定データと偽のエンジン（`-uiTesting`）で各画面を操作する（D31）。
class VisperUITestCase: XCTestCase {
    let app = XCUIApplication()
    let firstTitle = "量子誤り訂正の輪講"
    let secondTitle = "超伝導量子ビットの進捗報告"

    override func setUp() {
        continueAfterFailure = false
    }

    func launch(_ extra: [String] = []) {
        app.launchArguments = ["-uiTesting"] + extra
        app.launch()
        XCTAssertTrue(sessionTitles.firstMatch.waitForExistence(timeout: 10))
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func elements(_ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    var sessionTitles: XCUIElementQuery { elements("sessionTitle") }

    func sessionTitle(_ text: String) -> XCUIElement {
        sessionTitles.matching(NSPredicate(format: "value == %@ OR label == %@", text, text)).firstMatch
    }

    func waitFor(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("待っても成立しない: \(description)") }
            usleep(200_000)
        }
    }

    /// 指定した要素を含むウィンドウを撮って、テスト結果に添付する。テストランナーはリポジトリに
    /// 書けないので、`screenshots/` へは次のように取り出す:
    /// `xcrun xcresulttool export attachments --path build/Logs/Test/<最新>.xcresult --output-path <出力先>`
    func saveScreenshot(_ name: String, windowContaining id: String) {
        save(app.windows.containing(.any, identifier: id).firstMatch.screenshot(), as: name)
    }

    func save(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// IME の状態に左右されないよう、日本語は貼り付けで入力する。
    func paste(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
    }
}

final class MainWindowUITests: VisperUITestCase {
    func testListShowsSessionsAndTranscript() {
        launch()
        XCTAssertEqual(sessionTitles.count, 2)
        XCTAssertTrue(sessionTitle(firstTitle).exists)
        XCTAssertTrue(sessionTitle(secondTitle).exists)
        XCTAssertEqual(app.windows.count, 1, "ライブ用のテスト窓は -lyricsWindow のときだけ")

        sessionTitle(firstTitle).click()
        XCTAssertTrue(element("transcriptLine").waitForExistence(timeout: 5))
        XCTAssertEqual(elements("transcriptLine").count, 6)
        for id in ["copyButton", "exportButton", "deleteButton"] {
            XCTAssertTrue(element(id).exists, id)
            XCTAssertTrue(element(id).isEnabled, id)
        }
        XCTAssertTrue(element("playButton").exists)
        XCTAssertFalse(element("provisionalNotice").exists)
    }

    func testSearchFilters() {
        launch()
        let field = app.searchFields.firstMatch
        field.click()
        paste("輪講", into: field)
        waitFor("タイトルで絞り込み") { sessionTitles.count == 1 }
        XCTAssertTrue(sessionTitle(firstTitle).exists)

        paste("報告 3", into: field)
        waitFor("本文で絞り込み") { sessionTitles.count == 1 && sessionTitle(secondTitle).exists }

        paste("surface", into: field)
        waitFor("両方に含まれる語") { sessionTitles.count == 2 }

        paste("zzz", into: field)
        waitFor("該当なし") { sessionTitles.count == 0 }
    }

    func testRename() {
        launch()
        sessionTitle(firstTitle).click()
        let field = element("titleField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed\n")
        waitFor("一覧に新しいタイトル") { sessionTitle("Renamed").exists }
        XCTAssertFalse(sessionTitle(firstTitle).exists)
        XCTAssertEqual(sessionTitles.count, 2)
    }

    func testDelete() {
        launch()
        sessionTitle(secondTitle).click()
        element("deleteButton").click()
        let confirm = element("confirmDelete")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        waitFor("1件に減る") { sessionTitles.count == 1 }
        XCTAssertTrue(sessionTitle(firstTitle).exists)
        XCTAssertFalse(element("transcriptLine").exists)
    }
}

final class SettingsUITests: VisperUITestCase {
    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("glossaryEditor").waitForExistence(timeout: 5))
    }

    func testFourControls() {
        launch(["-glossary", "トランズモン、surface code、デコヒーレンス"])
        openSettings()
        for id in ["glossaryEditor", "unloadStepper", "launchAtLoginToggle", "micDevicePicker"] {
            XCTAssertTrue(element(id).exists, id)
        }
        XCTAssertTrue(element("glossaryCount").exists)
        XCTAssertFalse(element("glossaryWarning").exists)
    }

    func testDisconnectedMicStaysSelected() {
        launch(["-micDeviceUID", "gone-device"])
        openSettings()
        let value = element("micDevicePicker").value as? String ?? ""
        XCTAssertTrue(value.contains("未接続"), "選択中の表示: \(value)")
    }

    func testGlossaryOverLimitWarning() {
        // 偽の tokenCount は文字数を返す。上限は 224。
        launch(["-glossary", String(repeating: "量", count: 225)])
        openSettings()
        XCTAssertTrue(element("glossaryWarning").waitForExistence(timeout: 5))
    }
}

/// メニューバーの中身を通常ウィンドウに載せて確かめる（`-lyricsWindow`）。
final class LyricsUITests: VisperUITestCase {
    private var lines: XCUIElementQuery { elements("lyricsLine") }
    private var state: String { element("recordingState").value as? String ?? "" }

    private func launchLyrics() {
        launch(["-lyricsWindow"])
        XCTAssertTrue(element("startStopButton").waitForExistence(timeout: 10))
    }

    func testStartStopCreatesFinalizedSession() {
        launchLyrics()
        XCTAssertEqual(state, "待機中")
        XCTAssertTrue(element("startStopButton").isEnabled)
        XCTAssertEqual(lines.count, 0)

        element("startStopButton").click()
        waitFor("録音中になる") { state == "録音中" }
        waitFor("1行目が出る") { lines.count >= 1 }
        waitFor("行が増える") { lines.count >= 3 }
        XCTAssertEqual(sessionTitles.count, 3)
        XCTAssertEqual(elements("sessionStatus").firstMatch.value as? String, "録音中")

        element("startStopButton").click()
        waitFor("待機中に戻る") { state == "待機中" }
        waitFor("仕上げが終わる") { elements("sessionStatus").count == 0 }
        XCTAssertEqual(sessionTitles.count, 3)

        // 新しいセッションが一番上。本文は最終パスの6行に置き換わっている。
        sessionTitles.element(boundBy: 0).click()
        waitFor("最終版の本文") { elements("transcriptLine").count == 6 }
        XCTAssertFalse(element("provisionalNotice").exists)
    }

    func testAutoFollowAndJumpToLatest() {
        launchLyrics()
        let scroll = element("lyricsScroll")
        func newestVisible() -> Bool {
            scroll.frame.intersects(lines.element(boundBy: lines.count - 1).frame)
        }

        element("startStopButton").click()
        waitFor("画面からあふれる行数", timeout: 40) { lines.count >= 18 }
        XCTAssertTrue(newestVisible(), "最新行に追従している")
        XCTAssertFalse(scroll.frame.intersects(lines.element(boundBy: 0).frame), "最初の行は上に流れた")
        XCTAssertFalse(element("jumpToLatest").exists)

        scroll.scroll(byDeltaX: 0, deltaY: 300)
        XCTAssertTrue(element("jumpToLatest").waitForExistence(timeout: 5), "手動スクロールで追従が止まる")
        let count = lines.count
        waitFor("止まっている間も行は増える") { lines.count >= count + 2 }
        XCTAssertFalse(newestVisible(), "追従していない")
        XCTAssertTrue(element("jumpToLatest").exists)

        element("jumpToLatest").click()
        waitFor("最新へ戻る") { !element("jumpToLatest").exists && newestVisible() }
        let resumed = lines.count
        waitFor("追従が再開する") { lines.count >= resumed + 2 }
        XCTAssertTrue(newestVisible())

        element("startStopButton").click()
        waitFor("待機中に戻る") { state == "待機中" }
    }
}

/// 目視確認用のスクリーンショット（D31）。撮影できない環境でも動作のテストを落とさないよう、ここに分けてある。
final class ScreenshotUITests: VisperUITestCase {
    func testMainWindow() {
        launch()
        sessionTitle(firstTitle).click()
        XCTAssertTrue(element("transcriptLine").waitForExistence(timeout: 5))
        saveScreenshot("main", windowContaining: "sessionTitle")
    }

    func testSettings() {
        launch(["-glossary", "トランズモン、surface code、デコヒーレンス"])
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("glossaryEditor").waitForExistence(timeout: 5))
        saveScreenshot("settings", windowContaining: "glossaryEditor")
    }

    func testLyricsWhileRecording() {
        launch(["-lyricsWindow"])
        XCTAssertTrue(element("startStopButton").waitForExistence(timeout: 10))
        element("startStopButton").click()
        waitFor("画面からあふれる行数", timeout: 40) { elements("lyricsLine").count >= 18 }
        saveScreenshot("lyrics", windowContaining: "lyricsScroll")
        save(XCUIScreen.main.screenshot(), as: "screen-recording")
        element("startStopButton").click()
    }
}
