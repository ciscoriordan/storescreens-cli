import Foundation

struct CaptureManifest: Codable, Sendable {
    let version: Int
    let generatedAt: Date
    let generatedBy: String
    let appName: String
    let displayName: String?
    let scheme: String
    let devices: [DeviceCapture]

    struct DeviceCapture: Codable, Sendable {
        let deviceType: String
        let simulatorName: String
        let locale: String?
        let appearance: String?
        let screenshots: [Screenshot]
    }

    struct Screenshot: Codable, Sendable {
        let name: String
        let filename: String
        let capturedAt: Date
    }
}
