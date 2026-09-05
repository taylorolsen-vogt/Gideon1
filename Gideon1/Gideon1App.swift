import SwiftUI

@main
struct Gideon1App: App {
    @StateObject private var modelSelection = GideonModelSelectionStore.shared
    @StateObject private var session = AppSessionStore.shared
    @StateObject private var dataMode = AppDataModeStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelSelection)
                .environmentObject(session)
                .environmentObject(dataMode)
        }
    }
}
