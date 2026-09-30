// アプリが使うモデルの置き場所と取得。モデルはアプリに同梱せず、初回に Hugging Face から取得する。
// リポジトリとリビジョン（コミット）を固定して、誰の Mac でも同じ重みで動くようにする。
// 置き場所は Hugging Face の標準のキャッシュの形（Python の huggingface_hub と同じ）で、
// 取得済みなら起動のたびにネットワークを使わない

import Foundation
import HuggingFace

public struct ModelStore: Sendable {
    /// Hugging Face のリポジトリの、使うファイル
    public struct Model: Sendable {
        public var repo: Repo.ID
        public var revision: String
        public var files: [String]
    }

    /// 話者分離: Nemotron-3-Diarization の Core ML 版（.mlpackage は初回の読み込みでコンパイルする）
    public static let diarizer = Model(
        repo: "altic-dev/nemotron-3-diarization-coreml", revision: "8976c3c40a752cd6468a08f2aa08626770bc048f",
        files: ["nemotron_3_diarization.mlpackage/Manifest.json",
                "nemotron_3_diarization.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                "nemotron_3_diarization.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                "learnable_sil_emb.f32"])
    /// 文字起こしのモデル（transformers の形式の重みを、読み込むときに MLX の形に読み替える）。
    /// turbo は large-v3 のデコーダーを 32 層から 4 層に減らしたもので、約 3 倍速くメモリも少ないが、聞き違いが増える
    public enum Whisper: String, CaseIterable, Sendable {
        case turbo, large

        public var model: Model {
            let files = ["config.json", "generation_config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
            return switch self {
            case .turbo: Model(repo: "openai/whisper-large-v3-turbo", revision: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9", files: files)
            case .large: Model(repo: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1", files: files)
            }
        }

        public var name: String {
            switch self {
            case .turbo: "Whisper large-v3-turbo"
            case .large: "Whisper large-v3"
            }
        }
    }

    /// 発言の整形: Gemma 4 E2B のテキスト専用版（MLX の int4）
    public static let tidier = Model(
        repo: "mlx-community/Gemma4-E2B-IT-Text-int4", revision: "61d85e83c959ac93109dc5be7104c8de9942ef66",
        files: ["config.json", "generation_config.json", "model.safetensors", "model.safetensors.index.json",
                "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"])

    /// 取得したモデルの場所
    public struct Paths: Sendable {
        public var diarizer: URL
        public var silenceEmbedding: URL
        public var whisper: URL
        public var tidier: URL
    }

    /// 使う文字起こしのモデル
    public let whisper: Whisper
    private let cache: HubCache
    private let client: HubClient

    /// cacheDirectory: モデルを置くフォルダ。nil なら Hugging Face の標準のキャッシュ（HF_HUB_CACHE か ~/.cache/huggingface/hub）
    public init(cacheDirectory: URL? = nil, whisper: Whisper = .turbo) {
        self.whisper = whisper
        cache = cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default
        // 公開のリポジトリだけなので、手元の Hugging Face のトークンは送らない
        client = HubClient(host: HubClient.defaultHost, cache: cache)
    }

    public var paths: Paths {
        let diarizer = folder(Self.diarizer)
        return Paths(diarizer: diarizer.appending(path: "nemotron_3_diarization.mlpackage"),
                     silenceEmbedding: diarizer.appending(path: "learnable_sil_emb.f32"),
                     whisper: folder(whisper.model), tidier: folder(Self.tidier))
    }

    /// 使うモデル（話者分離・文字起こし・整形）
    private var models: [Model] { [Self.diarizer, whisper.model, Self.tidier] }

    /// すべてのファイルがそろっているか（ネットワークは使わない）
    public var isComplete: Bool {
        models.allSatisfy(isComplete)
    }

    /// 足りないモデルを取得する。progress には取得済みの割合（0〜1、バイト数で重み付け）を渡す。
    /// 途中で止めても、取得を終えたファイルは次に使い回す
    public func download(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let missing = models.filter { !isComplete($0) }
        var sizes: [Int64] = []
        for model in missing { sizes.append(try await size(of: model)) }
        let total = Double(max(sizes.reduce(0, +), 1))
        var done = 0.0
        for (model, size) in zip(missing, sizes) {
            let base = done
            _ = try await client.downloadSnapshot(of: model.repo, revision: model.revision, matching: model.files) { p in
                progress((base + Double(size) * p.fractionCompleted) / total)
            }
            try Task.checkCancellation()
            done += Double(size)
        }
        await progress(1)
    }

    /// 取得するファイルの合計の大きさ（バイト）
    public func downloadSize() async throws -> Int64 {
        var total: Int64 = 0
        for model in models where !isComplete(model) { total += try await size(of: model) }
        return total
    }

    private func folder(_ model: Model) -> URL {
        cache.snapshotsDirectory(repo: model.repo, kind: .model).appending(component: model.revision)
    }

    private func isComplete(_ model: Model) -> Bool {
        let folder = folder(model)
        return model.files.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    private func size(of model: Model) async throws -> Int64 {
        let entries = try await client.listFiles(in: model.repo, kind: .model, revision: model.revision, recursive: true)
        return entries.filter { model.files.contains($0.path) }.reduce(0) { $0 + Int64($1.size ?? 0) }
    }
}

public extension ModelStore {
    /// CLI 用: 足りないモデルを取得して（進み具合は標準エラーに出す）、場所を返す
    func pathsDownloadingIfNeeded() async throws -> Paths {
        if !isComplete {
            FileHandle.standardError.write(Data("モデルを取得しています（初回のみ）…\n".utf8))
            try await download { FileHandle.standardError.write(Data(String(format: "\r%5.1f%%", $0 * 100).utf8)) }
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return paths
    }
}
