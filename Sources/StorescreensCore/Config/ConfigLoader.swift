import Foundation
import Yams

package struct ConfigLoader {
    package init() {}

    package func load(from path: String) throws -> CaptureConfig {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.configNotFound(path: path)
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = YAMLDecoder()

        do {
            var config = try decoder.decode(CaptureConfig.self, from: contents)
            // Normalize output_dir: strip leading "./" so relative paths like
            // "./storescreens-output" don't cause path resolution failures downstream.
            if config.outputDir.hasPrefix("./") {
                config.outputDir = String(config.outputDir.dropFirst(2))
            }
            return config
        } catch {
            throw CLIError.configInvalid(reason: error.localizedDescription)
        }
    }

    package func write(_ config: CaptureConfig, to path: String) throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
