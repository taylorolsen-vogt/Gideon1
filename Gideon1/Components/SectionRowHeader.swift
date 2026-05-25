import SwiftUI

struct SectionRowHeader: View {
    let title: String
    var collapsed: Bool = false
    var showChevron: Bool = true

    var body: some View {
        HStack {
            Eyebrow(text: title, size: 12, color: AppTheme.textTertiary)
            Spacer()
            if showChevron {
                CollapseChevron(isCollapsed: collapsed)
            }
        }
    }
}
