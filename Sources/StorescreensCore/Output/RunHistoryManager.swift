import Foundation

package struct CaptureDestination {
    package let writeDir: String
    package let isStaging: Bool
    package let timestampDir: String?

    package init(writeDir: String, isStaging: Bool, timestampDir: String?) {
        self.writeDir = writeDir
        self.isStaging = isStaging
        self.timestampDir = timestampDir
    }
}

package struct RunHistoryManager {
    package let outputDir: String
    package let keepRuns: Int
    package let logger: Logger

    package init(outputDir: String, keepRuns: Int, logger: Logger) {
        self.outputDir = outputDir
        self.keepRuns = keepRuns
        self.logger = logger
    }

    /// Prepare the directory where the current capture should write screenshots.
    package func prepareCaptureDirectory() throws -> CaptureDestination {
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        if keepRuns == 1 {
            // Staging mode: write to a hidden staging dir next to outputDir
            // (same parent directory = same filesystem for atomic moves).
            // The staging dir must NOT be inside outputDir because mergeDirectory
            // uses removeItem(dst) on leaf directories - if the staging dir were a
            // child of outputDir, removing outputDir would also delete the staging dir
            // before moveItem can move it into place.
            let parentDir = (outputDir as NSString).deletingLastPathComponent
            let outputName = (outputDir as NSString).lastPathComponent
            let stagingDir = (parentDir as NSString)
                .appendingPathComponent(".\(outputName)-staging-\(UUID().uuidString.prefix(8))")
            try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
            return CaptureDestination(writeDir: stagingDir, isStaging: true, timestampDir: nil)
        } else {
            // History mode: write to a timestamped subdirectory
            let timestamp = makeTimestamp()
            var dirName = timestamp
            let targetPath = (outputDir as NSString).appendingPathComponent(dirName)
            if fm.fileExists(atPath: targetPath) {
                dirName = "\(timestamp)-\(UUID().uuidString.prefix(4))"
            }
            let runDir = (outputDir as NSString).appendingPathComponent(dirName)
            try fm.createDirectory(atPath: runDir, withIntermediateDirectories: true)
            return CaptureDestination(writeDir: runDir, isStaging: false, timestampDir: dirName)
        }
    }

    /// After a successful capture, finalize the output.
    package func finalizeCapture(_ destination: CaptureDestination) throws {
        let fm = FileManager.default

        if destination.isStaging {
            // Merge staging contents into outputDir.
            // Only replace at the device-size leaf level so that screenshots from
            // previous runs with different devices or appearances are preserved.
            let stagingDir = destination.writeDir
            try mergeDirectory(from: stagingDir, into: outputDir)

            // Clean up staging dir
            try? fm.removeItem(atPath: stagingDir)

            // Clean up any leftover staging dirs from interrupted runs
            cleanupStaleStagingDirs()
        } else {
            // History mode: update the "latest" symlink
            if let dirName = destination.timestampDir {
                let latestPath = (outputDir as NSString).appendingPathComponent("latest")
                try? fm.removeItem(atPath: latestPath)
                try fm.createSymbolicLink(atPath: latestPath, withDestinationPath: dirName)
                logger.log("Updated latest -> \(dirName)", level: .success)
            }

            // Prune old runs if needed
            if keepRuns > 1 {
                pruneOldRuns()
            }
        }
    }

    /// Clean up after a failed capture without touching existing output.
    package func handleFailure(_ destination: CaptureDestination) {
        try? FileManager.default.removeItem(atPath: destination.writeDir)
    }

    // MARK: - Private

    /// Recursively merge `src` into `dst`.
    private func mergeDirectory(from src: String, into dst: String) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: src) else { return }

        // Ensure destination exists, then merge individual items.
        // Never remove the whole destination directory - other devices'
        // screenshots may already be there from a previous run.
        if !fm.fileExists(atPath: dst) {
            try fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        }

        for item in items {
            let srcItem = (src as NSString).appendingPathComponent(item)
            let dstItem = (dst as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: srcItem, isDirectory: &isDir)
            if isDir.boolValue {
                try mergeDirectory(from: srcItem, into: dstItem)
            } else {
                // Plain file - overwrite only this file, leave others untouched.
                try? fm.removeItem(atPath: dstItem)
                try fm.moveItem(atPath: srcItem, toPath: dstItem)
            }
        }
    }

    private func makeTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func cleanupStaleStagingDirs() {
        let fm = FileManager.default
        let parentDir = (outputDir as NSString).deletingLastPathComponent
        let outputName = (outputDir as NSString).lastPathComponent
        let stagingPrefix = ".\(outputName)-staging-"
        guard let items = try? fm.contentsOfDirectory(atPath: parentDir) else { return }
        for item in items where item.hasPrefix(stagingPrefix) {
            let path = (parentDir as NSString).appendingPathComponent(item)
            try? fm.removeItem(atPath: path)
        }
        // Also clean up old-style staging dirs that were inside outputDir
        if let outputItems = try? fm.contentsOfDirectory(atPath: outputDir) {
            for item in outputItems where item.hasPrefix(".storescreens-staging-") {
                let path = (outputDir as NSString).appendingPathComponent(item)
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private func pruneOldRuns() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: outputDir) else { return }

        // Find timestamped run directories (format: yyyy-MM-dd_HH-mm-ss*)
        let timestampPattern = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#
        let regex = try? NSRegularExpression(pattern: timestampPattern)

        let runDirs = items.filter { name in
            let range = NSRange(name.startIndex..., in: name)
            return regex?.firstMatch(in: name, range: range) != nil
        }.sorted(by: >) // newest first (lexicographic sort works for this format)

        // Remove runs beyond the keep count
        if runDirs.count > keepRuns {
            for dirName in runDirs.dropFirst(keepRuns) {
                let path = (outputDir as NSString).appendingPathComponent(dirName)
                try? fm.removeItem(atPath: path)
                logger.log("Pruned old run: \(dirName)", level: .info)
            }
        }
    }
}
