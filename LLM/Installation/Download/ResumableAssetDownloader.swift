import Foundation

actor ResumableAssetDownloader {
    private let manifestStore: DownloadManifestStore
    private let observer: any DownloadObserver
    private let fileManager: FileManager
    private let urlSession: URLSession
    private let backgroundSession: BackgroundDownloadSession

    init(
        manifestStore: DownloadManifestStore,
        observer: any DownloadObserver = NoopDownloadObserver(),
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared,
        backgroundSession: BackgroundDownloadSession = .shared
    ) {
        self.manifestStore = manifestStore
        self.observer = observer
        self.fileManager = fileManager
        self.urlSession = urlSession
        self.backgroundSession = backgroundSession
    }

    func download(asset: DownloadAsset) async throws -> DownloadProgressSnapshot {
        guard !asset.files.isEmpty else {
            throw DownloadFailure.invalidResponse("Download asset has no files")
        }

        try fileManager.createDirectory(at: asset.destinationDirectory, withIntermediateDirectories: true)
        try await preflightDiskSpace(for: asset)

        var manifest = try await readManifestOrRestart(assetID: asset.id)
            ?? freshManifest(for: asset, now: Date())
        let totalBytes = totalExpectedBytes(for: asset)
        var completedFiles = 0
        var completedBytes: Int64 = 0

        for file in asset.files {
            let finalURL = asset.destinationDirectory.appendingPathComponent(file.relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: finalURL.path) {
                let size = fileSize(finalURL)
                let isUsable: Bool
                if let expected = file.expectedSize {
                    isUsable = size >= expected * 9 / 10
                } else {
                    isUsable = size > 0
                }
                if isUsable {
                    completedFiles += 1
                    completedBytes += size
                    continue
                }
            }

            let result = try await downloadFile(
                file,
                asset: asset,
                manifest: manifest,
                completedFiles: completedFiles,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
            manifest = result.manifest
            completedFiles += 1
            completedBytes += result.bytesWritten
        }

        let snapshot = DownloadProgressSnapshot(
            assetID: asset.id,
            completedFileCount: completedFiles,
            totalFileCount: asset.files.count,
            downloadedBytes: completedBytes,
            totalBytes: completedBytes,
            bytesPerSecond: nil,
            activeFilePath: nil,
            activeSourceLabel: nil,
            phase: .complete,
            updatedAt: Date()
        )
        if !asset.preservesWorkspaceOnCompletion {
            try await manifestStore.purge(assetID: asset.id)
        }
        return snapshot
    }

    func pause(assetID: String) async {
        // Cancellation is driven by the caller's Task. The downloader persists a
        // paused manifest when that cancellation is observed in the transfer loop.
    }

    func purge(assetID: String) async throws {
        try await manifestStore.purge(assetID: assetID)
    }

    func pruneOrphans(knownAssetIDs: Set<String>) async throws {
        try await manifestStore.pruneOrphans(knownAssetIDs: knownAssetIDs)
    }

    private func downloadFile(
        _ file: DownloadFile,
        asset: DownloadAsset,
        manifest: DownloadManifest,
        completedFiles: Int,
        completedBytes: Int64,
        totalBytes: Int64?
    ) async throws -> (manifest: DownloadManifest, bytesWritten: Int64) {
        let partialURL = try await manifestStore.partialFileURL(for: asset.id, relativePath: file.relativePath)
        let finalURL = asset.destinationDirectory.appendingPathComponent(file.relativePath, isDirectory: false)
        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var currentManifest = manifest
        var lastError: Error?
        var previousSource: DownloadFile.Source?
        var sources = orderedSources(file.sources)

        if let selectedSourceLabel = currentManifest.files.first(where: { $0.relativePath == file.relativePath })?.selectedSourceLabel,
           let index = sources.firstIndex(where: { $0.label == selectedSourceLabel }) {
            sources.insert(sources.remove(at: index), at: 0)
        }

        for (attempt, source) in sources.enumerated() {
            if let previousSource {
                await observer.onSourceSwitch(
                    assetID: asset.id,
                    filePath: file.relativePath,
                    from: previousSource,
                    to: source,
                    reason: lastError.map(downloadFailure(from:))
                )
            }
            previousSource = source

            do {
                let plan = try await resumePlan(
                    assetID: asset.id,
                    file: file,
                    source: source,
                    partialURL: partialURL,
                    manifest: currentManifest
                )

                if plan.restart {
                    try? fileManager.removeItem(at: partialURL)
                    if let resumeDataURL = try? await manifestStore.resumeDataURL(for: asset.id, relativePath: file.relativePath) {
                        try? fileManager.removeItem(at: resumeDataURL)
                    }
                }

                let result = try await transfer(
                    file: file,
                    asset: asset,
                    source: source,
                    partialURL: partialURL,
                    initialOffset: plan.restart ? 0 : plan.offset,
                    metadata: plan.metadata,
                    manifest: currentManifest,
                    completedFiles: completedFiles,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    allowsResumeData: !plan.restart
                )
                currentManifest = result.manifest

                try? fileManager.removeItem(at: finalURL)
                try fileManager.moveItem(at: partialURL, to: finalURL)

                currentManifest = updatedManifest(
                    currentManifest,
                    asset: asset,
                    replacing: DownloadManifestFile(
                        relativePath: file.relativePath,
                        state: .complete,
                        downloadedBytes: result.bytesWritten,
                        expectedBytes: result.expectedBytes,
                        selectedSourceLabel: source.label,
                        metadata: result.metadata
                    )
                )
                try await manifestStore.writeManifest(currentManifest, for: asset.id)
                return (currentManifest, result.bytesWritten)
            } catch {
                if isCancellation(error) {
                    let latestManifest = (try? await manifestStore.readManifest(for: asset.id)) ?? currentManifest
                    let existingEntry = latestManifest.files.first(where: { $0.relativePath == file.relativePath })
                    let bytes = max(fileSize(partialURL), existingEntry?.downloadedBytes ?? 0)
                    currentManifest = updatedManifest(
                        latestManifest,
                        asset: asset,
                        replacing: DownloadManifestFile(
                            relativePath: file.relativePath,
                            state: .paused,
                            downloadedBytes: bytes,
                            expectedBytes: existingEntry?.expectedBytes ?? file.expectedSize,
                            selectedSourceLabel: source.label,
                            metadata: existingEntry?.metadata
                        )
                    )
                    try? await manifestStore.writeManifest(currentManifest, for: asset.id)
                    throw CancellationError()
                }

                lastError = error
                let failure = downloadFailure(from: error)
                await observer.onRetry(
                    assetID: asset.id,
                    filePath: file.relativePath,
                    source: source,
                    attempt: attempt + 1,
                    error: failure
                )
                let latestManifest = (try? await manifestStore.readManifest(for: asset.id)) ?? currentManifest
                let existingEntry = latestManifest.files.first(where: { $0.relativePath == file.relativePath })
                let bytes = max(fileSize(partialURL), existingEntry?.downloadedBytes ?? 0)
                currentManifest = updatedManifest(
                    latestManifest,
                    asset: asset,
                    replacing: DownloadManifestFile(
                        relativePath: file.relativePath,
                        state: .failed,
                        downloadedBytes: bytes,
                        expectedBytes: existingEntry?.expectedBytes ?? file.expectedSize,
                        selectedSourceLabel: source.label,
                        metadata: existingEntry?.metadata
                    )
                )
                try? await manifestStore.writeManifest(currentManifest, for: asset.id)
            }
        }

        let failure = downloadFailure(from: lastError ?? DownloadFailure.invalidResponse("No source succeeded"))
        await observer.onFailure(assetID: asset.id, failure: failure)
        throw lastError ?? failure
    }

    private func transfer(
        file: DownloadFile,
        asset: DownloadAsset,
        source: DownloadFile.Source,
        partialURL: URL,
        initialOffset: Int64,
        metadata: DownloadFileMetadata?,
        manifest: DownloadManifest,
        completedFiles: Int,
        completedBytes: Int64,
        totalBytes: Int64?,
        allowsResumeData: Bool = true
    ) async throws -> (
        manifest: DownloadManifest,
        bytesWritten: Int64,
        expectedBytes: Int64?,
        metadata: DownloadFileMetadata?
    ) {
        var request = URLRequest(url: source.url)
        let offset = initialOffset
        let resumeDataURL = try await manifestStore.resumeDataURL(for: asset.id, relativePath: file.relativePath)
        let manifestEntry = manifest.files.first { $0.relativePath == file.relativePath }
        let knownExpectedBytes = manifestEntry?.metadata?.contentLength ?? manifestEntry?.expectedBytes ?? file.expectedSize
        let resumeDataSourceMatches =
            manifestEntry?.selectedSourceLabel == source.label &&
            (manifestEntry?.metadata?.sourceURL == nil || manifestEntry?.metadata?.sourceURL == source.url)
        let resumeData = allowsResumeData && offset == 0 && resumeDataSourceMatches
            ? (try? Data(contentsOf: resumeDataURL))
            : nil
        let usingResumeData = resumeData?.isEmpty == false
        let resumeDataProgressBase = usingResumeData
            ? clampedDownloadedBytes(max(offset, manifestEntry?.downloadedBytes ?? 0), expectedBytes: knownExpectedBytes)
            : 0
        if offset == 0 && (!allowsResumeData || !resumeDataSourceMatches) {
            try? fileManager.removeItem(at: resumeDataURL)
        }

        if offset > 0, !usingResumeData {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let ifRange = metadata?.etag ?? metadata?.lastModified {
                request.setValue(ifRange, forHTTPHeaderField: "If-Range")
            }
        }

        let normalizer = BackgroundDownloadProgressNormalizer(
            usingResumeData: usingResumeData,
            rangeOffset: offset,
            resumeBase: resumeDataProgressBase,
            expectedBytes: knownExpectedBytes
        )
        let tracker = DownloadProgressAccumulator(
            downloadedBytes: usingResumeData ? resumeDataProgressBase : offset,
            expectedBytes: knownExpectedBytes
        )
        let handle = backgroundSession.start(
            request: request,
            resumeData: resumeData
        ) { [observer, manifestStore] bytesWritten, totalBytesExpected in
            let expectedBytes: Int64? = {
                if totalBytesExpected > 0 {
                    if usingResumeData {
                        return expectedBytesForResumeDataProgress(
                            taskBytesExpected: totalBytesExpected,
                            resumeBase: resumeDataProgressBase,
                            declaredExpectedBytes: knownExpectedBytes
                        )
                    }
                    return offset + totalBytesExpected
                }
                return knownExpectedBytes
            }()
            let normalizedProgress = normalizer.progress(
                taskBytesWritten: bytesWritten,
                taskBytesExpected: totalBytesExpected,
                currentExpectedBytes: expectedBytes
            )
            let progress = tracker.update(
                downloadedBytes: normalizedProgress.downloadedBytes,
                expectedBytes: expectedBytes,
                resetBaseline: normalizedProgress.resetBaseline
            )
            let downloadedBytes = progress.downloadedBytes
            let bytesPerSecond = progress.bytesPerSecond

            Task {
                let updated = updatedManifestForProgress(
                    manifest,
                    asset: asset,
                    file: file,
                    source: source,
                    downloadedBytes: downloadedBytes,
                    expectedBytes: expectedBytes,
                    metadata: metadata
                )
                try? await manifestStore.writeManifest(updated, for: asset.id)
                await observer.onProgress(
                    DownloadProgressSnapshot(
                        assetID: asset.id,
                        completedFileCount: completedFiles,
                        totalFileCount: asset.files.count,
                        downloadedBytes: completedBytes + downloadedBytes,
                        totalBytes: adjustedTotalBytes(
                            configuredTotalBytes: totalBytes,
                            completedBytes: completedBytes,
                            file: file,
                            expectedBytes: expectedBytes
                        ),
                        bytesPerSecond: bytesPerSecond,
                        activeFilePath: file.relativePath,
                        activeSourceLabel: source.label,
                        phase: .downloading,
                        updatedAt: Date()
                    )
                )
            }
        }

        let result: BackgroundDownloadResult
        do {
            result = try await handle.wait()
            try? fileManager.removeItem(at: resumeDataURL)
        } catch let error as BackgroundDownloadError {
            if let resumeData = error.resumeData {
                try? resumeData.write(to: resumeDataURL, options: [.atomic])
            }
            if error.isCancellation {
                throw CancellationError()
            }
            throw error.underlyingError ?? error
        }

        let httpResponse = result.response
        guard let temporaryFileURL = result.fileURL else {
            throw DownloadFailure.invalidResponse("Missing downloaded file")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DownloadFailure.httpStatus(httpResponse.statusCode)
        }

        if offset > 0, !usingResumeData, httpResponse.statusCode == 416 {
            throw DownloadFailure.validatorMismatch(
                expected: "valid byte range from \(offset)",
                actual: "HTTP 416",
                field: "Range"
            )
        }

        if offset > 0, !usingResumeData, httpResponse.statusCode != 206 {
            throw DownloadFailure.validatorMismatch(
                expected: "206 Partial Content",
                actual: "HTTP \(httpResponse.statusCode)",
                field: "Range"
            )
        }

        let responseMetadata = makeMetadata(from: httpResponse, source: source, offset: usingResumeData ? 0 : offset)

        // serverAuthoritativeBytes: 只接受这次下载里 HTTP 服务器给出的大小
        //   — 来自当前 GET 响应的 Content-Length / Content-Range
        //   — 或 resumePlan 阶段 HEAD probe 拿到的 metadata.contentLength
        // 绝不接受常量 (file.expectedSize) 或上一次 manifest 里的 stale 值。
        // 只有它非 nil 时才参与 finalSizeMismatch 硬校验, 不然信任下载字节数。
        let serverAuthoritativeBytes = responseMetadata.contentLength ?? metadata?.contentLength

        // expectedBytes: 给进度 UI / manifest 估算用, 允许常量兜底。
        // 这个值不参与硬校验。
        let expectedBytes = serverAuthoritativeBytes ?? tracker.expectedBytes ?? file.expectedSize

        if offset > 0, !usingResumeData {
            try appendDownloadedFile(temporaryFileURL, to: partialURL)
        } else {
            try? fileManager.removeItem(at: partialURL)
            try fileManager.moveItem(at: temporaryFileURL, to: partialURL)
        }
        try? fileManager.removeItem(at: temporaryFileURL)

        let bytesReceived = fileSize(partialURL)
        // 硬校验只在我们有 server-authoritative 大小时才进行。
        // 没拿到 Content-Length (e.g. ModelScope 某些时段, 代理 strip)
        // 就信任下载字节数 — 比删了刚下完的文件再换源好得多。
        if let authBytes = serverAuthoritativeBytes,
           let sizeMismatch = finalSizeMismatch(bytesReceived, expectedBytes: authBytes) {
            print("[ResumableAssetDownloader] file-size mismatch — deleting partial. " +
                  "source=\(source.label) actual=\(bytesReceived) expected=\(authBytes) " +
                  "tolerance_band=\(sizeMismatch.expected)")
            try? fileManager.removeItem(at: partialURL)
            try? fileManager.removeItem(at: resumeDataURL)
            let resetManifest = updatedManifest(
                (try? await manifestStore.readManifest(for: asset.id)) ?? manifest,
                asset: asset,
                replacing: DownloadManifestFile(
                    relativePath: file.relativePath,
                    state: .pending,
                    downloadedBytes: 0,
                    expectedBytes: expectedBytes,
                    selectedSourceLabel: source.label,
                    metadata: responseMetadata
                )
            )
            try? await manifestStore.writeManifest(resetManifest, for: asset.id)
            throw DownloadFailure.validatorMismatch(
                expected: sizeMismatch.expected,
                actual: sizeMismatch.actual,
                field: "file-size"
            )
        } else if serverAuthoritativeBytes == nil {
            print("[ResumableAssetDownloader] no Content-Length from \(source.label) — " +
                  "skipping size validation, trusting received \(bytesReceived) bytes")
        }

        var currentManifest = (try? await manifestStore.readManifest(for: asset.id)) ?? manifest
        currentManifest = try await persistProgress(
            manifest: currentManifest,
            asset: asset,
            file: file,
            source: source,
            bytesReceived: bytesReceived,
            expectedBytes: expectedBytes,
            metadata: responseMetadata,
            completedFiles: completedFiles,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: 0
        )

        return (currentManifest, bytesReceived, expectedBytes, responseMetadata)
    }

    private func persistProgress(
        manifest: DownloadManifest,
        asset: DownloadAsset,
        file: DownloadFile,
        source: DownloadFile.Source,
        bytesReceived: Int64,
        expectedBytes: Int64?,
        metadata: DownloadFileMetadata?,
        completedFiles: Int,
        completedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double
    ) async throws -> DownloadManifest {
        let updated = updatedManifest(
            manifest,
            asset: asset,
            replacing: DownloadManifestFile(
                relativePath: file.relativePath,
                state: .downloading,
                downloadedBytes: bytesReceived,
                expectedBytes: expectedBytes,
                selectedSourceLabel: source.label,
                metadata: metadata
            )
        )
        try await manifestStore.writeManifest(updated, for: asset.id)
        await observer.onProgress(
            DownloadProgressSnapshot(
                assetID: asset.id,
                completedFileCount: completedFiles,
                totalFileCount: asset.files.count,
                downloadedBytes: completedBytes + bytesReceived,
                totalBytes: adjustedTotalBytes(
                    configuredTotalBytes: totalBytes,
                    completedBytes: completedBytes,
                    file: file,
                    expectedBytes: expectedBytes
                ),
                bytesPerSecond: bytesPerSecond > 0 ? bytesPerSecond : nil,
                activeFilePath: file.relativePath,
                activeSourceLabel: source.label,
                phase: .downloading,
                updatedAt: Date()
            )
        )
        return updated
    }

    private func resumePlan(
        assetID: String,
        file: DownloadFile,
        source: DownloadFile.Source,
        partialURL: URL,
        manifest: DownloadManifest
    ) async throws -> (offset: Int64, metadata: DownloadFileMetadata?, restart: Bool) {
        let existingBytes = fileSize(partialURL)
        guard existingBytes > 0 else { return (0, nil, false) }

        // 早期 oversized partial 检测: 落盘字节比 expected 还多 → 必然是脏数据
        // (上一次 bug 导致写超 / 不同源拼接残留 / 手动写错). 直接 restart, 不依赖
        // 服务器 HEAD 校验 — HF mirror 经 CloudFront 重定向时 HEAD 不一定返回
        // Content-Length, 拿不到 currentLength 就漏检, 然后 Range: bytes=existing-
        // 落到服务器上是越界请求 → 416 死循环。
        if let expected = file.expectedSize, existingBytes > expected {
            return (0, nil, true)
        }

        guard let entry = manifest.files.first(where: { $0.relativePath == file.relativePath }) else {
            return (existingBytes, nil, false)
        }

        let headMetadata = try? await fetchHeadMetadata(for: source)

        guard let storedMetadata = entry.metadata else {
            if let headMetadata {
                // 之前没有存过 server-authoritative metadata, 不能拿 entry.expectedBytes
                // (可能是常量) 跟当前 HEAD Content-Length 做严格相等比较 — 那是
                // v1.3.2 之前那个 "下完了又重新下载" bug 的 resume 路径双胞胎。
                // 信任 HEAD 给出的 Content-Length 作为新基线, 只保留越界保护:
                // 如果服务器现在说文件比我们已下载的字节还小, 肯定是远端换了文件,
                // restart 比 Range 请求 416 死循环安全。
                if let currentLength = headMetadata.contentLength, currentLength < existingBytes {
                    throw DownloadFailure.validatorMismatch(
                        expected: ">= \(existingBytes)",
                        actual: "\(currentLength)",
                        field: "Content-Length"
                    )
                }
                return (existingBytes, headMetadata, false)
            }

            return (existingBytes, nil, false)
        }

        if let headMetadata, validatorsMatch(stored: storedMetadata, current: headMetadata) {
            return (existingBytes, headMetadata, false)
        }

        if headMetadata == nil {
            return (existingBytes, storedMetadata.sourceURL == source.url ? storedMetadata : nil, false)
        }

        if let expectedBytes = file.expectedSize,
           let currentLength = headMetadata?.contentLength,
           currentLength == expectedBytes,
           currentLength >= existingBytes {
            return (existingBytes, headMetadata, false)
        }

        throw DownloadFailure.validatorMismatch(
            expected: storedMetadata.etag ?? storedMetadata.lastModified ?? "\(storedMetadata.contentLength ?? 0)",
            actual: headMetadata?.etag ?? headMetadata?.lastModified ?? "\(headMetadata?.contentLength ?? 0)",
            field: "metadata"
        )
    }

    private func fetchHeadMetadata(for source: DownloadFile.Source) async throws -> DownloadFileMetadata {
        var request = URLRequest(url: source.url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadFailure.invalidResponse("Missing HEAD response")
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw DownloadFailure.httpStatus(httpResponse.statusCode)
        }
        return makeMetadata(from: httpResponse, source: source, offset: 0)
    }

    private func validatorsMatch(stored: DownloadFileMetadata, current: DownloadFileMetadata) -> Bool {
        if let storedChecksum = stored.checksumSHA256,
           let currentChecksum = current.checksumSHA256,
           storedChecksum == currentChecksum {
            return true
        }
        if let storedETag = stored.etag, let currentETag = current.etag, storedETag == currentETag {
            return true
        }
        if let storedLength = stored.contentLength,
           let currentLength = current.contentLength,
           storedLength == currentLength {
            return true
        }
        if let storedModified = stored.lastModified,
           let currentModified = current.lastModified,
           storedModified == currentModified {
            return true
        }
        return false
    }

    /// 把 HTTP 响应转换为 DownloadFileMetadata。
    ///
    /// **重要**: contentLength 字段只接受真正来自 HTTP 头 (Content-Length /
    /// Content-Range) 的值, **不会从常量回填**。如果服务器/镜像没给 Content-Length
    /// (e.g. 早期 ModelScope, 某些代理 strip 掉, chunked transfer encoding),
    /// 这里返回 contentLength = nil, 由调用方决定如何处理。
    ///
    /// 这条规则是 v1.3.2 修复的关键: 之前这里有 `?? fallbackExpectedSize` 兜底,
    /// 会把 PredefinedModels.swift 写死的"期望大小"(可能因 HF 重传而过时)
    /// 静默注入 contentLength, 导致下游 finalSizeMismatch 用陈旧常量做硬校验,
    /// 把刚下载完整的文件误判为大小不符 → 删除 partial → 自动换源重下 → 死循环。
    private func makeMetadata(
        from response: HTTPURLResponse,
        source: DownloadFile.Source,
        offset: Int64
    ) -> DownloadFileMetadata {
        let responseLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let contentRangeTotal = header("Content-Range", from: response).flatMap(parseContentRangeTotal)
        // 只用 HTTP 头, 没有就是 nil — 不从常量回填
        let totalLength = contentRangeTotal ?? responseLength.map { offset + $0 }

        return DownloadFileMetadata(
            sourceURL: source.url,
            sourceHost: source.url.host,
            etag: header("ETag", from: response),
            contentLength: totalLength,
            lastModified: header("Last-Modified", from: response),
            checksumSHA256: nil,
            updatedAt: Date()
        )
    }

    private func parseContentRangeTotal(_ value: String) -> Int64? {
        guard let slashIndex = value.lastIndex(of: "/") else { return nil }
        let suffix = value[value.index(after: slashIndex)...]
        guard suffix != "*" else { return nil }
        return Int64(suffix)
    }

    private func header(_ name: String, from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    private func appendDownloadedFile(_ sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destinationURL.path) {
            fileManager.createFile(atPath: destinationURL.path, contents: nil)
        }

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }
        try output.seekToEnd()

        while true {
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
    }

    private func readManifestOrRestart(assetID: String) async throws -> DownloadManifest? {
        do {
            return try await manifestStore.readManifest(for: assetID)
        } catch let failure as DownloadFailure {
            if case .manifestCorrupt = failure {
                print("[Download] Manifest corrupt for \(assetID); restarting asset download from 0")
                try await manifestStore.purge(assetID: assetID)
                return nil
            }
            throw failure
        }
    }

    private func preflightDiskSpace(for asset: DownloadAsset) async throws {
        let required = try await remainingExpectedBytes(for: asset)
        guard required > 0 else { return }
        try DownloadPreflight.validateDiskSpace(requiredBytes: required, at: asset.destinationDirectory)
    }

    private func remainingExpectedBytes(for asset: DownloadAsset) async throws -> Int64 {
        var required: Int64 = 0
        for file in asset.files {
            guard let expected = file.expectedSize, expected > 0 else { continue }
            let partialURL = try await manifestStore.partialFileURL(for: asset.id, relativePath: file.relativePath)
            let remaining = max(0, expected - fileSize(partialURL))
            required += remaining
        }
        return required
    }

    private func totalExpectedBytes(for asset: DownloadAsset) -> Int64? {
        var total: Int64 = 0
        for file in asset.files {
            guard let expected = file.expectedSize, expected > 0 else { return nil }
            total += expected
        }
        return total
    }

    private func freshManifest(for asset: DownloadAsset, now: Date) -> DownloadManifest {
        DownloadManifest(
            assetID: asset.id,
            createdAt: now,
            updatedAt: now,
            files: asset.files.map {
                DownloadManifestFile(
                    relativePath: $0.relativePath,
                    state: .pending,
                    downloadedBytes: 0,
                    expectedBytes: $0.expectedSize
                )
            }
        )
    }

    private func updatedManifest(
        _ manifest: DownloadManifest,
        asset: DownloadAsset,
        replacing replacement: DownloadManifestFile
    ) -> DownloadManifest {
        let existing = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
        let files = asset.files.map { file -> DownloadManifestFile in
            if file.relativePath == replacement.relativePath {
                return replacement
            }
            return existing[file.relativePath] ?? DownloadManifestFile(
                relativePath: file.relativePath,
                state: .pending,
                downloadedBytes: 0,
                expectedBytes: file.expectedSize
            )
        }

        return DownloadManifest(
            schemaVersion: manifest.schemaVersion,
            assetID: manifest.assetID,
            createdAt: manifest.createdAt,
            updatedAt: Date(),
            files: files
        )
    }

    private func orderedSources(_ sources: [DownloadFile.Source]) -> [DownloadFile.Source] {
        sources.sorted {
            if $0.priority == $1.priority {
                return $0.label < $1.label
            }
            return $0.priority < $1.priority
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? Int64) ?? 0
    }

    private func finalSizeMismatch(_ bytes: Int64, expectedBytes: Int64?) -> (expected: String, actual: String)? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        let tolerance = progressTolerance(for: expectedBytes)
        let lowerBound = max(0, expectedBytes - tolerance)
        let upperBound = expectedBytes + tolerance
        guard bytes < lowerBound || bytes > upperBound else { return nil }
        return ("\(lowerBound)...\(upperBound)", "\(bytes)")
    }

    private func downloadFailure(from error: Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure {
            return failure
        }
        if isCancellation(error) {
            return .cancelled
        }
        return .invalidResponse(error.localizedDescription)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }
}

private struct NormalizedDownloadProgress: Sendable {
    let downloadedBytes: Int64
    let resetBaseline: Bool
}

private struct BackgroundDownloadProgressNormalizer: Sendable {
    let usingResumeData: Bool
    let rangeOffset: Int64
    let resumeBase: Int64
    let expectedBytes: Int64?

    func progress(
        taskBytesWritten: Int64,
        taskBytesExpected: Int64,
        currentExpectedBytes: Int64?
    ) -> NormalizedDownloadProgress {
        let expectedBytes = currentExpectedBytes ?? self.expectedBytes

        if usingResumeData {
            let resumeProgress = resumeDataProgress(
                taskBytesWritten: taskBytesWritten,
                taskBytesExpected: taskBytesExpected,
                expectedBytes: expectedBytes
            )
            return NormalizedDownloadProgress(
                downloadedBytes: clampedDownloadedBytes(resumeProgress.downloadedBytes, expectedBytes: expectedBytes),
                resetBaseline: resumeProgress.resetBaseline
            )
        } else {
            return NormalizedDownloadProgress(
                downloadedBytes: clampedDownloadedBytes(rangeOffset + taskBytesWritten, expectedBytes: expectedBytes),
                resetBaseline: false
            )
        }
    }

    private func resumeDataProgress(
        taskBytesWritten: Int64,
        taskBytesExpected: Int64,
        expectedBytes: Int64?
    ) -> (downloadedBytes: Int64, resetBaseline: Bool) {
        guard resumeBase > 0 else { return (taskBytesWritten, false) }

        if let expectedBytes, expectedBytes > 0, taskBytesExpected > 0 {
            let tolerance = progressTolerance(for: expectedBytes)

            if taskBytesExpected >= expectedBytes - tolerance {
                return (taskBytesWritten, taskBytesWritten < resumeBase)
            }

            if resumeBase + taskBytesExpected <= expectedBytes + tolerance {
                return (resumeBase + taskBytesWritten, false)
            }
        }

        if taskBytesWritten >= resumeBase {
            return (taskBytesWritten, false)
        }

        return (resumeBase + taskBytesWritten, false)
    }
}

struct BackgroundDownloadResult: Sendable {
    let fileURL: URL?
    let response: HTTPURLResponse
}

enum BackgroundDownloadError: Error {
    case cancelled(resumeData: Data?)
    case failed(Error, resumeData: Data?)
    case missingDownloadedFile
    case invalidResponse

    var resumeData: Data? {
        switch self {
        case .cancelled(let resumeData), .failed(_, let resumeData):
            return resumeData
        case .missingDownloadedFile, .invalidResponse:
            return nil
        }
    }

    var underlyingError: Error? {
        switch self {
        case .failed(let error, _):
            return error
        case .cancelled, .missingDownloadedFile, .invalidResponse:
            return nil
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundDownloadSession()

    private let stateQueue = DispatchQueue(label: "com.phoneclaw.background-downloads.state")
    private var transfers: [Int: BackgroundTransfer] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private lazy var session: URLSession = {
        let configuration: URLSessionConfiguration
        if Bundle.main.bundleURL.pathExtension == "app" {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.phoneclaw.app"
            configuration = URLSessionConfiguration.background(withIdentifier: "\(bundleID).background-downloads")
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
        } else {
            configuration = .ephemeral
        }
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    func start(
        request: URLRequest,
        resumeData: Data?,
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ totalBytesExpected: Int64) -> Void
    ) -> BackgroundDownloadTaskHandle {
        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        task.taskDescription = request.url?.absoluteString

        let box = BackgroundDownloadResultBox()
        let transfer = BackgroundTransfer(task: task, resultBox: box, progress: progress)
        stateQueue.sync {
            transfers[task.taskIdentifier] = transfer
        }
        task.resume()
        return BackgroundDownloadTaskHandle(
            taskIdentifier: task.taskIdentifier,
            session: self,
            resultBox: box
        )
    }

    func setBackgroundCompletionHandler(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        stateQueue.async {
            self.backgroundCompletionHandlers[identifier] = completionHandler
        }
    }

    fileprivate func cancel(taskIdentifier: Int) {
        let transfer = stateQueue.sync {
            transfers[taskIdentifier]
        }
        transfer?.task.cancel { resumeData in
            transfer?.resultBox.finish(.failure(BackgroundDownloadError.cancelled(resumeData: resumeData)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let transfer = stateQueue.sync {
            transfers[downloadTask.taskIdentifier]
        }
        transfer?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let transfer = stateQueue.sync {
            transfers[downloadTask.taskIdentifier]
        }
        guard let transfer else { return }

        do {
            let destination = try makeTemporaryDownloadURL()
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                try FileManager.default.copyItem(at: location, to: destination)
            }
            stateQueue.sync {
                transfer.fileURL = destination
            }
        } catch {
            transfer.resultBox.finish(.failure(BackgroundDownloadError.failed(error, resumeData: nil)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let transfer = stateQueue.sync {
            transfers.removeValue(forKey: task.taskIdentifier)
        }
        guard let transfer else { return }

        if let error {
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                transfer.resultBox.finish(.failure(BackgroundDownloadError.cancelled(resumeData: resumeData)))
            } else {
                transfer.resultBox.finish(.failure(BackgroundDownloadError.failed(error, resumeData: resumeData)))
            }
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            transfer.resultBox.finish(.failure(BackgroundDownloadError.invalidResponse))
            return
        }
        guard transfer.fileURL != nil else {
            transfer.resultBox.finish(.failure(BackgroundDownloadError.missingDownloadedFile))
            return
        }
        transfer.resultBox.finish(.success(BackgroundDownloadResult(fileURL: transfer.fileURL, response: response)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = stateQueue.sync {
            backgroundCompletionHandlers.removeValue(forKey: session.configuration.identifier ?? "")
        }
        guard let handler else { return }
        DispatchQueue.main.async {
            handler()
        }
    }

    private func makeTemporaryDownloadURL() throws -> URL {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("BackgroundDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)
        return directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
    }
}

final class BackgroundDownloadTaskHandle {
    private let taskIdentifier: Int
    private unowned let session: BackgroundDownloadSession
    private let resultBox: BackgroundDownloadResultBox

    fileprivate init(
        taskIdentifier: Int,
        session: BackgroundDownloadSession,
        resultBox: BackgroundDownloadResultBox
    ) {
        self.taskIdentifier = taskIdentifier
        self.session = session
        self.resultBox = resultBox
    }

    func wait() async throws -> BackgroundDownloadResult {
        try await withTaskCancellationHandler {
            try await resultBox.wait()
        } onCancel: {
            session.cancel(taskIdentifier: taskIdentifier)
        }
    }
}

private final class BackgroundTransfer {
    let task: URLSessionDownloadTask
    let resultBox: BackgroundDownloadResultBox
    let progress: @Sendable (_ bytesWritten: Int64, _ totalBytesExpected: Int64) -> Void
    var fileURL: URL?

    init(
        task: URLSessionDownloadTask,
        resultBox: BackgroundDownloadResultBox,
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ totalBytesExpected: Int64) -> Void
    ) {
        self.task = task
        self.resultBox = resultBox
        self.progress = progress
    }
}

private final class BackgroundDownloadResultBox {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BackgroundDownloadResult, Error>?
    private var result: Result<BackgroundDownloadResult, Error>?

    func wait() async throws -> BackgroundDownloadResult {
        try await withCheckedThrowingContinuation { continuation in
            var resultToResume: Result<BackgroundDownloadResult, Error>?
            lock.lock()
            if let result {
                resultToResume = result
            } else {
                self.continuation = continuation
            }
            lock.unlock()

            if let resultToResume {
                continuation.resume(with: resultToResume)
            }
        }
    }

    func finish(_ result: Result<BackgroundDownloadResult, Error>) {
        var continuationToResume: CheckedContinuation<BackgroundDownloadResult, Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuationToResume = continuation
        continuation = nil
        lock.unlock()

        continuationToResume?.resume(with: result)
    }
}

private final class DownloadProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDownloadedBytes: Int64
    private var storedExpectedBytes: Int64?
    private var lastSpeedUpdate: CFAbsoluteTime
    private var lastSpeedBytes: Int64
    private var smoothedBytesPerSecond: Double = 0

    init(downloadedBytes: Int64, expectedBytes: Int64?) {
        self.storedDownloadedBytes = clampedDownloadedBytes(downloadedBytes, expectedBytes: expectedBytes)
        self.storedExpectedBytes = expectedBytes
        self.lastSpeedUpdate = CFAbsoluteTimeGetCurrent()
        self.lastSpeedBytes = self.storedDownloadedBytes
    }

    var downloadedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedDownloadedBytes
    }

    var expectedBytes: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return storedExpectedBytes
    }

    func update(
        downloadedBytes: Int64,
        expectedBytes: Int64?,
        resetBaseline: Bool = false
    ) -> (downloadedBytes: Int64, bytesPerSecond: Double?) {
        lock.lock()
        let effectiveDownloadedBytes = clampedDownloadedBytes(downloadedBytes, expectedBytes: expectedBytes)
        let nextDownloadedBytes = resetBaseline
            ? effectiveDownloadedBytes
            : max(storedDownloadedBytes, effectiveDownloadedBytes)
        storedDownloadedBytes = nextDownloadedBytes
        if let expectedBytes {
            storedExpectedBytes = expectedBytes
        }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastSpeedUpdate
        if resetBaseline {
            smoothedBytesPerSecond = 0
            lastSpeedUpdate = now
            lastSpeedBytes = nextDownloadedBytes
        } else if elapsed > 0.5 {
            let delta = nextDownloadedBytes - lastSpeedBytes
            if delta > 0 {
                let instantSpeed = Double(delta) / elapsed
                smoothedBytesPerSecond = smoothedBytesPerSecond > 0
                    ? smoothedBytesPerSecond * 0.7 + instantSpeed * 0.3
                    : instantSpeed
            }
            lastSpeedUpdate = now
            lastSpeedBytes = nextDownloadedBytes
        }
        let speed = smoothedBytesPerSecond > 0 ? smoothedBytesPerSecond : nil
        lock.unlock()
        return (nextDownloadedBytes, speed)
    }
}

private func clampedDownloadedBytes(_ bytes: Int64, expectedBytes: Int64?) -> Int64 {
    let positiveBytes = max(0, bytes)
    guard let expectedBytes, expectedBytes > 0 else { return positiveBytes }
    return min(positiveBytes, expectedBytes)
}

private func expectedBytesForResumeDataProgress(
    taskBytesExpected: Int64,
    resumeBase: Int64,
    declaredExpectedBytes: Int64?
) -> Int64 {
    guard taskBytesExpected > 0 else {
        return declaredExpectedBytes ?? max(0, resumeBase)
    }

    guard let declaredExpectedBytes, declaredExpectedBytes > 0, resumeBase > 0 else {
        return taskBytesExpected
    }

    let fullTransferDelta = abs(taskBytesExpected - declaredExpectedBytes)
    let incrementalTransferTotal = resumeBase + taskBytesExpected
    let incrementalTransferDelta = abs(incrementalTransferTotal - declaredExpectedBytes)
    return fullTransferDelta <= incrementalTransferDelta
        ? taskBytesExpected
        : incrementalTransferTotal
}

private func adjustedTotalBytes(
    configuredTotalBytes: Int64?,
    completedBytes: Int64,
    file: DownloadFile,
    expectedBytes: Int64?
) -> Int64? {
    guard let expectedBytes, expectedBytes > 0 else {
        return configuredTotalBytes
    }
    guard let configuredTotalBytes, let configuredFileBytes = file.expectedSize, configuredFileBytes > 0 else {
        return completedBytes + expectedBytes
    }
    return max(0, configuredTotalBytes - configuredFileBytes + expectedBytes)
}

private func progressTolerance(for expectedBytes: Int64) -> Int64 {
    max(1, min(Int64(1_048_576), expectedBytes / 1000))
}

private func updatedManifestForProgress(
    _ manifest: DownloadManifest,
    asset: DownloadAsset,
    file: DownloadFile,
    source: DownloadFile.Source,
    downloadedBytes: Int64,
    expectedBytes: Int64?,
    metadata: DownloadFileMetadata?
) -> DownloadManifest {
    let replacement = DownloadManifestFile(
        relativePath: file.relativePath,
        state: .downloading,
        downloadedBytes: downloadedBytes,
        expectedBytes: expectedBytes,
        selectedSourceLabel: source.label,
        metadata: metadata
    )
    let existing = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
    let files = asset.files.map { candidate -> DownloadManifestFile in
        if candidate.relativePath == file.relativePath {
            return replacement
        }
        return existing[candidate.relativePath] ?? DownloadManifestFile(
            relativePath: candidate.relativePath,
            state: .pending,
            downloadedBytes: 0,
            expectedBytes: candidate.expectedSize
        )
    }
    return DownloadManifest(
        schemaVersion: manifest.schemaVersion,
        assetID: manifest.assetID,
        createdAt: manifest.createdAt,
        updatedAt: Date(),
        files: files
    )
}
