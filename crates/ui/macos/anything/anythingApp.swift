import SwiftUI

@main
struct anythingApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 620)
    }
}
