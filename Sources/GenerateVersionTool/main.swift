import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: GenerateVersionTool <VERSION-file> <output.swift>\n", stderr)
    exit(1)
}

let versionFile = CommandLine.arguments[1]
let outputFile = CommandLine.arguments[2]

guard let version = try? String(contentsOfFile: versionFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines),
    !version.isEmpty
else {
    fputs("Could not read VERSION file at \(versionFile)\n", stderr)
    exit(1)
}

let content = """
// Auto-generated from VERSION - do not edit directly.
package let storescreensVersion: String = "\(version)"

"""

do {
    try content.write(toFile: outputFile, atomically: true, encoding: .utf8)
} catch {
    fputs("Could not write \(outputFile): \(error)\n", stderr)
    exit(1)
}
