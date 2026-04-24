import XCTest
@testable import StorescreensCore

/// Covers `ASCClient.APIError.isAlreadySetConflict`, the predicate
/// SubmitOrchestrator uses to treat "re-running attach-build or
/// set-compliance when the values already match" as a no-op success
/// instead of a noisy 409. Apple's error payloads are not
/// machine-friendly (the code is generic `ENTITY_ERROR.ATTRIBUTE.INVALID`
/// and the decisive part is free-form text) so the helper has to
/// pattern-match on the message. These cases are the ones we've seen
/// in the wild; regressions here mean re-runs will start failing
/// visibly again.
final class APIErrorIdempotencyTests: XCTestCase {

    private func err(
        status: Int,
        code: String,
        detail: String
    ) -> ASCClient.APIError {
        ASCClient.APIError(
            statusCode: status,
            details: [ASCClient.ErrorDetail(
                id: nil, status: "\(status)",
                code: code, title: "Conflict", detail: detail
            )],
            rawBody: ""
        )
    }

    func testAttribute_alreadySet_usesNonExemptEncryption() {
        // Real payload observed when PATCHing /v1/builds/{id} after
        // usesNonExemptEncryption was already set to the same value.
        let e = err(
            status: 409,
            code: "ENTITY_ERROR.ATTRIBUTE.INVALID",
            detail: "The provided entity includes an attribute with an invalid value: You cannot update when the value is already set."
        )
        XCTAssertTrue(e.isAlreadySetConflict)
    }

    func testRelationship_alreadyAttached_build() {
        // Plausible payload when re-attaching an already-attached
        // build to the same version.
        let e = err(
            status: 409,
            code: "ENTITY_ERROR.RELATIONSHIP.INVALID",
            detail: "The specified build is already attached to this version."
        )
        XCTAssertTrue(e.isAlreadySetConflict)
    }

    func testNot409_notIdempotent() {
        // Same message text but a 400 — we only forgive 409s.
        let e = err(
            status: 400,
            code: "ENTITY_ERROR.ATTRIBUTE.INVALID",
            detail: "value is already set"
        )
        XCTAssertFalse(e.isAlreadySetConflict)
    }

    func testGeneric409_notIdempotent() {
        // 409 but the detail doesn't match any of our patterns —
        // a real conflict, shouldn't be silently swallowed.
        let e = err(
            status: 409,
            code: "SOME_OTHER_CODE",
            detail: "resource has been modified by someone else"
        )
        XCTAssertFalse(e.isAlreadySetConflict)
    }
}
