import Foundation
import AppKit
import CoreText

/// Converts a caption string (possibly containing markdown inline runs like
/// `**bold**`, `*italic*`, `` `code` ``) into an `NSAttributedString` ready
/// for Core Text layout. Each run gets the appropriate font (bold / italic /
/// bold+italic variant resolved via `FontResolver`) and the role's base color.
///
/// After markdown attribution, `applyHighlights` layers per-slide highlight
/// rules (literal substring matches) over the result, overriding color /
/// weight / italic on matching ranges.
package enum MarkdownAttributor {

    /// Builds an attributed string for one role's text, with markdown bold /
    /// italic expanded into proper font runs and the role's base color
    /// applied uniformly.
    package static func buildAttributed(
        plainOrMarkdown text: String,
        role: ResolvedRoleStyle,
        resolver: FontResolver
    ) throws -> NSAttributedString {
        // Parse markdown. If parsing fails (unlikely but not impossible),
        // fall back to treating the input as plain text.
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        let ns = NSMutableAttributedString(string: String(parsed.characters))

        // Walk runs of the AttributedString; translate inlinePresentationIntent
        // to concrete fonts and apply the role's base color.
        var idx = ns.string.startIndex
        var nsLocation = 0

        for run in parsed.runs {
            let runSubstring = parsed[run.range]
            let runString = String(runSubstring.characters)
            let length = runString.utf16.count

            let intent = run.inlinePresentationIntent ?? []
            let isBold = intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)

            let effectiveWeight: FontWeight = isBold ? .bold : role.weight
            let effectiveItalic = isItalic || role.italic

            let font = try resolver.resolve(
                role.font,
                size: role.fontSize,
                weight: effectiveWeight,
                italic: effectiveItalic
            )

            let range = NSRange(location: nsLocation, length: length)
            ns.addAttribute(.font, value: font, range: range)
            ns.addAttribute(.foregroundColor, value: role.color, range: range)

            nsLocation += length
            idx = ns.string.index(idx, offsetBy: runString.count, limitedBy: ns.string.endIndex) ?? ns.string.endIndex
        }

        return ns
    }

    /// Applies highlight rules on top of an already-attributed string. Each
    /// rule matches its `match` substring (case-sensitive, all occurrences)
    /// and overrides color / weight / italic on every hit range.
    package static func applyHighlights(
        _ base: NSAttributedString,
        role: ResolvedRoleStyle,
        highlights: [CaptionHighlight],
        resolver: FontResolver
    ) throws -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: base)
        let plain = base.string as NSString

        for rule in highlights {
            guard !rule.match.isEmpty else { continue }
            var searchStart = 0
            while searchStart < plain.length {
                let found = plain.range(
                    of: rule.match,
                    options: [.literal],
                    range: NSRange(location: searchStart, length: plain.length - searchStart)
                )
                if found.location == NSNotFound { break }

                // Determine effective attributes, inheriting from the current
                // run for anything the rule doesn't override.
                let effectiveWeight = rule.weight ?? role.weight
                let effectiveItalic = rule.italic ?? role.italic
                let newFont = try resolver.resolve(
                    role.font,
                    size: role.fontSize,
                    weight: effectiveWeight,
                    italic: effectiveItalic
                )
                mutable.addAttribute(.font, value: newFont, range: found)
                if let colorHex = rule.color, let color = RenderColors.parseHex(colorHex) {
                    mutable.addAttribute(.foregroundColor, value: color, range: found)
                }

                searchStart = found.location + found.length
            }
        }

        return mutable
    }
}

/// Role style with all defaults resolved into concrete non-optional values.
/// Produced by `CaptionLayouter` before calling into `MarkdownAttributor`.
package struct ResolvedRoleStyle: Sendable {
    package let font: FontSpec
    package let weight: FontWeight
    package let italic: Bool
    package let fontSize: CGFloat   // current pt size (may be shrunk)
    package let color: NSColor
    package let align: CaptionAlign

    package init(
        font: FontSpec,
        weight: FontWeight,
        italic: Bool,
        fontSize: CGFloat,
        color: NSColor,
        align: CaptionAlign
    ) {
        self.font = font
        self.weight = weight
        self.italic = italic
        self.fontSize = fontSize
        self.color = color
        self.align = align
    }
}

/// Color helpers shared across render modules.
package enum RenderColors {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` into NSColor. Returns nil for
    /// unparseable inputs.
    package static func parseHex(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        if hex.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1.0
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
