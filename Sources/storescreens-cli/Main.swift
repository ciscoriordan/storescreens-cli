import ArgumentParser
import Foundation
import StorescreensCore

@main
struct StoreScreensCLI: AsyncParsableCommand {
    // Force line-buffered stdout so progress lines stream in real-time
    // even when output is piped (e.g. to another process or file).
    static let _lineBuffered: Void = {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
    }()

    static let configuration = CommandConfiguration(
        commandName: "storescreens",
        abstract: "Capture App Store screenshots across iOS simulators and macOS.",
        version: storescreensVersion,
        subcommands: [ListCommand.self, InitCommand.self, SetupCommand.self, CaptureCommand.self, CheckCommand.self, ScreenshotCommand.self, BezelsCommand.self, RenderCommand.self, AuthCommand.self, SubmitCommand.self]
    )

    mutating func validate() throws {
        _ = Self._lineBuffered
    }
}
