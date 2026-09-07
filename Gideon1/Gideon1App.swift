import SwiftUI

@main
struct Gideon1App: App {
    @StateObject private var session = AppSessionStore.shared
    @StateObject private var dataMode = AppDataModeStore.shared
    @StateObject private var modelSelection = GideonModelSelectionStore.shared

    var body: some Scene {
        WindowGroup {
            if isIsolationTestHost {
                Color.clear
            } else {
                RootView()
                    .environmentObject(modelSelection)
                    .environmentObject(session)
                    .environmentObject(dataMode)
                    .onOpenURL { url in
                        session.handleIncomingURL(url)
                    }
            }
        }
    }

    private var isIsolationTestHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--isolation-tests")
        #else
        false
        #endif
    }
}
