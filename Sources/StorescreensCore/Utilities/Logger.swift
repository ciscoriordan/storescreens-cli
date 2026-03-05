import Foundation

package struct Logger {
    package enum Level { case info, success, warning, error, verbose }

    package enum LogLevel: String, Codable, CaseIterable {
        case quiet, normal, verbose
    }

    package var logLevel: LogLevel = .normal

    package init(logLevel: LogLevel = .normal) {
        self.logLevel = logLevel
    }

    package func log(_ message: String, level: Level = .info) {
        switch logLevel {
        case .quiet:
            // Only errors and warnings pass through
            guard level == .error || level == .warning else { return }
        case .normal:
            // Everything except verbose
            guard level != .verbose else { return }
        case .verbose:
            break // All messages pass through
        }

        let prefix: String
        switch level {
        case .info:    prefix = "  "
        case .success: prefix = "\u{001B}[32m✓\u{001B}[0m "
        case .warning: prefix = "\u{001B}[33m!\u{001B}[0m "
        case .error:   prefix = "\u{001B}[31m✗\u{001B}[0m "
        case .verbose: prefix = "  "
        }
        print("\(prefix)\(message)")
    }

    package func header(_ message: String) {
        guard logLevel != .quiet else { return }
        print("\n\u{001B}[1m\(message)\u{001B}[0m")
    }

    package func progress(_ current: Int, of total: Int, message: String) {
        guard logLevel != .quiet else { return }
        print("  [\(current)/\(total)] \(message)")
    }
}
