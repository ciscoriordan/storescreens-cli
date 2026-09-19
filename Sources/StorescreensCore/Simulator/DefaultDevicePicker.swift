import Foundation

/// Chooses the simulator `storescreens init` writes into a new config.
package enum DefaultDevicePicker {

    /// App Store Connect's display type for the 6.9" iPhone class (iPhone
    /// 16/17/18 Pro Max and the other sizes App Store Connect groups with
    /// them). An iPhone app needs screenshots in this class or, when there
    /// are none, in the 6.5" class (`APP_IPHONE_65`), and App Store Connect
    /// scales the larger set down for the smaller classes. The 6.9" class is
    /// preferred; the 6.5" class is the accepted alternative.
    private static let largestIPhoneDisplayType = "APP_IPHONE_67"

    /// The one iPhone a new config captures on.
    ///
    /// Only sizes App Store Connect takes screenshots for are considered
    /// (`ScreenshotDisplayType` resolves them), preferring the 6.9" class.
    /// Picking the widest iPhone outright would pick the iPhone Duo, whose
    /// 2007 px wide inner display has no App Store Connect slot, and leave the
    /// config with no uploadable device. Among those, the widest screen wins,
    /// so a machine without a 6.9" iPhone gets a 6.5" class device when it
    /// has one; among simulators with the same screen, the newest model ("iPhone 18
    /// Pro Max" over "iPhone 17 Pro Max"), since the older model may not
    /// exist on the next Xcode's runtimes. When no iPhone size resolves (a
    /// machine with only sizes storescreens does not know yet), falls back to
    /// the widest iPhone. Pure, so the choice is testable without a simulator.
    ///
    /// - Parameter sizes: App Store size of each device, keyed by UDID.
    package static func iPhone(
        from devices: [SimulatorDevice],
        sizes: [String: AppStoreScreenSize]
    ) -> SimulatorDevice? {
        let iPhones: [(device: SimulatorDevice, size: AppStoreScreenSize)] = devices.compactMap { device in
            guard let size = sizes[device.udid], size.isIPhone else { return nil }
            return (device, size)
        }
        let listed = iPhones.filter { $0.size.screenshotDisplayType != nil }
        let largestClass = listed.filter { $0.size.screenshotDisplayType == largestIPhoneDisplayType }
        let pool = !largestClass.isEmpty ? largestClass : (!listed.isEmpty ? listed : iPhones)

        return pool.sorted { a, b in
            let aWidth = min(a.size.width, a.size.height), bWidth = min(b.size.width, b.size.height)
            if aWidth != bWidth { return aWidth > bWidth }
            let aHeight = max(a.size.width, a.size.height), bHeight = max(b.size.width, b.size.height)
            if aHeight != bHeight { return aHeight > bHeight }
            let aGeneration = modelGeneration(a.device.name) ?? -1
            let bGeneration = modelGeneration(b.device.name) ?? -1
            if aGeneration != bGeneration { return aGeneration > bGeneration }
            return a.device.name < b.device.name
        }.first?.device
    }

    /// The model number in an iPhone simulator's name: 18 for "iPhone 18 Pro
    /// Max", 16 for "iPhone 16e". Nil for names without one ("iPhone Air",
    /// "iPhone SE (3rd generation)").
    package static func modelGeneration(_ name: String) -> Int? {
        guard name.hasPrefix("iPhone ") else { return nil }
        let digits = name.dropFirst("iPhone ".count).prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }
}
