import XCTest
import Yams
@testable import StorescreensCore

/// Verifies the export-compliance plumbing for `upload-build`: YAML decode,
/// default value, and the mapping from `ExportCompliance` to the
/// `usesNonExemptEncryption` boolean used both in the ASC API patch path
/// (submit) and the Info.plist build-setting path (archive).
final class ExportComplianceTests: XCTestCase {

    func testUploadBuildConfig_decodesExportCompliance() throws {
        let yaml = """
            export_compliance: non_exempt
            """
        let cfg = try YAMLDecoder().decode(UploadBuildConfig.self, from: yaml)
        XCTAssertEqual(cfg.exportCompliance, .nonExempt)
    }

    func testUploadBuildConfig_defaultsNilWhenUnset() throws {
        let yaml = "scheme: MyApp"
        let cfg = try YAMLDecoder().decode(UploadBuildConfig.self, from: yaml)
        XCTAssertNil(cfg.exportCompliance,
                     "unset means callers fall back to the documented .none default")
    }

    func testExportCompliance_usesNonExemptEncryption_mapping() {
        XCTAssertEqual(ExportCompliance.none.usesNonExemptEncryption, false,
                       ".none -> false (standard iOS crypto, the default)")
        XCTAssertEqual(ExportCompliance.exemptAlgorithms.usesNonExemptEncryption, false,
                       ".exempt_algorithms -> false (custom crypto under an exemption)")
        XCTAssertEqual(ExportCompliance.nonExempt.usesNonExemptEncryption, true,
                       ".non_exempt -> true (BIS paperwork required)")
        XCTAssertNil(ExportCompliance.skip.usesNonExemptEncryption,
                     ".skip -> nil (don't touch the build setting)")
    }
}
