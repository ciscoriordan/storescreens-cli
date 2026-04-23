import Foundation
import CoreGraphics

/// Minimal Adobe Photoshop (.psd) file parser.
///
/// Extracts only what storescreens needs for bezel import: canvas dimensions
/// and each layer's name + pixel bbox. Rasterization stays with `NSImage` /
/// Image I/O — this parser reads metadata only.
///
/// Reference: Adobe Photoshop File Format Specification
/// https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/
package enum PSDParser {

    package struct File {
        package let canvasWidth: Int
        package let canvasHeight: Int
        package let layers: [Layer]
    }

    package struct Layer {
        package let name: String
        package let bbox: CGRect   // (left, top, width, height) in pixel coords
    }

    package enum ParseError: Error, CustomStringConvertible {
        case notAPSD
        case unsupportedVersion(Int)
        case truncated(section: String)
        case invalidLayerBlendSignature

        package var description: String {
            switch self {
            case .notAPSD:
                return "file is not a PSD (missing '8BPS' signature)"
            case .unsupportedVersion(let v):
                return "unsupported PSD version \(v) (expected 1)"
            case .truncated(let section):
                return "PSD truncated while reading \(section)"
            case .invalidLayerBlendSignature:
                return "PSD layer record has invalid blend mode signature"
            }
        }
    }

    package static func parse(at url: URL) throws -> File {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var cursor = Cursor(data: data)

        // --- File Header (26 bytes) ---
        let signature = try cursor.readBytes(4)
        guard signature == [0x38, 0x42, 0x50, 0x53] else { throw ParseError.notAPSD }  // "8BPS"
        let version = try cursor.readUInt16()
        guard version == 1 else { throw ParseError.unsupportedVersion(Int(version)) }
        try cursor.skip(6)                              // reserved
        _ = try cursor.readUInt16()                     // channels
        let height = Int(try cursor.readUInt32())
        let width = Int(try cursor.readUInt32())
        _ = try cursor.readUInt16()                     // depth
        _ = try cursor.readUInt16()                     // color mode

        // --- Color Mode Data (length-prefixed, skip) ---
        try cursor.skipLengthPrefixed()

        // --- Image Resources (length-prefixed, skip) ---
        try cursor.skipLengthPrefixed()

        // --- Layer and Mask Information ---
        let layerMaskLen = Int(try cursor.readUInt32())
        let layerMaskEnd = cursor.offset + layerMaskLen
        guard layerMaskLen > 0 else { return File(canvasWidth: width, canvasHeight: height, layers: []) }

        // Layer Info sub-section
        let layerInfoLen = Int(try cursor.readUInt32())
        if layerInfoLen == 0 {
            return File(canvasWidth: width, canvasHeight: height, layers: [])
        }
        let layerInfoEnd = cursor.offset + layerInfoLen

        // Layer count: signed int16; negative = has absolute alpha, |n| is count
        let rawCount = try cursor.readInt16()
        let layerCount = Int(abs(rawCount))

        var layers: [Layer] = []
        layers.reserveCapacity(layerCount)

        for _ in 0..<layerCount {
            // Bounds: top, left, bottom, right (4 × u32 = 16 bytes)
            let top = Int(try cursor.readInt32())
            let left = Int(try cursor.readInt32())
            let bottom = Int(try cursor.readInt32())
            let right = Int(try cursor.readInt32())

            // Channels + channel info
            let numChannels = Int(try cursor.readUInt16())
            try cursor.skip(numChannels * 6)

            // Blend mode signature ('8BIM')
            let blendSig = try cursor.readBytes(4)
            guard blendSig == [0x38, 0x42, 0x49, 0x4D] else {
                throw ParseError.invalidLayerBlendSignature
            }
            try cursor.skip(4)  // blend mode key
            try cursor.skip(4)  // opacity, clipping, flags, filler

            // Extra data field: length-prefixed block containing mask, blending
            // ranges, name, and additional layer info.
            let extraLen = Int(try cursor.readUInt32())
            let extraEnd = cursor.offset + extraLen

            // Layer mask data (length-prefixed)
            try cursor.skipLengthPrefixed()
            // Layer blending ranges (length-prefixed)
            try cursor.skipLengthPrefixed()

            // Pascal layer name: 1-byte length + bytes, padded to 4-byte boundary
            // INCLUDING the length byte itself.
            let pascalNameStart = cursor.offset
            let pascalLen = Int(try cursor.readUInt8())
            let pascalBytes = try cursor.readBytes(pascalLen)
            let totalPascalBytes = 1 + pascalLen
            let padding = (4 - (totalPascalBytes % 4)) % 4
            try cursor.skip(padding)
            _ = pascalNameStart

            // Additional layer info blocks — look for a Unicode name ('luni')
            // which is preferred over the Pascal name when present.
            var unicodeName: String? = nil
            while cursor.offset + 12 <= extraEnd {
                let sig = try cursor.readBytes(4)
                // Accept either '8BIM' or '8B64' signatures
                let is8BIM = sig == [0x38, 0x42, 0x49, 0x4D]
                let is8B64 = sig == [0x38, 0x42, 0x36, 0x34]
                guard is8BIM || is8B64 else {
                    // Unknown signature — abandon additional info scan for this layer
                    break
                }
                let key = try cursor.readBytes(4)
                let blockLen = Int(try cursor.readUInt32())
                let blockEnd = cursor.offset + blockLen

                if key == [0x6C, 0x75, 0x6E, 0x69] {  // "luni"
                    let charCount = Int(try cursor.readUInt32())
                    let byteCount = charCount * 2
                    let utf16Bytes = try cursor.readBytes(byteCount)
                    unicodeName = Self.decodeUTF16BE(bytes: utf16Bytes)
                }

                // Block data is padded to even length in PSD spec
                let paddedLen = blockLen + (blockLen % 2)
                let toSkip = (blockEnd + (blockLen % 2)) - cursor.offset
                if toSkip > 0 { try cursor.skip(toSkip) }
                _ = paddedLen
            }

            // Jump to end of extra section if we bailed early
            if cursor.offset < extraEnd {
                try cursor.skip(extraEnd - cursor.offset)
            }

            let pascalName = Self.decodeMacRoman(bytes: pascalBytes)
            let name = unicodeName?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? pascalName

            // PSD spec allows "empty" bounds (e.g. layer groups with no pixel content).
            // Emit them anyway so callers can filter; width/height may be 0.
            let bbox = CGRect(
                x: CGFloat(left),
                y: CGFloat(top),
                width: CGFloat(max(0, right - left)),
                height: CGFloat(max(0, bottom - top))
            )
            layers.append(Layer(name: name, bbox: bbox))
        }

        // Don't consume channel image data (follows this; irrelevant to us).
        // Jump straight to end of the layer/mask section.
        _ = layerInfoEnd
        _ = layerMaskEnd

        return File(canvasWidth: width, canvasHeight: height, layers: layers)
    }

    // MARK: - String decoding

    private static func decodeMacRoman(bytes: [UInt8]) -> String {
        // Legacy Pascal names in PSDs are Mac Roman. For ASCII-only strings
        // (which covers every layer name we've seen in Apple's DMGs), UTF-8
        // round-trips correctly; for non-ASCII, CFStringCreateWithBytes would be
        // more accurate but we don't need that level of precision here.
        if let s = String(bytes: bytes, encoding: .macOSRoman) { return s }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func decodeUTF16BE(bytes: [UInt8]) -> String {
        var data = Data(bytes)
        // Prepend BOM so String(data:encoding:) treats it as big-endian UTF-16
        data.insert(contentsOf: [0xFE, 0xFF], at: 0)
        return String(data: data, encoding: .utf16) ?? ""
    }
}

// MARK: - Binary cursor

private struct Cursor {
    let data: Data
    var offset: Int = 0

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw PSDParser.ParseError.truncated(section: "u8") }
        let v = data[data.startIndex + offset]
        offset += 1
        return v
    }

    mutating func readUInt16() throws -> UInt16 {
        let b = try readBytes(2)
        return (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    mutating func readInt16() throws -> Int16 {
        let u = try readUInt16()
        return Int16(bitPattern: u)
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    mutating func readInt32() throws -> Int32 {
        let u = try readUInt32()
        return Int32(bitPattern: u)
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw PSDParser.ParseError.truncated(section: "readBytes(\(count))")
        }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
        let bytes = Array(data[range])
        offset += count
        return bytes
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw PSDParser.ParseError.truncated(section: "skip(\(count))")
        }
        offset += count
    }

    mutating func skipLengthPrefixed() throws {
        let len = Int(try readUInt32())
        try skip(len)
    }
}
