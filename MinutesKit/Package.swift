// swift-tools-version: 6.2
// Minutes の処理部分。UI から切り離して、確認用の CLI（diarize / transcribe / tidy）でも動かせる。
import PackageDescription

let package = Package(
    name: "MinutesKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
        .library(name: "Tidying", targets: ["Tidying"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        .executable(name: "diarize", targets: ["diarize"]),
        .executable(name: "transcribe", targets: ["transcribe"]),
        .executable(name: "tidy", targets: ["tidy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.11.0"),
    ],
    targets: [
        // 話者分離: Nemotron-3-Diarization（Core ML）
        .target(name: "Diarization"),
        // 文字起こし: Whisper large-v3（mlx_whisper の移植、MLX）
        .target(name: "Transcription", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // 録音の処理の流れ（話者分離 → 無音で区切りながら文字起こし → 話者の割り当て）と、結果のデータ
        .target(name: "MinutesCore", dependencies: ["Diarization", "Transcription"]),
        // 発言の整形: つなぎ言葉などを決まりと Gemma 4 E2B（テキスト専用、MLX）で消す
        .target(name: "Tidying", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // モデルの取得: Hugging Face からリビジョンを固定して取ってくる（アプリの初回と、CLI）
        .target(name: "ModelStore", dependencies: [.product(name: "HuggingFace", package: "swift-huggingface")]),
        .executableTarget(name: "diarize", dependencies: ["Diarization", "ModelStore"]),
        .executableTarget(name: "transcribe", dependencies: ["MinutesCore", "ModelStore", .product(name: "MLX", package: "mlx-swift")]),
        .executableTarget(name: "tidy", dependencies: ["Tidying", "MinutesCore", "ModelStore"]),
    ]
)
