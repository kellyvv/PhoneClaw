import Foundation

actor ResumableAssetDownloader {
    private let manifestStore: DownloadManifestStore
    private let observer: any DownloadObserver
    private let fileManager: FileManager
    private let urlSession: URLSession

    init(
        manifestStore: DownloadManifestStore,
        observer: any DownloadObserver = NoopDownloadObserver(),
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared
    ) {
        self.manifestStore = manifestStore
        self.observer = observer
        self.fileManager = fileManager
        self.urlSession = urlSession
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
            totalBytes: totalBytes,
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
                    totalBytes: totalBytes
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
                    let bytes = fileSize(partialURL)
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
                let bytes = fileSize(partialURL)
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
        totalBytes: Int64?
    ) async throws -> (
        manifest: DownloadManifest,
        bytesWritten: Int64,
        expectedBytes: Int64?,
        metadata: DownloadFileMetadata?
    ) {
        var request = URLRequest(url: source.url)
        var offset = initialOffset
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let ifRange = metadata?.etag ?? metadata?.lastModified {
                request.setValue(ifRange, forHTTPHeaderField: "If-Range")
            }
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadFailure.invalidResponse("Missing HTTP response")
        }

        if offset > 0, httpResponse.statusCode == 416 {
            try? fileManager.removeItem(at: partialURL)
            return try await transfer(
                file: file,
                asset: asset,
                source: source,
                partialURL: partialURL,
                initialOffset: 0,
                metadata: metadata,
                manifest: manifest,
                completedFiles: completedFiles,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DownloadFailure.httpStatus(httpResponse.statusCode)
        }

        let appending = offset > 0 && httpResponse.statusCode == 206
        if offset > 0, !appending {
            try? fileManager.removeItem(at: partialURL)
            offset = 0
        }

        let responseMetadata = makeMetadata(from: httpResponse, source: source, offset: offset, fallbackExpectedSize: file.expectedSize)
        let expectedBytes = responseMetadata.contentLength ?? file.expectedSize

        let fileHandle = try openPartialFile(at: partialURL, appending: appending)
        defer { try? fileHandle.close() }

        var currentManifest = manifest
        var bytesReceived = offset
        var buffer = Data()
        let flushInterval = 1024 * 1024
        let startedAt = CFAbsoluteTimeGetCurrent()
        var lastSpeedUpdate = startedAt
        var lastSpeedBytes = bytesReceived
        var smoothedSpeed: Double = 0

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
            bytesPerSecond: smoothedSpeed
        )

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }

            buffer.append(byte)
            bytesReceived += 1

            if buffer.count >= flushInterval {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastSpeedUpdate
                if elapsed > 0.5 {
                    let instantSpeed = Double(bytesReceived - lastSpeedBytes) / elapsed
                    smoothedSpeed = smoothedSpeed > 0 ? smoothedSpeed * 0.7 + instantSpeed * 0.3 : instantSpeed
                    lastSpeedUpdate = now
                    lastSpeedBytes = bytesReceived
                }

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
                    bytesPerSecond: smoothedSpeed
                )
            }
        }

        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }

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
            bytesPerSecond: smoothedSpeed
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
                totalBytes: totalBytes ?? expectedBytes.map { completedBytes + $0 },
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

        guard let entry = manifest.files.first(where: { $0.relativePath == file.relativePath }),
              let storedMetadata = entry.metadata else {
            return (0, nil, true)
        }

        let headMetadata = try? await fetchHeadMetadata(for: source)
        if let headMetadata, validatorsMatch(stored: storedMetadata, current: headMetadata) {
            return (existingBytes, headMetadata, false)
        }

        if headMetadata == nil, storedMetadata.sourceURL == source.url {
            return (existingBytes, storedMetadata, false)
        }

        return (0, headMetadata, true)
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
        return makeMetadata(from: httpResponse, source: source, offset: 0, fallbackExpectedSize: nil)
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

    private func makeMetadata(
        from response: HTTPURLResponse,
        source: DownloadFile.Source,
        offset: Int64,
        fallbackExpectedSize: Int64?
    ) -> DownloadFileMetadata {
        let responseLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let contentRangeTotal = header("Content-Range", from: response).flatMap(parseContentRangeTotal)
        let totalLength = contentRangeTotal ?? responseLength.map { offset + $0 } ?? fallbackExpectedSize

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

    private func openPartialFile(at url: URL, appending: Bool) throws -> FileHandle {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !appending {
            try? fileManager.removeItem(at: url)
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        if appending {
            try handle.seekToEnd()
        }
        return handle
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
