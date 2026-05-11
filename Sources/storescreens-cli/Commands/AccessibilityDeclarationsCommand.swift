import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens accessibility` command. Wraps the App Store
/// Connect Accessibility Declarations (Accessibility Nutrition Label)
/// API as nested subcommands so AI agents (and humans) can manage the
/// per-device-family accessibility answers Apple surfaces on the App
/// Store product page.
///
/// Every leaf subcommand accepts `--json` for machine-readable output;
/// without it, results print as readable text via the shared Logger.
struct AccessibilityDeclarationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accessibility",
        abstract: "Manage Accessibility Nutrition Label declarations on App Store Connect.",
        discussion: """
            Wraps the App Store Connect `accessibilityDeclarations` resource: \
            the per-(app, deviceFamily) answers to whether the app supports \
            VoiceOver, Voice Control, Dynamic Type / Larger Text, Captions, \
            Audio Descriptions, Sufficient Contrast, Differentiate Without \
            Color Alone, Reduce Motion, and Dark Interface. Apple surfaces \
            these answers on the App Store product page.

            Records move through DRAFT (editable, not visible) -> PUBLISHED \
            (live on the product page) -> REPLACED (supplanted by a newer \
            PUBLISHED record). PATCH with `--publish` to transition a DRAFT \
            to PUBLISHED.

            Requires credentials via `storescreens auth login` or \
            ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH env vars. Use \
            `--json` on any leaf subcommand for machine-readable output. \
            The same operations are exposed as MCP tools under the \
            `accessibility_declarations_*` namespace.
            """,
        subcommands: [
            AccessibilityListCommand.self,
            AccessibilityListForAppCommand.self,
            AccessibilityGetCommand.self,
            AccessibilityCreateCommand.self,
            AccessibilityUpdateCommand.self,
            AccessibilityDeleteCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Resolves ASC credentials and builds an `AccessibilityDeclarationsAPI`.
/// Throws ExitCode(1) after logging on failure so subcommands stay tiny.
fileprivate func a11yClient(logger: Logger) throws -> AccessibilityDeclarationsAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return AccessibilityDeclarationsAPI(client: client)
}

/// Emits any `Encodable` as pretty-printed JSON on stdout.
fileprivate func a11yEmitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

/// Emit-helper for "single resource or nil" results.
fileprivate func a11yEmitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value { try a11yEmitJSON(value) } else { print("null") }
}

/// Maps `ASCClient.APIError` to a readable, formatted error then throws
/// ExitCode(1). Other errors propagate.
fileprivate func a11ySurface<T>(
    _ block: () async throws -> T,
    logger: Logger
) async throws -> T {
    do {
        return try await block()
    } catch let e as ASCClient.APIError {
        logger.log("App Store Connect API error: HTTP \(e.statusCode)", level: .error)
        for d in e.details {
            print("  [\(d.code)] \(d.title): \(d.detail)")
        }
        throw ExitCode(1)
    }
}

/// Wraps a paged response in the same shape the MCP tools emit.
fileprivate struct A11yCLIPage<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

/// JSON-friendly view of a Declaration. Mirrors the MCP DeclarationJSON
/// keys so CLI + MCP output line up.
fileprivate struct A11yDeclarationJSON: Encodable {
    let id: String
    let deviceFamily: String?
    let state: String?
    let supportsAudioDescriptions: Bool?
    let supportsCaptions: Bool?
    let supportsDarkInterface: Bool?
    let supportsDifferentiateWithoutColorAlone: Bool?
    let supportsLargerText: Bool?
    let supportsReducedMotion: Bool?
    let supportsSufficientContrast: Bool?
    let supportsVoiceControl: Bool?
    let supportsVoiceover: Bool?

    init(_ d: AccessibilityDeclarationsAPI.Declaration) {
        self.id = d.id
        self.deviceFamily = d.attributes?.deviceFamily?.rawValue
        self.state = d.attributes?.state?.rawValue
        self.supportsAudioDescriptions = d.attributes?.supportsAudioDescriptions
        self.supportsCaptions = d.attributes?.supportsCaptions
        self.supportsDarkInterface = d.attributes?.supportsDarkInterface
        self.supportsDifferentiateWithoutColorAlone =
            d.attributes?.supportsDifferentiateWithoutColorAlone
        self.supportsLargerText = d.attributes?.supportsLargerText
        self.supportsReducedMotion = d.attributes?.supportsReducedMotion
        self.supportsSufficientContrast = d.attributes?.supportsSufficientContrast
        self.supportsVoiceControl = d.attributes?.supportsVoiceControl
        self.supportsVoiceover = d.attributes?.supportsVoiceover
    }
}

/// Parses a device-family raw string into the API enum, logging + exiting
/// on an unknown value.
fileprivate func parseDeviceFamily(
    _ raw: String?,
    required: Bool,
    logger: Logger
) throws -> AccessibilityDeclarationsAPI.DeviceFamily? {
    guard let raw, !raw.isEmpty else {
        if required {
            logger.log(
                "device-family is required (one of: " +
                AccessibilityDeclarationsAPI.DeviceFamily.allCases
                    .map(\.rawValue).joined(separator: ", ") +
                ")",
                level: .error
            )
            throw ExitCode(1)
        }
        return nil
    }
    guard let df = AccessibilityDeclarationsAPI.DeviceFamily(rawValue: raw) else {
        logger.log(
            "unknown device-family '\(raw)'. Expected one of: " +
            AccessibilityDeclarationsAPI.DeviceFamily.allCases
                .map(\.rawValue).joined(separator: ", "),
            level: .error
        )
        throw ExitCode(1)
    }
    return df
}

fileprivate func parseState(
    _ raw: String?,
    logger: Logger
) throws -> AccessibilityDeclarationsAPI.State? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let s = AccessibilityDeclarationsAPI.State(rawValue: raw) else {
        logger.log(
            "unknown state '\(raw)'. Expected one of: " +
            AccessibilityDeclarationsAPI.State.allCases
                .map(\.rawValue).joined(separator: ", "),
            level: .error
        )
        throw ExitCode(1)
    }
    return s
}

// MARK: - Shared field options

/// The supports-* booleans, modeled as Optional<Bool> so callers can
/// leave a field untouched simply by omitting the flag.
///
/// Each option is a String that callers pass as `true` / `false`. Using a
/// plain `@Flag` would lock the field to "true if present, nil if
/// absent", which makes "set this to false" impossible to express. The
/// String form trades a tiny bit of typing (`--supports-voiceover true`)
/// for the full tri-state needed when downgrading an answer from `true`
/// to `false` after a regression.
///
/// `parseBool` accepts `true|false|yes|no|1|0` (case-insensitive) so
/// shell habits all just work.
///
/// Internal access level (not fileprivate) is required because
/// `@OptionGroup` on a non-fileprivate parent struct needs the option
/// group's type to be at least as visible as the parent.
struct AccessibilityFieldOptions: ParsableArguments {
    @Option(name: .long, help: "Supports VoiceOver (true / false).")
    var supportsVoiceover: String?
    @Option(name: .long, help: "Supports Voice Control (true / false).")
    var supportsVoiceControl: String?
    @Option(name: .long, help: "Supports Dynamic Type / Larger Text (true / false).")
    var supportsLargerText: String?
    @Option(name: .long, help: "Supports captions / subtitles for audio (true / false).")
    var supportsCaptions: String?
    @Option(name: .long, help: "Supports audio descriptions for video (true / false).")
    var supportsAudioDescriptions: String?
    @Option(name: .long, help: "Meets sufficient contrast for text + meaningful UI (true / false).")
    var supportsSufficientContrast: String?
    @Option(name: .long, help: "Conveys information beyond color alone (true / false).")
    var supportsDifferentiateWithoutColorAlone: String?
    @Option(name: .long, help: "Respects Reduce Motion (true / false).")
    var supportsReducedMotion: String?
    @Option(name: .long, help: "Respects system Dark Appearance (true / false).")
    var supportsDarkInterface: String?
}

/// Parses an Optional<Bool> from a raw string. Returns nil for nil
/// inputs. Throws ExitCode(1) on a value that's neither true-ish nor
/// false-ish so users see the bad input rather than silently dropping
/// it.
fileprivate func parseBool(
    _ raw: String?,
    flagName: String,
    logger: Logger
) throws -> Bool? {
    guard let raw else { return nil }
    switch raw.lowercased() {
    case "true", "yes", "1":  return true
    case "false", "no", "0":  return false
    default:
        logger.log(
            "--\(flagName) expects true|false (got '\(raw)')",
            level: .error
        )
        throw ExitCode(1)
    }
}

/// Reads every supports-* flag off the parsed options into a Fields
/// value (with `deviceFamily` + `publish` left nil; callers fill those
/// in for create / update as appropriate).
fileprivate func fieldsFromOptions(
    _ opts: AccessibilityFieldOptions,
    logger: Logger
) throws -> AccessibilityDeclarationsAPI.Fields {
    AccessibilityDeclarationsAPI.Fields(
        supportsAudioDescriptions: try parseBool(
            opts.supportsAudioDescriptions,
            flagName: "supports-audio-descriptions", logger: logger
        ),
        supportsCaptions: try parseBool(
            opts.supportsCaptions, flagName: "supports-captions", logger: logger
        ),
        supportsDarkInterface: try parseBool(
            opts.supportsDarkInterface,
            flagName: "supports-dark-interface", logger: logger
        ),
        supportsDifferentiateWithoutColorAlone: try parseBool(
            opts.supportsDifferentiateWithoutColorAlone,
            flagName: "supports-differentiate-without-color-alone", logger: logger
        ),
        supportsLargerText: try parseBool(
            opts.supportsLargerText, flagName: "supports-larger-text", logger: logger
        ),
        supportsReducedMotion: try parseBool(
            opts.supportsReducedMotion,
            flagName: "supports-reduced-motion", logger: logger
        ),
        supportsSufficientContrast: try parseBool(
            opts.supportsSufficientContrast,
            flagName: "supports-sufficient-contrast", logger: logger
        ),
        supportsVoiceControl: try parseBool(
            opts.supportsVoiceControl,
            flagName: "supports-voice-control", logger: logger
        ),
        supportsVoiceover: try parseBool(
            opts.supportsVoiceover, flagName: "supports-voiceover", logger: logger
        )
    )
}

// MARK: - list (defaults to listing per app via the relationship endpoint)

struct AccessibilityListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List accessibility declarations attached to an app."
    )
    @Option(name: .long, help: "App Store Connect app id (numeric string).")
    var appId: String
    @Option(name: .long, help: "Filter: IPHONE, IPAD, APPLE_TV, APPLE_WATCH, MAC, VISION.")
    var deviceFamily: String?
    @Option(name: .long, help: "Filter: DRAFT, PUBLISHED, REPLACED.")
    var state: String?
    @Option(name: .long, help: "Page size (default 200).")
    var limit: Int = 200
    @Option(name: .long, help: "Pagination cursor from a previous page.")
    var cursor: String?
    @Flag(name: .long, help: "Emit JSON instead of text.") var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try a11yClient(logger: logger)
        let df = try parseDeviceFamily(deviceFamily, required: false, logger: logger)
        let st = try parseState(state, logger: logger)
        let page = try await a11ySurface(
            {
                try await api.list(
                    appID: appId,
                    deviceFamily: df,
                    state: st,
                    limit: limit,
                    cursor: cursor
                )
            },
            logger: logger
        )
        if json {
            try a11yEmitJSON(A11yCLIPage(
                data: page.data.map(A11yDeclarationJSON.init),
                nextCursor: page.nextCursor
            ))
            return
        }
        logger.header("Accessibility declarations for app \(appId) (\(page.data.count))")
        for d in page.data {
            let df = d.attributes?.deviceFamily?.rawValue ?? "(no family)"
            let st = d.attributes?.state?.rawValue ?? "(no state)"
            print("  \(d.id)  [\(df)] \(st)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

/// Alias of `list` named to mirror the MCP tool. Keeps the CLI in sync
/// with `accessibility_declarations_list_for_app` for agents that
/// translate one surface to the other verbatim.
struct AccessibilityListForAppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-for-app",
        abstract: "Alias of `list`: list every declaration attached to an app via the relationship endpoint."
    )
    @Option(name: .long) var appId: String
    @Option(name: .long) var deviceFamily: String?
    @Option(name: .long) var state: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        var inner = AccessibilityListCommand()
        inner.appId = appId
        inner.deviceFamily = deviceFamily
        inner.state = state
        inner.limit = limit
        inner.cursor = cursor
        inner.json = json
        try await inner.run()
    }
}

// MARK: - get

struct AccessibilityGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a single accessibility declaration by id."
    )
    @Argument(help: "accessibilityDeclarations id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try a11yClient(logger: logger)
        let decl = try await a11ySurface(
            { try await api.get(id: id) },
            logger: logger
        )
        if json {
            try a11yEmitOptionalJSON(decl.map(A11yDeclarationJSON.init))
            return
        }
        guard let decl else {
            logger.log("no accessibility declaration \(id)", level: .warning)
            return
        }
        logger.header("Accessibility declaration \(decl.id)")
        let a = decl.attributes
        print("  deviceFamily: \(a?.deviceFamily?.rawValue ?? "(none)")")
        print("  state:        \(a?.state?.rawValue ?? "(none)")")
        printSupports("VoiceOver",                       a?.supportsVoiceover)
        printSupports("VoiceControl",                    a?.supportsVoiceControl)
        printSupports("LargerText",                      a?.supportsLargerText)
        printSupports("Captions",                        a?.supportsCaptions)
        printSupports("AudioDescriptions",               a?.supportsAudioDescriptions)
        printSupports("SufficientContrast",              a?.supportsSufficientContrast)
        printSupports("DifferentiateWithoutColorAlone",  a?.supportsDifferentiateWithoutColorAlone)
        printSupports("ReducedMotion",                   a?.supportsReducedMotion)
        printSupports("DarkInterface",                   a?.supportsDarkInterface)
    }

    private func printSupports(_ label: String, _ value: Bool?) {
        let v: String
        switch value {
        case .some(true):  v = "yes"
        case .some(false): v = "no"
        case .none:        v = "(unset)"
        }
        let pad = String(repeating: " ", count: max(1, 34 - label.count))
        print("  supports\(label):\(pad)\(v)")
    }
}

// MARK: - create

struct AccessibilityCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new DRAFT accessibility declaration for an (app, deviceFamily).",
        discussion: """
            The resulting declaration is always in DRAFT state. Pass any \
            subset of the supports-* flags to set initial answers; omit a \
            flag to leave it unset. Run `accessibility update --id <id> \
            --publish true` after to transition the draft to PUBLISHED so it \
            appears on the App Store product page.
            """
    )
    @Option(name: .long, help: "App Store Connect app id (numeric string).")
    var appId: String
    @Option(name: .long, help: "Required: IPHONE, IPAD, APPLE_TV, APPLE_WATCH, MAC, VISION.")
    var deviceFamily: String
    @OptionGroup var fieldOptions: AccessibilityFieldOptions
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try a11yClient(logger: logger)
        let df = try parseDeviceFamily(deviceFamily, required: true, logger: logger)!
        var fields = try fieldsFromOptions(fieldOptions, logger: logger)
        fields.deviceFamily = df
        let decl = try await a11ySurface(
            { try await api.create(appID: appId, fields: fields) },
            logger: logger
        )
        if json {
            try a11yEmitJSON(A11yDeclarationJSON(decl))
            return
        }
        logger.log(
            "created accessibility declaration \(decl.id) " +
            "[\(decl.attributes?.deviceFamily?.rawValue ?? "?")] for app \(appId)",
            level: .success
        )
    }
}

// MARK: - update

struct AccessibilityUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing accessibility declaration (PATCH).",
        discussion: """
            Pass any subset of supports-* flags to change answers; omitted \
            flags stay untouched. Pass `--publish true` to transition a \
            DRAFT record to PUBLISHED. Apple rejects an empty PATCH, so at \
            least one field must be set.
            """
    )
    @Option(name: .long, help: "accessibilityDeclarations id to update.")
    var id: String
    @Option(name: .long, help: "Transition a DRAFT to PUBLISHED (true / false).")
    var publish: String?
    @OptionGroup var fieldOptions: AccessibilityFieldOptions
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try a11yClient(logger: logger)
        var fields = try fieldsFromOptions(fieldOptions, logger: logger)
        fields.publish = try parseBool(publish, flagName: "publish", logger: logger)
        if fields.isEmpty {
            logger.log(
                "update requires at least one field (--publish or any supports-* flag)",
                level: .error
            )
            throw ExitCode(1)
        }
        let decl = try await a11ySurface(
            { try await api.update(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try a11yEmitJSON(A11yDeclarationJSON(decl))
            return
        }
        logger.log(
            "updated accessibility declaration \(decl.id) " +
            "(state now \(decl.attributes?.state?.rawValue ?? "?"))",
            level: .success
        )
    }
}

// MARK: - delete

struct AccessibilityDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an accessibility declaration by id."
    )
    @Argument(help: "accessibilityDeclarations id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try a11yClient(logger: logger)
        try await a11ySurface({ try await api.delete(id: id) }, logger: logger)
        logger.log("deleted accessibility declaration \(id)", level: .success)
    }
}
