import ArgumentParser
import Foundation
import StorescreensCore

/// Top-level `storescreens xcode-cloud` command. Wraps the App Store
/// Connect Xcode Cloud (CI/CD) APIs as nested subcommands so AI agents
/// (and humans) can drive Xcode Cloud workflows, build runs, and
/// artifacts without hand-rolling HTTP requests.
///
/// Every leaf subcommand accepts `--json` for machine-readable output;
/// without it, results print as readable text via the shared Logger.
struct XcodeCloudCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-cloud",
        abstract: "Manage Xcode Cloud workflows, build runs, and artifacts.",
        discussion: """
            Wraps the App Store Connect Xcode Cloud API. Requires credentials \
            via `storescreens auth login` or ASC_KEY_ID / ASC_ISSUER_ID / \
            ASC_KEY_PATH env vars.

            Use `--json` on any leaf subcommand to get machine-readable output. \
            The same operations are exposed as MCP tools under the `xcc_*` \
            namespace.
            """,
        subcommands: [
            XCCProductsCommand.self,
            XCCProductAdditionalRepositoriesCommand.self,
            XCCWorkflowsCommand.self,
            XCCBuildRunsCommand.self,
            XCCBuildActionsCommand.self,
            XCCArtifactsCommand.self,
            XCCIssuesCommand.self,
            XCCTestResultsCommand.self,
            XCCMacOsVersionsCommand.self,
            XCCXcodeVersionsCommand.self,
            XCCScmRepositoriesCommand.self,
            XCCScmGitReferencesCommand.self,
            XCCScmPullRequestsCommand.self,
            XCCScmProvidersCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Resolves ASC credentials and builds an `XcodeCloudAPI`. Throws an
/// ExitCode(1) after logging on failure so subcommands stay tiny.
fileprivate func xccClient(logger: Logger) throws -> XcodeCloudAPI {
    let creds: ASCCredentials
    do {
        creds = try ASCCredentialResolver.resolve()
    } catch {
        logger.log("credentials not configured: \(error)", level: .error)
        print("  run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH")
        throw ExitCode(1)
    }
    let client = ASCClient(credentials: creds)
    return XcodeCloudAPI(client: client)
}

fileprivate func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

fileprivate func emitOptionalJSON<T: Encodable>(_ value: T?) throws {
    if let value {
        try emitJSON(value)
    } else {
        print("null")
    }
}

/// Wraps a paged page in the same shape MCP tools emit.
fileprivate struct CLIPage<Item: Encodable>: Encodable {
    let data: [Item]
    let nextCursor: String?
}

/// Maps ASCClient.APIError to a readable, formatted error then throws
/// ExitCode(1). Other errors propagate.
fileprivate func surface<T>(_ block: () async throws -> T, logger: Logger) async throws -> T {
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

/// Parses a JSON string into an `AnyCodableValue` so callers can pass
/// inline workflow conditions/actions on the command line.
fileprivate func parseJSONValue(_ raw: String?) throws -> XcodeCloudAPI.AnyCodableValue? {
    guard let raw, !raw.isEmpty else { return nil }
    let data = Data(raw.utf8)
    let decoder = JSONDecoder()
    return try decoder.decode(XcodeCloudAPI.AnyCodableValue.self, from: data)
}

// MARK: - ciProducts

struct XCCProductsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "products",
        abstract: "List, fetch, or detach Xcode Cloud products.",
        subcommands: [
            XCCProductsListCommand.self,
            XCCProductsGetCommand.self,
            XCCProductsDeleteCommand.self,
        ]
    )
}

struct XCCProductsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Xcode Cloud products.")
    @Option(name: .long, help: "Optional ASC app id filter.") var appId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.ciProducts.list(appID: appId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Xcode Cloud products (\(page.data.count))")
        for p in page.data {
            let name = p.attributes?.name ?? "(no name)"
            let type = p.attributes?.productType ?? "(unknown)"
            print("  \(p.id)  \(name)  [\(type)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCProductsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an Xcode Cloud product by id.")
    @Argument(help: "Product id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let product = try await surface({ try await api.ciProducts.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(product)
            return
        }
        guard let product else {
            logger.log("no product \(id)", level: .warning)
            return
        }
        logger.header("Product \(product.id)")
        print("  name:        \(product.attributes?.name ?? "(none)")")
        print("  productType: \(product.attributes?.productType ?? "(none)")")
        if let c = product.attributes?.createdDate {
            print("  createdDate: \(c)")
        }
    }
}

struct XCCProductsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Detach an Xcode Cloud product from ASC.")
    @Argument(help: "Product id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        try await surface({ try await api.ciProducts.delete(id: id) }, logger: logger)
        logger.log("detached product \(id)", level: .success)
    }
}

// MARK: - ciProductAdditionalRepositories

struct XCCProductAdditionalRepositoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "product-additional-repositories",
        abstract: "List or fetch additional SCM repositories attached to an Xcode Cloud product.",
        subcommands: [
            XCCProductAdditionalRepositoriesListCommand.self,
            XCCProductAdditionalRepositoriesGetCommand.self,
        ]
    )
}

struct XCCProductAdditionalRepositoriesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List additional repositories attached to a product.")
    @Option(name: .long) var productId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.productAdditionalRepositories.list(
                productID: productId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Additional repositories (\(page.data.count))")
        for r in page.data {
            print("  \(r.id)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCProductAdditionalRepositoriesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an additional repository link by id.")
    @Argument(help: "Additional repository link id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let repo = try await surface(
            { try await api.productAdditionalRepositories.get(id: id) },
            logger: logger
        )
        if json {
            try emitOptionalJSON(repo)
            return
        }
        guard let repo else {
            logger.log("no additional repository \(id)", level: .warning)
            return
        }
        print("  id: \(repo.id)")
    }
}

// MARK: - ciWorkflows

struct XCCWorkflowsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflows",
        abstract: "Manage Xcode Cloud workflows.",
        subcommands: [
            XCCWorkflowsListCommand.self,
            XCCWorkflowsGetCommand.self,
            XCCWorkflowsCreateCommand.self,
            XCCWorkflowsUpdateCommand.self,
            XCCWorkflowsDeleteCommand.self,
        ]
    )
}

struct XCCWorkflowsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List workflows for a product.")
    @Option(name: .long) var productId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.workflows.list(productID: productId, limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Workflows (\(page.data.count))")
        for w in page.data {
            let name = w.attributes?.name ?? "(no name)"
            let enabled = (w.attributes?.isEnabled ?? false) ? "enabled" : "disabled"
            print("  \(w.id)  \(name)  [\(enabled)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCWorkflowsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a workflow by id.")
    @Argument(help: "Workflow id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let wf = try await surface({ try await api.workflows.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(wf)
            return
        }
        guard let wf else {
            logger.log("no workflow \(id)", level: .warning)
            return
        }
        logger.header("Workflow \(wf.id)")
        print("  name:                \(wf.attributes?.name ?? "(none)")")
        print("  description:         \(wf.attributes?.description ?? "(none)")")
        print("  isEnabled:           \(wf.attributes?.isEnabled.map(String.init(describing:)) ?? "(unknown)")")
        print("  isLockedForEditing:  \(wf.attributes?.isLockedForEditing.map(String.init(describing:)) ?? "(unknown)")")
        print("  containerFilePath:   \(wf.attributes?.containerFilePath ?? "(none)")")
    }
}

struct XCCWorkflowsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a workflow on a product attached to a repository."
    )
    @Option(name: .long) var productId: String
    @Option(name: .long) var repositoryId: String
    @Option(name: .long) var xcodeVersionId: String
    @Option(name: .long) var macOsVersionId: String
    @Option(name: .long) var name: String
    @Option(name: .long) var description: String?
    @Option(name: .long) var isEnabled: Bool?
    @Option(name: .long) var isLockedForEditing: Bool?
    @Option(name: .long) var containerFilePath: String?
    @Option(name: .long, help: "Branch start condition as raw JSON.") var branchStartCondition: String?
    @Option(name: .long, help: "Tag start condition as raw JSON.") var tagStartCondition: String?
    @Option(name: .long, help: "Pull-request start condition as raw JSON.") var pullRequestStartCondition: String?
    @Option(name: .long, help: "Scheduled start condition as raw JSON.") var scheduledStartCondition: String?
    @Option(name: .long, help: "Manual branch start condition as raw JSON.") var manualBranchStartCondition: String?
    @Option(name: .long, help: "Manual PR start condition as raw JSON.") var manualPullRequestStartCondition: String?
    @Option(name: .long, help: "Manual tag start condition as raw JSON.") var manualTagStartCondition: String?
    @Option(name: .long, help: "Actions array as raw JSON.") var actions: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let fields = XcodeCloudAPI.Workflows.WorkflowCreateFields(
            name: name,
            description: description,
            isEnabled: isEnabled,
            isLockedForEditing: isLockedForEditing,
            containerFilePath: containerFilePath,
            branchStartCondition: try parseJSONValue(branchStartCondition),
            tagStartCondition: try parseJSONValue(tagStartCondition),
            pullRequestStartCondition: try parseJSONValue(pullRequestStartCondition),
            scheduledStartCondition: try parseJSONValue(scheduledStartCondition),
            manualBranchStartCondition: try parseJSONValue(manualBranchStartCondition),
            manualPullRequestStartCondition: try parseJSONValue(manualPullRequestStartCondition),
            manualTagStartCondition: try parseJSONValue(manualTagStartCondition),
            actions: try parseJSONValue(actions)
        )
        let wf = try await surface(
            { try await api.workflows.create(
                productID: productId,
                repositoryID: repositoryId,
                xcodeVersionID: xcodeVersionId,
                macOsVersionID: macOsVersionId,
                fields: fields
            ) },
            logger: logger
        )
        if json {
            try emitJSON(wf)
            return
        }
        logger.log("created workflow \(wf.id) (\(wf.attributes?.name ?? name))", level: .success)
    }
}

struct XCCWorkflowsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a workflow. Nil/omitted fields are left untouched."
    )
    @Argument(help: "Workflow id.") var id: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var description: String?
    @Option(name: .long) var isEnabled: Bool?
    @Option(name: .long) var isLockedForEditing: Bool?
    @Option(name: .long) var containerFilePath: String?
    @Option(name: .long) var branchStartCondition: String?
    @Option(name: .long) var tagStartCondition: String?
    @Option(name: .long) var pullRequestStartCondition: String?
    @Option(name: .long) var scheduledStartCondition: String?
    @Option(name: .long) var manualBranchStartCondition: String?
    @Option(name: .long) var manualPullRequestStartCondition: String?
    @Option(name: .long) var manualTagStartCondition: String?
    @Option(name: .long, help: "Actions array as raw JSON.") var actions: String?
    @Option(name: .long) var xcodeVersionId: String?
    @Option(name: .long) var macOsVersionId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let fields = XcodeCloudAPI.Workflows.WorkflowUpdateFields(
            name: name,
            description: description,
            isEnabled: isEnabled,
            isLockedForEditing: isLockedForEditing,
            containerFilePath: containerFilePath,
            branchStartCondition: try parseJSONValue(branchStartCondition),
            tagStartCondition: try parseJSONValue(tagStartCondition),
            pullRequestStartCondition: try parseJSONValue(pullRequestStartCondition),
            scheduledStartCondition: try parseJSONValue(scheduledStartCondition),
            manualBranchStartCondition: try parseJSONValue(manualBranchStartCondition),
            manualPullRequestStartCondition: try parseJSONValue(manualPullRequestStartCondition),
            manualTagStartCondition: try parseJSONValue(manualTagStartCondition),
            actions: try parseJSONValue(actions),
            xcodeVersionID: xcodeVersionId,
            macOsVersionID: macOsVersionId
        )
        let wf = try await surface(
            { try await api.workflows.update(id: id, fields: fields) },
            logger: logger
        )
        if json {
            try emitJSON(wf)
            return
        }
        logger.log("updated workflow \(wf.id)", level: .success)
    }
}

struct XCCWorkflowsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a workflow.")
    @Argument(help: "Workflow id.") var id: String

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        try await surface({ try await api.workflows.delete(id: id) }, logger: logger)
        logger.log("deleted workflow \(id)", level: .success)
    }
}

// MARK: - ciBuildRuns

struct XCCBuildRunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-runs",
        abstract: "Manage Xcode Cloud build runs.",
        subcommands: [
            XCCBuildRunsListCommand.self,
            XCCBuildRunsListForWorkflowCommand.self,
            XCCBuildRunsListForProductCommand.self,
            XCCBuildRunsGetCommand.self,
            XCCBuildRunsStartCommand.self,
            XCCBuildRunsCancelCommand.self,
            XCCBuildRunsRetryCommand.self,
        ]
    )
}

struct XCCBuildRunsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List build runs with optional filters.")
    @Option(name: .long) var productId: String?
    @Option(name: .long) var workflowId: String?
    @Option(name: .long) var sourceCommitSha: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.buildRuns.list(
                productID: productId,
                workflowID: workflowId,
                sourceCommitSha: sourceCommitSha,
                limit: limit,
                cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Build runs (\(page.data.count))")
        for r in page.data {
            let num = r.attributes?.number.map(String.init) ?? "?"
            let progress = r.attributes?.executionProgress ?? "?"
            let status = r.attributes?.completionStatus ?? "-"
            print("  \(r.id)  #\(num)  [\(progress)/\(status)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCBuildRunsListForWorkflowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-for-workflow", abstract: "List build runs scoped to a workflow.")
    @Option(name: .long) var workflowId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.buildRuns.listForWorkflow(
                workflowID: workflowId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Build runs for workflow (\(page.data.count))")
        for r in page.data {
            let num = r.attributes?.number.map(String.init) ?? "?"
            let progress = r.attributes?.executionProgress ?? "?"
            print("  \(r.id)  #\(num)  [\(progress)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCBuildRunsListForProductCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-for-product", abstract: "List build runs scoped to a product.")
    @Option(name: .long) var productId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.buildRuns.listForProduct(
                productID: productId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Build runs for product (\(page.data.count))")
        for r in page.data {
            let num = r.attributes?.number.map(String.init) ?? "?"
            let progress = r.attributes?.executionProgress ?? "?"
            print("  \(r.id)  #\(num)  [\(progress)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCBuildRunsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a build run by id.")
    @Argument(help: "Build run id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let run = try await surface({ try await api.buildRuns.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(run)
            return
        }
        guard let run else {
            logger.log("no build run \(id)", level: .warning)
            return
        }
        logger.header("Build run \(run.id)")
        print("  number:             \(run.attributes?.number.map(String.init) ?? "(unknown)")")
        print("  executionProgress:  \(run.attributes?.executionProgress ?? "(unknown)")")
        print("  completionStatus:   \(run.attributes?.completionStatus ?? "(unknown)")")
        print("  startReason:        \(run.attributes?.startReason ?? "(unknown)")")
        if let started = run.attributes?.startedDate {
            print("  startedDate:        \(started)")
        }
        if let finished = run.attributes?.finishedDate {
            print("  finishedDate:       \(finished)")
        }
        if let counts = run.attributes?.issueCounts {
            print("  errors:             \(counts.errors.map(String.init) ?? "0")")
            print("  warnings:           \(counts.warnings.map(String.init) ?? "0")")
            print("  testFailures:       \(counts.testFailures.map(String.init) ?? "0")")
        }
    }
}

struct XCCBuildRunsStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a new build run for a workflow."
    )
    @Option(name: .long) var workflowId: String
    @Option(name: .long, help: "scmGitReferences id (alias for source-branch-or-tag-id).") var gitReferenceId: String?
    @Option(name: .long, help: "scmGitReferences id (branch or tag).") var sourceBranchOrTagId: String?
    @Option(name: .long, help: "scmPullRequests id.") var pullRequestId: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let run = try await surface(
            { try await api.buildRuns.create(
                workflowID: workflowId,
                gitReferenceID: gitReferenceId,
                pullRequestID: pullRequestId,
                sourceBranchOrTagID: sourceBranchOrTagId
            ) },
            logger: logger
        )
        if json {
            try emitJSON(run)
            return
        }
        logger.log(
            "started build run \(run.id) (#\(run.attributes?.number.map(String.init) ?? "?"))",
            level: .success
        )
    }
}

struct XCCBuildRunsCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel an in-progress build run.")
    @Argument(help: "Build run id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let run = try await surface({ try await api.buildRuns.cancel(id: id) }, logger: logger)
        if json {
            try emitJSON(run)
            return
        }
        logger.log("requested cancel on build run \(id)", level: .success)
    }
}

struct XCCBuildRunsRetryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retry", abstract: "Retry a finished build run (creates a new run).")
    @Argument(help: "Build run id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let run = try await surface({ try await api.buildRuns.retry(id: id) }, logger: logger)
        if json {
            try emitJSON(run)
            return
        }
        logger.log(
            "retry started new build run \(run.id) (#\(run.attributes?.number.map(String.init) ?? "?"))",
            level: .success
        )
    }
}

// MARK: - ciBuildActions

struct XCCBuildActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-actions",
        abstract: "List or fetch build actions (Build, Test, Archive, Analyze).",
        subcommands: [
            XCCBuildActionsListCommand.self,
            XCCBuildActionsGetCommand.self,
        ]
    )
}

struct XCCBuildActionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List build actions for a build run.")
    @Option(name: .long) var buildRunId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.buildActions.list(
                buildRunID: buildRunId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Build actions (\(page.data.count))")
        for a in page.data {
            let name = a.attributes?.name ?? "(no name)"
            let type = a.attributes?.actionType ?? "?"
            let status = a.attributes?.completionStatus ?? a.attributes?.executionProgress ?? "?"
            print("  \(a.id)  \(name)  [\(type)/\(status)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCBuildActionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a build action by id.")
    @Argument(help: "Build action id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let action = try await surface({ try await api.buildActions.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(action)
            return
        }
        guard let action else {
            logger.log("no build action \(id)", level: .warning)
            return
        }
        logger.header("Build action \(action.id)")
        print("  name:              \(action.attributes?.name ?? "(none)")")
        print("  actionType:        \(action.attributes?.actionType ?? "(none)")")
        print("  executionProgress: \(action.attributes?.executionProgress ?? "(none)")")
        print("  completionStatus:  \(action.attributes?.completionStatus ?? "(none)")")
    }
}

// MARK: - ciArtifacts

struct XCCArtifactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "artifacts",
        abstract: "List, fetch, or download artifacts produced by build actions.",
        subcommands: [
            XCCArtifactsListCommand.self,
            XCCArtifactsGetCommand.self,
            XCCArtifactsDownloadCommand.self,
        ]
    )
}

struct XCCArtifactsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List artifacts for a build action.")
    @Option(name: .long) var buildActionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.artifacts.list(
                buildActionID: buildActionId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Artifacts (\(page.data.count))")
        for a in page.data {
            let name = a.attributes?.fileName ?? "(no name)"
            let type = a.attributes?.fileType ?? "?"
            let size = a.attributes?.fileSize.map { "\($0)B" } ?? "?"
            print("  \(a.id)  \(name)  [\(type), \(size)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCArtifactsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an artifact by id (returns its short-lived downloadUrl).")
    @Argument(help: "Artifact id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let artifact = try await surface({ try await api.artifacts.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(artifact)
            return
        }
        guard let artifact else {
            logger.log("no artifact \(id)", level: .warning)
            return
        }
        logger.header("Artifact \(artifact.id)")
        print("  fileName:    \(artifact.attributes?.fileName ?? "(none)")")
        print("  fileType:    \(artifact.attributes?.fileType ?? "(none)")")
        print("  fileSize:    \(artifact.attributes?.fileSize.map(String.init) ?? "(unknown)")")
        print("  downloadUrl: \(artifact.attributes?.downloadUrl ?? "(none)")")
    }
}

struct XCCArtifactsDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Resolve an artifact's signed downloadUrl and stream it to disk."
    )
    @Argument(help: "Artifact id (or build action id when --action-id is set).") var id: String
    @Option(name: .long, help: "Output file path. Defaults to the artifact's fileName in the current directory.")
    var output: String?
    @Flag(name: .long, help: "Treat the positional id as a build action id; downloads every artifact under that action.")
    var actionId: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)

        if actionId {
            // Download every artifact under the given build action.
            let page = try await surface(
                { try await api.artifacts.list(buildActionID: id, limit: 200, cursor: nil) },
                logger: logger
            )
            for a in page.data {
                try await downloadArtifact(a, logger: logger, suggestedPath: nil)
            }
            return
        }

        let artifact = try await surface({ try await api.artifacts.get(id: id) }, logger: logger)
        guard let artifact else {
            logger.log("no artifact \(id)", level: .error)
            throw ExitCode(1)
        }
        try await downloadArtifact(artifact, logger: logger, suggestedPath: output)
    }

    /// Streams the signed URL into a local file. The signed URL is on
    /// Apple's CDN, not on `/v1`, so we use URLSession directly.
    private func downloadArtifact(
        _ artifact: XcodeCloudAPI.Artifacts.Artifact,
        logger: Logger,
        suggestedPath: String?
    ) async throws {
        guard let urlStr = artifact.attributes?.downloadUrl,
              let url = URL(string: urlStr)
        else {
            logger.log("artifact \(artifact.id) has no downloadUrl (expired?)", level: .error)
            throw ExitCode(1)
        }
        let fileName = suggestedPath
            ?? artifact.attributes?.fileName
            ?? "artifact-\(artifact.id).bin"
        let outURL = URL(fileURLWithPath: fileName)
        let (tmp, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.removeItem(at: outURL)
        }
        try FileManager.default.moveItem(at: tmp, to: outURL)
        logger.log("downloaded \(fileName) (\(artifact.attributes?.fileSize.map(String.init) ?? "?") bytes)", level: .success)
    }
}

// MARK: - ciIssues

struct XCCIssuesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issues",
        abstract: "List or fetch issues surfaced by a build action.",
        subcommands: [
            XCCIssuesListCommand.self,
            XCCIssuesGetCommand.self,
        ]
    )
}

struct XCCIssuesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List issues for a build action.")
    @Option(name: .long) var buildActionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.issues.list(
                buildActionID: buildActionId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Issues (\(page.data.count))")
        for i in page.data {
            let type = i.attributes?.issueType ?? "?"
            let msg = i.attributes?.message ?? "(no message)"
            print("  \(i.id)  [\(type)]  \(msg)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCIssuesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an issue by id.")
    @Argument(help: "Issue id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let issue = try await surface({ try await api.issues.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(issue)
            return
        }
        guard let issue else {
            logger.log("no issue \(id)", level: .warning)
            return
        }
        logger.header("Issue \(issue.id)")
        print("  issueType: \(issue.attributes?.issueType ?? "(none)")")
        print("  category:  \(issue.attributes?.category ?? "(none)")")
        print("  message:   \(issue.attributes?.message ?? "(none)")")
        if let src = issue.attributes?.fileSource {
            print("  file:      \(src.fileName ?? "?"):\(src.lineNumber.map(String.init) ?? "?")")
        }
    }
}

// MARK: - ciTestResults

struct XCCTestResultsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-results",
        abstract: "List or fetch Xcode Cloud test results.",
        subcommands: [
            XCCTestResultsListForBuildActionCommand.self,
            XCCTestResultsListForProductCommand.self,
            XCCTestResultsGetCommand.self,
        ]
    )
}

struct XCCTestResultsListForBuildActionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-for-build-action",
        abstract: "List per-test results emitted by a single build action."
    )
    @Option(name: .long) var buildActionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.testResults.listForBuildAction(
                buildActionID: buildActionId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Test results (\(page.data.count))")
        for t in page.data {
            let cls = t.attributes?.className ?? "?"
            let nm = t.attributes?.name ?? "(no name)"
            let status = t.attributes?.status ?? "?"
            print("  \(t.id)  \(cls).\(nm)  [\(status)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCTestResultsListForProductCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-for-product",
        abstract: "List per-test results aggregated across all builds for a product."
    )
    @Option(name: .long) var productId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.testResults.listForProduct(
                productID: productId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Test results for product (\(page.data.count))")
        for t in page.data {
            let cls = t.attributes?.className ?? "?"
            let nm = t.attributes?.name ?? "(no name)"
            let status = t.attributes?.status ?? "?"
            print("  \(t.id)  \(cls).\(nm)  [\(status)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCTestResultsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a test result by id.")
    @Argument(help: "Test result id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let result = try await surface({ try await api.testResults.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(result)
            return
        }
        guard let result else {
            logger.log("no test result \(id)", level: .warning)
            return
        }
        logger.header("Test result \(result.id)")
        print("  className: \(result.attributes?.className ?? "(none)")")
        print("  name:      \(result.attributes?.name ?? "(none)")")
        print("  status:    \(result.attributes?.status ?? "(none)")")
        if let dests = result.attributes?.destinationTestResults, !dests.isEmpty {
            print("  destinations:")
            for d in dests {
                print("    - \(d.displayName ?? "?")  [\(d.status ?? "?")]")
            }
        }
    }
}

// MARK: - ciMacOsVersions

struct XCCMacOsVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-os-versions",
        abstract: "List or fetch macOS versions Xcode Cloud can run builds against.",
        subcommands: [
            XCCMacOsVersionsListCommand.self,
            XCCMacOsVersionsGetCommand.self,
        ]
    )
}

struct XCCMacOsVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List macOS versions.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.macOsVersions.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("macOS versions (\(page.data.count))")
        for v in page.data {
            let nm = v.attributes?.name ?? "?"
            let ver = v.attributes?.version ?? "?"
            print("  \(v.id)  \(nm)  (\(ver))")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCMacOsVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a macOS version by id.")
    @Argument(help: "macOS version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let v = try await surface({ try await api.macOsVersions.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(v)
            return
        }
        guard let v else {
            logger.log("no macOS version \(id)", level: .warning)
            return
        }
        print("  id:      \(v.id)")
        print("  name:    \(v.attributes?.name ?? "(none)")")
        print("  version: \(v.attributes?.version ?? "(none)")")
    }
}

// MARK: - ciXcodeVersions

struct XCCXcodeVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-versions",
        abstract: "List or fetch Xcode versions Xcode Cloud supports.",
        subcommands: [
            XCCXcodeVersionsListCommand.self,
            XCCXcodeVersionsGetCommand.self,
            XCCXcodeVersionsListMacOsVersionsCommand.self,
        ]
    )
}

struct XCCXcodeVersionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Xcode versions.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.xcodeVersions.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Xcode versions (\(page.data.count))")
        for v in page.data {
            let nm = v.attributes?.name ?? "?"
            let ver = v.attributes?.version ?? "?"
            print("  \(v.id)  \(nm)  (\(ver))")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCXcodeVersionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an Xcode version by id.")
    @Argument(help: "Xcode version id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let v = try await surface({ try await api.xcodeVersions.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(v)
            return
        }
        guard let v else {
            logger.log("no Xcode version \(id)", level: .warning)
            return
        }
        print("  id:      \(v.id)")
        print("  name:    \(v.attributes?.name ?? "(none)")")
        print("  version: \(v.attributes?.version ?? "(none)")")
    }
}

struct XCCXcodeVersionsListMacOsVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-mac-os-versions",
        abstract: "List macOS versions compatible with a specific Xcode version."
    )
    @Option(name: .long) var xcodeVersionId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.xcodeVersions.listCompatibleMacOsVersions(
                xcodeVersionID: xcodeVersionId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Compatible macOS versions (\(page.data.count))")
        for v in page.data {
            let nm = v.attributes?.name ?? "?"
            let ver = v.attributes?.version ?? "?"
            print("  \(v.id)  \(nm)  (\(ver))")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

// MARK: - scmRepositories

struct XCCScmRepositoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scm-repositories",
        abstract: "List or fetch Git repositories linked to Xcode Cloud.",
        subcommands: [
            XCCScmRepositoriesListCommand.self,
            XCCScmRepositoriesGetCommand.self,
        ]
    )
}

struct XCCScmRepositoriesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Git repositories linked to Xcode Cloud.")
    @Option(name: .long) var ciProductId: String?
    @Option(name: .long) var scmProviderId: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.scmRepositories.list(
                ciProductID: ciProductId,
                scmProviderID: scmProviderId,
                limit: limit,
                cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("SCM repositories (\(page.data.count))")
        for r in page.data {
            let owner = r.attributes?.ownerName ?? "?"
            let name = r.attributes?.repositoryName ?? "?"
            print("  \(r.id)  \(owner)/\(name)")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCScmRepositoriesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an SCM repository by id.")
    @Argument(help: "Repository id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let repo = try await surface({ try await api.scmRepositories.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(repo)
            return
        }
        guard let repo else {
            logger.log("no SCM repository \(id)", level: .warning)
            return
        }
        logger.header("SCM repository \(repo.id)")
        print("  owner:        \(repo.attributes?.ownerName ?? "(none)")")
        print("  name:         \(repo.attributes?.repositoryName ?? "(none)")")
        print("  httpCloneUrl: \(repo.attributes?.httpCloneUrl ?? "(none)")")
        print("  sshCloneUrl:  \(repo.attributes?.sshCloneUrl ?? "(none)")")
    }
}

// MARK: - scmGitReferences

struct XCCScmGitReferencesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scm-git-references",
        abstract: "List or fetch branches and tags for an SCM repository.",
        subcommands: [
            XCCScmGitReferencesListCommand.self,
            XCCScmGitReferencesGetCommand.self,
        ]
    )
}

struct XCCScmGitReferencesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Git references for a repository.")
    @Option(name: .long) var repositoryId: String
    @Option(name: .long, help: "BRANCH or TAG.") var kind: String?
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.scmGitReferences.list(
                repositoryID: repositoryId, kind: kind, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Git references (\(page.data.count))")
        for r in page.data {
            let nm = r.attributes?.name ?? "?"
            let k = r.attributes?.kind ?? "?"
            print("  \(r.id)  \(nm)  [\(k)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCScmGitReferencesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a Git reference by id.")
    @Argument(help: "Git reference id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let ref = try await surface({ try await api.scmGitReferences.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(ref)
            return
        }
        guard let ref else {
            logger.log("no Git reference \(id)", level: .warning)
            return
        }
        print("  id:            \(ref.id)")
        print("  name:          \(ref.attributes?.name ?? "(none)")")
        print("  kind:          \(ref.attributes?.kind ?? "(none)")")
        print("  canonicalName: \(ref.attributes?.canonicalName ?? "(none)")")
    }
}

// MARK: - scmPullRequests

struct XCCScmPullRequestsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scm-pull-requests",
        abstract: "List or fetch pull requests known to Xcode Cloud's SCM integration.",
        subcommands: [
            XCCScmPullRequestsListCommand.self,
            XCCScmPullRequestsGetCommand.self,
        ]
    )
}

struct XCCScmPullRequestsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List pull requests for an SCM repository.")
    @Option(name: .long) var repositoryId: String
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.scmPullRequests.list(
                repositoryID: repositoryId, limit: limit, cursor: cursor
            ) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("Pull requests (\(page.data.count))")
        for p in page.data {
            let num = p.attributes?.number.map(String.init) ?? "?"
            let title = p.attributes?.title ?? "(no title)"
            let state = (p.attributes?.isClosed ?? false) ? "closed" : "open"
            print("  \(p.id)  #\(num)  \(title)  [\(state)]")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCScmPullRequestsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a pull request by id.")
    @Argument(help: "Pull request id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let pr = try await surface({ try await api.scmPullRequests.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(pr)
            return
        }
        guard let pr else {
            logger.log("no pull request \(id)", level: .warning)
            return
        }
        logger.header("Pull request \(pr.id)")
        print("  number:                       \(pr.attributes?.number.map(String.init) ?? "(none)")")
        print("  title:                        \(pr.attributes?.title ?? "(none)")")
        print("  webUrl:                       \(pr.attributes?.webUrl ?? "(none)")")
        print("  sourceBranchName:             \(pr.attributes?.sourceBranchName ?? "(none)")")
        print("  destinationBranchName:        \(pr.attributes?.destinationBranchName ?? "(none)")")
        print("  isClosed:                     \(pr.attributes?.isClosed.map(String.init(describing:)) ?? "(unknown)")")
    }
}

// MARK: - scmProviders

struct XCCScmProvidersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scm-providers",
        abstract: "List or fetch SCM providers linked to Xcode Cloud.",
        subcommands: [
            XCCScmProvidersListCommand.self,
            XCCScmProvidersGetCommand.self,
        ]
    )
}

struct XCCScmProvidersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List SCM providers.")
    @Option(name: .long) var limit: Int = 200
    @Option(name: .long) var cursor: String?
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let page = try await surface(
            { try await api.scmProviders.list(limit: limit, cursor: cursor) },
            logger: logger
        )
        if json {
            try emitJSON(CLIPage(data: page.data, nextCursor: page.nextCursor))
            return
        }
        logger.header("SCM providers (\(page.data.count))")
        for p in page.data {
            let kind = p.attributes?.scmProviderType ?? "?"
            let url = p.attributes?.url ?? "?"
            print("  \(p.id)  \(kind)  (\(url))")
        }
        if let c = page.nextCursor { print("\n  next-cursor: \(c)") }
    }
}

struct XCCScmProvidersGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get an SCM provider by id.")
    @Argument(help: "SCM provider id.") var id: String
    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let logger = Logger()
        let api = try xccClient(logger: logger)
        let provider = try await surface({ try await api.scmProviders.get(id: id) }, logger: logger)
        if json {
            try emitOptionalJSON(provider)
            return
        }
        guard let provider else {
            logger.log("no SCM provider \(id)", level: .warning)
            return
        }
        print("  id:              \(provider.id)")
        print("  scmProviderType: \(provider.attributes?.scmProviderType ?? "(none)")")
        print("  url:             \(provider.attributes?.url ?? "(none)")")
    }
}
