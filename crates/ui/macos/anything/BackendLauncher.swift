import Foundation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "anything", category: "BackendLauncher")

/// Manages the lifecycle of the embedded Rust backend process.
final class BackendLauncher {

    // MARK: - Configuration

    /// Name of the binary as added to the Xcode project (placed in Contents/Resources).
    static let binaryName = "store"

    /// How long to wait for the backend to emit its ready signal before giving up.
    static let startupTimeout: TimeInterval = 1

    /// The line the Rust binary prints to stdout when it is ready to accept work.
    /// Change this to match whatever your binary actually prints.
    static let readySignal = "ready"

    // MARK: - State

    private(set) var process: Process?
    static let shared = BackendLauncher()
    private init() {}

    // MARK: - Launch

    /// Synchronously starts the backend and blocks until it signals readiness or the
    /// timeout elapses. Throws if the binary cannot be found or the process exits early.
    func launchAndWait() async throws {
        let binaryURL = try resolvedBinaryURL()
        log.info("Launching backend: \(binaryURL.path)")

        let p = Process()
        p.executableURL = binaryURL
        p.currentDirectoryURL = binaryURL.deletingLastPathComponent()

        // Capture stdout so we can detect the ready signal.
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()          // suppress stderr noise in logs

        try p.run()
        self.process = p

        try await waitForReadySignal(pipe: outPipe, process: p)
        log.info("Backend is ready (pid \(p.processIdentifier))")
    }

    /// Terminates the backend process. Safe to call more than once.
    func terminate() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        p.waitUntilExit()
        log.info("Backend terminated")
    }

    // MARK: - Helpers

    private func resolvedBinaryURL() throws -> URL {
        // Xcode copies the binary into Contents/Resources when added via the
        // "Copy Bundle Resources" build phase.
        guard let url = Bundle.main.url(forResource: Self.binaryName, withExtension: nil) else {
            throw LaunchError.binaryNotFound(
                Bundle.main.resourceURL?.appendingPathComponent(Self.binaryName).path ?? Self.binaryName
            )
        }
        // Resources are not executable by default — ensure the bit is set.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let current = (attrs[.posixPermissions] as? Int) ?? 0o644
        if current & 0o100 == 0 {
            try FileManager.default.setAttributes(
                [.posixPermissions: current | 0o755],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    /// Reads stdout line-by-line until the ready signal appears, the process dies,
    /// or the timeout elapses.
    private func waitForReadySignal(pipe: Pipe, process p: Process) async throws {
        let handle = pipe.fileHandleForReading
        let waitQueue = DispatchQueue(label: "anything.backend.ready", qos: .userInitiated)
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReadyWaitResult, Error>) in
            let readSource = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: waitQueue)
            let timeoutSource = DispatchSource.makeTimerSource(queue: waitQueue)
            var bufferedText = ""
            var finished = false

            func finish(_ result: Result<ReadyWaitResult, Error>) {
                guard !finished else { return }
                finished = true
                p.terminationHandler = nil
                readSource.cancel()
                timeoutSource.cancel()
                continuation.resume(with: result)
            }

            func consumeBufferedLines() {
                while let newlineRange = bufferedText.rangeOfCharacter(from: .newlines) {
                    let line = String(bufferedText[..<newlineRange.lowerBound])
                    bufferedText.removeSubrange(..<newlineRange.upperBound)
                    log.debug("[backend] \(line)")
                    if line.contains(Self.readySignal) {
                        finish(.success(.ready))
                        return
                    }
                }
            }

            readSource.setEventHandler {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                bufferedText += String(decoding: data, as: UTF8.self)
                consumeBufferedLines()
            }

            timeoutSource.schedule(deadline: .now() + Self.startupTimeout)
            timeoutSource.setEventHandler {
                finish(.success(.timedOut))
            }

            p.terminationHandler = { process in
                waitQueue.async {
                    finish(.success(.exited(process.terminationStatus)))
                }
            }

            readSource.resume()
            timeoutSource.resume()
        }

        switch result {
        case .ready:
            return
        case .timedOut:
            log.warning("Backend did not emit ready signal within \(Self.startupTimeout)s — proceeding anyway")
        case .exited(let code):
            throw LaunchError.processExited(code)
        }
    }
}

// MARK: - Errors

private enum ReadyWaitResult {
    case ready
    case timedOut
    case exited(Int32)
}

enum LaunchError: LocalizedError {
    case bundleNotFound
    case binaryNotFound(String)
    case processExited(Int32)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound:
            return "Could not locate the app bundle's executable directory."
        case .binaryNotFound(let path):
            return "Backend binary not found or not executable at: \(path)"
        case .processExited(let code):
            return "Backend process exited unexpectedly with code \(code)."
        }
    }
}
