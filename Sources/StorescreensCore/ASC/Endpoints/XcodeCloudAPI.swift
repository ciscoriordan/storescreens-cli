import Foundation

/// App Store Connect endpoints covering Xcode Cloud, Apple's hosted
/// continuous-integration service for Xcode projects. Wraps the JSON:API
/// resources Apple groups under "Xcode Cloud" in the docs:
///
///   - ciProducts (read-only; created by Apple when an Xcode project enables
///     Xcode Cloud)
///   - ciProductAdditionalRepositories (read-only)
///   - ciWorkflows (CRUD; the workflow definitions, including start
///     conditions, environment, and post-actions)
///   - ciBuildRuns (list, get, create/start, cancel, retry)
///   - ciBuildActions (read-only; the workflow steps like Archive, Test,
///     Analyze)
///   - ciArtifacts (read-only; downloadable artifact metadata with signed
///     URLs)
///   - ciIssues (read-only; errors, warnings, test failures)
///   - ciTestResults (read-only; per-test result metadata)
///   - ciMacOsVersions (read-only; available macOS versions for build
///     environments)
///   - ciXcodeVersions (read-only; available Xcode versions, plus the
///     macOS versions each is compatible with)
///   - scmRepositories (read-only; Git repos linked to Xcode Cloud
///     products)
///   - scmGitReferences (read-only; branches and tags that can trigger
///     workflows)
///   - scmPullRequests (read-only; PRs that can trigger workflows)
///   - scmProviders (read-only; GitHub, Bitbucket, GitLab providers)
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/xcode_cloud_workflows_and_builds
///
/// Pagination convention: every list endpoint accepts an optional `limit`
/// and `cursor` and returns `(data, nextCursor)`. The cursor is Apple's
/// opaque `links.next` continuation token; pass it back unchanged on the
/// next call to get the next page. When `nextCursor` is nil, the caller
/// has reached the end of the list.
///
/// Master namespace; resource families are accessed as nested properties
/// (e.g. `XcodeCloudAPI(client: client).workflows.list(...)`).
package struct XcodeCloudAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Shared paged response shape

    /// Generic JSON:API page envelope. Apple returns `links.next` as a
    /// full URL with a base64-encoded `cursor=` query parameter; we
    /// extract the cursor value so callers can pass it back on
    /// subsequent calls without having to parse the URL themselves.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let data: [Item]
        package let nextCursor: String?
    }

    /// Internal helper: decodes a JSON:API list response and pulls out
    /// the `cursor=` parameter from `links.next` if present.
    fileprivate struct PageEnvelope<Item: Codable>: Decodable {
        struct Links: Decodable { let next: String? }
        let data: [Item]
        let links: Links?
    }

    fileprivate static func extractCursor(from link: String?) -> String? {
        guard let link, !link.isEmpty,
              let comps = URLComponents(string: link)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    /// Standard list query builder used by every paged endpoint here.
    fileprivate static func listQuery(
        limit: Int,
        cursor: String?,
        extras: [String: String] = [:]
    ) -> [String: String] {
        var q = extras
        q["limit"] = String(limit)
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    // MARK: - Nested resource namespaces

    package var ciProducts: CiProducts { .init(client: client) }
    package var productAdditionalRepositories: ProductAdditionalRepositories {
        .init(client: client)
    }
    package var workflows: Workflows { .init(client: client) }
    package var buildRuns: BuildRuns { .init(client: client) }
    package var buildActions: BuildActions { .init(client: client) }
    package var artifacts: Artifacts { .init(client: client) }
    package var issues: Issues { .init(client: client) }
    package var testResults: TestResults { .init(client: client) }
    package var macOsVersions: MacOsVersions { .init(client: client) }
    package var xcodeVersions: XcodeVersions { .init(client: client) }
    package var scmRepositories: ScmRepositories { .init(client: client) }
    package var scmGitReferences: ScmGitReferences { .init(client: client) }
    package var scmPullRequests: ScmPullRequests { .init(client: client) }
    package var scmProviders: ScmProviders { .init(client: client) }

    // MARK: - ciProducts

    /// Read-only listing/get of Xcode Cloud "products". A product is the
    /// Xcode Cloud counterpart to an ASC App (or framework). Apple
    /// creates one when an Xcode project enables Xcode Cloud.
    package struct CiProducts: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct CiProduct: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Display name shown in Xcode Cloud.
                package let name: String?
                /// "APP" or "FRAMEWORK".
                package let productType: String?
                /// When Apple linked the Xcode project to Xcode Cloud.
                package let createdDate: Date?
            }
        }

        /// Lists every Xcode Cloud product visible to the API key. Pass
        /// `appID` to scope to a single ASC app.
        package func list(
            appID: String? = nil,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<CiProduct> {
            var extras: [String: String] = [:]
            if let appID { extras["filter[app]"] = appID }
            let resp: PageEnvelope<CiProduct> = try await client.get(
                path: "ciProducts",
                query: XcodeCloudAPI.listQuery(
                    limit: limit, cursor: cursor, extras: extras
                ),
                as: PageEnvelope<CiProduct>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Fetches a single product by id. Returns nil on 404.
        package func get(id: String) async throws -> CiProduct? {
            struct Resp: Decodable { let data: CiProduct }
            do {
                let resp: Resp = try await client.get(
                    path: "ciProducts/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Deletes the link between an Xcode Cloud product and ASC.
        /// Apple's docs surface this as a teardown for an Xcode Cloud
        /// integration; the Xcode project itself is untouched.
        package func delete(id: String) async throws {
            try await client.delete(path: "ciProducts/\(id)")
        }
    }

    // MARK: - ciProductAdditionalRepositories

    /// Read-only listing/get of extra SCM repositories attached to a
    /// product (for example, a frameworks repo plus an app repo). Each
    /// entry pairs a ciProduct with an scmRepository.
    package struct ProductAdditionalRepositories: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct AdditionalRepository: Codable, Sendable {
            package let id: String
            /// Apple does not return attributes for this resource as of
            /// the public API; the relationship side carries the data.
        }

        package func list(
            productID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<AdditionalRepository> {
            let resp: PageEnvelope<AdditionalRepository> = try await client.get(
                path: "ciProducts/\(productID)/additionalRepositories",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<AdditionalRepository>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> AdditionalRepository? {
            struct Resp: Decodable { let data: AdditionalRepository }
            do {
                let resp: Resp = try await client.get(
                    path: "ciProductAdditionalRepositories/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - Workflow shared types

    /// Container settings for a workflow: target app type, build
    /// environment, autoStartCondition. These ride along with the
    /// workflow body on create/update.
    package struct WorkflowContainer: Codable, Sendable, Equatable {
        /// "APP", "EXTENSION", "FRAMEWORK".
        package var appType: String?
        /// Apple-supplied Xcode version id (from ciXcodeVersions.list).
        package var xcodeVersionID: String?
        /// Apple-supplied macOS version id (from ciMacOsVersions.list).
        package var macOsVersionID: String?
        /// "IOS", "MAC_OS", "TV_OS", "WATCH_OS", "VISION_OS"; usually
        /// derived by Apple, but listed here for completeness.
        package var platforms: [String]?

        package init(
            appType: String? = nil,
            xcodeVersionID: String? = nil,
            macOsVersionID: String? = nil,
            platforms: [String]? = nil
        ) {
            self.appType = appType
            self.xcodeVersionID = xcodeVersionID
            self.macOsVersionID = macOsVersionID
            self.platforms = platforms
        }
    }

    /// Start conditions for a workflow. Apple represents these as
    /// arrays of typed entries (branchStart, tagStart, pullRequestStart,
    /// scheduledStart); we expose them as one merged struct with the
    /// raw JSON values so callers can round-trip what Apple returns
    /// without us locking the schema down further than Apple does.
    package struct WorkflowStartCondition: Codable, Sendable, Equatable {
        package var source: String?
        /// JSON value blob (Branch / Tag / PR / Scheduled). Stored as
        /// `AnyCodableValue` so we don't have to mirror every variant.
        package var conditions: AnyCodableValue?

        package init(
            source: String? = nil,
            conditions: AnyCodableValue? = nil
        ) {
            self.source = source
            self.conditions = conditions
        }
    }

    /// Workflow actions config: archive, analyze, build, test. Apple
    /// represents this as a heterogeneous array; we keep raw JSON so
    /// agents can construct/round-trip these exactly as Apple expects.
    package struct WorkflowActions: Codable, Sendable, Equatable {
        package var raw: AnyCodableValue?

        package init(raw: AnyCodableValue? = nil) { self.raw = raw }

        package init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.raw = try? container.decode(AnyCodableValue.self)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(raw)
        }
    }

    /// Loose JSON value type so workflow payloads can pass through
    /// Apple's free-form nested objects without us pinning down every
    /// branch. Maps to bool / int / double / string / null / array /
    /// dictionary.
    package enum AnyCodableValue: Codable, Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyCodableValue])
        case object([String: AnyCodableValue])

        package init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([AnyCodableValue].self) { self = .array(a); return }
            if let o = try? c.decode([String: AnyCodableValue].self) { self = .object(o); return }
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")
            )
        }

        package func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    // MARK: - ciWorkflows

    /// Full CRUD over Xcode Cloud workflow definitions. A workflow
    /// describes what Xcode Cloud should build, on which Xcode + macOS
    /// version, in response to which Git reference change.
    package struct Workflows: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Workflow: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?
            package let relationships: Relationships?

            package struct Attributes: Codable, Sendable {
                package let name: String?
                package let description: String?
                package let branchStartCondition: AnyCodableValue?
                package let tagStartCondition: AnyCodableValue?
                package let pullRequestStartCondition: AnyCodableValue?
                package let scheduledStartCondition: AnyCodableValue?
                package let manualBranchStartCondition: AnyCodableValue?
                package let manualPullRequestStartCondition: AnyCodableValue?
                package let manualTagStartCondition: AnyCodableValue?
                package let pullRequestStartConditions: AnyCodableValue?
                package let isLockedForEditing: Bool?
                package let isEnabled: Bool?
                package let containerFilePath: String?
                package let actions: AnyCodableValue?
                package let lastModifiedDate: Date?
            }

            package struct Relationships: Codable, Sendable {
                package let product: Relation?
                package let repository: Relation?
                package let xcodeVersion: Relation?
                package let macOsVersion: Relation?

                package struct Relation: Codable, Sendable {
                    package let data: Reference?

                    package struct Reference: Codable, Sendable {
                        package let type: String
                        package let id: String
                    }
                }
            }
        }

        /// Lists workflows for an Xcode Cloud product. Apple does not
        /// expose a top-level `ciWorkflows` listing without a product
        /// scope.
        package func list(
            productID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Workflow> {
            let resp: PageEnvelope<Workflow> = try await client.get(
                path: "ciProducts/\(productID)/workflows",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Workflow>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> Workflow? {
            struct Resp: Decodable { let data: Workflow }
            do {
                let resp: Resp = try await client.get(
                    path: "ciWorkflows/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Fields accepted on workflow create. All but `name`, `product`,
        /// and `repository` map straight onto the JSON:API attributes
        /// block. Nil fields are omitted from the wire body.
        package struct WorkflowCreateFields: Sendable {
            package var name: String
            package var description: String?
            package var isEnabled: Bool?
            package var isLockedForEditing: Bool?
            package var containerFilePath: String?
            package var branchStartCondition: AnyCodableValue?
            package var tagStartCondition: AnyCodableValue?
            package var pullRequestStartCondition: AnyCodableValue?
            package var scheduledStartCondition: AnyCodableValue?
            package var manualBranchStartCondition: AnyCodableValue?
            package var manualPullRequestStartCondition: AnyCodableValue?
            package var manualTagStartCondition: AnyCodableValue?
            package var actions: AnyCodableValue?

            package init(
                name: String,
                description: String? = nil,
                isEnabled: Bool? = nil,
                isLockedForEditing: Bool? = nil,
                containerFilePath: String? = nil,
                branchStartCondition: AnyCodableValue? = nil,
                tagStartCondition: AnyCodableValue? = nil,
                pullRequestStartCondition: AnyCodableValue? = nil,
                scheduledStartCondition: AnyCodableValue? = nil,
                manualBranchStartCondition: AnyCodableValue? = nil,
                manualPullRequestStartCondition: AnyCodableValue? = nil,
                manualTagStartCondition: AnyCodableValue? = nil,
                actions: AnyCodableValue? = nil
            ) {
                self.name = name
                self.description = description
                self.isEnabled = isEnabled
                self.isLockedForEditing = isLockedForEditing
                self.containerFilePath = containerFilePath
                self.branchStartCondition = branchStartCondition
                self.tagStartCondition = tagStartCondition
                self.pullRequestStartCondition = pullRequestStartCondition
                self.scheduledStartCondition = scheduledStartCondition
                self.manualBranchStartCondition = manualBranchStartCondition
                self.manualPullRequestStartCondition = manualPullRequestStartCondition
                self.manualTagStartCondition = manualTagStartCondition
                self.actions = actions
            }
        }

        fileprivate struct WorkflowAttrsCreate: Encodable {
            var name: String
            var description: String?
            var isEnabled: Bool?
            var isLockedForEditing: Bool?
            var containerFilePath: String?
            var branchStartCondition: AnyCodableValue?
            var tagStartCondition: AnyCodableValue?
            var pullRequestStartCondition: AnyCodableValue?
            var scheduledStartCondition: AnyCodableValue?
            var manualBranchStartCondition: AnyCodableValue?
            var manualPullRequestStartCondition: AnyCodableValue?
            var manualTagStartCondition: AnyCodableValue?
            var actions: AnyCodableValue?

            init(fields: WorkflowCreateFields) {
                self.name = fields.name
                self.description = fields.description
                self.isEnabled = fields.isEnabled
                self.isLockedForEditing = fields.isLockedForEditing
                self.containerFilePath = fields.containerFilePath
                self.branchStartCondition = fields.branchStartCondition
                self.tagStartCondition = fields.tagStartCondition
                self.pullRequestStartCondition = fields.pullRequestStartCondition
                self.scheduledStartCondition = fields.scheduledStartCondition
                self.manualBranchStartCondition = fields.manualBranchStartCondition
                self.manualPullRequestStartCondition = fields.manualPullRequestStartCondition
                self.manualTagStartCondition = fields.manualTagStartCondition
                self.actions = fields.actions
            }
        }

        /// Creates a new workflow on the given product, attached to a
        /// repository. The xcode + macOS version ids are required by
        /// Apple: pull them from `xcodeVersions.list()` and
        /// `macOsVersions.list()` and pin to a known combination.
        @discardableResult
        package func create(
            productID: String,
            repositoryID: String,
            xcodeVersionID: String,
            macOsVersionID: String,
            fields: WorkflowCreateFields
        ) async throws -> Workflow {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "ciWorkflows"
                    let attributes: WorkflowAttrsCreate
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct Ref: Encodable {
                        struct D: Encodable {
                            let type: String
                            let id: String
                        }
                        let data: D
                    }
                    let product: Ref
                    let repository: Ref
                    let xcodeVersion: Ref
                    let macOsVersion: Ref
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: WorkflowAttrsCreate(fields: fields),
                relationships: .init(
                    product: .init(data: .init(type: "ciProducts", id: productID)),
                    repository: .init(data: .init(type: "scmRepositories", id: repositoryID)),
                    xcodeVersion: .init(data: .init(type: "ciXcodeVersions", id: xcodeVersionID)),
                    macOsVersion: .init(data: .init(type: "ciMacOsVersions", id: macOsVersionID))
                )
            ))
            struct Resp: Decodable { let data: Workflow }
            let resp: Resp = try await client.post(
                path: "ciWorkflows", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Fields accepted on workflow update (PATCH). Nil fields are
        /// omitted, so existing Apple-side values stay untouched.
        package struct WorkflowUpdateFields: Sendable {
            package var name: String?
            package var description: String?
            package var isEnabled: Bool?
            package var isLockedForEditing: Bool?
            package var containerFilePath: String?
            package var branchStartCondition: AnyCodableValue?
            package var tagStartCondition: AnyCodableValue?
            package var pullRequestStartCondition: AnyCodableValue?
            package var scheduledStartCondition: AnyCodableValue?
            package var manualBranchStartCondition: AnyCodableValue?
            package var manualPullRequestStartCondition: AnyCodableValue?
            package var manualTagStartCondition: AnyCodableValue?
            package var actions: AnyCodableValue?
            package var xcodeVersionID: String?
            package var macOsVersionID: String?

            package init(
                name: String? = nil,
                description: String? = nil,
                isEnabled: Bool? = nil,
                isLockedForEditing: Bool? = nil,
                containerFilePath: String? = nil,
                branchStartCondition: AnyCodableValue? = nil,
                tagStartCondition: AnyCodableValue? = nil,
                pullRequestStartCondition: AnyCodableValue? = nil,
                scheduledStartCondition: AnyCodableValue? = nil,
                manualBranchStartCondition: AnyCodableValue? = nil,
                manualPullRequestStartCondition: AnyCodableValue? = nil,
                manualTagStartCondition: AnyCodableValue? = nil,
                actions: AnyCodableValue? = nil,
                xcodeVersionID: String? = nil,
                macOsVersionID: String? = nil
            ) {
                self.name = name
                self.description = description
                self.isEnabled = isEnabled
                self.isLockedForEditing = isLockedForEditing
                self.containerFilePath = containerFilePath
                self.branchStartCondition = branchStartCondition
                self.tagStartCondition = tagStartCondition
                self.pullRequestStartCondition = pullRequestStartCondition
                self.scheduledStartCondition = scheduledStartCondition
                self.manualBranchStartCondition = manualBranchStartCondition
                self.manualPullRequestStartCondition = manualPullRequestStartCondition
                self.manualTagStartCondition = manualTagStartCondition
                self.actions = actions
                self.xcodeVersionID = xcodeVersionID
                self.macOsVersionID = macOsVersionID
            }
        }

        fileprivate struct WorkflowAttrsPatch: Encodable {
            var name: String?
            var description: String?
            var isEnabled: Bool?
            var isLockedForEditing: Bool?
            var containerFilePath: String?
            var branchStartCondition: AnyCodableValue?
            var tagStartCondition: AnyCodableValue?
            var pullRequestStartCondition: AnyCodableValue?
            var scheduledStartCondition: AnyCodableValue?
            var manualBranchStartCondition: AnyCodableValue?
            var manualPullRequestStartCondition: AnyCodableValue?
            var manualTagStartCondition: AnyCodableValue?
            var actions: AnyCodableValue?

            init(fields: WorkflowUpdateFields) {
                self.name = fields.name
                self.description = fields.description
                self.isEnabled = fields.isEnabled
                self.isLockedForEditing = fields.isLockedForEditing
                self.containerFilePath = fields.containerFilePath
                self.branchStartCondition = fields.branchStartCondition
                self.tagStartCondition = fields.tagStartCondition
                self.pullRequestStartCondition = fields.pullRequestStartCondition
                self.scheduledStartCondition = fields.scheduledStartCondition
                self.manualBranchStartCondition = fields.manualBranchStartCondition
                self.manualPullRequestStartCondition = fields.manualPullRequestStartCondition
                self.manualTagStartCondition = fields.manualTagStartCondition
                self.actions = fields.actions
            }
        }

        @discardableResult
        package func update(
            id: String, fields: WorkflowUpdateFields
        ) async throws -> Workflow {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "ciWorkflows"
                    let id: String
                    let attributes: WorkflowAttrsPatch
                    var relationships: Rels?
                }
                struct Rels: Encodable {
                    struct Ref: Encodable {
                        struct D: Encodable {
                            let type: String
                            let id: String
                        }
                        let data: D
                    }
                    var xcodeVersion: Ref?
                    var macOsVersion: Ref?
                }
                let data: Data
            }
            var rels: Body.Rels?
            if fields.xcodeVersionID != nil || fields.macOsVersionID != nil {
                rels = Body.Rels(
                    xcodeVersion: fields.xcodeVersionID.map {
                        .init(data: .init(type: "ciXcodeVersions", id: $0))
                    },
                    macOsVersion: fields.macOsVersionID.map {
                        .init(data: .init(type: "ciMacOsVersions", id: $0))
                    }
                )
            }
            let body = Body(data: .init(
                id: id,
                attributes: WorkflowAttrsPatch(fields: fields),
                relationships: rels
            ))
            struct Resp: Decodable { let data: Workflow }
            let resp: Resp = try await client.patch(
                path: "ciWorkflows/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        package func delete(id: String) async throws {
            try await client.delete(path: "ciWorkflows/\(id)")
        }
    }

    // MARK: - ciBuildRuns

    /// One execution of a workflow. CRUD-ish: list, get, create (start a
    /// new run), and the PATCH/POST variants for cancel and retry. Apple
    /// does not allow DELETE on a build run; they're append-only.
    package struct BuildRuns: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct BuildRun: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// Integer build run number within the workflow.
                package let number: Int?
                /// "BUILDING", "TESTING", "COMPLETE", "CANCELED", etc.
                package let executionProgress: String?
                /// "SUCCEEDED", "FAILED", "ERRORED", "CANCELED",
                /// "ISSUE", "UNKNOWN".
                package let completionStatus: String?
                package let startReason: String?
                package let createdDate: Date?
                package let startedDate: Date?
                package let finishedDate: Date?
                package let cancelReason: String?
                package let sourceCommit: SourceCommit?
                package let destinationCommit: SourceCommit?
                package let isPullRequestBuild: Bool?
                package let issueCounts: IssueCounts?

                package struct SourceCommit: Codable, Sendable {
                    package let commitSha: String?
                    package let htmlUrl: String?
                    package let message: String?
                    package let author: Person?
                    package let committer: Person?

                    package struct Person: Codable, Sendable {
                        package let displayName: String?
                        package let avatarUrl: String?
                    }
                }

                package struct IssueCounts: Codable, Sendable {
                    package let analyzerWarnings: Int?
                    package let errors: Int?
                    package let testFailures: Int?
                    package let warnings: Int?
                }
            }
        }

        /// Lists build runs filtered by product, workflow, and/or
        /// source commit sha. Sort defaults to newest-first.
        package func list(
            productID: String? = nil,
            workflowID: String? = nil,
            sourceCommitSha: String? = nil,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<BuildRun> {
            var extras: [String: String] = ["sort": "-number"]
            if let productID { extras["filter[product]"] = productID }
            if let workflowID { extras["filter[workflow]"] = workflowID }
            if let sourceCommitSha {
                extras["filter[sourceCommit]"] = sourceCommitSha
            }
            let resp: PageEnvelope<BuildRun> = try await client.get(
                path: "ciBuildRuns",
                query: XcodeCloudAPI.listQuery(
                    limit: limit, cursor: cursor, extras: extras
                ),
                as: PageEnvelope<BuildRun>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Lists build runs scoped to a workflow. Convenience wrapper
        /// around `list(workflowID:)` matching Apple's nested-resource
        /// URL shape.
        package func listForWorkflow(
            workflowID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<BuildRun> {
            let resp: PageEnvelope<BuildRun> = try await client.get(
                path: "ciWorkflows/\(workflowID)/buildRuns",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<BuildRun>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Lists build runs scoped to a product (Apple nested URL).
        package func listForProduct(
            productID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<BuildRun> {
            let resp: PageEnvelope<BuildRun> = try await client.get(
                path: "ciProducts/\(productID)/buildRuns",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<BuildRun>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> BuildRun? {
            struct Resp: Decodable { let data: BuildRun }
            do {
                let resp: Resp = try await client.get(
                    path: "ciBuildRuns/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Starts a new build run for a workflow. Pass exactly one of
        /// `gitReferenceID` (branch / tag) or `pullRequestID` so Apple
        /// knows where to source the commit. The build run is created
        /// asynchronously; poll `get(id:)` until executionProgress
        /// settles to a terminal state.
        @discardableResult
        package func create(
            workflowID: String,
            gitReferenceID: String? = nil,
            pullRequestID: String? = nil,
            sourceBranchOrTagID: String? = nil
        ) async throws -> BuildRun {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "ciBuildRuns"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct Ref: Encodable {
                        struct D: Encodable {
                            let type: String
                            let id: String
                        }
                        let data: D
                    }
                    let workflow: Ref
                    var sourceBranchOrTag: Ref?
                    var pullRequest: Ref?
                }
                let data: Data
            }
            var rels = Body.Rels(
                workflow: .init(data: .init(type: "ciWorkflows", id: workflowID))
            )
            // Apple accepts either a sourceBranchOrTag relationship or
            // a pullRequest relationship. `gitReferenceID` is the
            // friendly alias for sourceBranchOrTagID.
            let sourceRef = sourceBranchOrTagID ?? gitReferenceID
            if let sourceRef {
                rels.sourceBranchOrTag = .init(
                    data: .init(type: "scmGitReferences", id: sourceRef)
                )
            }
            if let pullRequestID {
                rels.pullRequest = .init(
                    data: .init(type: "scmPullRequests", id: pullRequestID)
                )
            }
            let body = Body(data: .init(relationships: rels))
            struct Resp: Decodable { let data: BuildRun }
            let resp: Resp = try await client.post(
                path: "ciBuildRuns", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Cancels an in-flight build run by PATCHing `canceled: true`.
        /// Apple finalizes the cancellation asynchronously; poll the
        /// run until `executionProgress == "COMPLETE"` and
        /// `completionStatus == "CANCELED"`.
        @discardableResult
        package func cancel(id: String) async throws -> BuildRun {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "ciBuildRuns"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable { let canceled: Bool }
                let data: Data
            }
            let body = Body(data: .init(id: id, attributes: .init(canceled: true)))
            struct Resp: Decodable { let data: BuildRun }
            let resp: Resp = try await client.patch(
                path: "ciBuildRuns/\(id)", body: body, as: Resp.self
            )
            return resp.data
        }

        /// Retries a previously-finished build run by creating a new
        /// run that copies the existing run's source commit and
        /// workflow. Apple exposes this as a POST to
        /// `/ciBuildRuns/{id}/retry` which returns a brand-new
        /// ciBuildRun resource.
        @discardableResult
        package func retry(id: String) async throws -> BuildRun {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "ciBuildRuns"
                    let id: String
                }
                let data: Data
            }
            let body = Body(data: .init(id: id))
            struct Resp: Decodable { let data: BuildRun }
            let resp: Resp = try await client.post(
                path: "ciBuildRuns/\(id)/retry", body: body, as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - ciBuildActions

    /// Read-only view of the individual steps (Archive, Test, Analyze,
    /// Build) inside a build run. Each step has its own status and
    /// surfaces issues, artifacts, and test results.
    package struct BuildActions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct BuildAction: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let name: String?
                /// "BUILD", "TEST", "ARCHIVE", "ANALYZE".
                package let actionType: String?
                /// "BUILDING", "TESTING", "COMPLETE", etc.
                package let executionProgress: String?
                /// "SUCCEEDED", "FAILED", "ERRORED", "CANCELED",
                /// "ISSUE", "UNKNOWN".
                package let completionStatus: String?
                package let startedDate: Date?
                package let finishedDate: Date?
                package let isRequiredToPass: Bool?
                package let issueCounts: IssueCounts?

                package struct IssueCounts: Codable, Sendable {
                    package let analyzerWarnings: Int?
                    package let errors: Int?
                    package let testFailures: Int?
                    package let warnings: Int?
                }
            }
        }

        /// Lists build actions for a single build run. Apple does not
        /// expose a top-level listing, just the nested one.
        package func list(
            buildRunID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<BuildAction> {
            let resp: PageEnvelope<BuildAction> = try await client.get(
                path: "ciBuildRuns/\(buildRunID)/actions",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<BuildAction>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> BuildAction? {
            struct Resp: Decodable { let data: BuildAction }
            do {
                let resp: Resp = try await client.get(
                    path: "ciBuildActions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - ciArtifacts

    /// Read-only metadata for downloadable artifacts produced by a
    /// build action (archives, test results bundles, logs). Each
    /// artifact has a signed `downloadUrl` that Apple expires after a
    /// short window.
    package struct Artifacts: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Artifact: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// File name Apple suggests for the download (e.g.
                /// "MyApp.xcarchive.zip", "results.xcresult.zip").
                package let fileName: String?
                /// Short-lived signed URL to fetch the artifact body.
                package let downloadUrl: String?
                /// "ARCHIVE", "TEMPORARY_FILES_DIRECTORY",
                /// "RESULT_BUNDLE", "LOG_BUNDLE".
                package let fileType: String?
                package let fileSize: Int?
            }
        }

        /// Lists artifacts produced by a single build action.
        package func list(
            buildActionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Artifact> {
            let resp: PageEnvelope<Artifact> = try await client.get(
                path: "ciBuildActions/\(buildActionID)/artifacts",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Artifact>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> Artifact? {
            struct Resp: Decodable { let data: Artifact }
            do {
                let resp: Resp = try await client.get(
                    path: "ciArtifacts/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - ciIssues

    /// Read-only listing of issues surfaced by a build action: compiler
    /// errors, analyzer warnings, test failures, etc.
    package struct Issues: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct Issue: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "ANALYZER_WARNING", "ERROR", "TEST_FAILURE",
                /// "WARNING".
                package let issueType: String?
                package let message: String?
                package let fileSource: FileSource?
                package let category: String?

                package struct FileSource: Codable, Sendable {
                    package let fileName: String?
                    package let lineNumber: Int?
                }
            }
        }

        /// Lists issues surfaced by a single build action.
        package func list(
            buildActionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Issue> {
            let resp: PageEnvelope<Issue> = try await client.get(
                path: "ciBuildActions/\(buildActionID)/issues",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Issue>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> Issue? {
            struct Resp: Decodable { let data: Issue }
            do {
                let resp: Resp = try await client.get(
                    path: "ciIssues/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - ciTestResults

    /// Read-only XCTest result metadata for a build action. One entry
    /// per test case run; failures carry their assertion messages
    /// inline.
    package struct TestResults: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct TestResult: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let className: String?
                package let name: String?
                /// "SUCCESS", "FAILURE", "MIXED", "SKIPPED",
                /// "EXPECTED_FAILURE".
                package let status: String?
                /// Apple's per-destination breakdowns (one entry per
                /// device / locale combination Xcode Cloud ran).
                package let destinationTestResults: [DestinationResult]?
                package let fileSource: FileSource?

                package struct DestinationResult: Codable, Sendable {
                    package let displayName: String?
                    package let uuid: String?
                    package let status: String?
                    package let duration: Double?
                    package let failureMessages: [String]?
                }

                package struct FileSource: Codable, Sendable {
                    package let fileName: String?
                    package let lineNumber: Int?
                }
            }
        }

        /// Lists test results for a build action.
        package func listForBuildAction(
            buildActionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<TestResult> {
            let resp: PageEnvelope<TestResult> = try await client.get(
                path: "ciBuildActions/\(buildActionID)/testResults",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<TestResult>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Lists test results across a product (handy for tracking a
        /// single test case's status across builds).
        package func listForProduct(
            productID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<TestResult> {
            let resp: PageEnvelope<TestResult> = try await client.get(
                path: "ciProducts/\(productID)/testResults",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<TestResult>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> TestResult? {
            struct Resp: Decodable { let data: TestResult }
            do {
                let resp: Resp = try await client.get(
                    path: "ciTestResults/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - ciMacOsVersions

    /// Read-only catalog of macOS versions Xcode Cloud can run builds
    /// against. Used when creating or updating a workflow to pin the
    /// build environment.
    package struct MacOsVersions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct MacOsVersion: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "macOS Sonoma 14.5", "macOS Ventura 13.6.7" etc.
                package let name: String?
                /// e.g. "14.5".
                package let version: String?
            }
        }

        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<MacOsVersion> {
            let resp: PageEnvelope<MacOsVersion> = try await client.get(
                path: "ciMacOsVersions",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<MacOsVersion>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> MacOsVersion? {
            struct Resp: Decodable { let data: MacOsVersion }
            do {
                let resp: Resp = try await client.get(
                    path: "ciMacOsVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - ciXcodeVersions

    /// Read-only catalog of Xcode versions Xcode Cloud supports. Pair
    /// with `listCompatibleMacOsVersions(for:)` to know which macOS
    /// versions a given Xcode build can use.
    package struct XcodeVersions: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct XcodeVersion: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "Xcode 16.0", "Xcode 15.4" etc.
                package let name: String?
                /// e.g. "16.0".
                package let version: String?
            }
        }

        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<XcodeVersion> {
            let resp: PageEnvelope<XcodeVersion> = try await client.get(
                path: "ciXcodeVersions",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<XcodeVersion>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> XcodeVersion? {
            struct Resp: Decodable { let data: XcodeVersion }
            do {
                let resp: Resp = try await client.get(
                    path: "ciXcodeVersions/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Lists which macOS versions are compatible with a specific
        /// Xcode version. Apple keeps this matrix per Xcode release.
        package func listCompatibleMacOsVersions(
            xcodeVersionID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<MacOsVersions.MacOsVersion> {
            let resp: PageEnvelope<MacOsVersions.MacOsVersion> = try await client.get(
                path: "ciXcodeVersions/\(xcodeVersionID)/macOsVersions",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<MacOsVersions.MacOsVersion>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }
    }

    // MARK: - scmRepositories

    /// Read-only listing/get of Git repositories that have been linked
    /// to Xcode Cloud. Each repository belongs to one scmProvider
    /// (GitHub, Bitbucket, GitLab).
    package struct ScmRepositories: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct ScmRepository: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let lastAccessedDate: Date?
                package let httpCloneUrl: String?
                package let sshCloneUrl: String?
                package let ownerName: String?
                package let repositoryName: String?
            }
        }

        /// Lists every scmRepository visible to the API key. Pass
        /// `ciProductID` to scope to repos attached to a specific
        /// product, or `scmProviderID` to filter by provider.
        package func list(
            ciProductID: String? = nil,
            scmProviderID: String? = nil,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<ScmRepository> {
            var extras: [String: String] = [:]
            if let ciProductID { extras["filter[ciProduct]"] = ciProductID }
            if let scmProviderID { extras["filter[scmProvider]"] = scmProviderID }
            let resp: PageEnvelope<ScmRepository> = try await client.get(
                path: "scmRepositories",
                query: XcodeCloudAPI.listQuery(
                    limit: limit, cursor: cursor, extras: extras
                ),
                as: PageEnvelope<ScmRepository>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> ScmRepository? {
            struct Resp: Decodable { let data: ScmRepository }
            do {
                let resp: Resp = try await client.get(
                    path: "scmRepositories/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - scmGitReferences

    /// Read-only listing/get of branch and tag refs that can trigger a
    /// workflow. Apple lazily populates this from the linked
    /// repository.
    package struct ScmGitReferences: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct GitReference: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "main", "release/2.5", "v2.5.0" etc.
                package let name: String?
                /// "BRANCH" or "TAG".
                package let kind: String?
                package let isDeleted: Bool?
                package let canonicalName: String?
            }
        }

        /// Lists git references for a repository. Pass `kind` to
        /// filter to branches or tags only.
        package func list(
            repositoryID: String,
            kind: String? = nil,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<GitReference> {
            var extras: [String: String] = [:]
            if let kind { extras["filter[kind]"] = kind }
            let resp: PageEnvelope<GitReference> = try await client.get(
                path: "scmRepositories/\(repositoryID)/gitReferences",
                query: XcodeCloudAPI.listQuery(
                    limit: limit, cursor: cursor, extras: extras
                ),
                as: PageEnvelope<GitReference>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> GitReference? {
            struct Resp: Decodable { let data: GitReference }
            do {
                let resp: Resp = try await client.get(
                    path: "scmGitReferences/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - scmPullRequests

    /// Read-only listing/get of pull requests known to Apple's SCM
    /// integration. Used as the source for PR-triggered workflows.
    package struct ScmPullRequests: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct PullRequest: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                package let title: String?
                /// Numeric PR id in the upstream SCM.
                package let number: Int?
                /// "OPEN", "CLOSED" (Apple's normalized state).
                package let webUrl: String?
                package let sourceRepositoryOwner: String?
                package let sourceRepositoryName: String?
                package let sourceBranchName: String?
                package let destinationRepositoryOwner: String?
                package let destinationRepositoryName: String?
                package let destinationBranchName: String?
                package let isClosed: Bool?
                package let isCrossRepository: Bool?
            }
        }

        package func list(
            repositoryID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<PullRequest> {
            let resp: PageEnvelope<PullRequest> = try await client.get(
                path: "scmRepositories/\(repositoryID)/pullRequests",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<PullRequest>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> PullRequest? {
            struct Resp: Decodable { let data: PullRequest }
            do {
                let resp: Resp = try await client.get(
                    path: "scmPullRequests/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }

    // MARK: - scmProviders

    /// Read-only listing/get of SCM providers the team has linked to
    /// Xcode Cloud (GitHub, Bitbucket, GitLab).
    package struct ScmProviders: Sendable {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        package struct ScmProvider: Codable, Sendable {
            package let id: String
            package let attributes: Attributes?

            package struct Attributes: Codable, Sendable {
                /// "GITHUB", "GITHUB_ENTERPRISE", "BITBUCKET_CLOUD",
                /// "BITBUCKET_SERVER", "GITLAB_SELF_MANAGED",
                /// "GITLAB_HOSTED".
                package let scmProviderType: String?
                package let url: String?
            }
        }

        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<ScmProvider> {
            let resp: PageEnvelope<ScmProvider> = try await client.get(
                path: "scmProviders",
                query: XcodeCloudAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<ScmProvider>.self
            )
            return .init(
                data: resp.data,
                nextCursor: XcodeCloudAPI.extractCursor(from: resp.links?.next)
            )
        }

        package func get(id: String) async throws -> ScmProvider? {
            struct Resp: Decodable { let data: ScmProvider }
            do {
                let resp: Resp = try await client.get(
                    path: "scmProviders/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }
    }
}
