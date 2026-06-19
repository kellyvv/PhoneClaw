import Foundation
import UIKit

@MainActor
final class LiveLandSkillPromptHaptics {
    private static let supportedDetails: Set<String> = [
        "正在查询",
        "正在执行",
        "正在处理",
        "正在整理",
        "结果展示"
    ]

    private let impactFeedback = UIImpactFeedbackGenerator(style: .rigid)

    func prepare() {
        impactFeedback.prepare()
    }

    func play(for detail: String) {
        guard Self.supportedDetails.contains(detail) else { return }
        impactFeedback.impactOccurred(intensity: 1.0)
        impactFeedback.prepare()
    }
}
