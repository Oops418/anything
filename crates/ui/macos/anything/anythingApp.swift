import SwiftUI
import OSLog
import Combine

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "anything", category: "App")

@main
struct anythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launchController = LaunchController()

    var body: some Scene {
        WindowGroup {
            RootView(controller: launchController)
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
    @ObservedObject var controller: LaunchController

    var body: some View {
        Group {
            switch controller.state {
            case .launching:
                BackendLoadingView()
            case .ready:
                ContentView()
            case .failed(let error):
                BackendErrorView(message: error)
            }
        }
        .task {
            controller.startIfNeeded()
        }
    }
}

private struct BackendLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
            Text("Starting backend...")
                .font(.headline)
            Text("Preparing the local search service.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 400, height: 260)
        .padding()
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

// MARK: - Launch state

enum LaunchState {
    case launching
    case ready
    case failed(String)
}

@MainActor
final class LaunchController: ObservableObject {
    @Published private(set) var state: LaunchState = .launching
    private var didStart = false

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        Task(priority: .userInitiated) {
            do {
                try await BackendLauncher.shared.launchAndWait()
                await MainActor.run {
                    self.state = .ready
                }
            } catch {
                log.error("Backend launch failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        BackendLauncher.shared.terminate()
    }
}
