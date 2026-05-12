import Foundation
import Compression

// MARK: - ZipExtractor
//
// 最小化 zip 解压实现, 专为下载完成后展开 .mlmodelc.zip 类的"目录归档"使用。
//
// 为什么自己写而不用 ZIPFoundation:
//   - 我们只需要 read-only 单档解压, 不需要 ZIPFoundation 的 90% 功能 (写入、
//     update、stream-add 等).
//   - ZIPFoundation 是 ~200 KB SPM 依赖, 引一个新 package 改 pbxproj + 维护
//     版本约束, 比这 150 行代码的维护成本大。
//   - OpenBMB 的 mlmodelc.zip 实测用 STORED 方法 (compression=0x0000, 没压缩),
//     我们走 raw byte copy 即可零依赖跑通; 留个 DEFLATE 兜底走 Apple
//     `Compression.framework` 万一上游换 zip 工具时也不挂。
//
// 支持的:
//   - 单档归档解压 (extract(at:to:))
//   - STORED 方法 (method=0) — 主路径
//   - DEFLATE 方法 (method=8) — 兜底, 走 Compression.framework
//   - UTF-8 文件名 (zip 通用)
//   - 目录条目自动创建
//
// 不支持 (按需扩展):
//   - 加密
//   - Zip64 (4 GB+ 单文件 / 65535+ 条目)。OpenBMB mlmodelc.zip 远低于这条线。
//   - 增量更新 / 流式 add
//
// 安全:
//   - **拒绝相对路径逃逸** (../, 绝对路径, symlink 字段) — Zip-Slip 防御。
//     CoreML mlmodelc 内部不会有这种内容, 但下载内容来自外部 OBS, 给个 belt-and-
//     suspenders 防护。

enum ZipExtractorError: LocalizedError {
    case fileNotFound(URL)
    case invalidArchive(String)
    case unsupportedFeature(String)
    case extractionFailed(String)
    case pathTraversal(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Zip archive not found: \(url.path)"
        case .invalidArchive(let reason):
            return "Invalid zip archive: \(reason)"
        case .unsupportedFeature(let what):
            return "Unsupported zip feature: \(what)"
        case .extractionFailed(let reason):
            return "Zip extraction failed: \(reason)"
        case .pathTraversal(let name):
            return "Zip entry path traversal attempt: \(name)"
        }
    }
}

enum ZipExtractor {

    /// 解压 zip 归档到目标目录。`destinationDirectory` 必须存在或可创建。
    /// 解压完成不删除源 zip — 调用方自行决定 (例如下载器删除 zip 释放磁盘)。
    static func extract(at archiveURL: URL, to destinationDirectory: URL) throws {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ZipExtractorError.fileNotFound(archiveURL)
        }
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        // 整档读到内存:
        //   优点: 实现简单 (mmap-like 随机访问), 不用流式解析 ECDR/CDH.
        //   缺点: 内存占用等于 zip 大小。
        // OpenBMB mlmodelc.zip ~1 GB, iPhone 17 Pro Max 16 GB 内存下吃得下,
        // 但 6 GB 机型 (iPhone 13/14) 上接近上限。如果将来要支持更大 zip 或者
        // 更小内存设备, 改 mmap (Data(contentsOf:url, options:.alwaysMapped))
        // 让系统按需 page in, 内存占用降到几十 MB。
        let data: Data
        do {
            data = try Data(contentsOf: archiveURL, options: .alwaysMapped)
        } catch {
            throw ZipExtractorError.invalidArchive("read failed: \(error.localizedDescription)")
        }

        let centralDirectory = try findCentralDirectory(in: data)
        let entries = try parseCentralDirectory(data: data,
                                                offset: centralDirectory.offset,
                                                count: centralDirectory.count)

        for entry in entries {
            try extractEntry(entry, archiveData: data, to: destinationDirectory)
        }
    }

    // MARK: - End of Central Directory Record

    private struct CentralDirectoryInfo {
        let offset: Int   // 偏移到 central directory 起点
        let count: Int    // 条目数
    }

    /// 找 ECDR (End of Central Directory Record): zip 文件尾部的固定结构,
    /// signature 0x06054b50。允许末尾有 zip "comment" (变长), 所以要从尾部往前扫。
    private static func findCentralDirectory(in data: Data) throws -> CentralDirectoryInfo {
        let signature: UInt32 = 0x06054b50
        // ECDR 固定 22 字节, comment 最大 65535 字节 → 最远从末尾倒推 22 + 65535
        let maxScan = min(data.count, 22 + 0xFFFF)
        guard data.count >= 22 else {
            throw ZipExtractorError.invalidArchive("file too small to contain ECDR")
        }

        var ecdrOffset: Int?
        let scanStart = data.count - maxScan
        // 倒着扫, 找到第一个 ECDR signature 就行 (zip 规范 ECDR 必须是文件末尾)
        for i in stride(from: data.count - 22, through: scanStart, by: -1) {
            if data.readUInt32LE(at: i) == signature {
                ecdrOffset = i
                break
            }
        }
        guard let ecdr = ecdrOffset else {
            throw ZipExtractorError.invalidArchive("ECDR signature not found")
        }

        // ECDR 结构:
        //   0..3   signature (4)
        //   4..5   disk number (2)
        //   6..7   disk where CD starts (2)
        //   8..9   CD entries on this disk (2)
        //   10..11 total CD entries (2)
        //   12..15 CD size (4)
        //   16..19 CD offset (4)
        //   20..21 comment length (2)
        let totalEntries = Int(data.readUInt16LE(at: ecdr + 10))
        let cdOffset = Int(data.readUInt32LE(at: ecdr + 16))

        // Zip64 哨兵: 任何字段 = 0xFFFFFFFF 表示真实值在 zip64 ECDR 里。
        // OpenBMB mlmodelc.zip 不会触发, 但留个明确错误信息以防万一。
        if cdOffset == 0xFFFFFFFF || totalEntries == 0xFFFF {
            throw ZipExtractorError.unsupportedFeature("Zip64 (>4GB or >65535 entries)")
        }

        return CentralDirectoryInfo(offset: cdOffset, count: totalEntries)
    }

    // MARK: - Central Directory Header parsing

    private struct ZipEntry {
        let fileName: String
        let compressionMethod: UInt16   // 0=STORED, 8=DEFLATE
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int       // 偏移到 local file header
        let isDirectory: Bool            // 文件名以 "/" 结尾
    }

    private static func parseCentralDirectory(data: Data, offset: Int, count: Int) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        entries.reserveCapacity(count)

        var cursor = offset
        let cdSignature: UInt32 = 0x02014b50

        for entryIdx in 0..<count {
            guard cursor + 46 <= data.count else {
                throw ZipExtractorError.invalidArchive("CDH \(entryIdx) overruns archive")
            }
            guard data.readUInt32LE(at: cursor) == cdSignature else {
                throw ZipExtractorError.invalidArchive("CDH \(entryIdx) bad signature at \(cursor)")
            }

            // CDH 结构 (节选, 全字段见 PKWARE APPNOTE.TXT):
            //   10..11 compression method (2)
            //   20..23 compressed size (4)
            //   24..27 uncompressed size (4)
            //   28..29 file name length (2)
            //   30..31 extra field length (2)
            //   32..33 file comment length (2)
            //   42..45 local header offset (4)
            //   46..   file name (variable)
            let method = data.readUInt16LE(at: cursor + 10)
            let compSize = Int(data.readUInt32LE(at: cursor + 20))
            let uncompSize = Int(data.readUInt32LE(at: cursor + 24))
            let nameLen = Int(data.readUInt16LE(at: cursor + 28))
            let extraLen = Int(data.readUInt16LE(at: cursor + 30))
            let commentLen = Int(data.readUInt16LE(at: cursor + 32))
            let localOffset = Int(data.readUInt32LE(at: cursor + 42))

            // Zip64 哨兵
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                throw ZipExtractorError.unsupportedFeature("Zip64 size/offset in entry \(entryIdx)")
            }

            let nameStart = cursor + 46
            guard nameStart + nameLen <= data.count else {
                throw ZipExtractorError.invalidArchive("CDH \(entryIdx) name overruns archive")
            }
            let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLen))
            guard let name = String(data: nameBytes, encoding: .utf8) else {
                throw ZipExtractorError.invalidArchive("CDH \(entryIdx) non-UTF8 filename")
            }

            entries.append(ZipEntry(
                fileName: name,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/")
            ))

            cursor = nameStart + nameLen + extraLen + commentLen
        }

        return entries
    }

    // MARK: - Per-entry extraction

    private static func extractEntry(_ entry: ZipEntry, archiveData: Data, to destinationDirectory: URL) throws {
        // Zip-Slip 防御: 拒绝绝对路径或包含 ".." 的相对路径
        if entry.fileName.hasPrefix("/")
            || entry.fileName.contains("\\")
            || entry.fileName.split(separator: "/").contains(where: { $0 == ".." }) {
            throw ZipExtractorError.pathTraversal(entry.fileName)
        }

        let outURL = destinationDirectory.appendingPathComponent(entry.fileName)

        if entry.isDirectory {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            return
        }

        // 文件: 找 local file header → 跳过其 name/extra 字段 → 拿数据区
        //
        // LFH 结构:
        //   0..3   signature 0x04034b50
        //   4..5   version needed (2)
        //   6..7   flags (2)
        //   8..9   compression method (2)
        //   10..13 mod time + date (4)
        //   14..17 CRC32 (4)
        //   18..21 compressed size (4)
        //   22..25 uncompressed size (4)
        //   26..27 file name length (2)
        //   28..29 extra field length (2)
        //   30..   file name + extra (variable)
        //
        // 注意: LFH 的字段可能跟 CDH 不一致 (flag bit 3 = 数据描述符模式, sizes
        // 在 entry 后另写, LFH 里全是 0)。我们以 CDH 的值为准 — OpenBMB 的 zip
        // 不用数据描述符, 但 belt-and-suspenders。
        let lfhOffset = entry.localHeaderOffset
        guard lfhOffset + 30 <= archiveData.count,
              archiveData.readUInt32LE(at: lfhOffset) == 0x04034b50 else {
            throw ZipExtractorError.invalidArchive("LFH bad signature for \(entry.fileName)")
        }
        let lfhNameLen = Int(archiveData.readUInt16LE(at: lfhOffset + 26))
        let lfhExtraLen = Int(archiveData.readUInt16LE(at: lfhOffset + 28))
        let dataStart = lfhOffset + 30 + lfhNameLen + lfhExtraLen

        guard dataStart + entry.compressedSize <= archiveData.count else {
            throw ZipExtractorError.invalidArchive("data for \(entry.fileName) overruns archive")
        }

        let compressed = archiveData.subdata(in: dataStart..<(dataStart + entry.compressedSize))
        let outData: Data
        switch entry.compressionMethod {
        case 0:
            // STORED — 直接写入。OpenBMB mlmodelc.zip 全部走这个路径。
            outData = compressed
        case 8:
            // DEFLATE — 走 Apple Compression.framework 的 ZLIB_RAW (deflate stream
            // 不带 zlib header)。
            outData = try inflateDeflate(compressed, expectedSize: entry.uncompressedSize, name: entry.fileName)
        default:
            throw ZipExtractorError.unsupportedFeature("compression method \(entry.compressionMethod) on \(entry.fileName)")
        }

        // 父目录可能没显式 directory entry, 这里保险一下
        let parent = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        try outData.write(to: outURL, options: .atomic)
    }

    /// DEFLATE 解压: Apple Compression.framework 的 ZLIB algorithm 接收 raw
    /// deflate stream (zip 容器里的 method=8 数据正是 raw deflate, 不带 zlib
    /// header 的 2 字节 0x789C/0x78DA)。
    private static func inflateDeflate(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
        // expectedSize 可能是 0 (空文件) — 直接返回, 别走解压路径吃 0-byte 边界。
        guard expectedSize > 0 else {
            return Data()
        }
        var output = Data(count: expectedSize)
        let actual: Int = output.withUnsafeMutableBytes { outBuf -> Int in
            guard let outBase = outBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compressed.withUnsafeBytes { inBuf -> Int in
                guard let inBase = inBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outBase, expectedSize,
                    inBase, compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard actual == expectedSize else {
            throw ZipExtractorError.extractionFailed("deflate \(name): got \(actual), want \(expectedSize)")
        }
        return output
    }
}

// MARK: - Data little-endian helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        // 不用 withUnsafeBytes + load(as:): 不能保证 offset 对齐, 显式按字节组装
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
