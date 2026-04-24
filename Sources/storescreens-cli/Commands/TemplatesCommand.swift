import ArgumentParser
import Foundation
import StorescreensCore

struct TemplatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "templates",
        abstract: "List built-in render templates.",
        discussion: """
            Templates seed the `render:` block with a curated color palette, \
            typography, and background pattern. Apply one by name via \
            `storescreens render --template NAME` or by adding `template: NAME` \
            under `render:` in storescreens.yml. User-supplied fields always \
            win over template defaults.
            """
    )

    @Flag(name: .long, help: "Output as JSON instead of a formatted table.")
    var json: Bool = false

    func run() async throws {
        if json {
            try printJSON()
        } else {
            printTable()
        }
    }

    // MARK: - Output modes

    private func printTable() {
        let templates = RenderTemplate.builtIn
        let nameW = max(4, templates.map { $0.name.count }.max() ?? 0)
        let idW = max(2, templates.map { $0.id.count }.max() ?? 0)
        let catW = max(8, templates.map { $0.category.count }.max() ?? 0)

        let header = "  \(padded("NAME", to: nameW))  \(padded("ID", to: idW))  \(padded("CATEGORY", to: catW))  DESCRIPTION"
        print(header)
        print("  \(String(repeating: "-", count: nameW))  \(String(repeating: "-", count: idW))  \(String(repeating: "-", count: catW))  \(String(repeating: "-", count: 48))")
        for t in templates {
            print("  \(padded(t.name, to: nameW))  \(padded(t.id, to: idW))  \(padded(t.category, to: catW))  \(t.description)")
        }
        print("")
        print("Apply with: storescreens render --template <id>")
        print("Or set `template: <id>` under `render:` in storescreens.yml.")
    }

    private func printJSON() throws {
        struct Out: Encodable {
            let id: String
            let name: String
            let category: String
            let description: String
        }
        let out = RenderTemplate.builtIn.map {
            Out(id: $0.id, name: $0.name, category: $0.category, description: $0.description)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(out)
        if let s = String(data: data, encoding: .utf8) { print(s) }
    }

    private func padded(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }
}
