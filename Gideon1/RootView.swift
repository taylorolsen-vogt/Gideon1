import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .agent
    @StateObject private var messagesStore = MessagesSessionStore()

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            // Orb floats behind every page, centered.
            OrbView(size: 398)
                .opacity(0.90)
                .offset(y: 22)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .white.opacity(0.28), location: 0.26),
                            .init(color: .white.opacity(0.78), location: 0.46),
                            .init(color: .white, location: 0.62),
                            .init(color: .white, location: 0.86),
                            .init(color: .white.opacity(0.30), location: 0.95),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)

            // Page content.
            Group {
                switch selection {
                case .agent:    AgentView()
                case .messages: MessagesView(store: messagesStore)
                case .activity: ActivityView()
                case .projects: ProjectView()
                case .connections: ConnectionsView()
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
