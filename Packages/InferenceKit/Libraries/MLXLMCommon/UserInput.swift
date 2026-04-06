// Copyright © 2024 Apple Inc.

@preconcurrency import AVFoundation
import CoreImage
import Foundation
import MLX

public typealias Message = [String: any Sendable]

/// Container for raw user input.
///
/// A ``UserInputProcessor`` can convert this to ``LMInput``.
/// See also ``ModelContext``.
public struct UserInput {

    /// Representation of a prompt or series of messages (conversation).
    ///
    /// This may be a single string with a user prompt or a series of back
    /// and forth responses representing a conversation.
    public enum Prompt: CustomStringConvertible {
        /// A single string
        case text(String)

        /// Model-specific array of dictionaries
        case messages([Message])

        /// Model-agnostic structured chat (series of messages)
        case chat([Chat.Message])

        public var description: String {
            switch self {
            case .text(let text):
                return text
            case .messages(let messages):
                return messages.map { $0.description }.joined(separator: "\n")
            case .chat(let messages):
                return messages.map(\.content).joined(separator: "\n")
            }
        }
    }

    public struct VideoFrame {
        public let frame: CIImage
        public let timeStamp: CMTime

        public init(frame: CIImage, timeStamp: CMTime) {
            self.frame = frame
            self.timeStamp = timeStamp
        }
    }

    /// Representation of raw audio input.
    public enum Audio {
        case pcm(PCM)
        case url(URL)

        public struct PCM: Sendable {
            public let samples: [Float]
            public let sampleRate: Double
            public let channelCount: Int

            public init(samples: [Float], sampleRate: Double, channelCount: Int) {
                self.samples = samples
                self.sampleRate = sampleRate
                self.channelCount = channelCount
            }

            public var duration: TimeInterval {
                guard sampleRate > 0 else { return 0 }
                return Double(samples.count) / sampleRate
            }
        }
    }

    /// Representation of a video resource.
    public enum Video {
        case avAsset(AVAsset)
        case url(URL)
        /// Useful for decoded frames held in memory
        case frames([VideoFrame])

        @available(
            *, deprecated,
            message: "Use MediaProcessing.asProcessedSequence() with the Video directly"
        )
        public func asAVAsset() -> AVAsset {
            switch self {
            case .avAsset(let asset):
                return asset
            case .url(let url):
                return AVAsset(url: url)
            case .frames:
                fatalError(
                    "calling asAVAsset() on Video Input with VideoFames provided is unsupported and deprecated - please use MediaProcessing.asProcessedSequence() instead"
                )
            }
        }
    }

    /// Representation of an image resource.
    public enum Image {
        case ciImage(CIImage)
        case url(URL)
        case array(MLXArray)

        public func asCIImage() throws -> CIImage {
            switch self {
            case .ciImage(let image):
                return image

            case .url(let url):
                if let image = CIImage(contentsOf: url) {
                    return image
                }
                throw UserInputError.unableToLoad(url)

            case .array(let array):
                guard array.ndim == 3 else {
                    throw UserInputError.arrayError("array must have 3 dimensions: \(array.ndim)")
                }

                var array = array

                // convert to 0 .. 255
                if array.max().item(Float.self) <= 1.0 {
                    array = array * 255
                }

                // planar -> pixels
                switch array.dim(0) {
                case 3, 4:
                    // channels first (planar)
                    array = array.transposed(1, 2, 0)
                default:
                    break
                }

                // 4 components per pixel
                switch array.dim(-1) {
                case 3:
                    // pad to 4 bytes per pixel
                    array = padded(array, widths: [0, 0, [0, 1]], value: MLXArray(255))
                case 4:
                    // good
                    break
                default:
                    throw UserInputError.arrayError(
                        "channel dimension must be last and 3/4: \(array.shape)")
                }

                let arrayData = array.asData()
                let (H, W, _) = array.shape3
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!

                return CIImage(
                    bitmapData: arrayData.data, bytesPerRow: W * 4,
                    size: .init(width: W, height: H),
                    format: .RGBA8, colorSpace: cs)
            }
        }
    }

    /// Representation of processing to apply to media.
    public struct Processing: Sendable {
        public var resize: CGSize?

        public init(resize: CGSize? = nil) {
            self.resize = resize
        }
    }

    /// The prompt to evaluate.
    public var prompt: Prompt {
        didSet {
            switch prompt {
            case .text, .messages:
                // no action
                break
            case .chat(let messages):
                // rebuild images & videos
                self.images = messages.reduce(into: []) { result, message in
                    result.append(contentsOf: message.images)
                }
                self.videos = messages.reduce(into: []) { result, message in
                    result.append(contentsOf: message.videos)
                }
                self.audios = messages.reduce(into: []) { result, message in
                    result.append(contentsOf: message.audios)
                }
            }
        }
    }

    /// The images associated with the `UserInput`.
    ///
    /// If the ``prompt-swift.property`` is a ``Prompt-swift.enum/chat(_:)`` this will
    /// collect the images from the chat messages, otherwise these are the stored images with the ``UserInput``.
    public var images = [Image]()

    /// The images associated with the `UserInput`.
    ///
    /// If the ``prompt-swift.property`` is a ``Prompt-swift.enum/chat(_:)`` this will
    /// collect the videos from the chat messages, otherwise these are the stored videos with the ``UserInput``.
    public var videos = [Video]()

    /// The audio clips associated with the `UserInput`.
    ///
    /// If the ``prompt-swift.property`` is a ``Prompt-swift.enum/chat(_:)`` this will
    /// collect the audios from the chat messages, otherwise these are the stored audios with the ``UserInput``.
    public var audios = [Audio]()

    public var tools: [ToolSpec]?

    /// Additional values provided for the chat template rendering context
    public var additionalContext: [String: any Sendable]?
    public var processing: Processing = .init()

    /// Initialize the `UserInput` with a single text prompt.
    ///
    /// - Parameters:
    ///   - prompt: text prompt
    ///   - images: optional images
    ///   - videos: optional videos
    ///   - tools: optional tool specifications
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        prompt: String,
        images: [Image] = [Image](),
        videos: [Video] = [Video](),
        audios: [Audio] = [Audio](),
        tools: [ToolSpec]? = nil,
        additionalContext: [String: any Sendable]? = nil
    ) {
        self.prompt = .chat([
            .user(prompt, images: images, videos: videos, audios: audios)
        ])
        self.tools = tools
        self.additionalContext = additionalContext
    }

    /// Initialize the `UserInput` with model specific mesage structures.
    ///
    /// For example, the Qwen2VL model wants input in this format:
    ///
    /// ```
    /// [
    ///     [
    ///         "role": "user",
    ///         "content": [
    ///             [
    ///                 "type": "text",
    ///                 "text": "What is this?"
    ///             ],
    ///             [
    ///                 "type": "image",
    ///             ],
    ///         ]
    ///     ]
    /// ]
    /// ```
    ///
    /// Typically the ``init(chat:tools:additionalContext:)`` should be used instead
    /// along with a model specific ``MessageGenerator`` (supplied by the ``UserInputProcessor``).
    ///
    /// - Parameters:
    ///   - messages: array of dictionaries representing the prompt in a model specific format
    ///   - images: optional images
    ///   - videos: optional videos
    ///   - tools: optional tool specifications
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        messages: [Message],
        images: [Image] = [Image](),
        videos: [Video] = [Video](),
        audios: [Audio] = [Audio](),
        tools: [ToolSpec]? = nil,
        additionalContext: [String: any Sendable]? = nil
    ) {
        self.prompt = .messages(messages)
        self.images = images
        self.videos = videos
        self.audios = audios
        self.tools = tools
        self.additionalContext = additionalContext
    }

    /// Initialize the `UserInput` with a model agnostic structured context.
    ///
    /// For example:
    ///
    /// ```
    /// let chat: [Chat.Message] = [
    ///     .system("You are a helpful photographic assistant."),
    ///     .user("Please describe the photo.", images: [image1]),
    /// ]
    /// let userInput = UserInput(chat: chat)
    /// ```
    ///
    /// A model specific ``MessageGenerator`` (supplied by the ``UserInputProcessor``)
    /// is used to convert this into a model specific format.
    ///
    /// - Parameters:
    ///   - chat: structured content
    ///   - tools: optional tool specifications
    ///   - processing: optional processing to be applied to media
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        chat: [Chat.Message],
        processing: Processing = .init(),
        tools: [ToolSpec]? = nil,
        additionalContext: [String: any Sendable]? = nil
    ) {
        self.prompt = .chat(chat)

        // note: prompt.didSet is not triggered in init
        self.images = chat.reduce(into: []) { result, message in
            result.append(contentsOf: message.images)
        }
        self.videos = chat.reduce(into: []) { result, message in
            result.append(contentsOf: message.videos)
        }
        self.audios = chat.reduce(into: []) { result, message in
            result.append(contentsOf: message.audios)
        }

        self.processing = processing
        self.tools = tools
        self.additionalContext = additionalContext
    }

    /// Initialize the `UserInput` with a preconfigured ``Prompt-swift.enum``.
    ///
    /// ``init(chat:tools:additionalContext:)`` is the preferred mechanism.
    ///
    /// - Parameters:
    ///   - prompt: the prompt
    ///   - images: optional images
    ///   - videos: optional videos
    ///   - tools: optional tool specifications
    ///   - processing: optional processing to be applied to media
    ///   - additionalContext: optional context (model specific)
    /// ### See Also
    /// - ``Prompt-swift.enum/text(_:)``
    /// - ``init(chat:tools:additionalContext:)``
    public init(
        prompt: Prompt,
        images: [Image] = [Image](),
        videos: [Video] = [Video](),
        audios: [Audio] = [Audio](),
        processing: Processing = .init(),
        tools: [ToolSpec]? = nil, additionalContext: [String: any Sendable]? = nil
    ) {
        self.prompt = prompt
        switch prompt {
        case .text, .messages:
            self.images = images
            self.videos = videos
            self.audios = audios
        case .chat:
            break
        }
        self.processing = processing
        self.tools = tools
        self.additionalContext = additionalContext
    }
}

/// Protocol for a type that can convert ``UserInput`` to ``LMInput``.
///
/// See also ``ModelContext``.
public protocol UserInputProcessor: Sendable {
    func prepare(input: UserInput) async throws -> LMInput
}

internal enum UserInputError: LocalizedError {
    case notImplemented
    case unableToLoad(URL)
    case arrayError(String)
    case audioLoadingNotImplemented(URL)
    case audioCountExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return String(localized: "This functionality is not implemented.")
        case .unableToLoad(let url):
            return String(localized: "Unable to load image from URL: \(url.path).")
        case .arrayError(let message):
            return String(localized: "Error processing image array: \(message).")
        case .audioLoadingNotImplemented(let url):
            return String(localized: "Audio loading from URL is not implemented yet: \(url.path).")
        case .audioCountExceeded(let count):
            return String(localized: "Only a single audio clip is supported right now, received \(count).")
        }
    }
}

/// A do-nothing ``UserInputProcessor``.
public struct StandInUserInputProcessor: UserInputProcessor {
    public init() {}

    public func prepare(input: UserInput) throws -> LMInput {
        throw UserInputError.notImplemented
    }
}
