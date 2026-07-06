import SwiftUI

@main
struct Gideon1App: App {
    @StateObject private var modelSelection = GideonModelSelectionStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelSelection)
        }
    }
}
