import ArgumentParser
import Foundation
import StorescreensCore

struct BezelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bezels",
        abstract: "Manage device bezel assets for rendered screenshots.",
        discussion: """
            Device bezels are used by `render` when chrome style is `bezel`.
            Download Apple's Design Resource DMGs from \
            https://developer.apple.com/design/resources/, mount them, then run \
            `storescreens bezels import` to classify and install the PSDs.
            """,
        subcommands: [BezelsPathCommand.self, BezelsImportCommand.self, BezelsCheckCommand.self],
        defaultSubcommand: BezelsCheckCommand.self
    )
}

// MARK: - path

struct BezelsPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the user-global bezel install directory."
    )

    func run() async throws {
        print(BezelExporter.defaultInstallDirectory().path)
    }
}

// MARK: - check

struct BezelsCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Report which bezels are installed."
    )

    func run() async throws {
        let logger = Logger()
        let installDir = BezelExporter.defaultInstallDirectory()
        logger.header("Installed bezels")
        print("  location: \(installDir.path)")

        let store = BezelStore(projectLocal: nil, userGlobal: installDir)
        let keys = store.installedKeys().sorted()

        if keys.isEmpty {
            print("")
            logger.log("no bezels installed yet", level: .warning)
            print("  fix: mount an Apple Design Resource DMG and run `storescreens bezels import`")
            print("  download: https://developer.apple.com/design/resources/")
            return
        }

        print("")
        for key in keys {
            if let asset = store.lookup(canonicalKey: key) {
                let md = asset.metadata
                let screen = "\(md.screenWidth)x\(md.screenHeight)"
                let canvas = "\(md.canvasWidth)x\(md.canvasHeight)"
                print("  \(key)  screen \(screen)  canvas \(canvas)  ← \(md.sourceFilename)")
            } else {
                print("  \(key)  (metadata missing)")
            }
        }
        print("")
        print("  \(keys.count) bezel(s) installed")
    }
}

// MARK: - import

struct BezelsImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Classify mounted DMG bezel files and install them to the user-global directory."
    )

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt.")
    var yes: Bool = false

    @Option(name: .long, help: "Scan only this volume path (defaults to autoscan of /Volumes).")
    var volume: String?

    func run() async throws {
        let logger = Logger()

        let volumes: [URL]
        if let explicit = volume {
            let url = URL(fileURLWithPath: explicit)
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.log("volume path does not exist: \(explicit)", level: .error)
                throw ExitCode(1)
            }
            volumes = [url]
        } else {
            volumes = VolumeScanner.findAppleDesignResourceVolumes()
        }

        if volumes.isEmpty {
            logger.log("no Apple Design Resource DMGs mounted", level: .error)
            print("  mount a DMG from https://developer.apple.com/design/resources/ and retry")
            throw ExitCode(1)
        }

        logger.header("Scanning volumes")
        for v in volumes {
            print("  \(v.path)")
        }

        var warnings: [String] = []
        let candidates = BezelImporter.discover(in: volumes) { warnings.append($0) }

        if candidates.isEmpty {
            logger.log("no .psd files found under the scanned volumes", level: .error)
            for w in warnings { logger.log(w, level: .warning) }
            throw ExitCode(1)
        }

        let winners = BezelImporter.selectWinners(candidates: candidates)

        print("")
        logger.header("Selected bezels")

        let sortedKeys = winners.keys.sorted()
        let keyWidth = sortedKeys.map(\.count).max() ?? 0

        for key in sortedKeys {
            guard let w = winners[key] else { continue }
            let pad = String(repeating: " ", count: max(0, keyWidth - key.count))
            print("  \(key)\(pad)  ← \(w.filename)")
        }

        let skipped = candidates.count - winners.count
        if skipped > 0 {
            print("")
            print("  \(skipped) file(s) skipped (other colorways / duplicates)")
        }

        if !warnings.isEmpty {
            print("")
            for w in warnings { logger.log(w, level: .warning) }
        }

        let installDir = BezelExporter.defaultInstallDirectory()
        print("")
        print("  install into: \(installDir.path)")

        if !yes {
            print("")
            print("  proceed? [Y/n] ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
                logger.log("aborted", level: .warning)
                throw ExitCode(1)
            }
            let ok = line.isEmpty || line.lowercased() == "y" || line.lowercased() == "yes"
            if !ok {
                logger.log("aborted", level: .warning)
                throw ExitCode(1)
            }
        }

        print("")
        logger.header("Exporting")
        var exported = 0
        var failures: [(String, Error)] = []
        for key in sortedKeys {
            guard let winner = winners[key] else { continue }
            do {
                let (pngURL, _) = try BezelExporter.export(candidate: winner, to: installDir)
                print("  ✓ \(pngURL.lastPathComponent)")
                exported += 1
            } catch {
                print("  ✗ \(key): \(error)")
                failures.append((key, error))
            }
        }

        print("")
        logger.log("exported \(exported) bezel(s) to \(installDir.path)", level: .success)
        if !failures.isEmpty {
            logger.log("\(failures.count) failure(s)", level: .error)
            throw ExitCode(1)
        }
    }
}
