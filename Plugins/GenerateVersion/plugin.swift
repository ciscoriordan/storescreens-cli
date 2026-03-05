import PackagePlugin

@main
struct GenerateVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let versionFile = context.package.directory.appending("VERSION")
        let outputFile = context.pluginWorkDirectory.appending("Version.swift")
        return [
            .buildCommand(
                displayName: "Generate Version.swift from VERSION",
                executable: try context.tool(named: "GenerateVersionTool").path,
                arguments: [versionFile.string, outputFile.string],
                inputFiles: [versionFile],
                outputFiles: [outputFile]
            )
        ]
    }
}
