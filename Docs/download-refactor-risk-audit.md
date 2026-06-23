# Download Refactor Phase 0 Risk Audit

Date: 2026-04-24
Branch: `codex/resumable-downloads`

## Current Download Surfaces

There are three download-related code paths. They are not equivalent.

### 1. LiteRT model download: primary user path

Files:

- `LLM/Installation/LiteRTModelStore.swift`
- `LLM/Core/ModelInstallerProtocol.swift`
- `LLM/Models/PredefinedModels.swift`
- `LLM/Backends/LiteRT/LiteRTBackend.swift`
- `UI/ConfigurationsView.swift`

Flow:

1. `ConfigurationsView` calls `engine.installer.install(model:)`.
2. `AgentEngine` defaults `installer` to `LiteRTModelStore`.
3. `LiteRTModelStore` downloads one `.litertlm` file into `Documents/models/<fileName>`.
4. `LiteRTBackend` resolves the selected model path through `ModelInstaller.artifactPath(for:)`.
5. If model loading fails, `LiteRTBackend` deletes the model file and posts `LiteRTModelCorrupt`; `LiteRTModelStore` refreshes install state.

Current limitations:

- `tempURL` is deleted before every download, so there is no true resume.
- Multi-source behavior is fallback-only; no speed probe.
- Progress is per current transfer and does not represent persisted partial bytes.
- Size validation is `>= 90% expectedFileSize`, not exact size or checksum.
- `activeTasks[modelID]` is not cleared on normal completion, though current code does not guard installs by it.

Regression boundaries:

- Final LiteRT path must remain `Documents/models/<fileName>`.
- `artifactPath(for:)` must continue checking bundle first, then Documents.
- Partial files must never be considered installed.
- Corrupt-model notification flow must continue to refresh the settings UI.
- Settings UI currently expects `ModelInstallState.downloading(completedFiles:totalFiles:currentFile:)` and `DownloadProgress`.

### 2. LIVE voice model download: secondary user path

Files:

- `LLM/MLX/Installation/LiveModelDownloader.swift`
- `LLM/MLX/Installation/LiveModelDefinition.swift`
- `Shared/Audio/ASRService.swift`
- `Live/TTS/TTSService.swift`
- `Live/VAD/VADService.swift`
- `UI/ConfigurationsView.swift`

Assets:

- ASR: `sherpa-asr-zh`
- TTS: `vits-zh-hf-keqing`
- VAD: `silero-vad-coreml`

Flow:

1. `ConfigurationsView` owns `LiveModelDownloader`.
2. `downloadAll()` lists HF repo trees, filters files, and downloads every missing asset.
3. Downloads go to `Documents/models/<asset>.partial`, then rename to final asset directory.
4. Runtime services call `LiveModelDefinition.resolve(for:)`.
5. ASR and TTS prefer bundle resources, then Documents. VAD prefers Documents, then falls back to FluidAudio auto-download.

Current limitations:

- `refreshState()` calls `cleanupStalePartials()`, deleting any partial download.
- `downloadAll()` also deletes each asset partial directory before downloading.
- Progress is mainly file count based.
- HF tree listing currently stores file paths only; sizes must be derived from API metadata or per-file HEAD.
- Source order is fixed: `hf-mirror.com`, then `huggingface.co`.
- ModelScope is intentionally excluded for `csukuangfj/*` repos because those repos return 404 there.

Regression boundaries:

- Final asset directories must remain under `Documents/models/<directoryName>`.
- ASR required files are `encoder.int8.onnx`, `decoder.onnx`, `joiner.int8.onnx`, `tokens.txt`.
- TTS fallback to system speech must still work if TTS is unavailable.
- VAD fallback to FluidAudio auto-download must still work if unified VAD is unavailable.
- `LiveModelDefinition.isAvailable` should only return true when all required assets resolve.

### 3. MLX directory downloader: legacy path

Files:

- `LLM/MLX/MLXLocalLLMService.swift`
- `LLM/MLX/Installation/ModelDownloader.swift`
- `LLM/MLX/Installation/ModelInstaller.swift`
- `LLM/MLX/Installation/ModelPaths.swift`

Status:

- The iOS app default path now uses LiteRT via `AgentEngine` injection.
- `MLXLocalLLMService` is still compiled into the project and remains relevant for legacy code, tests, or harnesses.
- It has its own state dictionaries: `modelInstallStates`, `modelDownloadMetrics`, `currentDownloadTasks`.

Regression boundaries:

- Do not remove or rewrite this path in the first download refactor.
- Avoid changing `ModelPaths.documentsRoot()` semantics because LIVE uses it too.
- Avoid naming new partial files/directories in a way that legacy cleanup can delete.

## Shared State Contracts

### Current install state

`ModelInstallState` is shared by LiteRT, LIVE, and MLX legacy:

- `.notInstalled`
- `.checkingSource`
- `.downloading(completedFiles:totalFiles:currentFile:)`
- `.downloaded`
- `.bundled`
- `.failed(String)`

Risk:

- Changing this enum immediately would touch multiple UI and legacy call sites.

Recommendation:

- Phase 1 should keep this enum shape.
- Add richer progress through `DownloadProgress` / `ModelDownloadMetrics` first.
- Only introduce new enum cases after LiteRT and LIVE have migrated to the common downloader.

### Current progress types

LiteRT:

- `DownloadProgress`
- fields: `bytesReceived`, `totalBytes`, `bytesPerSecond`, `currentFile`

LIVE:

- `ModelDownloadMetrics`
- fields: `bytesReceived`, `totalBytes`, `bytesPerSecond`, `sourceLabel`

Risk:

- Two progress models make UI and downloader behavior diverge.

Recommendation:

- Introduce a richer internal `DownloadProgressSnapshot`.
- Adapt it back to current public progress types during migration.

## Proposed Safe Refactor Shape

### New internal downloader core

Add a common core under `LLM/Installation/Download/`:

- `DownloadAsset`
- `DownloadFile`
- `DownloadManifest`
- `DownloadProgressSnapshot`
- `DownloadFailure`
- `DownloadSourceProbe`
- `DownloadSourceScoreCache`
- `ResumableAssetDownloader`

The core must be UI-language-neutral. It returns enums, numbers, URLs, and host labels only.

### Manifest and partial file policy

For each asset:

- Manifest: `<asset>.partial/.download-manifest.json`
- Partial file: `<relativePath>.part`
- Metadata: `<relativePath>.part.meta.json`
- Final file: `<relativePath>`

Rules:

- Never delete partial data in `refreshState()`.
- Resume only when local bytes are less than expected size.
- Use `Range: bytes=<localBytes>-`.
- Accept `206 Partial Content` for append.
- Treat `200 OK` after a range request as restart-from-zero.
- Do not cross-resume to another host unless size and validators are compatible.
- Prefer same-source resume; if switching source is required, restart that file unless validation is strong.

### Source selection

Probe candidates before download:

1. `HEAD`
2. small range request, capped by bytes or time
3. cache score per host

LiteRT candidates come from `ModelDescriptor.downloadURLs`.

LIVE candidates remain:

- `hf-mirror.com`
- `huggingface.co`

Do not add ModelScope to LIVE in the first refactor.

### Progress calculation

Primary progress:

```text
sum(completed file sizes + current partial bytes) / sum(known total file sizes)
```

Secondary display:

```text
completedFiles / totalFiles
currentFile
sourceLabel
bytesPerSecond
etaSeconds
```

If some file sizes are unknown:

- Use byte progress for known-size files.
- Use file count as fallback only for unknown-size files.

## Implementation Phases

### Phase 1: Add common types only

No behavior change.

- Add internal download core types.
- Add adapters that can produce current `DownloadProgress` and `ModelDownloadMetrics`.
- Do not replace existing download loops yet.

Validation:

- `xcodebuild -list -workspace PhoneClaw.xcworkspace`
- iOS build if practical.

### Phase 2: Migrate LiteRT single-file download

Why first:

- Single file.
- Clear expected size.
- Direct user path.
- Easier to test interruption and resume.

Keep:

- `ModelInstaller` protocol unchanged.
- `ModelInstallState` enum unchanged.
- final path unchanged: `Documents/models/<fileName>`.

New behavior:

- pause keeps `.partial`.
- retry resumes from `.partial`.
- delete model removes final file and partial data.

Validation:

- interrupt E2B download, resume, verify it does not restart from zero.
- corrupt partial file, verify it restarts safely.
- load model after download.

### Phase 3: Migrate LIVE multi-file download

Keep:

- final directories unchanged.
- ASR/TTS/VAD runtime resolution unchanged.
- TTS and VAD fallback behavior unchanged.

New behavior:

- no partial cleanup in `refreshState()`.
- completed files are skipped.
- progress uses aggregate bytes.

Validation:

- interrupt ASR mid-file and resume.
- interrupt between assets and resume.
- ASR initializes after download without app restart.
- TTS uses system fallback when TTS is absent.
- VAD FluidAudio fallback remains available when unified VAD is absent.

### Phase 4: Source speed probing

Add source probing after resumable download works.

Validation:

- one host unreachable -> fallback.
- one host slow -> faster host selected.
- cached result avoids repeated probe overhead.

### Phase 5: UI improvements

Only after backend behavior is stable.

Add display for:

- percent by bytes
- file count
- current source
- speed
- ETA
- pause / resume / delete

All visible text must use `tr()` or an existing localization helper.

## High-Risk Items To Avoid Initially

- Do not introduce background `URLSession` in the first pass. Foreground resumable download is enough to survive app relaunch via persisted `.part` files.
- Do not rewrite `ModelInstallState` first.
- Do not delete legacy MLX downloader first.
- Do not share partial directory names with legacy MLX `.partial` cleanup.
- Do not cross-resume across mirrors without validation.
- Do not store localized strings in manifests.
- Do not rely on `URLSession` resume data as the primary resume mechanism.

## Test Matrix

LiteRT:

- clean install -> no model -> download button visible
- start download -> progress bytes increase
- cancel/pause -> partial remains
- resume -> starts from partial byte count
- failed mirror -> fallback
- completed download -> `artifactPath(for:)` non-nil
- load model -> status downloaded/loaded
- corrupt final file -> backend deletes file and store refreshes to notInstalled

LIVE:

- clean install -> not downloaded
- partial ASR -> resume file
- partial TTS -> resume file
- partial VAD directory -> resume nested files
- completed all -> `LiveModelDefinition.isAvailable == true`
- ASR initializes after completed download
- TTS fallback remains system when TTS missing
- VAD fallback remains FluidAudio when VAD missing

UI / i18n:

- Chinese device shows Chinese download strings.
- English device shows English download strings.
- Manifest contains no natural-language strings.
- Progress does not jump to near-complete because small files completed first.

