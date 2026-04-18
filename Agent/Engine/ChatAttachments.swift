import CoreImage
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct ChatImageAttachment: Identifiable, Codable {
    let id: UUID
    let data: Data
    private static let storageMaxDimension: CGFloat = 1_024
    private static let compressionQuality: CGFloat = 0.78

    init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }

    // 签名用 PlatformImage (iOS = UIImage, macOS CLI = CIImage).
    // 保证 AgentEngine.processInput 里 images.compactMap(ChatImageAttachment.init(image:))
    // 在两个平台都能编译; macOS 下实际走 CLI 占位分支 (不测图像场景).
    init?(image: PlatformImage) {
        #if canImport(UIKit)
        let prepared = Self.preparedImage(image, maxDimension: Self.storageMaxDimension)
        if let jpeg = prepared.jpegData(compressionQuality: Self.compressionQuality) {
            self.id = UUID()
            self.data = jpeg
        } else if let png = prepared.pngData() {
            self.id = UUID()
            self.data = png
        } else {
            return nil
        }
        #else
        // macOS CLI: harness 不测图像输入, 不应走到这里
        return nil
        #endif
    }

    #if canImport(UIKit)
    static func preparedImage(_ image: UIImage, maxDimension: CGFloat = storageMaxDimension) -> UIImage {
        let originalSize = image.size
        let longestSide = max(originalSize.width, originalSize.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return image
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(
            width: max(1, floor(originalSize.width * scale)),
            height: max(1, floor(originalSize.height * scale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    var uiImage: UIImage? {
        UIImage(data: data)
    }
    #endif

    var ciImage: CIImage? {
        if let image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) {
            return image
        }
        #if canImport(UIKit)
        guard let uiImage else { return nil }
        if let ciImage = uiImage.ciImage {
            return ciImage
        }
        if let cgImage = uiImage.cgImage {
            return CIImage(cgImage: cgImage)
        }
        return CIImage(image: uiImage)
        #else
        // macOS CLI: CIImage(data:) 已失败, 没有 UIKit fallback
        return nil
        #endif
    }
}

struct ChatAudioAttachment: Identifiable, Codable {
    let id: UUID
    let wavData: Data
    let duration: TimeInterval
    let sampleRate: Double
    let waveform: [Float]

    init(
        id: UUID = UUID(),
        wavData: Data,
        duration: TimeInterval,
        sampleRate: Double,
        waveform: [Float]
    ) {
        self.id = id
        self.wavData = wavData
        self.duration = duration
        self.sampleRate = sampleRate
        self.waveform = waveform
    }

    init?(snapshot: AudioCaptureSnapshot) {
        guard !snapshot.pcm.isEmpty, snapshot.sampleRate > 0 else { return nil }
        self.id = UUID()
        self.wavData = Self.makeWAVData(
            pcm: snapshot.pcm,
            sampleRate: snapshot.sampleRate,
            channelCount: 1
        )
        self.duration = snapshot.duration
        self.sampleRate = snapshot.sampleRate
        self.waveform = Self.makeWaveform(from: snapshot.pcm)
    }

    var formattedDuration: String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func makeWaveform(from pcm: [Float], bucketCount: Int = 36) -> [Float] {
        guard !pcm.isEmpty else { return Array(repeating: 0.12, count: bucketCount) }
        let samplesPerBucket = max(pcm.count / bucketCount, 1)
        var levels: [Float] = []
        levels.reserveCapacity(bucketCount)

        var index = 0
        while index < pcm.count {
            let end = min(index + samplesPerBucket, pcm.count)
            let slice = pcm[index..<end]
            let peak = slice.reduce(Float.zero) { current, sample in
                max(current, abs(sample))
            }
            levels.append(peak)
            index = end
        }

        if levels.count < bucketCount, let last = levels.last {
            levels.append(contentsOf: Array(repeating: last, count: bucketCount - levels.count))
        }
        if levels.count > bucketCount {
            levels = Array(levels.prefix(bucketCount))
        }

        let maxLevel = max(levels.max() ?? 0, 0.001)
        return levels.map { max($0 / maxLevel, 0.08) }
    }

    private static func makeWAVData(
        pcm: [Float],
        sampleRate: Double,
        channelCount: Int
    ) -> Data {
        let integerSampleRate = max(Int(sampleRate.rounded()), 1)
        let clampedSamples = pcm.map { sample -> Int16 in
            let limited = min(max(sample, -1), 1)
            return Int16((limited * Float(Int16.max)).rounded())
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let dataChunkSize = clampedSamples.count * bytesPerSample
        let riffChunkSize = 36 + dataChunkSize
        let byteRate = integerSampleRate * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataChunkSize)
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(riffChunkSize), to: &data)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channelCount), to: &data)
        append(UInt32(integerSampleRate), to: &data)
        append(UInt32(byteRate), to: &data)
        append(UInt16(blockAlign), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataChunkSize), to: &data)

        for sample in clampedSamples {
            append(sample, to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
