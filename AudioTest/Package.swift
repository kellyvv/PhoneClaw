// swift-tools-version: 6.0
import PackageDescription

// AudioTest — 独立的 Mac CLI, 验证 Gemma 4 MLX 模型的音频处理能力。
// 不依赖 PhoneClawCLI / AgentEngine / LiteRT (iOS-only), 用最短路径跑:
//   audio.mp3 → AVAudioFile decode → UserInput.Audio.pcm → MLXVLM → 输出

let package = Package(
    name: "AudioTest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/InferenceKit"),
        .package(path: "../Packages/mlx-swift"),
        .package(
            url: "https://github.com/DePasqualeOrg/swift-tokenizers",
            .upToNextMinor(from: "0.2.0")
        ),
    ],
    targets: [
        .executableTarget(
            name: "AudioTest",
            dependencies: [
                .product(name: "MLXLLM", package: "InferenceKit"),
                .product(name: "MLXVLM", package: "InferenceKit"),
                .product(name: "MLXLMCommon", package: "InferenceKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
            ],
            path: "Sources/AudioTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
