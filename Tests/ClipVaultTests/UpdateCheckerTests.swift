import Foundation
@testable import ClipVaultCore

/// Pure logic of the update checker: version ordering and response handling.
/// An updater that silently does nothing is the worst kind, so both halves are
/// covered directly rather than through the network.
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version ordering

    func testNewerVersionsAreDetected() {
        XCTAssertTrue(UpdateChecker.isVersion("1.1.0", newerThan: "1.0.7"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.8", newerThan: "1.0.7"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0.0", newerThan: "1.9.9"))
    }

    func testNumericComponentsCompareAsNumbersNotStrings() {
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.0"),
                      "1.10.0 must beat 1.9.0 — the classic lexicographic trap")
        XCTAssertFalse(UpdateChecker.isVersion("1.9.0", newerThan: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.10", newerThan: "1.0.9"))
    }

    func testSameVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.isVersion("1.0.7", newerThan: "1.0.7"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.6", newerThan: "1.0.7"))
    }

    func testLeadingVAndShortFormsAreTolerated() {
        XCTAssertTrue(UpdateChecker.isVersion("v1.1.0", newerThan: "1.0.7"))
        XCTAssertTrue(UpdateChecker.isVersion("1.1", newerThan: "1.0.7"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0", newerThan: "1.0.0"))
    }

    func testPrereleasesNeverNagStableUsers() {
        XCTAssertFalse(UpdateChecker.isVersion("1.1.0-beta.1", newerThan: "1.1.0"),
                       "a beta of the installed version is not an upgrade")
        XCTAssertTrue(UpdateChecker.isVersion("1.1.0", newerThan: "1.1.0-beta.1"),
                      "the final release is an upgrade over its own beta")
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0-beta.1", newerThan: "1.1.0"),
                      "a beta of a later version still sorts newer by numbers")
    }

    // MARK: - Response handling

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.github.com/x")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    private func payload(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/o/r/releases/tag/\(tag)",
         "body":"Notes here","draft":\(draft),"prerelease":\(prerelease)}
        """.utf8)
    }

    func testNewerReleaseSurfacesAsAvailable() {
        let state = UpdateChecker.interpret(data: payload(tag: "v1.1.0"),
                                            response: response(200), error: nil, current: "1.0.7")
        guard case .available(let release) = state else {
            return XCTFail("expected .available, got \(state)")
        }
        XCTAssertEqual(release.version, "1.1.0")
        XCTAssertEqual(release.notes, "Notes here")
        XCTAssertEqual(release.page.absoluteString, "https://github.com/o/r/releases/tag/v1.1.0")
    }

    func testSameReleaseReportsUpToDate() {
        let state = UpdateChecker.interpret(data: payload(tag: "v1.0.7"),
                                            response: response(200), error: nil, current: "1.0.7")
        guard case .upToDate = state else { return XCTFail("expected .upToDate, got \(state)") }
    }

    func testDraftsAndPrereleasesAreIgnored() {
        let draft = UpdateChecker.interpret(data: payload(tag: "v2.0.0", draft: true),
                                            response: response(200), error: nil, current: "1.0.7")
        guard case .upToDate = draft else { return XCTFail("drafts must not surface") }

        let pre = UpdateChecker.interpret(data: payload(tag: "v2.0.0", prerelease: true),
                                          response: response(200), error: nil, current: "1.0.7")
        guard case .upToDate = pre else { return XCTFail("pre-releases must not surface") }
    }

    func testNoReleasesYetIsNotAnError() {
        let state = UpdateChecker.interpret(data: nil, response: response(404), error: nil, current: "1.0.7")
        guard case .upToDate = state else {
            return XCTFail("a repo with no releases is 'up to date', not a failure — got \(state)")
        }
    }

    func testRateLimitOrOutageReportsFailure() {
        let state = UpdateChecker.interpret(data: nil, response: response(403), error: nil, current: "1.0.7")
        guard case .failed = state else { return XCTFail("expected .failed, got \(state)") }
    }

    func testNetworkErrorReportsFailure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let state = UpdateChecker.interpret(data: nil, response: nil, error: error, current: "1.0.7")
        guard case .failed = state else { return XCTFail("expected .failed, got \(state)") }
    }

    func testGarbageBodyReportsFailure() {
        let state = UpdateChecker.interpret(data: Data("not json".utf8),
                                            response: response(200), error: nil, current: "1.0.7")
        guard case .failed = state else { return XCTFail("expected .failed, got \(state)") }
    }
}
