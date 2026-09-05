import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case agent
    case messages
    case activity
    case projects
    case connections

    var id: String { rawValue }

    var accessibilityLabel: String {
        rawValue.capitalized
    }
}
