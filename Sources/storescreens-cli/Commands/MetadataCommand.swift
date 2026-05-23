import ArgumentParser
import Foundation
import StorescreensCore

struct MetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "Manage App Store Connect metadata (description, what's new, etc.).",
        subcommands: [MetadataInitCommand.self],
        defaultSubcommand: MetadataInitCommand.self
    )
}

struct MetadataInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scaffold a metadata/ directory with per-locale subfolders and a field reference."
    )

    @Option(
        name: .shortAndLong,
        parsing: .upToNextOption,
        help: "Locales to create directories for (default: en-US). Accept multiple: --locales en-US es-ES ja."
    )
    var locales: [String] = ["en-US"]

    @Option(name: .shortAndLong, help: "Target directory (default: ./metadata).")
    var dir: String = "metadata"

    @Flag(name: .shortAndLong, help: "Overwrite an existing README.md if present.")
    var force: Bool = false

    func run() async throws {
        let logger = Logger()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Create locale directories (empty - user creates only the files they want).
        var createdLocales: [String] = []
        for locale in locales {
            let localeDir = root.appendingPathComponent(locale, isDirectory: true)
            if !fm.fileExists(atPath: localeDir.path) {
                try fm.createDirectory(at: localeDir, withIntermediateDirectories: true)
                createdLocales.append(locale)
            }
        }

        // Write / refresh the README.
        let readmePath = root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readmePath.path) || force {
            try readmeContent.write(to: readmePath, atomically: true, encoding: .utf8)
        }

        logger.log("scaffolded \(root.path)", level: .success)
        if !createdLocales.isEmpty {
            print("  created locale(s): \(createdLocales.joined(separator: ", "))")
        }
        print("  next: add .txt files in each locale folder. See \(readmePath.path) for the field reference.")
        print("  then run `storescreens submit --dry-run` to verify.")
    }

    private var readmeContent: String {
        """
        # App Store Connect metadata

        One subdirectory per locale (`en-US`, `ja`, `es-ES`, `de-DE`, ...). Each
        file contains the value for one App Store Connect field. Omit a file
        entirely if you don't want `storescreens submit` to touch that field.

        ## Supported filenames

        App Store Connect splits per-locale metadata across two resources.
        `submit` routes each file to the correct endpoint automatically;
        the "ASC resource" column is informational.

        | Filename             | ASC field          | ASC resource | Max length | Notes |
        |----------------------|--------------------|--------------|------------|-------|
        | `name.txt`           | App name           | appInfoLocalizations | 30   | Only editable while an `appInfo` is in an editable state |
        | `subtitle.txt`       | Subtitle           | appInfoLocalizations | 30   | Only editable while an `appInfo` is in an editable state |
        | `privacy_url.txt`    | Privacy policy URL | appInfoLocalizations |  -   | Per-locale, on the App Info record (not the version) |
        | `privacy_choices_url.txt` | Privacy choices URL | appInfoLocalizations | - | CCPA "do not sell my data" landing page |
        | `description.txt`    | Description        | appStoreVersionLocalizations | 4000 | Newlines preserved |
        | `keywords.txt`       | Keywords           | appStoreVersionLocalizations | 100  | Comma-separated list |
        | `promotional_text.txt` | Promotional text | appStoreVersionLocalizations | 170  | Can be edited without a new version |
        | `release_notes.txt`  | "What's New"       | appStoreVersionLocalizations | 4000 | |
        | `support_url.txt`    | Support URL        | appStoreVersionLocalizations |  -   | Must be https:// |
        | `marketing_url.txt`  | Marketing URL      | appStoreVersionLocalizations |  -   | Optional; https:// |

        Updating `name`, `subtitle`, or the privacy URLs requires the app
        to have an `appInfo` record in an editable state
        (`PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, etc.). If the only
        existing version is `READY_FOR_SALE`, `submit` logs a clear skip
        line and continues with the version-level fields rather than
        failing. Bump `submit.create_version` so `submit` creates a new
        editable version, then re-run.

        ## App Review Information

        These files feed the version's `appStoreReviewDetails` resource (the
        "App Review Information" panel in App Store Connect). They are
        version-scoped, NOT per-locale, so put them under one locale only -
        typically your primary. If they appear in multiple locales the
        alphabetically first one wins and the rest produce a warning.

        | Filename                              | ASC field            |
        |---------------------------------------|----------------------|
        | `review_notes.txt`                    | `notes` (free-form notes for Apple's reviewers) |
        | `review_contact_first_name.txt`       | `contactFirstName`   |
        | `review_contact_last_name.txt`        | `contactLastName`    |
        | `review_contact_phone.txt`            | `contactPhone`       |
        | `review_contact_email.txt`            | `contactEmail`       |
        | `review_demo_account_name.txt`        | `demoAccountName`    |
        | `review_demo_account_password.txt`    | `demoAccountPassword`|

        ## Example

            metadata/
              README.md             <- this file
              en-US/
                name.txt
                description.txt
                release_notes.txt
                review_notes.txt
                review_contact_first_name.txt
                review_contact_last_name.txt
                review_contact_email.txt
                review_contact_phone.txt
              ja/
                description.txt
                release_notes.txt

        ## Upload

        After filling in the files you want:

            storescreens submit --dry-run   # validate
            storescreens submit             # live push

        `submit` only patches fields whose files exist. Empty-file behavior: the
        submit pipeline reads whitespace-trimmed content; an empty file WILL
        overwrite the corresponding App Store Connect field with an empty
        string. If you don't want to touch a field, delete its file.
        """
    }
}
