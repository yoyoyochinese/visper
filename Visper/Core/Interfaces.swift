import Foundation

/// 音声の取り込みと録音ファイルの書き出し。
protocol AudioCapturing: AnyObject {
    func inputDevices() -> [AudioInputDevice]

    /// 取り込みを開始する。16 kHz モノラルの Float サンプルを流し、同時に `url`（.caf）へ
    /// 逐次書き出す。このファイルはプロセスが強制終了されても読める状態を保つこと。
    /// `micDeviceUID` が nil のときは既定の入力デバイス。
    func start(source: AudioSource, micDeviceUID: String?, recordingTo url: URL) async throws -> AsyncStream<[Float]>

    /// 取り込みを止めてストリームを終了し、再生用の音声ファイル（.m4a）の URL を返す。
    /// 録音中に取り込みや書き込みが失敗した場合、実装はその時点でストリームを終了する。
    /// その後の `stop()` は、そこまでの録音を可能なら .m4a に変換したうえで、保存しておいたエラーを投げる。
    func stop() async throws -> URL

    /// 異常終了で残った録音ファイルを再生用ファイルに変換する。使えなければ nil。
    func recover(recordingAt url: URL) async -> URL?
}

/// Whisper による文字起こし。実装は @Observable にして `modelState` を画面から監視できるようにする。
@MainActor
protocol Transcribing: AnyObject {
    var modelState: ModelState { get }

    /// 2つのモデルを必要ならダウンロードする。進捗は `modelState` に反映。
    func prepareModels() async

    /// ライブ文字起こし。`audio` が終了したら、残りの文字列をすべて確定行として流してから終了する。
    func live(audio: AsyncStream<[Float]>, options: TranscriptionOptions) -> AsyncThrowingStream<LiveUpdate, Error>

    /// 録音ファイル全体を large-v3 で文字起こしする。Task のキャンセルに速やかに応じること。
    func finalPass(audioFile: URL, options: TranscriptionOptions) async throws -> [TranscribedSegment]

    /// 用語集の上限判定用（`Tuning.glossaryTokenLimit` と比べる）。
    func tokenCount(of text: String) async -> Int
}
