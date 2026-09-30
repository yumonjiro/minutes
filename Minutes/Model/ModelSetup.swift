import Foundation
import ModelStore

/// 初回のモデルの取得。そろうまでは録音を処理できないので、画面はこの案内を出す（ModelSetupView）
@Observable
final class ModelSetup {
    enum State: Equatable {
        case ready
        /// 取得が要る（bytes は取得する大きさ。調べ終わるまでは nil）
        case needed(bytes: Int64?)
        case downloading(Double)
        case failed(String)
    }

    private(set) var state: State
    let store: ModelStore
    private var task: Task<Void, Never>?

    init() {
        #if DEBUG
        store = ModelStore()  // 開発中は Hugging Face の標準のキャッシュ（CLI と共有する）
        #else
        store = ModelStore(cacheDirectory: .applicationSupportDirectory.appending(path: "Minutes/Models"))
        #endif
        state = store.isComplete ? .ready : .needed(bytes: nil)
        if state != .ready { Task { await measure() } }
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task {
            do {
                try await store.download { [weak self] in self?.state = .downloading($0) }
                state = .ready
            } catch where Task.isCancelled {  // 止めた（取得を終えたファイルは次に使い回す）
                state = .needed(bytes: nil)
                await measure()
            } catch {
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
