# PhoneClawEngine

Swift Package for on-device LLM inference on iOS GPU. Built around [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) with a native Metal-accelerated inference pipeline — runs entirely on GPU, no CPU fallback during sampling.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/kellyvv/PhoneClawEngine", from: "0.1.0"),
]
```

Then in your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["PhoneClawEngine"]
),
```

SPM auto-downloads the prebuilt xcframework (~29 MB zipped) from this repo's Releases on first resolve.

## Usage

```swift
import PhoneClawEngine

let engine = try LiteRTLMEngine()
try engine.load(modelPath: "/path/to/model.litertlm", backend: "gpu")

for try await chunk in engine.stream("Count from 1 to 5, one number per line.") {
    print(chunk, terminator: "")
}
```

Full API in [`Sources/PhoneClawEngine/PhoneClawEngine.swift`](Sources/PhoneClawEngine/PhoneClawEngine.swift).

## Framework embedding

When integrating into an iOS app, make sure the SPM package is set to **Embed & Sign** in your app target's "Frameworks, Libraries, and Embedded Content" section. Xcode handles the rest automatically.

## Requirements

| | |
|---|---|
| iOS | 17.0+ |
| Architectures | arm64 only (device + Apple-Silicon simulator) |
| Apple Developer account | Free tier works |

## Compatible models

Any `.litertlm` model that runs on LiteRT-LM's GPU backend. Tested primarily with Gemma-4 instruction variants.

Device memory footprint scales with model size; a 4 GB-class model generally needs ≥8 GB RAM headroom on the device.

## License

MIT on the Swift wrapper source in `Sources/`. Bundled runtime binaries are Apache 2.0 (derived from upstream LiteRT-LM). See [LICENSE](LICENSE).
