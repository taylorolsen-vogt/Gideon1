import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .agent

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            // Orb floats behind every page, centered.
            OrbView(size: 398)
                .opacity(0.95)
                .offset(y: 0)
                .allowsHitTesting(false)

            // Page content.
            Group {
                switch selection {
                case .agent:    AgentView()
                case .messages: MessagesView()
                case .activity: ActivityView()
                case .projects: ProjectView()
                case .health:   HealthView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        // Place tab row in the bottom safe area so taps remain reliable across all pages.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selection: $selection)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(Color.clear)
        }
    }
}

#Preview {
    RootView()
}
