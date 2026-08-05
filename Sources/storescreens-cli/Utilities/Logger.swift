import StorescreensCore
import Foundation

struct Logger {
    enum Level { case info, success, warning, error, verbose }

    var isVerbose: Bool = false

    func log(_ message: String, level: Level = .info) {
        let prefix: String
        switch level {
        case .info:    prefix = "  "
        case .success: prefix = "\u{001B}[32m✓\u{001B}[0m "
        case .warning: prefix = "\u{001B}[33m!\u{001B}[0m "
        case .error:   prefix = "\u{001B}[31m✗\u{001B}[0m "
        case .verbose:
            guard isVerbose else { return }
            prefix = "  "
        }
        print("\(prefix)\(message)")
    }

    func header(_ message: String) {
        print("\n\u{001B}[1m\(message)\u{001B}[0m")
    }

    func progress(_ current: Int, of total: Int, message: String) {
        print("  [\(current)/\(total)] \(message)")
    }
}
