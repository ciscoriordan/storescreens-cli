import Foundation

package struct CaptureManifest: Codable, Sendable {
    package let version: Int
    package let generatedAt: Date
    package let generatedBy: String
    package let appName: String
    package let displayName: String?
    package let scheme: String
    package let devices: [DeviceCapture]

    package init(version: Int, generatedAt: Date, generatedBy: String, appName: String, displayName: String?, scheme: String, devices: [DeviceCapture]) {
        self.version = version
        self.generatedAt = generatedAt
        self.generatedBy = generatedBy
        self.appName = appName
        self.displayName = displayName
        self.scheme = scheme
        self.devices = devices
    }

    package struct DeviceCapture: Codable, Sendable {
        package let deviceType: String
        package let simulatorName: String
        package let locale: String?
        package let appearance: String?
        package let screenshots: [Screenshot]

        package init(deviceType: String, simulatorName: String, locale: String?, appearance: String?, screenshots: [Screenshot]) {
            self.deviceType = deviceType
            self.simulatorName = simulatorName
            self.locale = locale
            self.appearance = appearance
            self.screenshots = screenshots
        }
    }

    package struct Screenshot: Codable, Sendable {
        package let name: String
        package let filename: String
        package let capturedAt: Date
        /// Per-slide appearance override. When set, the renderer pulls the
        /// matching `{ light:, dark: }` variant for every chrome field
        /// regardless of `DeviceCapture.appearance`. nil means inherit
        /// from the device's appearance (legacy multiplier path).
        package let appearance: String?

        package init(name: String, filename: String, capturedAt: Date, appearance: String? = nil) {
            self.name = name
            self.filename = filename
            self.capturedAt = capturedAt
            self.appearance = appearance
        }
    }
}
