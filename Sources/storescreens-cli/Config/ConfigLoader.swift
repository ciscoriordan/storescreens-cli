import Foundation
import Yams

struct ConfigLoader {
    func load(from path: String) throws -> CaptureConfig {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.configNotFound(path: path)
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = YAMLDecoder()

        do {
            return try decoder.decode(CaptureConfig.self, from: contents)
        } catch {
            throw CLIError.configInvalid(reason: error.localizedDescription)
        }
    }

    func write(_ config: CaptureConfig, to path: String) throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
