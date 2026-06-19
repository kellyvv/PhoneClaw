import Foundation

struct LiveLandAgentResult: Equatable {
    let success: Bool
    let dialog: String
    let skillID: String?
    let toolName: String?
}
