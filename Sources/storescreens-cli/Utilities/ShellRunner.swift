import Foundation

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

actor ShellRunner {

    func run(
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

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    group.leave()
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
                    group.leave()
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

            // Wait for both pipes to signal EOF using continuation to avoid
            // blocking the cooperative thread pool.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) {
                    continuation.resume()
                }
            }

            process.waitUntilExit()

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

    func xcrun(_ tool: String, arguments: [String] = []) async throws -> ProcessResult {
        try await run("/usr/bin/xcrun", arguments: [tool] + arguments)
    }

    func xcodebuild(
        arguments: [String],
        stdoutLineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await run("/usr/bin/xcodebuild", arguments: arguments, stdoutLineHandler: stdoutLineHandler)
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
