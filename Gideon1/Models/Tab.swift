import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case agent
    case messages
    case activity
    case projects
    case health

    var id: String { rawValue }
}
