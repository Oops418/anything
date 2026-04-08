import SwiftUI
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "anything", category: "App")

@main
struct anythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(state: appDelegate.launchState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 620)

        Window("Treemap", id: "treemap") {
            TreemapWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
    }
}

// MARK: - Root gating view

private struct RootView: View {
    let state: LaunchState

    var body: some View {
        switch state {
        case .ready:
            ContentView()
        case .failed(let error):
            BackendErrorView(message: error)
        }
    }
}

private struct BackendErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Backend failed to start")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 400, height: 260)
        .padding()
    }
}

// MARK: - App delegate (runs before SwiftUI scene lifecycle)

enum LaunchState {
    case ready
    case failed(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set synchronously in `applicationWillFinishLaunching` — SwiftUI reads it
    /// only after the delegate phase completes, so the UI always sees a final value.
    private(set) var launchState: LaunchState = .ready

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            try BackendLauncher.shared.launchAndWait()
        } catch {
            log.error("Backend launch failed: \(error.localizedDescription)")
            launchState = .failed(error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendLauncher.shared.terminate()
    }
}
