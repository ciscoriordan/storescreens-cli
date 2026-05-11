import Foundation

/// App Store Connect endpoints for `accessibilityDeclarations`, Apple's
/// "Accessibility Nutrition Label" resource. These declarations encode
/// per-device-family answers to a small set of yes/no questions about how
/// an app supports system accessibility features (VoiceOver, Voice
/// Control, Dynamic Type / Larger Text, Captions, Audio Descriptions,
/// Sufficient Contrast, Differentiate Without Color Alone, Reduce Motion,
/// Dark Interface). Apple surfaces the answers on the app's App Store
/// product page so customers can see at a glance which accessibility
/// features the app supports before they download it.
///
/// Resource model:
///
///   - One `accessibilityDeclaration` record per (app, deviceFamily)
///     pairing. Same app can carry separate declarations for IPHONE,
///     IPAD, MAC, etc., each with its own answer set.
///   - Records move through a small state machine: DRAFT (editable),
///     PUBLISHED (live on the App Store product page), REPLACED (an
///     older record that was supplanted by a newer one).
///   - PATCH with `publish: true` transitions a DRAFT to PUBLISHED.
///   - The previous PUBLISHED record (if any) for the same
///     (app, deviceFamily) is moved to REPLACED automatically by Apple.
///
/// Operations wrapped here:
///
///   - GET    /v1/apps/{id}/accessibilityDeclarations - list per app,
///     filterable by deviceFamily and state.
///   - GET    /v1/accessibilityDeclarations/{id}      - read one.
///   - POST   /v1/accessibilityDeclarations           - create a new
///     draft declaration for an (app, deviceFamily).
///   - PATCH  /v1/accessibilityDeclarations/{id}      - update fields
///     and/or publish.
///   - DELETE /v1/accessibilityDeclarations/{id}      - remove a draft.
///
/// Localizations: Apple's OpenAPI spec v4.3 (2026-03-10) does NOT expose
/// an `accessibilityDeclarationLocalizations` resource. The declaration
/// is global per (app, deviceFamily); there is no per-locale variant. If
/// Apple adds localizations in a later spec version, a sub-namespace can
/// be added here mirroring the keys / packages pattern in
/// AltDistributionAPI.
///
/// Conventions match the rest of the ASC surface here:
///   - 404 -> nil from `get`
///   - 409 surfaces as `ASCClient.APIError.isAlreadySetConflict`
///     (e.g. attempting to PATCH a record whose state has already
///     advanced past where the caller expects)
///   - Paginated lists accept `limit` (default 200) and `cursor`,
///     return `(data, nextCursor)`. Pass `nextCursor` back unchanged
///     on the next call.
///   - All attribute fields are Optional<T> so partial PATCHes leave
///     untouched fields alone on Apple's side.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi
/// (Accessibility Declarations section, shipped with API v4.0 in
/// June 2025; attribute set verified against spec v4.3, 2026-03-10).
package struct AccessibilityDeclarationsAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Enums

    /// Which Apple device family the declaration applies to. One
    /// declaration record per (app, deviceFamily) is permitted. The raw
    /// values match Apple's wire format exactly.
    package enum DeviceFamily: String, Codable, Sendable, CaseIterable {
        case iphone = "IPHONE"
        case ipad = "IPAD"
        case appleTV = "APPLE_TV"
        case appleWatch = "APPLE_WATCH"
        case mac = "MAC"
        case vision = "VISION"
    }

    /// Lifecycle state of a single declaration.
    ///
    /// - `DRAFT`: editable, not visible on the App Store product page.
    ///   Newly created records start here.
    /// - `PUBLISHED`: live on the product page. Created by PATCHing
    ///   `publish: true` on a draft (see `update`).
    /// - `REPLACED`: was previously PUBLISHED but a newer record for
    ///   the same (app, deviceFamily) was published, moving this one
    ///   to REPLACED automatically.
    package enum State: String, Codable, Sendable, CaseIterable {
        case draft = "DRAFT"
        case published = "PUBLISHED"
        case replaced = "REPLACED"
    }

    // MARK: - Resource

    /// A single `accessibilityDeclarations` record. Returned by every
    /// read / write call.
    package struct Declaration: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?

        package struct Attributes: Codable, Sendable {
            /// Which device family this declaration applies to. Set at
            /// create time; immutable after that.
            package let deviceFamily: DeviceFamily?

            /// Current lifecycle state. Read-only on the wire (driven
            /// by `publish` in the update body and by Apple-side
            /// REPLACED transitions when a newer record is published).
            package let state: State?

            // Supports-* booleans. Each one answers "does this app, on
            // this device family, support the named accessibility
            // feature?". Apple shows the positive answers on the App
            // Store product page; negative or nil answers are simply
            // absent from the customer-facing summary. Every field is
            // Optional<Bool> so partial PATCHes leave untouched
            // answers alone.

            /// Does the app provide audio descriptions for video
            /// content (a narrated alternative track for blind /
            /// low-vision customers)?
            package let supportsAudioDescriptions: Bool?

            /// Does the app provide captions / subtitles for audio
            /// content (for deaf / hard-of-hearing customers)?
            package let supportsCaptions: Bool?

            /// Does the app respect the system Dark Appearance setting
            /// (renders a dedicated dark UI rather than forcing light)?
            package let supportsDarkInterface: Bool?

            /// Does the app avoid using color as the sole means of
            /// conveying information (also adds shape / text / iconography
            /// to differentiate states)?
            package let supportsDifferentiateWithoutColorAlone: Bool?

            /// Does the app respect Dynamic Type / Larger Text and
            /// reflow its UI at large text sizes?
            package let supportsLargerText: Bool?

            /// Does the app respect the Reduce Motion accessibility
            /// setting (disables / dampens motion-heavy animations)?
            package let supportsReducedMotion: Bool?

            /// Does the app meet WCAG-style contrast ratios for all
            /// text and meaningful UI elements?
            package let supportsSufficientContrast: Bool?

            /// Does the app's UI work with Voice Control (verbal
            /// commands to operate every interactive element)?
            package let supportsVoiceControl: Bool?

            /// Does the app's UI work with VoiceOver (every
            /// interactive element has a meaningful accessibility
            /// label and is reachable via swipe / focus)?
            package let supportsVoiceover: Bool?
        }
    }

    // MARK: - Editable field set

    /// Fields accepted on create + update. All booleans are
    /// Optional<Bool> so partial PATCHes leave untouched answers alone.
    ///
    /// `deviceFamily` is required on create (Apple rejects a POST that
    /// omits it) and is ignored on update because the value is
    /// immutable after the record is created.
    ///
    /// `publish` is update-only: PATCH with `publish: true` to
    /// transition a DRAFT record to PUBLISHED. It is not a stored
    /// attribute (it does not appear on reads); it just acts as an
    /// imperative state-transition flag on the PATCH body.
    package struct Fields: Sendable, Equatable {
        package var deviceFamily: DeviceFamily?
        package var publish: Bool?
        package var supportsAudioDescriptions: Bool?
        package var supportsCaptions: Bool?
        package var supportsDarkInterface: Bool?
        package var supportsDifferentiateWithoutColorAlone: Bool?
        package var supportsLargerText: Bool?
        package var supportsReducedMotion: Bool?
        package var supportsSufficientContrast: Bool?
        package var supportsVoiceControl: Bool?
        package var supportsVoiceover: Bool?

        package init(
            deviceFamily: DeviceFamily? = nil,
            publish: Bool? = nil,
            supportsAudioDescriptions: Bool? = nil,
            supportsCaptions: Bool? = nil,
            supportsDarkInterface: Bool? = nil,
            supportsDifferentiateWithoutColorAlone: Bool? = nil,
            supportsLargerText: Bool? = nil,
            supportsReducedMotion: Bool? = nil,
            supportsSufficientContrast: Bool? = nil,
            supportsVoiceControl: Bool? = nil,
            supportsVoiceover: Bool? = nil
        ) {
            self.deviceFamily = deviceFamily
            self.publish = publish
            self.supportsAudioDescriptions = supportsAudioDescriptions
            self.supportsCaptions = supportsCaptions
            self.supportsDarkInterface = supportsDarkInterface
            self.supportsDifferentiateWithoutColorAlone = supportsDifferentiateWithoutColorAlone
            self.supportsLargerText = supportsLargerText
            self.supportsReducedMotion = supportsReducedMotion
            self.supportsSufficientContrast = supportsSufficientContrast
            self.supportsVoiceControl = supportsVoiceControl
            self.supportsVoiceover = supportsVoiceover
        }

        /// True when no field has been set. Callers can use this to
        /// short-circuit a PATCH whose body would otherwise be empty
        /// (ASC rejects empty PATCH bodies with a 4xx).
        package var isEmpty: Bool {
            deviceFamily == nil && publish == nil
                && supportsAudioDescriptions == nil && supportsCaptions == nil
                && supportsDarkInterface == nil
                && supportsDifferentiateWithoutColorAlone == nil
                && supportsLargerText == nil && supportsReducedMotion == nil
                && supportsSufficientContrast == nil
                && supportsVoiceControl == nil && supportsVoiceover == nil
        }
    }

    // MARK: - Pagination shape

    /// Page envelope returned by `list`. Matches the convention used
    /// elsewhere in this module: cursor is Apple's opaque continuation
    /// token, pass it back unchanged on the next call. When
    /// `nextCursor` is nil the caller has reached the end of the list.
    package struct Page: Sendable {
        package let data: [Declaration]
        package let nextCursor: String?
    }

    /// Wire-level paged envelope. Apple returns `links.next` as a full
    /// URL with a base64-encoded `cursor=` query parameter; the
    /// extractor below pulls that value out so callers don't have to
    /// parse the URL themselves.
    private struct PageEnvelope: Decodable {
        struct Links: Decodable { let next: String? }
        let data: [Declaration]
        let links: Links?
    }

    private static func extractCursor(from link: String?) -> String? {
        guard let link, !link.isEmpty,
              let comps = URLComponents(string: link)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    private static func listQuery(
        limit: Int,
        cursor: String?,
        extras: [String: String] = [:]
    ) -> [String: String] {
        var q = extras
        q["limit"] = String(limit)
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    // MARK: - List per app

    /// Lists every accessibility declaration attached to an app,
    /// optionally filtered to a single device family and/or state.
    /// Hits the canonical relationship endpoint
    /// `/v1/apps/{id}/accessibilityDeclarations`.
    ///
    /// In practice an app has at most a handful of declarations (one
    /// PUBLISHED + zero or one DRAFT per device family, plus any
    /// REPLACED history), so the page size cap is rarely exercised.
    package func list(
        appID: String,
        deviceFamily: DeviceFamily? = nil,
        state: State? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) async throws -> Page {
        var extras: [String: String] = [:]
        if let deviceFamily {
            extras["filter[deviceFamily]"] = deviceFamily.rawValue
        }
        if let state {
            extras["filter[state]"] = state.rawValue
        }
        let resp: PageEnvelope = try await client.get(
            path: "apps/\(appID)/accessibilityDeclarations",
            query: Self.listQuery(limit: limit, cursor: cursor, extras: extras),
            as: PageEnvelope.self
        )
        return Page(
            data: resp.data,
            nextCursor: Self.extractCursor(from: resp.links?.next)
        )
    }

    // MARK: - Read by id

    /// Fetches a single declaration by id. Returns nil on 404 (caller
    /// passed an id that does not exist or that the team is not
    /// permitted to see).
    package func get(id: String) async throws -> Declaration? {
        struct Resp: Decodable { let data: Declaration }
        do {
            let resp: Resp = try await client.get(
                path: "accessibilityDeclarations/\(id)",
                as: Resp.self
            )
            return resp.data
        } catch let e as ASCClient.APIError where e.statusCode == 404 {
            return nil
        }
    }

    // MARK: - Create

    /// Creates a new DRAFT declaration for an (app, deviceFamily). The
    /// returned record's `state` is `DRAFT`; call `update(publish:
    /// true)` to transition it to PUBLISHED.
    ///
    /// `fields.deviceFamily` is required: Apple rejects a POST that
    /// omits it. If you pass `Fields()` with no device family the
    /// method throws synchronously rather than waiting for the server
    /// 4xx, so the misuse fails fast in tests.
    ///
    /// `fields.publish` is ignored on create (it's a PATCH-only
    /// transition flag).
    @discardableResult
    package func create(
        appID: String,
        fields: Fields
    ) async throws -> Declaration {
        guard let deviceFamily = fields.deviceFamily else {
            throw NSError(
                domain: "AccessibilityDeclarationsAPI",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "deviceFamily is required when creating an accessibility declaration"
                ]
            )
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "accessibilityDeclarations"
                let attributes: Attrs
                let relationships: Rels
            }
            struct Attrs: Encodable {
                let deviceFamily: String
                var supportsAudioDescriptions: Bool?
                var supportsCaptions: Bool?
                var supportsDarkInterface: Bool?
                var supportsDifferentiateWithoutColorAlone: Bool?
                var supportsLargerText: Bool?
                var supportsReducedMotion: Bool?
                var supportsSufficientContrast: Bool?
                var supportsVoiceControl: Bool?
                var supportsVoiceover: Bool?
            }
            struct Rels: Encodable {
                struct App: Encodable {
                    struct D: Encodable { let type = "apps"; let id: String }
                    let data: D
                }
                let app: App
            }
            let data: Data
        }
        let body = Body(data: .init(
            attributes: .init(
                deviceFamily: deviceFamily.rawValue,
                supportsAudioDescriptions: fields.supportsAudioDescriptions,
                supportsCaptions: fields.supportsCaptions,
                supportsDarkInterface: fields.supportsDarkInterface,
                supportsDifferentiateWithoutColorAlone:
                    fields.supportsDifferentiateWithoutColorAlone,
                supportsLargerText: fields.supportsLargerText,
                supportsReducedMotion: fields.supportsReducedMotion,
                supportsSufficientContrast: fields.supportsSufficientContrast,
                supportsVoiceControl: fields.supportsVoiceControl,
                supportsVoiceover: fields.supportsVoiceover
            ),
            relationships: .init(app: .init(data: .init(id: appID)))
        ))
        struct Resp: Decodable { let data: Declaration }
        let resp: Resp = try await client.post(
            path: "accessibilityDeclarations",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    // MARK: - Update

    /// PATCHes a declaration with any non-nil fields. Nil fields are
    /// omitted from the wire body so existing values stay untouched.
    ///
    /// Passing `fields.publish == true` transitions a DRAFT record to
    /// PUBLISHED. If another PUBLISHED record exists for the same
    /// (app, deviceFamily), Apple automatically moves it to REPLACED.
    ///
    /// `fields.deviceFamily` is ignored on update because the value is
    /// immutable after creation.
    ///
    /// Throws if `fields` has no editable values set (ASC rejects an
    /// empty PATCH body with a 4xx). Use `Fields.isEmpty` to short-
    /// circuit on the caller side if needed.
    @discardableResult
    package func update(
        id: String,
        fields: Fields
    ) async throws -> Declaration {
        // Build a Fields copy with deviceFamily stripped, since it's
        // not a valid PATCH attribute. Then refuse an empty body up
        // front so the error is local rather than a 4xx round trip.
        var patchable = fields
        patchable.deviceFamily = nil
        guard !patchable.isEmpty else {
            throw NSError(
                domain: "AccessibilityDeclarationsAPI",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "update called with no fields to PATCH; pass at least one supports-* boolean or publish"
                ]
            )
        }
        struct Body: Encodable {
            struct Data: Encodable {
                let type = "accessibilityDeclarations"
                let id: String
                let attributes: Attrs
            }
            struct Attrs: Encodable {
                var publish: Bool?
                var supportsAudioDescriptions: Bool?
                var supportsCaptions: Bool?
                var supportsDarkInterface: Bool?
                var supportsDifferentiateWithoutColorAlone: Bool?
                var supportsLargerText: Bool?
                var supportsReducedMotion: Bool?
                var supportsSufficientContrast: Bool?
                var supportsVoiceControl: Bool?
                var supportsVoiceover: Bool?
            }
            let data: Data
        }
        let body = Body(data: .init(
            id: id,
            attributes: .init(
                publish: patchable.publish,
                supportsAudioDescriptions: patchable.supportsAudioDescriptions,
                supportsCaptions: patchable.supportsCaptions,
                supportsDarkInterface: patchable.supportsDarkInterface,
                supportsDifferentiateWithoutColorAlone:
                    patchable.supportsDifferentiateWithoutColorAlone,
                supportsLargerText: patchable.supportsLargerText,
                supportsReducedMotion: patchable.supportsReducedMotion,
                supportsSufficientContrast: patchable.supportsSufficientContrast,
                supportsVoiceControl: patchable.supportsVoiceControl,
                supportsVoiceover: patchable.supportsVoiceover
            )
        ))
        struct Resp: Decodable { let data: Declaration }
        let resp: Resp = try await client.patch(
            path: "accessibilityDeclarations/\(id)",
            body: body,
            as: Resp.self
        )
        return resp.data
    }

    // MARK: - Delete

    /// Deletes a declaration by id. Typically only meaningful for a
    /// DRAFT record; PUBLISHED records are normally superseded via the
    /// publish flow rather than deleted.
    package func delete(id: String) async throws {
        try await client.delete(path: "accessibilityDeclarations/\(id)")
    }
}
