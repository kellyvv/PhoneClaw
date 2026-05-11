# MiniCPM-V 集成跟进文档

> 本文档跟踪 PhoneClaw 集成 OpenBMB MiniCPM-V 多模态模型的进度和决策。
> 目标版本: v1.4.0
> Branch: `feature/minicpm-v`

---

## 背景

PhoneClaw 当前 (v1.3.2) 只跑 Google Gemma 4 (LiteRT-LM runtime, `.litertlm` 格式)。
MiniCPM-V 用 GGUF 格式 + llama.cpp 推理 + 自定义 mtmd (multimodal) C API,
原生支持图像 + 视频帧理解, **ANE 加速 vision tower 是他们的关键优化**
(SigLIP2 编码器跑在 iPhone Neural Engine 上而不是 GPU/CPU)。

参考代码: https://github.com/OpenBMB/MiniCPM-V-Apps (Apache-style)

---

## 已就绪的基础设施 (这个 commit)

| 内容 | 路径 |
|---|---|
| llama.xcframework (iOS-only slices, 29 MB) | `Frameworks/llama.xcframework` |
| MTMDWrapper Swift 类 (4 个文件) | `Sources/PhoneClawEngine/MTMD/` |
| Package.swift 接入 llama + 开 C++ interop | `Package.swift` |

llama.xcframework 来自 OpenBMB demo, 含他们的 fork llama.cpp + 自定义
mtmd-ios C API。Module 名 `llama`, Swift 直接 `import llama` 就能拿到所有 symbol。

`MTMD/` 下 4 个 Swift 文件直接拷自 demo, **未做修改** — 后续如果上游 demo
更新 API 我们能 diff 同步。MTMDWrapper 是个 @MainActor / ObservableObject,
有 416 行, 封装了 init / decode / cancel / cleanup 完整生命周期。

---

## Phase 1: Backend 抽象 + MiniCPM-V backend 接通

**目标**: app 跑起来能选 MiniCPM-V 4.6, 文本聊天通路打通 (先不管视觉)。

### 1.1 抽 InferenceBackend protocol

当前 `LLM/Backends/LiteRT/LiteRTBackend.swift` 直接实现 `InferenceService` 协议
(在 `LLM/Core/` 下)。需要在 backend 层再加一层 `InferenceBackend`,
让 LiteRT 和 MiniCPM-V 都实现它, 上层 `LiteRTService` (或重命名为
`InferenceService`) 持有一个 `InferenceBackend` 而不是写死 LiteRT。

接口大致:
```swift
protocol InferenceBackend: AnyObject {
    func load(modelID: String, mode: EngineMode) async throws
    func unload() async
    func generateStream(prompt: String, ...) -> AsyncThrowingStream<String, Error>
    var isLoaded: Bool { get }
    var memoryFootprintMB: Int { get }
}
```

### 1.2 写 MiniCPMVBackend.swift

`LLM/Backends/MiniCPMV/MiniCPMVBackend.swift` (新增 ~250 行)。

内部持有一个 `MTMDWrapper`, 把 `InferenceBackend` 协议方法转发过去:
- `load` → `MTMDWrapper.initialize(with: MTMDParams)`
- `generateStream` → `MTMDWrapper.generate(prompt:)` + 桥接 @Published `currentToken` 到 AsyncThrowingStream
- `unload` → `MTMDWrapper.cleanup()`

注意 MTMDWrapper 是 @MainActor, 我们的 stream consumer 在后台 task,
需要小心 actor isolation —— 可能要在 backend 层加一层 `MainActor.run { ... }` 包装。

### 1.3 PredefinedModels.swift 加 MiniCPM-V 条目

添加 3 个 ModelDescriptor (v2.6 / v4.0 / v4.6), 但每个有 **3 个文件**
(LLM gguf + mmproj gguf + ANE mlmodelc.zip), 跟现有的"单文件 .litertlm"模式不同。

需要扩展 `ModelDescriptor` 数据结构:
```swift
public enum ArtifactKind {
    case litertlmFile                       // 现有: 单文件 .litertlm
    case ggufBundle(ANEAccelerator)         // 新增: 多文件 gguf + 可选 ANE
}

public enum ANEAccelerator {
    case none
    case coreMLZip(downloadURL: URL, expectedSHA: String?)
}
```

并相应改 `LiteRTModelStore.artifactPath()` 让它能返回"主文件路径"还是
"完整的多文件 bundle 信息", 给两种 backend 各取所需。

下载 URL 参考 OpenBMB demo 的 `MiniCPMModelConst.swift`:
- v4.6 主模型: `https://data-transfer-huawei.obs.cn-north-4.myhuaweicloud.com/minicpmv46-instruct/MiniCPM-V-4_6-Q4_K_M.gguf`
- v4.6 mmproj: `https://data-transfer-huawei.obs.cn-north-4.myhuaweicloud.com/minicpmv46-instruct/mmproj-model-f16.gguf`
- v4.6 ANE zip: `https://data-transfer-huawei.obs.cn-north-4.myhuaweicloud.com/minicpmv46-instruct/coreml_minicpmv46_vit_all_f32.mlmodelc.zip`

(华为云中转, HF 也有, 但 demo 用华为云为国内用户优化速度)

### 1.4 下载器扩展支持 GGUF bundle

`ResumableAssetDownloader` 现在按单文件 asset 设计。MiniCPM-V 需要:
- 多文件并发下载 (3 个文件)
- ANE zip 下载完后自动解压
- 进度条聚合 3 个文件总进度

可以走两种路径:
- **A**: 把 3 个文件作为 1 个 `DownloadAsset` 的 3 个 `DownloadFile` (asset 数据结构已经支持多文件)
- **B**: 在 `LiteRTModelStore` 上层把 3 个 asset 当成 1 个"模型包" 调用 3 次 download API

A 更优雅, asset 结构原本就为多文件而设计。

### 1.5 验收点

- 设置页能看到 MiniCPM-V 4.6 条目
- 点下载, 3 个文件并发开始, 进度条聚合显示
- mlmodelc.zip 完成后自动解压到 Documents
- 切换到 MiniCPM-V 4.6, 模型加载成功
- 输入 "你好" → 流式吐出中文回复

**Phase 1 估算: 3-5 天**

---

## Phase 2: 视觉 + 视频通路

### 2.1 接图片输入

MTMDWrapper 已经支持图片输入 (mtmd_ios C API), 需要:
- 在 PhoneClaw 现有 chat UI 的"附件" 流程里, 把图片转成 MTMDWrapper 能吃的格式
- 验证 Gemma 4 现有的图片 prompt template 是否能复用, 还是要 MiniCPM-V 专属

### 2.2 视频帧采样 (v4.6 强项)

v4.6 主打视频理解。MTMDParams 里 `imageMaxSliceNums` 控制单帧切片数,
`nCtx = 8192` 是视频路径推荐值 (避免 KV 溢出)。

UI 需要:
- 视频文件 / 实时摄像头帧 → AVFoundation 抽帧
- 帧采样策略选择器 (`max_num_frames` 1~128)
- 图片切片数滑条 (1~9, 1 最快但丢细节)

参考 demo 的 `MBLiveCaptureVideoFrameManager.swift` 和
`MBHomeViewController+CaptureVideo.swift`。

### 2.3 验收点

- 拍照 → MiniCPM-V 描述图片内容
- 选视频 → MiniCPM-V 总结视频内容
- 实时摄像头 → 流式 "看到什么" 描述 (live mode)

**Phase 2 估算: 1 周**

---

## Phase 3: UX 整合 + 发布准备

### 3.1 配置页改造

模型选择按 backend 分组:
```
通用对话 / Gemma 4
  ○ Gemma 4 E2B (轻量, 推荐 Sideloadly)
  ○ Gemma 4 E4B (推理强, 仅 Xcode 自签)

视觉多模态 / MiniCPM-V
  ○ MiniCPM-V 4.6 (视频理解, 1.6 GB)
  ○ MiniCPM-V 4.0 (经典, 2.9 GB)
  ○ MiniCPM-V 2.6 (8B 大模型, 5.4 GB, 仅 Xcode 自签)
```

### 3.2 性能基线测试

跟 Gemma 4 做横向对比:
- 文本聊天 tok/s (E2B / E4B / MiniCPM-V 4.6)
- 首图理解延迟
- 内存峰值 / headroom 全程
- Sideloadly 签名兼容性 (E4B 跑不了, MiniCPM-V 4.6 应该可以)

### 3.3 文档 + Release Notes

- README.md / README_EN.md 加 MiniCPM-V 支持说明
- v1.4.0 release notes
- 配置页文案对每个模型的能力边界写清楚

**Phase 3 估算: 2-3 天**

---

## 已知风险 / 待解决

1. **C++ interop 兼容性**: 整个 PhoneClawEngine target 开 .Cxx 后, 现有
   LiteRT-LM wrapper 代码是否还能编译? 可能要分两个 target —
   `LiteRTEngine` (无 cxx) + `MTMDEngine` (有 cxx), 共用一个 product。

2. **ANE 模型大小**: mlmodelc.zip 几百 MB, 解压后更大。
   Documents 总占用要监控, 别超过用户存储。

3. **签名 app 内存**: MiniCPM-V 4.6 LLM 才 500 MB + mmproj 1.1 GB,
   理论上 sideloadly 用户能用 GPU。要实测确认。

4. **OpenBMB 上游更新**: 他们的 mtmd-ios C API 可能演进。我们的 MTMDWrapper
   是 v1.0 时刻的拷贝, 升级 llama.xcframework 时要同步检查 API 兼容性。
   建议在 `MTMD/` 下加一个 `UPSTREAM_VERSION.md` 记录拷贝时的 commit hash。

5. **License**: llama.cpp 是 MIT, OpenBMB 的 mtmd-ios 改动是 Apache 2.0,
   都跟 PhoneClaw 兼容。需要在 NOTICE / 关于页加引用。

---

## 上游版本锚定

本次 vendor 的 llama.xcframework 来自:
- Repo: `https://github.com/OpenBMB/MiniCPM-V-Apps`
- Commit at clone time: `1dc96d45b8bd0f17c2bbb137ceaa709877936b64` (2026-05-11)
- 拷贝日期: 2026-05-12

如果 mtmd-ios API 变化, 升级流程:
```bash
cd /tmp && git clone --depth=1 https://github.com/OpenBMB/MiniCPM-V-Apps.git
cp -R /tmp/MiniCPM-V-Apps/MiniCPM-V-demo/thirdparty/llama.xcframework \
      /Users/zxw/AITOOL/PhoneClaw/LocalPackages/PhoneClawEngine/Frameworks/
# Trim 到 ios slices (参考本次 commit 的 Info.plist 重生成)
# Diff MTMD/*.swift 跟 demo 的最新版本, 同步任何 breaking 改动
```
