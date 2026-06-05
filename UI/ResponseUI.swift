import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct FollowUpSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let prompt: String
}

// MARK: - AI 回复

struct AIResponseView: View, Equatable {
    let block: ResponseBlock
    let expandedSkillIDs: Set<UUID>
    let isThinkingExpanded: Bool
    let isStreamingResponseText: Bool
    let onToggle: (UUID) -> Void
    let onToggleThinking: () -> Void
    let onRetry: (() -> Void)?
    let followUpSuggestions: [FollowUpSuggestion]
    let onFollowUpSuggestion: (FollowUpSuggestion) -> Void

    static func == (lhs: AIResponseView, rhs: AIResponseView) -> Bool {
        lhs.block == rhs.block
            && lhs.expandedSkillIDs == rhs.expandedSkillIDs
            && lhs.isThinkingExpanded == rhs.isThinkingExpanded
            && lhs.isStreamingResponseText == rhs.isStreamingResponseText
            && (lhs.onRetry != nil) == (rhs.onRetry != nil)
            && lhs.followUpSuggestions == rhs.followUpSuggestions
    }

    private var hasSkill: Bool { !block.skills.isEmpty }
    private var hasThinkingText: Bool {
        guard let thinking = block.thinkingText else { return false }
        return !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var isPureThinking: Bool {
        !hasSkill && !hasThinkingText && block.responseText == nil && block.isThinking
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 12) {
                if isPureThinking {
                    ThinkingIndicator()
                        .padding(.vertical, 10)
                }

                ForEach(block.skills) { card in
                    SkillCardView(
                        card: card,
                        isExpanded: expandedSkillIDs.contains(card.id),
                        onToggle: { onToggle(card.id) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                if let thinking = block.thinkingText, !thinking.isEmpty {
                    ThinkingCardView(
                        text: thinking,
                        isExpanded: isThinkingExpanded,
                        onToggle: onToggleThinking
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if hasSkill && block.isThinking && block.responseText == nil {
                    ThinkingIndicator()
                }

                if let text = block.responseText {
                    StreamingMarkdownView(
                        renderID: block.id,
                        content: text,
                        isStreaming: isStreamingResponseText
                    )
                }

                if !followUpSuggestions.isEmpty, !block.isThinking {
                    FollowUpSuggestionRow(
                        suggestions: followUpSuggestions,
                        onTap: onFollowUpSuggestion
                    )
                    .padding(.top, 2)
                }

                if let onRetry, !block.isThinking {
                    Button(action: onRetry) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .regular))
                            Text(tr("重新生成", "Regenerate"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.quietAction)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: block.skills.count)

            Spacer(minLength: Theme.aiMinSpacer)
        }
    }
}

private struct FollowUpSuggestionRow: View {
    let suggestions: [FollowUpSuggestion]
    let onTap: (FollowUpSuggestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onTap(suggestion)
                    } label: {
                        Text(suggestion.title)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.textTertiary.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Theme.bgHover.opacity(0.34), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Theme.border.opacity(0.42), lineWidth: 0.5)
                                    .allowsHitTesting(false)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
    }

    private var assistantTextMaxWidth: CGFloat {
        #if os(macOS)
        return 620
        #else
        let availableWidth = UIScale.screenWidth - Theme.chatPadH * 2
        return max(280, availableWidth)
        #endif
    }
}

// MARK: - Streaming Markdown

/// Lightweight assistant text renderer.
/// MarkdownUI's default list typography is too document-like for the floating chat UI,
/// so plain text / lists / code blocks are mapped to a quieter local rhythm.
private struct StreamingMarkdownView: View {
    let renderID: UUID
    let content: String
    let isStreaming: Bool

    var body: some View {
        #if canImport(UIKit)
        if Self.needsUIKitLinkTextView(content) {
            SelectableAssistantTextView(renderID: renderID, content: content, useCache: !isStreaming)
                .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .animation(nil, value: content)
        } else {
            AssistantAttributedLabel(renderID: renderID, content: content, useCache: !isStreaming)
                .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .animation(nil, value: content)
        }
        #else
        AssistantTextStack(renderID: renderID, content: content, useCache: !isStreaming)
            .equatable()
            .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(nil, value: content)
        #endif
    }

    private var assistantTextMaxWidth: CGFloat {
        #if os(macOS)
        return 620
        #else
        let availableWidth = UIScale.screenWidth - Theme.chatPadH * 2
        return max(280, availableWidth)
        #endif
    }

    private static func needsUIKitLinkTextView(_ content: String) -> Bool {
        content.range(of: "http://", options: [.caseInsensitive]) != nil
            || content.range(of: "https://", options: [.caseInsensitive]) != nil
            || content.range(of: "www.", options: [.caseInsensitive]) != nil
    }
}

private struct AssistantTextStack: View, Equatable {
    let renderID: UUID
    let content: String
    let useCache: Bool

    static func == (lhs: AssistantTextStack, rhs: AssistantTextStack) -> Bool {
        lhs.renderID == rhs.renderID && lhs.content == rhs.content && lhs.useCache == rhs.useCache
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let text, let level):
                    Text(text)
                        .font(.system(size: level == 1 ? 17 : 15.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.assistantText.opacity(0.94))
                        .lineSpacing(7)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, block.id == 0 ? 0 : 10)

                case .paragraph(let text, let isLead):
                    Text(text)
                        .font(.system(size: isLead ? 14 : 14.5, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.assistantText.opacity(isLead ? 0.86 : 0.9))
                        .lineSpacing(8.5)
                        .fixedSize(horizontal: false, vertical: true)

                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(number)
                            .font(.system(size: 11.5, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary.opacity(0.5))
                            .frame(width: 13, alignment: .trailing)
                        Text(text)
                            .font(.system(size: 14.25, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.assistantText.opacity(0.86))
                            .lineSpacing(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Theme.accentMuted.opacity(0.38))
                            .frame(width: 3.5, height: 3.5)
                            .padding(.top, 8.5)
                            .frame(width: 10)
                        Text(text)
                            .font(.system(size: 14.25, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.assistantText.opacity(0.86))
                            .lineSpacing(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .codeBlock(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .background(Theme.bgHover.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.vertical, 2)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [AssistantTextBlock] {
        useCache ? AssistantTextBlockCache.blocks(for: content) : AssistantTextBlock.parseIncremental(content)
    }
}

#if canImport(UIKit)
extension Notification.Name {
    /// 广播到所有 SelectionDismissibleTextView, 让它们清掉当前 selection。
    /// UITextView (isSelectable=true, isEditable=false) 不会因为外部 tap 自动清选区,
    /// 这是 UIKit 设计行为, 不是 bug; 我们通过这个通道补回"点别处就消失"的预期。
    static let dismissAssistantTextSelection = Notification.Name("phoneclaw.dismissAssistantTextSelection")
}

private final class SelectionDismissibleTextView: UITextView {
    private var dismissObserver: NSObjectProtocol?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .dismissAssistantTextSelection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 没有选区时设 nil 是 no-op, 不会有副作用; 所以可以无脑发广播。
            self?.selectedTextRange = nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let token = dismissObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

private struct AssistantAttributedLabel: UIViewRepresentable {
    let renderID: UUID
    let content: String
    let useCache: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.backgroundColor = .clear
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        guard context.coordinator.appliedContent != content else { return }
        label.attributedText = attributedText()
        context.coordinator.appliedContent = content
        context.coordinator.invalidateSizeCache()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? 348
        uiView.preferredMaxLayoutWidth = width
        return context.coordinator.sizeThatFits(
            renderID: renderID,
            content: content,
            width: width,
            label: uiView,
            useCache: useCache
        )
    }

    private func attributedText() -> NSAttributedString {
        if useCache {
            return AssistantRenderedTextCache.attributedText(
                for: renderID,
                content: content
            ) {
                SelectableAssistantTextView.attributedText(
                    from: AssistantTextBlockCache.blocks(for: content)
                )
            }
        }
        return SelectableAssistantTextView.attributedText(
            from: AssistantTextBlock.parseIncremental(content)
        )
    }

    final class Coordinator {
        var appliedContent: String?
        private var cachedSizeContent: String?
        private var cachedSizeWidth: CGFloat = 0
        private var cachedSize: CGSize?

        func invalidateSizeCache() {
            cachedSizeContent = nil
            cachedSizeWidth = 0
            cachedSize = nil
        }

        func sizeThatFits(renderID: UUID, content: String, width: CGFloat, label: UILabel, useCache: Bool) -> CGSize {
            let normalizedWidth = width.rounded(.toNearestOrAwayFromZero)
            if useCache,
               let size = AssistantRenderedTextCache.size(
                    for: .label,
                    renderID: renderID,
                    content: content,
                    width: normalizedWidth
               ) {
                return size
            }

            if cachedSizeContent == content,
               abs(cachedSizeWidth - normalizedWidth) < 0.5,
               let cachedSize {
                return cachedSize
            }

            let measured = label.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            let size = CGSize(width: width, height: ceil(measured.height))
            cachedSizeContent = content
            cachedSizeWidth = normalizedWidth
            cachedSize = size
            if useCache {
                AssistantRenderedTextCache.storeSize(
                    size,
                    for: .label,
                    renderID: renderID,
                    content: content,
                    width: normalizedWidth
                )
            }
            return size
        }
    }
}

private struct SelectableAssistantTextView: UIViewRepresentable {
    let renderID: UUID
    let content: String
    let useCache: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = SelectionDismissibleTextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.dataDetectorTypes = [.link]
        textView.linkTextAttributes = [
            .foregroundColor: Self.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.adjustsFontForContentSizeCategory = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard context.coordinator.appliedContent != content else { return }
        textView.attributedText = context.coordinator.attributedText(
            for: content,
            renderID: renderID,
            useCache: useCache
        )
        context.coordinator.appliedContent = content
        context.coordinator.invalidateSizeCache()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 348
        uiView.bounds.size.width = width
        return context.coordinator.sizeThatFits(
            renderID: renderID,
            content: content,
            width: width,
            textView: uiView,
            useCache: useCache
        )
    }

    final class Coordinator {
        var appliedContent: String?
        private var cachedContent: String?
        private var cachedAttributedText: NSAttributedString?
        private var cachedSizeContent: String?
        private var cachedSizeWidth: CGFloat = 0
        private var cachedSize: CGSize?

        func attributedText(for content: String, renderID: UUID, useCache: Bool) -> NSAttributedString {
            if cachedContent == content, let cachedAttributedText {
                return cachedAttributedText
            }

            let attributedText: NSAttributedString
            if useCache {
                attributedText = AssistantRenderedTextCache.attributedText(
                    for: renderID,
                    content: content
                ) {
                    SelectableAssistantTextView.attributedText(
                        from: AssistantTextBlockCache.blocks(for: content)
                    )
                }
            } else {
                attributedText = SelectableAssistantTextView.attributedText(
                    from: AssistantTextBlock.parseIncremental(content)
                )
            }
            cachedContent = content
            cachedAttributedText = attributedText
            return attributedText
        }

        func invalidateSizeCache() {
            cachedSizeContent = nil
            cachedSize = nil
            cachedSizeWidth = 0
        }

        func sizeThatFits(renderID: UUID, content: String, width: CGFloat, textView: UITextView, useCache: Bool) -> CGSize {
            let normalizedWidth = width.rounded(.toNearestOrAwayFromZero)
            if useCache,
               let size = AssistantRenderedTextCache.size(
                    for: .textView,
                    renderID: renderID,
                    content: content,
                    width: normalizedWidth
               ) {
                return size
            }

            if cachedSizeContent == content,
               abs(cachedSizeWidth - normalizedWidth) < 0.5,
               let cachedSize {
                return cachedSize
            }

            let measured = textView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            let size = CGSize(width: width, height: ceil(measured.height))
            cachedSizeContent = content
            cachedSizeWidth = normalizedWidth
            cachedSize = size
            if useCache {
                AssistantRenderedTextCache.storeSize(
                    size,
                    for: .textView,
                    renderID: renderID,
                    content: content,
                    width: normalizedWidth
                )
            }
            return size
        }
    }

    fileprivate static func attributedText(from blocks: [AssistantTextBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for block in blocks {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            switch block.kind {
            case .heading(let text, let level):
                result.append(NSAttributedString(
                    string: text,
                    attributes: attributes(
                        font: roundedFont(size: level == 1 ? 17 : 15.5, weight: .semibold),
                        color: UIColor(Theme.assistantText.opacity(0.94)),
                        lineSpacing: 7,
                        paragraphSpacing: 10,
                        paragraphSpacingBefore: result.length == 0 ? 0 : 10
                    )
                ))

            case .paragraph(let text, let isLead):
                result.append(NSAttributedString(
                    string: text,
                    attributes: attributes(
                        font: roundedFont(size: isLead ? 14 : 14.5, weight: .regular),
                        color: UIColor(Theme.assistantText.opacity(isLead ? 0.86 : 0.9)),
                        lineSpacing: 8.5,
                        paragraphSpacing: 10
                    )
                ))

            case .numbered(let number, let text):
                result.append(NSAttributedString(
                    string: "\(number). \(text)",
                    attributes: attributes(
                        font: roundedFont(size: 14.25, weight: .regular),
                        color: UIColor(Theme.assistantText.opacity(0.86)),
                        lineSpacing: 8,
                        paragraphSpacing: 10,
                        firstLineHeadIndent: 0,
                        headIndent: 20
                    )
                ))

            case .bullet(let text):
                result.append(NSAttributedString(
                    string: "• \(text)",
                    attributes: attributes(
                        font: roundedFont(size: 14.25, weight: .regular),
                        color: UIColor(Theme.assistantText.opacity(0.86)),
                        lineSpacing: 8,
                        paragraphSpacing: 10,
                        firstLineHeadIndent: 0,
                        headIndent: 18
                    )
                ))

            case .codeBlock(let text):
                result.append(NSAttributedString(
                    string: text,
                    attributes: attributes(
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        color: UIColor(Theme.textSecondary),
                        lineSpacing: 4,
                        paragraphSpacing: 10
                    )
                ))
            }
        }

        applyLinks(in: result)
        return result
    }

    private static func applyLinks(in attributedText: NSMutableAttributedString) {
        applyMarkdownLinks(in: attributedText)
        applyRawURLLinks(in: attributedText)
        applyRawDomainLinks(in: attributedText)
    }

    private static func applyMarkdownLinks(in attributedText: NSMutableAttributedString) {
        let pattern = #"\[([^\]\n]{1,160})\]\((https?://[^\s)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullText = attributedText.string
        let matches = regex.matches(
            in: fullText,
            range: NSRange(location: 0, length: (fullText as NSString).length)
        )

        for match in matches.reversed() {
            guard match.numberOfRanges == 3 else { continue }
            let nsText = attributedText.string as NSString
            let label = nsText.substring(with: match.range(at: 1))
            let rawURL = nsText.substring(with: match.range(at: 2))
            guard let url = URL(string: rawURL) else { continue }

            var attributes = attributedText.attributes(at: max(0, match.range.location), effectiveRange: nil)
            attributes[.link] = url
            attributes[.foregroundColor] = linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributedText.replaceCharacters(
                in: match.range,
                with: NSAttributedString(string: label, attributes: attributes)
            )
        }
    }

    private static func applyRawURLLinks(in attributedText: NSMutableAttributedString) {
        let pattern = #"https?://[^\s\]\)）>，。；;、]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullText = attributedText.string
        let matches = regex.matches(
            in: fullText,
            range: NSRange(location: 0, length: (fullText as NSString).length)
        )

        for match in matches {
            let rawURL = (fullText as NSString).substring(with: match.range)
            guard let url = URL(string: rawURL) else { continue }
            attributedText.addAttributes([
                .link: url,
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private static func applyRawDomainLinks(in attributedText: NSMutableAttributedString) {
        let pattern = #"(?<![@/:])\b(?:www\.)[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s\]\)）>，。；;、]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullText = attributedText.string
        let matches = regex.matches(
            in: fullText,
            range: NSRange(location: 0, length: (fullText as NSString).length)
        )

        for match in matches {
            if attributedText.attribute(.link, at: match.range.location, effectiveRange: nil) != nil {
                continue
            }
            let rawDomain = (fullText as NSString).substring(with: match.range)
            guard let url = URL(string: "https://\(rawDomain)") else { continue }
            attributedText.addAttributes([
                .link: url,
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private static var linkColor: UIColor {
        UIColor.systemBlue
    }

    private static func attributes(
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        paragraphSpacingBefore: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = paragraphSpacing
        paragraphStyle.paragraphSpacingBefore = paragraphSpacingBefore
        paragraphStyle.firstLineHeadIndent = firstLineHeadIndent
        paragraphStyle.headIndent = headIndent
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let baseFont = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded) else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

private final class AssistantAttributedTextCacheBox {
    let attributedText: NSAttributedString

    init(attributedText: NSAttributedString) {
        self.attributedText = attributedText
    }
}

private final class AssistantTextSizeCacheBox {
    let size: CGSize

    init(size: CGSize) {
        self.size = size
    }
}

private enum AssistantRenderedTextKind: String {
    case label
    case textView
}

private enum AssistantRenderedTextCache {
    private static let attributedCache: NSCache<NSString, AssistantAttributedTextCacheBox> = {
        let cache = NSCache<NSString, AssistantAttributedTextCacheBox>()
        cache.countLimit = 700
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    private static let sizeCache: NSCache<NSString, AssistantTextSizeCacheBox> = {
        let cache = NSCache<NSString, AssistantTextSizeCacheBox>()
        cache.countLimit = 1_400
        return cache
    }()

    static func attributedText(
        for renderID: UUID,
        content: String,
        make: () -> NSAttributedString
    ) -> NSAttributedString {
        let key = attributedKey(renderID: renderID, content: content)
        if let cached = attributedCache.object(forKey: key) {
            return cached.attributedText
        }

        let attributedText = make()
        attributedCache.setObject(
            AssistantAttributedTextCacheBox(attributedText: attributedText),
            forKey: key,
            cost: max(1, content.utf8.count * 2)
        )
        return attributedText
    }

    static func size(
        for kind: AssistantRenderedTextKind,
        renderID: UUID,
        content: String,
        width: CGFloat
    ) -> CGSize? {
        sizeCache.object(
            forKey: sizeKey(kind: kind, renderID: renderID, content: content, width: width)
        )?.size
    }

    static func storeSize(
        _ size: CGSize,
        for kind: AssistantRenderedTextKind,
        renderID: UUID,
        content: String,
        width: CGFloat
    ) {
        sizeCache.setObject(
            AssistantTextSizeCacheBox(size: size),
            forKey: sizeKey(kind: kind, renderID: renderID, content: content, width: width)
        )
    }

    private static func attributedKey(renderID: UUID, content: String) -> NSString {
        NSString(string: "\(renderID.uuidString)|\(content)")
    }

    private static func sizeKey(
        kind: AssistantRenderedTextKind,
        renderID: UUID,
        content: String,
        width: CGFloat
    ) -> NSString {
        let roundedWidth = Int(width.rounded(.toNearestOrAwayFromZero))
        return NSString(string: "\(kind.rawValue)|\(roundedWidth)|\(renderID.uuidString)|\(content)")
    }
}
#endif

private final class AssistantTextBlockCacheBox {
    let blocks: [AssistantTextBlock]

    init(blocks: [AssistantTextBlock]) {
        self.blocks = blocks
    }
}

private enum AssistantTextBlockCache {
    private static let cache: NSCache<NSString, AssistantTextBlockCacheBox> = {
        let cache = NSCache<NSString, AssistantTextBlockCacheBox>()
        cache.countLimit = 700
        cache.totalCostLimit = 2_000_000
        return cache
    }()

    static func blocks(for content: String) -> [AssistantTextBlock] {
        let key = NSString(string: content)
        if let cached = cache.object(forKey: key) {
            return cached.blocks
        }

        let parsed = AssistantTextBlock.parse(content)
        cache.setObject(
            AssistantTextBlockCacheBox(blocks: parsed),
            forKey: key,
            cost: max(1, content.utf8.count)
        )
        return parsed
    }
}

private struct AssistantTextBlock: Identifiable {
    enum Kind {
        case heading(String, level: Int)
        case paragraph(String, isLead: Bool)
        case numbered(String, String)
        case bullet(String)
        case codeBlock(String)
    }

    let id: Int
    var kind: Kind

    static func parse(_ source: String) -> [AssistantTextBlock] {
        parseLines(normalizedLines(from: source))
    }

    /// 规范化换行后按行切分。增量解析器复用此入口, 保证行切分口径与全量解析完全一致。
    static func normalizedLines(from source: String) -> [String] {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func parseLines(_ lines: [String]) -> [AssistantTextBlock] {
        var blocks: [AssistantTextBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func flushParagraph() {
            let text = clean(paragraph.joined(separator: " "))
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            let isLead = text.count <= 16 && text.hasSuffix("：")
            blocks.append(.init(id: blocks.count, kind: .paragraph(text, isLead: isLead)))
        }

        func flushCodeBlock() {
            let text = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            codeLines.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.init(id: blocks.count, kind: .codeBlock(text)))
        }

        func appendToLastList(_ text: String) -> Bool {
            let text = clean(text)
            guard !text.isEmpty, let lastIndex = blocks.indices.last else { return false }
            switch blocks[lastIndex].kind {
            case .numbered(let number, let existing):
                blocks[lastIndex].kind = .numbered(number, clean(existing + " " + text))
                return true
            case .bullet(let existing):
                blocks[lastIndex].kind = .bullet(clean(existing + " " + text))
                return true
            case .heading, .paragraph, .codeBlock:
                return false
            }
        }

        for rawLine in lines {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("```") {
                if isInCodeBlock {
                    flushCodeBlock()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flushParagraph()
                continue
            }

            if rawLine.first?.isWhitespace == true, appendToLastList(rawLine) {
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isStandaloneMarkdownMarker(line) {
                flushParagraph()
                continue
            }

            if let heading = headingItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .heading(clean(heading.text), level: heading.level)))
                continue
            }

            if let item = numberedItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .numbered(item.number, clean(item.text))))
                continue
            }

            if let item = bulletItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .bullet(clean(item))))
                continue
            }

            paragraph.append(line)
        }

        flushParagraph()
        flushCodeBlock()
        return blocks
    }

    private static func headingItem(from line: String) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard (1...4).contains(level), index < line.endIndex, line[index].isWhitespace else {
            return nil
        }
        let text = line[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func numberedItem(from line: String) -> (number: String, text: String)? {
        var index = line.startIndex
        var number = ""
        while index < line.endIndex, line[index].isNumber {
            number.append(line[index])
            index = line.index(after: index)
        }
        guard !number.isEmpty, index < line.endIndex else { return nil }
        let marker = line[index]
        guard marker == "." || marker == "、" || marker == ")" || marker == "）" else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else { return nil }
        let text = line[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, text)
    }

    private static func bulletItem(from line: String) -> String? {
        let markers = ["- ", "* ", "• ", "· "]
        for marker in markers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func isStandaloneMarkdownMarker(_ line: String) -> Bool {
        ["*", "**", "***", "_", "__", "___", "-", "--", "---"].contains(line)
    }

    private static func clean(_ raw: String) -> String {
        var text = raw
        for token in [
            "**", "__", "`",
            "(DEVICE_SKILLS)", "（DEVICE_SKILLS）",
            "(CONTENT_SKILLS)", "（CONTENT_SKILLS）",
            "(NETWORK_SKILLS)", "（NETWORK_SKILLS）"
        ] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "：  ", with: "：")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ,", with: ",")
        text = text.replacingOccurrences(of: " .", with: ".")
        text = text.replacingOccurrences(of: " :", with: ":")
        text = text.replacingOccurrences(of: " ：", with: "：")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 流式增量解析 (block freezing)
//
// 流式时每帧拿到的是"到目前为止的全文", 整段重解析是 O(n²): 每帧解析当前全长,
// 沿整条流累加 ≈ N², 所以输出越长越卡。但前面已写完的块不会再变, 只有"正在写的最后
// 一个块"每帧在动。这里缓存已定稿前缀的块, 每帧只解析尾部那一个块, 把流式解析摊到 O(n)。
//
// 单槽设计: 同一时刻只有一条 AI 消息在流式, 其 content 单调增长 → 前缀稳定命中;
// 历史消息内容不变, 走各视图层自己的 content 守卫/缓存, 不会进到这里。前缀一旦对不上
// (换消息 / 重试 / 编辑) 就整体重建, 退化为全量解析, 正确性不受影响。

extension AssistantTextBlock {
    /// 解析 lines, 但**忽略最后一行**(它正在打字, 语义未定)且**不定稿最后一个块**。
    /// 返回 (已定稿的块, 这些块消费的行数)。调用方对剩余行做尾部全量解析以渲染正在写的块。
    ///
    /// 定稿安全性: 最后一行可能是空行 / 缩进续行 / 新块起始, 缩进续行还会反向把内容接到
    /// 前面的 list 块上, 所以只对已固定的行做决策; 最后一个块(及末尾未闭合的 list)永远留尾部。
    static func parseStablePrefix(_ lines: [String]) -> (blocks: [AssistantTextBlock], lineCount: Int) {
        let lines = lines.isEmpty ? lines : Array(lines.dropLast())
        var blocks: [AssistantTextBlock] = []
        var startLines: [Int] = []
        var paragraph: [String] = []
        var paragraphStart = -1
        var codeLines: [String] = []
        var codeStart = -1
        var isInCodeBlock = false

        func flushParagraph() {
            let text = clean(paragraph.joined(separator: " "))
            let start = paragraphStart
            paragraph.removeAll()
            paragraphStart = -1
            guard !text.isEmpty else { return }
            let isLead = text.count <= 16 && text.hasSuffix("：")
            blocks.append(.init(id: blocks.count, kind: .paragraph(text, isLead: isLead)))
            startLines.append(start)
        }
        func flushCodeBlock() {
            let text = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let start = codeStart
            codeLines.removeAll()
            codeStart = -1
            guard !text.isEmpty else { return }
            blocks.append(.init(id: blocks.count, kind: .codeBlock(text)))
            startLines.append(start)
        }
        func appendToLastList(_ raw: String) -> Bool {
            let text = clean(raw)
            guard !text.isEmpty, let lastIndex = blocks.indices.last else { return false }
            switch blocks[lastIndex].kind {
            case .numbered(let number, let existing):
                blocks[lastIndex].kind = .numbered(number, clean(existing + " " + text))
                return true
            case .bullet(let existing):
                blocks[lastIndex].kind = .bullet(clean(existing + " " + text))
                return true
            case .heading, .paragraph, .codeBlock:
                return false
            }
        }

        for (index, rawLine) in lines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("```") {
                if isInCodeBlock {
                    flushCodeBlock()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                    codeStart = index
                }
                continue
            }
            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }
            if trimmedLine.isEmpty {
                flushParagraph()
                continue
            }
            if rawLine.first?.isWhitespace == true, appendToLastList(rawLine) {
                continue
            }
            let line = trimmedLine
            if isStandaloneMarkdownMarker(line) {
                flushParagraph()
                continue
            }
            if let heading = headingItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .heading(clean(heading.text), level: heading.level)))
                startLines.append(index)
                continue
            }
            if let item = numberedItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .numbered(item.number, clean(item.text))))
                startLines.append(index)
                continue
            }
            if let item = bulletItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .bullet(clean(item))))
                startLines.append(index)
                continue
            }
            if paragraph.isEmpty { paragraphStart = index }
            paragraph.append(line)
        }
        // 末尾不 flush: paragraph / code buffer 是正在写的最后一个块, 留给尾部。

        let hasPendingParagraph = !paragraph.isEmpty
        let hasPending = hasPendingParagraph || isInCodeBlock
        let lastIsList: Bool = {
            guard let last = blocks.last else { return false }
            if case .bullet = last.kind { return true }
            if case .numbered = last.kind { return true }
            return false
        }()

        let stableCount: Int
        let lineCount: Int
        if !hasPending {
            // 末尾已 flush 的块就是正在写的那个 → 不定稿。
            stableCount = blocks.isEmpty ? 0 : blocks.count - 1
            lineCount = blocks.isEmpty ? 0 : startLines[blocks.count - 1]
        } else if lastIsList {
            // 末尾 list 可能被后续缩进续行扩展 → 不定稿。
            stableCount = blocks.isEmpty ? 0 : blocks.count - 1
            lineCount = blocks.isEmpty ? 0 : startLines[blocks.count - 1]
        } else {
            // 末尾非 list 块已被 pending 封口; pending 是正在写的新块。
            stableCount = blocks.count
            lineCount = hasPendingParagraph ? paragraphStart : codeStart
        }

        let stable = stableCount > 0 ? Array(blocks[0..<stableCount]) : []
        return (stable, max(0, lineCount))
    }

    /// 流式增量解析入口。语义等价于 `parse(source)`, 但复用已定稿前缀, 每帧只解析尾部。
    static func parseIncremental(_ source: String) -> [AssistantTextBlock] {
        StreamingMarkdownParseCache.shared.blocks(for: source)
    }
}

private final class StreamingMarkdownParseCache: @unchecked Sendable {
    static let shared = StreamingMarkdownParseCache()

    private let lock = NSLock()
    private var stableBlocks: [AssistantTextBlock] = []
    private var stableLineCount = 0
    private var firstLine = ""
    private var boundaryLine = ""

    func blocks(for source: String) -> [AssistantTextBlock] {
        lock.lock()
        defer { lock.unlock() }

        let lines = AssistantTextBlock.normalizedLines(from: source)

        // 前缀对不上(换消息 / 重试 / 编辑)就丢弃缓存, 退化为全量, 正确性不受影响。
        if !isPrefixConsistent(with: lines) {
            stableBlocks = []
            stableLineCount = 0
        }

        // 从已定稿边界继续, 把本帧新固定下来的块并入缓存。每行至多被定稿解析一次。
        if stableLineCount <= lines.count {
            let suffix = Array(lines[stableLineCount...])
            let (newlyStable, advance) = AssistantTextBlock.parseStablePrefix(suffix)
            for block in newlyStable {
                stableBlocks.append(AssistantTextBlock(id: stableBlocks.count, kind: block.kind))
            }
            stableLineCount += advance
        }

        firstLine = lines.first ?? ""
        boundaryLine = stableLineCount > 0 ? lines[stableLineCount - 1] : ""

        // 尾部(正在写的那个块)每帧重解析 —— 短、有界。
        guard stableLineCount < lines.count else { return stableBlocks }
        let tail = AssistantTextBlock.parseLines(Array(lines[stableLineCount...]))
        var result = stableBlocks
        for block in tail {
            result.append(AssistantTextBlock(id: result.count, kind: block.kind))
        }
        return result
    }

    /// O(1) 前缀校验: 首行与定稿边界行不变即认为是同一条消息的增量。
    /// 如前缀不一致就重建缓存, 让重试 / 编辑 / 换消息回到全量解析路径。
    private func isPrefixConsistent(with lines: [String]) -> Bool {
        guard stableLineCount > 0 else { return true }
        guard lines.count >= stableLineCount else { return false }
        guard (lines.first ?? "") == firstLine else { return false }
        return lines[stableLineCount - 1] == boundaryLine
    }
}

// MARK: - Thinking Card

struct ThinkingCardView: View {
    let text: String
    let isExpanded: Bool
    let onToggle: () -> Void

    private var lineCount: Int {
        max(1, text.components(separatedBy: .newlines).count)
    }

    private var previewText: String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return tr("已捕获思考内容", "Captured thinking content") }
        return String(compact.prefix(72)) + (compact.count > 72 ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // T 字标 — 跟顶栏 Think chip 的开启态同一套语言 (accentSubtle 圆角方块 + 品牌色 T),
                // 取代原来高细节的 brain.head.profile, 和整体图标风格统一。
                Text("T")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("思考", "Think"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    if !isExpanded {
                        Text(previewText)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(tr("\(lineCount) 行", "\(lineCount) lines"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                Rectangle().fill(Theme.borderSubtle).frame(height: 1)

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Skill Card

struct SkillCardView: View {
    let card: SkillCard
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isSkillDone: Bool { card.skillStatus == "done" }

    private var toolKey: String {
        (card.toolName ?? "").lowercased()
    }

    private func toolNameContains(_ fragments: String...) -> Bool {
        fragments.contains { toolKey.contains($0) }
    }

    private enum SkillKind {
        case calendar
        case reminders
        case contacts
        case health
        case clipboard
        case translate
        case generic
    }

    private var skillKind: SkillKind {
        let key = "\(card.skillName) \(card.toolName ?? "")".lowercased()
        if key.contains("health") || key.contains("健康") || key.contains("步数") {
            return .health
        }
        if key.contains("calendar") || key.contains("日历") || key.contains("日程") {
            return .calendar
        }
        if key.contains("reminder") || key.contains("提醒") || key.contains("待办") {
            return .reminders
        }
        if key.contains("contact") || key.contains("通讯录") || key.contains("联系人") {
            return .contacts
        }
        if key.contains("clipboard") || key.contains("剪贴板") {
            return .clipboard
        }
        if key.contains("translate") || key.contains("翻译") {
            return .translate
        }
        return .generic
    }

    private var iconName: String {
        if toolNameContains("contacts-search") {
            return "magnifyingglass"
        }
        if toolNameContains("contacts-upsert") {
            return "person.badge.plus"
        }
        if toolNameContains("contacts-delete") {
            return "trash"
        }
        if toolNameContains("health-report") {
            return "doc.text.magnifyingglass"
        }
        if toolNameContains("health-sleep") {
            return "moon"
        }
        if toolNameContains("health-workout") {
            return "figure.run"
        }
        if toolNameContains("health-weight") {
            return "scalemass"
        }
        if toolNameContains("health-active-energy") {
            return "flame"
        }
        if toolNameContains("health-heart") {
            return "heart"
        }

        switch skillKind {
        case .calendar: return "calendar"
        case .reminders: return "bell"
        case .contacts: return "person.crop.circle"
        case .health: return "figure.walk"
        case .clipboard: return "doc.on.clipboard"
        case .translate: return "character.bubble"
        case .generic: return "sparkles"
        }
    }

    private var statusTitle: String {
        if isSkillDone {
            if toolNameContains("calendar-create") {
                return tr("创建了日程", "Created Event")
            }
            if toolNameContains("reminders-create") {
                return tr("创建了提醒", "Created Reminder")
            }
            if toolNameContains("contacts-search") {
                return tr("查找了联系人", "Searched Contacts")
            }
            if toolNameContains("contacts-upsert") {
                return tr("保存了联系人", "Saved Contact")
            }
            if toolNameContains("contacts-delete") {
                return tr("删除了联系人", "Deleted Contact")
            }
            if toolNameContains("clipboard-write") {
                return tr("写入了剪贴板", "Updated Clipboard")
            }
            if toolNameContains("clipboard-read") {
                return tr("读取了剪贴板", "Read Clipboard")
            }
            if toolNameContains("health-report") {
                return tr("生成了健康报告", "Generated Health Report")
            }
            if toolNameContains("health-sleep") {
                return tr("读取了睡眠", "Read Sleep")
            }
            if toolNameContains("health-workout") {
                return tr("读取了运动记录", "Read Workouts")
            }
            if toolNameContains("health-weight") {
                return tr("读取了体重", "Read Weight")
            }
            if toolNameContains("health-distance") {
                return tr("读取了距离", "Read Distance")
            }
            if toolNameContains("health-active-energy") {
                return tr("读取了活动消耗", "Read Active Energy")
            }
            if toolNameContains("health-heart") {
                return tr("读取了心率", "Read Heart Rate")
            }
            if toolNameContains("health-steps") {
                return tr("读取了步数", "Read Steps")
            }
            if skillKind == .translate {
                return tr("翻译完成", "Translation Ready")
            }

            switch skillKind {
            case .calendar: return tr("处理了日程", "Used Calendar")
            case .reminders: return tr("处理了提醒", "Used Reminders")
            case .contacts: return tr("处理了联系人", "Used Contacts")
            case .health: return tr("读取了健康数据", "Read Health Data")
            case .clipboard: return tr("读取了剪贴板", "Read Clipboard")
            case .translate: return tr("翻译完成", "Translation Ready")
            case .generic: return tr("使用了\(card.skillName)", "Used \(card.skillName)")
            }
        }

        if toolNameContains("calendar-create") {
            return tr("正在创建日程…", "Creating Event…")
        }
        if toolNameContains("reminders-create") {
            return tr("正在创建提醒…", "Creating Reminder…")
        }
        if toolNameContains("contacts-search") {
            return tr("正在查找联系人…", "Searching Contacts…")
        }
        if toolNameContains("contacts-upsert") {
            return tr("正在保存联系人…", "Saving Contact…")
        }
        if toolNameContains("contacts-delete") {
            return tr("正在删除联系人…", "Deleting Contact…")
        }
        if toolNameContains("clipboard-write") {
            return tr("正在写入剪贴板…", "Updating Clipboard…")
        }
        if toolNameContains("clipboard-read") {
            return tr("正在读取剪贴板…", "Reading Clipboard…")
        }
        if toolNameContains("health-report") {
            return tr("正在生成健康报告…", "Generating Health Report…")
        }
        if toolNameContains("health-sleep") {
            return tr("正在读取睡眠…", "Reading Sleep…")
        }
        if toolNameContains("health-workout") {
            return tr("正在读取运动记录…", "Reading Workouts…")
        }
        if toolNameContains("health-weight") {
            return tr("正在读取体重…", "Reading Weight…")
        }
        if toolNameContains("health-distance") {
            return tr("正在读取距离…", "Reading Distance…")
        }
        if toolNameContains("health-active-energy") {
            return tr("正在读取活动消耗…", "Reading Active Energy…")
        }
        if toolNameContains("health-heart") {
            return tr("正在读取心率…", "Reading Heart Rate…")
        }
        if toolNameContains("health-steps") {
            return tr("正在读取步数…", "Reading Steps…")
        }

        switch skillKind {
        case .calendar: return tr("正在处理日程…", "Using Calendar…")
        case .reminders: return tr("正在处理提醒…", "Using Reminders…")
        case .contacts: return tr("正在处理联系人…", "Using Contacts…")
        case .health: return tr("正在读取健康数据…", "Reading Health Data…")
        case .clipboard: return tr("正在读取剪贴板…", "Reading Clipboard…")
        case .translate: return tr("正在翻译…", "Translating…")
        case .generic: return tr("正在使用\(card.skillName)…", "Using \(card.skillName)…")
        }
    }

    private var currentStep: Int {
        switch card.skillStatus {
        case "identified": return 0
        case "loaded":     return 1
        case let s where s?.hasPrefix("executing") == true: return 2
        case "done":       return 3
        default:           return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ZStack {
                    Image(systemName: iconName)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.textTertiary.opacity(0.76))
                        .frame(width: 16, height: 16)
                        .opacity(isSkillDone ? 1 : 0)

                    SpinnerIcon()
                        .frame(width: 16, height: 16)
                        .opacity(isSkillDone ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.3), value: isSkillDone)

                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.78))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isSkillDone)

                Text(isExpanded ? tr("收起", "Hide") : tr("查看", "View"))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textTertiary.opacity(0.52))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.52))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .padding(.vertical, isExpanded ? 10 : 2)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                Rectangle().fill(Theme.borderSubtle).frame(height: 1)

                VStack(alignment: .leading, spacing: 6) {
                    stepRow(label: tr("理解需求", "Understand request"),
                            done: currentStep > 0,
                            active: currentStep == 0)
                    stepRow(label: tr("准备能力", "Prepare skill"),
                            done: currentStep > 1,
                            active: currentStep == 1)
                    stepRow(label: tr("执行能力", "Run skill"),
                            done: currentStep > 2,
                            active: currentStep == 2)
                    stepRow(label: tr("整理回复", "Compose reply"),
                            done: isSkillDone,
                            active: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(.easeInOut(duration: 0.2), value: currentStep)
            }
        }
        .frame(maxWidth: isExpanded ? 322 : nil, alignment: .leading)
        .background(
            isExpanded ? Theme.bgHover.opacity(0.24) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.borderSubtle.opacity(0.9), lineWidth: 1)
            }
        }
    }

    private func stepRow(label: String, done: Bool, active: Bool = false) -> some View {
        HStack(spacing: 7) {
            Group {
                if done {
                    Circle()
                        .fill(Theme.accentMuted.opacity(0.58))
                        .frame(width: 5, height: 5)
                } else if active {
                    ProgressView().controlSize(.mini).tint(Theme.textTertiary)
                } else {
                    Circle()
                        .fill(Theme.textTertiary.opacity(0.24))
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 12, height: 12)

            Text(label)
                .font(.system(size: 11.5, weight: .regular, design: .rounded))
                .foregroundStyle(done ? Theme.textSecondary.opacity(0.74) : Theme.textTertiary.opacity(0.72))
        }
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (time * 1.35 + Double(index) * 0.22)
                        .truncatingRemainder(dividingBy: 1.0)
                    let wave = (sin(phase * .pi * 2.0) + 1.0) / 2.0

                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 6, height: 6)
                        .opacity(0.28 + wave * 0.52)
                        .scaleEffect(0.72 + wave * 0.28)
                }
            }
            .frame(height: 20)
        }
    }
}
