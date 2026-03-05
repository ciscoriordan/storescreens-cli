import Foundation

package struct ProcessResult: Sendable {
    package let stdout: String
    package let stderr: String
    package let exitCode: Int32
    package var succeeded: Bool { exitCode == 0 }
}

package actor ShellRunner {
    package init() {}

    package func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        stdoutLineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdoutLineHandler {
            // Stream stdout lines in real-time via readabilityHandler,
            // collecting data in a thread-safe buffer for the return value.
            let stdoutCollector = StreamingDataCollector()
            let stderrCollector = StreamingDataCollector()

            let group = DispatchGroup()
            group.enter() // stdout
            group.enter() // stderr
            group.enter() // process termination

            let stdoutDone = AtomicFlag()
            let stderrDone = AtomicFlag()

            // Use terminationHandler to track exit instead of waitUntilExit().
            // On some macOS versions (including 26.x), waitUntilExit() can deadlock
            // when called after both pipe readabilityHandlers have already seen EOF:
            // the RunLoop spin inside waitUntilExit() never receives the termination
            // notification even though the process has exited. Using terminationHandler
            // avoids this by letting NSTask deliver the notification asynchronously
            // via its own internal mechanism rather than spinning a RunLoop.
            process.terminationHandler = { _ in group.leave() }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if stdoutDone.setIfUnset() {
                        handle.readabilityHandler = nil
                        group.leave()
                    }
                    return
                }
                stdoutCollector.append(data)
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
                        stdoutLineHandler(String(line))
                    }
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if stderrDone.setIfUnset() {
                        handle.readabilityHandler = nil
                        group.leave()
                    }
                    return
                }
                stderrCollector.append(data)
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
                        stdoutLineHandler(String(line))
                    }
                }
            }

            try process.run()

            // Wait for stdout EOF, stderr EOF, and process termination.
            // All three are tracked in the DispatchGroup so this single await
            // covers everything — no waitUntilExit() needed.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) {
                    continuation.resume()
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            return ProcessResult(
                stdout: stdoutCollector.string,
                stderr: stderrCollector.string,
                exitCode: process.terminationStatus
            )
        } else {
            try process.run()

            let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
            let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

            process.waitUntilExit()

            return ProcessResult(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        }
    }

    package func xcrun(_ tool: String, arguments: [String] = []) async throws -> ProcessResult {
        try await run("/usr/bin/xcrun", arguments: [tool] + arguments)
    }

    package func xcodebuild(
        arguments: [String],
        stdoutLineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await run("/usr/bin/xcodebuild", arguments: arguments, stdoutLineHandler: stdoutLineHandler)
    }
}

/// Thread-safe one-shot flag to guard against duplicate calls.
private final class AtomicFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    /// Sets the flag and returns `true` if it was previously unset.
    /// Returns `false` if already set (i.e. duplicate call).
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

/// Thread-safe data collector for use in readabilityHandler callbacks.
private final class StreamingDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
