# LiteRT-LM 上游补丁归档

本目录是 PhoneClaw 对 LiteRT-LM (Google's iOS LLM 推理库) 的本地修改归档,
用于在 `LocalPackages/PhoneClawEngine/Frameworks/LiteRTLM.xcframework` 需要
重建时, 不丢失这两处关键 patch。

**当前 xcframework 已经把这些补丁编进去了** — 平时不需要做任何事。
此目录纯粹是 bus-factor 兜底, 给"未来某天需要升级 engine 或重建 dylib"的人。

---

## 上游基线

```
LiteRT-LM @ 0b48e5a (main HEAD, 2026-05)
"Fix flaky HW cache update kernel by adding dequantization support and robust validation."
```

clone:
```bash
git clone https://github.com/google-ai-edge/LiteRT-LM.git /tmp/LiteRT-LM
cd /tmp/LiteRT-LM && git checkout 0b48e5a
```

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `sampler_factory.cc` | **patched 完整文件** — 加了 Mach-O symbol walker, 解决 Google 官方 iOS sampler dylib 7 个 C ABI 入口只导出 3 个的问题 (其余 4 个是 hidden visibility, dlsym 抓不到 → 引擎走 fallback 慢路径 → MTP 反而比 baseline 慢)。覆盖到 `runtime/components/sampler_factory.cc`。 |
| `c-BUILD` | **patched 完整文件** — 在 `c/BUILD` 末尾加了 `cc_binary(name="libLiteRTLMEngine.dylib", ...)`, 把引擎打包成可独立分发的 dylib。覆盖到 `c/BUILD`。 |
| `litert-lm.patch` | 上面两处改动的合并 diff (相对 0b48e5a), 应用方式 `git apply litert-lm.patch`。 |
| `package-xcframework.sh` | 打包脚本: 把刚 build 出来的 device + sim dylib + 头文件 + 谷歌官方 Metal sampler dylib 组装成 `CLiteRTLM.xcframework`。 |

---

## 重建流程 (仅在需要更新 engine 版本时跑)

### 1. 准备上游

```bash
git clone https://github.com/google-ai-edge/LiteRT-LM.git /tmp/LiteRT-LM
cd /tmp/LiteRT-LM
git checkout <target-commit>     # 比如 0b48e5a, 或更新的 main HEAD
```

### 2. 应用补丁

二选一:

```bash
# 方法 A — 直接用 .patch
cd /tmp/LiteRT-LM
git apply <PhoneClaw>/LocalPackages/PhoneClawEngine/patches/litert-lm.patch
```

```bash
# 方法 B — 直接覆盖完整文件 (上游若与归档时大幅 drift, A 会失败, 用 B)
cp <PhoneClaw>/LocalPackages/PhoneClawEngine/patches/sampler_factory.cc \
   /tmp/LiteRT-LM/runtime/components/sampler_factory.cc
cp <PhoneClaw>/LocalPackages/PhoneClawEngine/patches/c-BUILD \
   /tmp/LiteRT-LM/c/BUILD
```

### 3. Bazel build (device + sim slice)

```bash
cd /tmp/LiteRT-LM

# Device (arm64)
bazel build -c opt --config=ios_arm64 \
  //c:libLiteRTLMEngine.dylib \
  //runtime/components:libLiteRtTopKMetalSampler.dylib \
  //runtime/components:libGemmaModelConstraintProvider.dylib \
  //runtime/accelerator:libLiteRtMetalAccelerator.dylib

mkdir -p /tmp/v3-dylibs/device
cp bazel-bin/c/libLiteRTLMEngine.dylib /tmp/v3-dylibs/device/
cp bazel-bin/runtime/components/libLiteRtTopKMetalSampler.dylib /tmp/v3-dylibs/device/
cp bazel-bin/runtime/components/libGemmaModelConstraintProvider.dylib /tmp/v3-dylibs/device/
cp bazel-bin/runtime/accelerator/libLiteRtMetalAccelerator.dylib /tmp/v3-dylibs/device/

# Simulator (arm64)
bazel build -c opt --config=ios_sim_arm64 \
  //c:libLiteRTLMEngine.dylib \
  //runtime/components:libGemmaModelConstraintProvider.dylib \
  //runtime/accelerator:libLiteRtMetalAccelerator.dylib

mkdir -p /tmp/v3-dylibs/sim
cp bazel-bin/c/libLiteRTLMEngine.dylib /tmp/v3-dylibs/sim/
cp bazel-bin/runtime/components/libGemmaModelConstraintProvider.dylib /tmp/v3-dylibs/sim/
cp bazel-bin/runtime/accelerator/libLiteRtMetalAccelerator.dylib /tmp/v3-dylibs/sim/
```

注意: **simulator slice 不打 sampler dylib** (sim 上跑不了 Metal verifier)。

### 4. 打 xcframework

```bash
cp <PhoneClaw>/LocalPackages/PhoneClawEngine/patches/package-xcframework.sh /tmp/v3-dylibs/
chmod +x /tmp/v3-dylibs/package-xcframework.sh
/tmp/v3-dylibs/package-xcframework.sh
```

脚本会**直接覆盖** `<PhoneClaw>/LocalPackages/PhoneClawEngine/Frameworks/LiteRTLM.xcframework/`。

### 5. 验证

```bash
# device slice 应该有 4 个 dylib
ls -la <PhoneClaw>/LocalPackages/PhoneClawEngine/Frameworks/LiteRTLM.xcframework/ios-arm64/CLiteRTLM.framework/

# 在 iPhone 上运行 PhoneClaw, 控制台应出现:
# > Resolved LiteRtTopKMetalSampler C API via Mach-O symbol walk (all 7 entry points).
```

---

## Mach-O walker 原理 (sampler_factory.cc 的核心 patch)

谷歌的 prebuilt iOS `libLiteRtTopKMetalSampler.dylib` 只在 exports trie 里
列了 3 个 symbol:
- `LiteRtTopKMetalSampler_Create`
- `LiteRtTopKMetalSampler_Destroy`
- `LiteRtTopKMetalSampler_SampleToIdAndScoreBuffer`

剩下 4 个 (`UpdateConfig`, `CanHandleInput`, `HandlesInput`,
`SetInputTensorsAndInferenceFunc`) 是 hidden visibility — 二进制里有,
但 `dlsym` 拿不到, 静态链接 `-l<lib>` 也找不到。

引擎逻辑: 如果 `CanHandleInput` 拿不到, 走 fallback 慢路径 (drafter forward
反复占满 GPU)。结果就是 MTP **比 baseline 还慢**。

绕过: 用 `_dyld_image_count` + `_dyld_get_image_header` + `_dyld_get_image_name`
找到加载的 dylib, 解析 Mach-O LC_SYMTAB + `__LINKEDIT` 段, 直接遍历
完整 symbol table (不仅仅是 export trie), 按 mangled name 找隐藏 symbol
的 vmaddr。同样的套路 Facebook 的 fishhook 用了多年。

修完之后控制台日志:
```
Resolved LiteRtTopKMetalSampler C API via Mach-O symbol walk (all 7 entry points).
```

引擎走 `sampler_handles_input` 优化路径 — drafter accept rate 这个真正
的算法瓶颈才暴露出来 (E2B ~20%、E4B ~37%)。

---

## 为什么不直接 fork LiteRT-LM 提 PR?

提了也不一定合 (Google 官方 sampler dylib 的 hidden visibility 是他们
内部 build 配置的副作用, 修上游 dylib 比修我们这边的 sampler_factory
影响面大很多)。先归档着, 等他们自己注意到再说。
