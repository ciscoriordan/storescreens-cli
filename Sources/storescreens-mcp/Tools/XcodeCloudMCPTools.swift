import MCP
import Foundation
import StorescreensCore

/// MCP tool surface for App Store Connect Xcode Cloud (CI/CD) endpoints.
///
/// Every tool is a thin wrapper around `XcodeCloudAPI`. Inputs arrive as
/// JSON arguments, outputs are pretty-printed JSON text content so AI
/// agents get a stable, machine-readable response shape without having
/// to construct raw HTTP requests against Apple's API.
///
/// Tool naming convention: `xcc_<resource>_<op>` (snake_case). `xcc` is
/// the short prefix for "Xcode Cloud".
enum XcodeCloudMCPTools {

    // MARK: - Tool definitions

    static let tools: [Tool] = [

        // ciProducts -----------------------------------------------------

        Tool(
            name: "xcc_products_list",
            description: """
            List Xcode Cloud products visible to the API key. Each product is the \
            Xcode Cloud counterpart to an ASC app or framework. Pass `app_id` to \
            scope to a single ASC app.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object(["type": .string("string"), "description": .string("Optional ASC app id filter")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "xcc_products_get",
            description: "Get a single Xcode Cloud product by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "xcc_products_delete",
            description: "Detach an Xcode Cloud product from ASC. The Xcode project itself is untouched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciProductAdditionalRepositories --------------------------------

        Tool(
            name: "xcc_product_additional_repositories_list",
            description: "List additional SCM repositories attached to an Xcode Cloud product.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("product_id")]),
            ])
        ),
        Tool(
            name: "xcc_product_additional_repositories_get",
            description: "Get a single additional repository link by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciWorkflows ---------------------------------------------------

        Tool(
            name: "xcc_workflows_list",
            description: "List Xcode Cloud workflows for a product.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("product_id")]),
            ])
        ),
        Tool(
            name: "xcc_workflows_get",
            description: "Get a single workflow by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "xcc_workflows_create",
            description: """
            Create a new Xcode Cloud workflow. Required: product_id, repository_id, \
            xcode_version_id, mac_os_version_id, name. Start conditions and actions \
            can be passed as raw JSON values matching Apple's documented shapes.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object(["type": .string("string")]),
                    "repository_id": .object(["type": .string("string")]),
                    "xcode_version_id": .object(["type": .string("string")]),
                    "mac_os_version_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                    "is_enabled": .object(["type": .string("boolean")]),
                    "is_locked_for_editing": .object(["type": .string("boolean")]),
                    "container_file_path": .object(["type": .string("string")]),
                    "branch_start_condition": .object(["description": .string("JSON value matching Apple's branchStartCondition shape")]),
                    "tag_start_condition": .object(["description": .string("JSON value matching Apple's tagStartCondition shape")]),
                    "pull_request_start_condition": .object(["description": .string("JSON value matching Apple's pullRequestStartCondition shape")]),
                    "scheduled_start_condition": .object(["description": .string("JSON value matching Apple's scheduledStartCondition shape")]),
                    "manual_branch_start_condition": .object(["description": .string("JSON value")]),
                    "manual_pull_request_start_condition": .object(["description": .string("JSON value")]),
                    "manual_tag_start_condition": .object(["description": .string("JSON value")]),
                    "actions": .object(["description": .string("JSON array of workflow actions (Build, Test, Archive, Analyze)")]),
                ]),
                "required": .array([
                    .string("product_id"),
                    .string("repository_id"),
                    .string("xcode_version_id"),
                    .string("mac_os_version_id"),
                    .string("name"),
                ]),
            ])
        ),
        Tool(
            name: "xcc_workflows_update",
            description: "PATCH a workflow. Nil/omitted fields are not touched.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                    "is_enabled": .object(["type": .string("boolean")]),
                    "is_locked_for_editing": .object(["type": .string("boolean")]),
                    "container_file_path": .object(["type": .string("string")]),
                    "branch_start_condition": .object(["description": .string("JSON value")]),
                    "tag_start_condition": .object(["description": .string("JSON value")]),
                    "pull_request_start_condition": .object(["description": .string("JSON value")]),
                    "scheduled_start_condition": .object(["description": .string("JSON value")]),
                    "manual_branch_start_condition": .object(["description": .string("JSON value")]),
                    "manual_pull_request_start_condition": .object(["description": .string("JSON value")]),
                    "manual_tag_start_condition": .object(["description": .string("JSON value")]),
                    "actions": .object(["description": .string("JSON array")]),
                    "xcode_version_id": .object(["type": .string("string")]),
                    "mac_os_version_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "xcc_workflows_delete",
            description: "Delete an Xcode Cloud workflow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciBuildRuns ---------------------------------------------------

        Tool(
            name: "xcc_build_runs_list",
            description: """
            List Xcode Cloud build runs. Filter by product_id, workflow_id, and/or \
            source_commit_sha. Sort defaults to newest-first.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object(["type": .string("string")]),
                    "workflow_id": .object(["type": .string("string")]),
                    "source_commit_sha": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "xcc_build_runs_list_for_workflow",
            description: "List build runs scoped to a single workflow (Apple's nested URL).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workflow_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("workflow_id")]),
            ])
        ),
        Tool(
            name: "xcc_build_runs_list_for_product",
            description: "List build runs scoped to a single product (Apple's nested URL).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("product_id")]),
            ])
        ),
        Tool(
            name: "xcc_build_runs_get",
            description: "Get a single build run by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "xcc_build_runs_create",
            description: """
            Start a new build run for a workflow. Pass exactly one of git_reference_id \
            (branch or tag) or pull_request_id so Apple knows where to source the commit. \
            The build run is created asynchronously: poll xcc_build_runs_get until \
            executionProgress reaches a terminal state.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workflow_id": .object(["type": .string("string")]),
                    "git_reference_id": .object(["type": .string("string"), "description": .string("scmGitReferences id (alias for source_branch_or_tag_id)")]),
                    "source_branch_or_tag_id": .object(["type": .string("string"), "description": .string("scmGitReferences id")]),
                    "pull_request_id": .object(["type": .string("string"), "description": .string("scmPullRequests id")]),
                ]),
                "required": .array([.string("workflow_id")]),
            ])
        ),
        Tool(
            name: "xcc_build_runs_cancel",
            description: """
            Cancel an in-progress build run by PATCHing canceled=true. Apple finalizes \
            the cancel asynchronously.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "xcc_build_runs_retry",
            description: """
            Retry a finished build run. Creates a brand-new ciBuildRun resource that \
            reuses the source commit and workflow.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciBuildActions ------------------------------------------------

        Tool(
            name: "xcc_build_actions_list",
            description: "List the individual actions (Build, Test, Archive, Analyze) inside a build run.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_run_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_run_id")]),
            ])
        ),
        Tool(
            name: "xcc_build_actions_get",
            description: "Get a single build action by id. Returns null on 404.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciArtifacts ---------------------------------------------------

        Tool(
            name: "xcc_artifacts_list",
            description: """
            List downloadable artifacts (archives, result bundles, logs) produced by a \
            build action. Each artifact carries a short-lived signed downloadUrl.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_action_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_action_id")]),
            ])
        ),
        Tool(
            name: "xcc_artifacts_get",
            description: "Get a single artifact by id. The returned downloadUrl is signed and short-lived.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciIssues ------------------------------------------------------

        Tool(
            name: "xcc_issues_list",
            description: "List issues (errors, warnings, test failures) surfaced by a build action.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_action_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_action_id")]),
            ])
        ),
        Tool(
            name: "xcc_issues_get",
            description: "Get a single issue by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciTestResults -------------------------------------------------

        Tool(
            name: "xcc_test_results_list_for_build_action",
            description: "List per-test results emitted by a single build action.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_action_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("build_action_id")]),
            ])
        ),
        Tool(
            name: "xcc_test_results_list_for_product",
            description: "List per-test results aggregated across all builds for a product.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("product_id")]),
            ])
        ),
        Tool(
            name: "xcc_test_results_get",
            description: "Get a single test result by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciMacOsVersions -----------------------------------------------

        Tool(
            name: "xcc_mac_os_versions_list",
            description: "List macOS versions Xcode Cloud can run builds against.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "xcc_mac_os_versions_get",
            description: "Get a single macOS version by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // ciXcodeVersions -----------------------------------------------

        Tool(
            name: "xcc_xcode_versions_list",
            description: "List Xcode versions Xcode Cloud supports.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "xcc_xcode_versions_get",
            description: "Get a single Xcode version by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "xcc_xcode_versions_list_compatible_mac_os_versions",
            description: "List macOS versions compatible with a specific Xcode version.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "xcode_version_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("xcode_version_id")]),
            ])
        ),

        // scmRepositories -----------------------------------------------

        Tool(
            name: "xcc_scm_repositories_list",
            description: """
            List Git repositories linked to Xcode Cloud. Filter by ci_product_id to \
            scope to repos for a specific product, or by scm_provider_id to scope to a \
            provider (GitHub, Bitbucket, GitLab).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "ci_product_id": .object(["type": .string("string")]),
                    "scm_provider_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "xcc_scm_repositories_get",
            description: "Get a single SCM repository by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // scmGitReferences ----------------------------------------------

        Tool(
            name: "xcc_scm_git_references_list",
            description: "List branches and tags for a repository. Pass kind=BRANCH or kind=TAG to filter.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repository_id": .object(["type": .string("string")]),
                    "kind": .object(["type": .string("string"), "description": .string("BRANCH or TAG")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("repository_id")]),
            ])
        ),
        Tool(
            name: "xcc_scm_git_references_get",
            description: "Get a single Git reference by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // scmPullRequests -----------------------------------------------

        Tool(
            name: "xcc_scm_pull_requests_list",
            description: "List pull requests for a repository (used as the source for PR-triggered workflows).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repository_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("repository_id")]),
            ])
        ),
        Tool(
            name: "xcc_scm_pull_requests_get",
            description: "Get a single pull request by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),

        // scmProviders --------------------------------------------------

        Tool(
            name: "xcc_scm_providers_list",
            description: "List SCM providers linked to Xcode Cloud (GitHub, Bitbucket, GitLab).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                    "cursor": .object(["type": .string("string")]),
                ]),
            ])
        ),
        Tool(
            name: "xcc_scm_providers_get",
            description: "Get a single SCM provider by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Tool names handled by this module. Used by the MCP main dispatcher
    /// to route a CallTool request when the name starts with `xcc_`.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Master entry point. Resolves credentials, constructs the API
    /// wrapper, and dispatches to the matching handler by tool name. All
    /// handlers return JSON text content; errors surface as
    /// `isError: true` results.
    static func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let creds: ASCCredentials
        do {
            creds = try ASCCredentialResolver.resolve()
        } catch {
            return errorResult(
                "App Store Connect credentials are not configured. " +
                "Run `storescreens auth login` or set ASC_KEY_ID / ASC_ISSUER_ID / " +
                "ASC_KEY_PATH. (\(error))"
            )
        }
        let client = ASCClient(credentials: creds)
        let api = XcodeCloudAPI(client: client)

        do {
            switch params.name {

            // ciProducts
            case "xcc_products_list":
                return try await handleProductsList(params, api: api)
            case "xcc_products_get":
                return try await handleProductsGet(params, api: api)
            case "xcc_products_delete":
                return try await handleProductsDelete(params, api: api)

            // ciProductAdditionalRepositories
            case "xcc_product_additional_repositories_list":
                return try await handleProductAdditionalRepositoriesList(params, api: api)
            case "xcc_product_additional_repositories_get":
                return try await handleProductAdditionalRepositoriesGet(params, api: api)

            // ciWorkflows
            case "xcc_workflows_list":
                return try await handleWorkflowsList(params, api: api)
            case "xcc_workflows_get":
                return try await handleWorkflowsGet(params, api: api)
            case "xcc_workflows_create":
                return try await handleWorkflowsCreate(params, api: api)
            case "xcc_workflows_update":
                return try await handleWorkflowsUpdate(params, api: api)
            case "xcc_workflows_delete":
                return try await handleWorkflowsDelete(params, api: api)

            // ciBuildRuns
            case "xcc_build_runs_list":
                return try await handleBuildRunsList(params, api: api)
            case "xcc_build_runs_list_for_workflow":
                return try await handleBuildRunsListForWorkflow(params, api: api)
            case "xcc_build_runs_list_for_product":
                return try await handleBuildRunsListForProduct(params, api: api)
            case "xcc_build_runs_get":
                return try await handleBuildRunsGet(params, api: api)
            case "xcc_build_runs_create":
                return try await handleBuildRunsCreate(params, api: api)
            case "xcc_build_runs_cancel":
                return try await handleBuildRunsCancel(params, api: api)
            case "xcc_build_runs_retry":
                return try await handleBuildRunsRetry(params, api: api)

            // ciBuildActions
            case "xcc_build_actions_list":
                return try await handleBuildActionsList(params, api: api)
            case "xcc_build_actions_get":
                return try await handleBuildActionsGet(params, api: api)

            // ciArtifacts
            case "xcc_artifacts_list":
                return try await handleArtifactsList(params, api: api)
            case "xcc_artifacts_get":
                return try await handleArtifactsGet(params, api: api)

            // ciIssues
            case "xcc_issues_list":
                return try await handleIssuesList(params, api: api)
            case "xcc_issues_get":
                return try await handleIssuesGet(params, api: api)

            // ciTestResults
            case "xcc_test_results_list_for_build_action":
                return try await handleTestResultsListForBuildAction(params, api: api)
            case "xcc_test_results_list_for_product":
                return try await handleTestResultsListForProduct(params, api: api)
            case "xcc_test_results_get":
                return try await handleTestResultsGet(params, api: api)

            // ciMacOsVersions
            case "xcc_mac_os_versions_list":
                return try await handleMacOsVersionsList(params, api: api)
            case "xcc_mac_os_versions_get":
                return try await handleMacOsVersionsGet(params, api: api)

            // ciXcodeVersions
            case "xcc_xcode_versions_list":
                return try await handleXcodeVersionsList(params, api: api)
            case "xcc_xcode_versions_get":
                return try await handleXcodeVersionsGet(params, api: api)
            case "xcc_xcode_versions_list_compatible_mac_os_versions":
                return try await handleXcodeVersionsListCompatibleMacOsVersions(params, api: api)

            // scmRepositories
            case "xcc_scm_repositories_list":
                return try await handleScmRepositoriesList(params, api: api)
            case "xcc_scm_repositories_get":
                return try await handleScmRepositoriesGet(params, api: api)

            // scmGitReferences
            case "xcc_scm_git_references_list":
                return try await handleScmGitReferencesList(params, api: api)
            case "xcc_scm_git_references_get":
                return try await handleScmGitReferencesGet(params, api: api)

            // scmPullRequests
            case "xcc_scm_pull_requests_list":
                return try await handleScmPullRequestsList(params, api: api)
            case "xcc_scm_pull_requests_get":
                return try await handleScmPullRequestsGet(params, api: api)

            // scmProviders
            case "xcc_scm_providers_list":
                return try await handleScmProvidersList(params, api: api)
            case "xcc_scm_providers_get":
                return try await handleScmProvidersGet(params, api: api)

            default:
                return errorResult("Unknown Xcode Cloud tool: \(params.name)")
            }
        } catch let e as ASCClient.APIError {
            return errorResult(
                "App Store Connect API error (HTTP \(e.statusCode))\n" +
                e.details.map { "  [\($0.code)] \($0.title): \($0.detail)" }
                    .joined(separator: "\n")
            )
        } catch {
            return errorResult("Error: \(error)")
        }
    }

    // MARK: - Argument helpers

    private static func arg(_ params: CallTool.Parameters, _ key: String) -> Value? {
        params.arguments?[key]
    }

    private static func requireString(_ params: CallTool.Parameters, _ key: String) throws -> String {
        guard let s = arg(params, key)?.stringValue else {
            throw MCPArgError("Missing required string argument: \(key)")
        }
        return s
    }

    private static func optionalString(_ params: CallTool.Parameters, _ key: String) -> String? {
        arg(params, key)?.stringValue
    }

    private static func optionalInt(_ params: CallTool.Parameters, _ key: String) -> Int? {
        if let v = arg(params, key)?.intValue { return v }
        if let s = arg(params, key)?.stringValue, let i = Int(s) { return i }
        return nil
    }

    private static func optionalBool(_ params: CallTool.Parameters, _ key: String) -> Bool? {
        arg(params, key)?.boolValue
    }

    /// Best-effort conversion of an MCP `Value` argument into the
    /// loose `XcodeCloudAPI.AnyCodableValue` shape so callers can pass
    /// raw JSON for workflow conditions / actions without a fixed
    /// schema.
    private static func optionalCodableValue(
        _ params: CallTool.Parameters, _ key: String
    ) -> XcodeCloudAPI.AnyCodableValue? {
        guard let value = arg(params, key) else { return nil }
        return convertValue(value)
    }

    private static func convertValue(_ value: Value) -> XcodeCloudAPI.AnyCodableValue {
        if let b = value.boolValue { return .bool(b) }
        if let i = value.intValue { return .int(i) }
        if let d = value.doubleValue { return .double(d) }
        if let s = value.stringValue { return .string(s) }
        if let a = value.arrayValue { return .array(a.map(convertValue)) }
        if let o = value.objectValue {
            return .object(o.mapValues(convertValue))
        }
        return .null
    }

    private struct MCPArgError: Error, CustomStringConvertible {
        let description: String
        init(_ m: String) { self.description = m }
    }

    // MARK: - JSON output

    private static func jsonText<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)])
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func ackResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)])
    }

    // MARK: - Page wrapper for JSON output

    private struct PageOut<Item: Encodable>: Encodable {
        let data: [Item]
        let nextCursor: String?
    }

    // MARK: - Handlers: ciProducts

    private static func handleProductsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let appID = optionalString(params, "app_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.ciProducts.list(
            appID: appID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleProductsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let product = try await api.ciProducts.get(id: id)
        return try jsonText(product)
    }

    private static func handleProductsDelete(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.ciProducts.delete(id: id)
        return ackResult("Deleted Xcode Cloud product \(id)")
    }

    // MARK: - Handlers: ciProductAdditionalRepositories

    private static func handleProductAdditionalRepositoriesList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let productID = try requireString(params, "product_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.productAdditionalRepositories.list(
            productID: productID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleProductAdditionalRepositoriesGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let repo = try await api.productAdditionalRepositories.get(id: id)
        return try jsonText(repo)
    }

    // MARK: - Handlers: ciWorkflows

    private static func handleWorkflowsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let productID = try requireString(params, "product_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.workflows.list(
            productID: productID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleWorkflowsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let wf = try await api.workflows.get(id: id)
        return try jsonText(wf)
    }

    private static func handleWorkflowsCreate(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let productID = try requireString(params, "product_id")
        let repositoryID = try requireString(params, "repository_id")
        let xcodeVersionID = try requireString(params, "xcode_version_id")
        let macOsVersionID = try requireString(params, "mac_os_version_id")
        let name = try requireString(params, "name")
        let fields = XcodeCloudAPI.Workflows.WorkflowCreateFields(
            name: name,
            description: optionalString(params, "description"),
            isEnabled: optionalBool(params, "is_enabled"),
            isLockedForEditing: optionalBool(params, "is_locked_for_editing"),
            containerFilePath: optionalString(params, "container_file_path"),
            branchStartCondition: optionalCodableValue(params, "branch_start_condition"),
            tagStartCondition: optionalCodableValue(params, "tag_start_condition"),
            pullRequestStartCondition: optionalCodableValue(params, "pull_request_start_condition"),
            scheduledStartCondition: optionalCodableValue(params, "scheduled_start_condition"),
            manualBranchStartCondition: optionalCodableValue(params, "manual_branch_start_condition"),
            manualPullRequestStartCondition: optionalCodableValue(params, "manual_pull_request_start_condition"),
            manualTagStartCondition: optionalCodableValue(params, "manual_tag_start_condition"),
            actions: optionalCodableValue(params, "actions")
        )
        let wf = try await api.workflows.create(
            productID: productID,
            repositoryID: repositoryID,
            xcodeVersionID: xcodeVersionID,
            macOsVersionID: macOsVersionID,
            fields: fields
        )
        return try jsonText(wf)
    }

    private static func handleWorkflowsUpdate(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let fields = XcodeCloudAPI.Workflows.WorkflowUpdateFields(
            name: optionalString(params, "name"),
            description: optionalString(params, "description"),
            isEnabled: optionalBool(params, "is_enabled"),
            isLockedForEditing: optionalBool(params, "is_locked_for_editing"),
            containerFilePath: optionalString(params, "container_file_path"),
            branchStartCondition: optionalCodableValue(params, "branch_start_condition"),
            tagStartCondition: optionalCodableValue(params, "tag_start_condition"),
            pullRequestStartCondition: optionalCodableValue(params, "pull_request_start_condition"),
            scheduledStartCondition: optionalCodableValue(params, "scheduled_start_condition"),
            manualBranchStartCondition: optionalCodableValue(params, "manual_branch_start_condition"),
            manualPullRequestStartCondition: optionalCodableValue(params, "manual_pull_request_start_condition"),
            manualTagStartCondition: optionalCodableValue(params, "manual_tag_start_condition"),
            actions: optionalCodableValue(params, "actions"),
            xcodeVersionID: optionalString(params, "xcode_version_id"),
            macOsVersionID: optionalString(params, "mac_os_version_id")
        )
        let wf = try await api.workflows.update(id: id, fields: fields)
        return try jsonText(wf)
    }

    private static func handleWorkflowsDelete(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        try await api.workflows.delete(id: id)
        return ackResult("Deleted Xcode Cloud workflow \(id)")
    }

    // MARK: - Handlers: ciBuildRuns

    private static func handleBuildRunsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let productID = optionalString(params, "product_id")
        let workflowID = optionalString(params, "workflow_id")
        let sourceCommitSha = optionalString(params, "source_commit_sha")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.buildRuns.list(
            productID: productID,
            workflowID: workflowID,
            sourceCommitSha: sourceCommitSha,
            limit: limit,
            cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBuildRunsListForWorkflow(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let workflowID = try requireString(params, "workflow_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.buildRuns.listForWorkflow(
            workflowID: workflowID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBuildRunsListForProduct(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let productID = try requireString(params, "product_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.buildRuns.listForProduct(
            productID: productID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBuildRunsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let run = try await api.buildRuns.get(id: id)
        return try jsonText(run)
    }

    private static func handleBuildRunsCreate(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let workflowID = try requireString(params, "workflow_id")
        let gitReferenceID = optionalString(params, "git_reference_id")
        let sourceBranchOrTagID = optionalString(params, "source_branch_or_tag_id")
        let pullRequestID = optionalString(params, "pull_request_id")
        let run = try await api.buildRuns.create(
            workflowID: workflowID,
            gitReferenceID: gitReferenceID,
            pullRequestID: pullRequestID,
            sourceBranchOrTagID: sourceBranchOrTagID
        )
        return try jsonText(run)
    }

    private static func handleBuildRunsCancel(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let run = try await api.buildRuns.cancel(id: id)
        return try jsonText(run)
    }

    private static func handleBuildRunsRetry(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let run = try await api.buildRuns.retry(id: id)
        return try jsonText(run)
    }

    // MARK: - Handlers: ciBuildActions

    private static func handleBuildActionsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let buildRunID = try requireString(params, "build_run_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.buildActions.list(
            buildRunID: buildRunID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleBuildActionsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let action = try await api.buildActions.get(id: id)
        return try jsonText(action)
    }

    // MARK: - Handlers: ciArtifacts

    private static func handleArtifactsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let buildActionID = try requireString(params, "build_action_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.artifacts.list(
            buildActionID: buildActionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleArtifactsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let artifact = try await api.artifacts.get(id: id)
        return try jsonText(artifact)
    }

    // MARK: - Handlers: ciIssues

    private static func handleIssuesList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let buildActionID = try requireString(params, "build_action_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.issues.list(
            buildActionID: buildActionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleIssuesGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let issue = try await api.issues.get(id: id)
        return try jsonText(issue)
    }

    // MARK: - Handlers: ciTestResults

    private static func handleTestResultsListForBuildAction(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let buildActionID = try requireString(params, "build_action_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.testResults.listForBuildAction(
            buildActionID: buildActionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleTestResultsListForProduct(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let productID = try requireString(params, "product_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.testResults.listForProduct(
            productID: productID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleTestResultsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let result = try await api.testResults.get(id: id)
        return try jsonText(result)
    }

    // MARK: - Handlers: ciMacOsVersions

    private static func handleMacOsVersionsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.macOsVersions.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleMacOsVersionsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.macOsVersions.get(id: id)
        return try jsonText(version)
    }

    // MARK: - Handlers: ciXcodeVersions

    private static func handleXcodeVersionsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.xcodeVersions.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleXcodeVersionsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let version = try await api.xcodeVersions.get(id: id)
        return try jsonText(version)
    }

    private static func handleXcodeVersionsListCompatibleMacOsVersions(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let xcodeVersionID = try requireString(params, "xcode_version_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.xcodeVersions.listCompatibleMacOsVersions(
            xcodeVersionID: xcodeVersionID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    // MARK: - Handlers: scmRepositories

    private static func handleScmRepositoriesList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let ciProductID = optionalString(params, "ci_product_id")
        let scmProviderID = optionalString(params, "scm_provider_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.scmRepositories.list(
            ciProductID: ciProductID,
            scmProviderID: scmProviderID,
            limit: limit,
            cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleScmRepositoriesGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let repo = try await api.scmRepositories.get(id: id)
        return try jsonText(repo)
    }

    // MARK: - Handlers: scmGitReferences

    private static func handleScmGitReferencesList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let repositoryID = try requireString(params, "repository_id")
        let kind = optionalString(params, "kind")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.scmGitReferences.list(
            repositoryID: repositoryID, kind: kind, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleScmGitReferencesGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let ref = try await api.scmGitReferences.get(id: id)
        return try jsonText(ref)
    }

    // MARK: - Handlers: scmPullRequests

    private static func handleScmPullRequestsList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let repositoryID = try requireString(params, "repository_id")
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.scmPullRequests.list(
            repositoryID: repositoryID, limit: limit, cursor: cursor
        )
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleScmPullRequestsGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let pr = try await api.scmPullRequests.get(id: id)
        return try jsonText(pr)
    }

    // MARK: - Handlers: scmProviders

    private static func handleScmProvidersList(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let limit = optionalInt(params, "limit") ?? 200
        let cursor = optionalString(params, "cursor")
        let page = try await api.scmProviders.list(limit: limit, cursor: cursor)
        return try jsonText(PageOut(data: page.data, nextCursor: page.nextCursor))
    }

    private static func handleScmProvidersGet(
        _ params: CallTool.Parameters, api: XcodeCloudAPI
    ) async throws -> CallTool.Result {
        let id = try requireString(params, "id")
        let provider = try await api.scmProviders.get(id: id)
        return try jsonText(provider)
    }
}
