import Foundation

/// モデル1つの読み込みと解放（D7）。最後の利用が終わってから `delay` 後に解放し、次の利用で読み直す。
@MainActor
final class ModelHolder<Model> {
    private let load: () async throws -> Model
    private let unload: (Model) async -> Void
    private let delay: () -> Duration
    private var model: Model?
    private var users = 0
    private var timer: Task<Void, Never>?

    /// `delay` はタイマーを仕掛けるたびに呼ばれる。既定は設定の分数。
    init(
        load: @escaping () async throws -> Model,
        unload: @escaping (Model) async -> Void,
        delay: @escaping () -> Duration = {
            .seconds(60 * (UserDefaults.standard.object(forKey: SettingsKey.unloadMinutes) as? Int ?? Tuning.defaultUnloadMinutes))
        }
    ) {
        self.load = load
        self.unload = unload
        self.delay = delay
    }

    /// モデルを使う。`body` の実行中は解放されない。
    func use<T>(_ body: @MainActor (Model) async throws -> T) async throws -> T {
        users += 1
        timer?.cancel()
        defer {
            users -= 1
            if users == 0 { arm() }
        }
        // ponytail: 読み込み中に別の use が重なると二重に読み込む。呼び出し側（ライブ1本、最終パスは直列）では
        // 起きない。並行利用が要るなら読み込みを Task にして共有する。
        if model == nil { model = try await load() }
        // 読み込み中に中断されたら body は走らせない。読み込んだモデルは残し、タイマーで解放する。
        try Task.checkCancellation()
        return try await body(model!)
    }

    /// 分数の設定を変えても、すでに動いているタイマーには効かない。次の利用が終わった時から新しい値になる。
    private func arm() {
        let delay = delay()
        timer = Task {
            guard (try? await Task.sleep(for: delay)) != nil, users == 0, let model else { return }
            self.model = nil
            await unload(model)
        }
    }
}
