import Foundation
import ModelStore

/// モデルの取得と、文字起こしのモデルの選択。そろうまでは録音を処理できないので、画面はこの案内を出す（ModelSetupView）
@Observable
final class ModelSetup {
    enum State: Equatable {
        case ready
        /// 取得が要る（bytes は取得する大きさ。調べ終わるまでは nil）
        case needed(bytes: Int64?)
        case downloading(Double)
        case failed(String)
    }

    private static let whisperKey = "whisper.model"

    private(set) var state: State
    private(set) var store: ModelStore
    private var task: Task<Void, Never>?

    /// 文字起こしのモデル（設定で選ぶ。既定は turbo）。選び直すと、未取得ならダウンロードの案内に戻る
    var whisper: ModelStore.Whisper {
        didSet {
            guard whisper != oldValue else { return }
            UserDefaults.standard.set(whisper.rawValue, forKey: Self.whisperKey)
            task?.cancel()
            task = nil
            store = Self.makeStore(whisper)
            state = store.isComplete ? .ready : .needed(bytes: nil)
            if state != .ready { Task { await measure() } }
        }
    }

    init() {
        let whisper = UserDefaults.standard.string(forKey: Self.whisperKey).flatMap(ModelStore.Whisper.init) ?? .turbo
        let store = Self.makeStore(whisper)
        self.whisper = whisper
        self.store = store
        state = store.isComplete ? .ready : .needed(bytes: nil)
        if state != .ready { Task { await measure() } }
    }

    private static func makeStore(_ whisper: ModelStore.Whisper) -> ModelStore {
        #if DEBUG
        ModelStore(whisper: whisper)  // 開発中は Hugging Face の標準のキャッシュ（CLI と共有する）
        #else
        ModelStore(cacheDirectory: .applicationSupportDirectory.appending(path: "Minutes/Models"), whisper: whisper)
        #endif
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard task == nil else { return }
        state = .downloading(0)
        let store = store, whisper = whisper
        task = Task {
            do {
                try await store.download { [weak self] p in
                    if self?.whisper == whisper { self?.state = .downloading(p) }
                }
                guard self.whisper == whisper else { return }  // 取得中に選び直した
                state = .ready
            } catch where Task.isCancelled {  // 止めたか、選び直した（取得を終えたファイルは次に使い回す）
                guard self.whisper == whisper else { return }
                state = .needed(bytes: nil)
                task = nil
                await measure()
                return
            } catch {
                guard self.whisper == whisper else { return }
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    private func measure() async {
        let bytes = try? await store.downloadSize()
        if case .needed = state { state = .needed(bytes: bytes) }
    }
}
