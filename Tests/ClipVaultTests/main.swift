import Foundation
@testable import ClipVaultCore

// Explicit test registry. No reflection in Swift, so suites are enumerated here.

// MARK: - ClipStoreTests

@discardableResult
func runClipStoreTests() -> Int {
    print("ClipStoreTests")
    var count = 0
    func run(_ name: String, _ body: (ClipStoreTests) throws -> Void) {
        let suite = ClipStoreTests()
        try? suite.setUpWithError()
        runTest(name) { try body(suite) }
        try? suite.tearDownWithError()
        count += 1
    }

    run("testAddTextInsertsAtTopAndPersistsPayload") { try $0.testAddTextInsertsAtTopAndPersistsPayload() }
    run("testReCopyOfOlderItemMovesItToTop") { try $0.testReCopyOfOlderItemMovesItToTop() }
    run("testIdenticalTopCopyIsIgnored") { try $0.testIdenticalTopCopyIsIgnored() }
    run("testSensitivityEscalatesOnMove") { try $0.testSensitivityEscalatesOnMove() }
    run("testSensitivityStaysWhenRecapturedPlain") { try $0.testSensitivityStaysWhenRecapturedPlain() }
    run("testLimitEvictsOldestUnpinnedOnly") { try $0.testLimitEvictsOldestUnpinnedOnly() }
    run("testPinnedSortsAboveChronological") { try $0.testPinnedSortsAboveChronological() }
    run("testRoundTripAcrossInstances") { try $0.testRoundTripAcrossInstances() }
    run("testMissingPayloadDropsEntryOnLoad") { try $0.testMissingPayloadDropsEntryOnLoad() }
    run("testDeleteRemovesPayloadFile") { try $0.testDeleteRemovesPayloadFile() }
    run("testClearAllKeepsPinnedUnlessForced") { try $0.testClearAllKeepsPinnedUnlessForced() }
    run("testImagePurgeRespectsRetentionAndPins") { try $0.testImagePurgeRespectsRetentionAndPins() }
    run("testZeroRetentionDisablesPurge") { try $0.testZeroRetentionDisablesPurge() }
    run("testCopyRestoresTextAndRichSidecars") { try $0.testCopyRestoresTextAndRichSidecars() }
    run("testCopyFailsGracefullyWhenPayloadMissing") { try $0.testCopyFailsGracefullyWhenPayloadMissing() }
    run("testImmediateCopyBackAfterCaptureSucceeds") { try $0.testImmediateCopyBackAfterCaptureSucceeds() }
    run("testLegacyFilesEntriesAreMigratedAway") { try $0.testLegacyFilesEntriesAreMigratedAway() }
    run("testApplyMaintenanceTrimsAndPurgesImmediately") { try $0.testApplyMaintenanceTrimsAndPurgesImmediately() }

    return count
}

// MARK: - UpdateCheckerTests

@discardableResult
func runUpdateCheckerTests() -> Int {
    print("\nUpdateCheckerTests")
    var count = 0
    func run(_ name: String, _ body: (UpdateCheckerTests) -> Void) {
        let suite = UpdateCheckerTests()
        runTest(name) { body(suite) }
        count += 1
    }

    run("testNewerVersionsAreDetected") { $0.testNewerVersionsAreDetected() }
    run("testNumericComponentsCompareAsNumbersNotStrings") { $0.testNumericComponentsCompareAsNumbersNotStrings() }
    run("testSameVersionIsNotAnUpdate") { $0.testSameVersionIsNotAnUpdate() }
    run("testLeadingVAndShortFormsAreTolerated") { $0.testLeadingVAndShortFormsAreTolerated() }
    run("testPrereleasesNeverNagStableUsers") { $0.testPrereleasesNeverNagStableUsers() }
    run("testNewerReleaseSurfacesAsAvailable") { $0.testNewerReleaseSurfacesAsAvailable() }
    run("testSameReleaseReportsUpToDate") { $0.testSameReleaseReportsUpToDate() }
    run("testDraftsAndPrereleasesAreIgnored") { $0.testDraftsAndPrereleasesAreIgnored() }
    run("testNoReleasesYetIsNotAnError") { $0.testNoReleasesYetIsNotAnError() }
    run("testRateLimitOrOutageReportsFailure") { $0.testRateLimitOrOutageReportsFailure() }
    run("testNetworkErrorReportsFailure") { $0.testNetworkErrorReportsFailure() }
    run("testGarbageBodyReportsFailure") { $0.testGarbageBodyReportsFailure() }

    return count
}

// MARK: - ClipboardClassifierTests

@discardableResult
func runClipboardClassifierTests() -> Int {
    print("\nClipboardClassifierTests")
    var count = 0
    func run(_ name: String, _ body: (ClipboardClassifierTests) throws -> Void) {
        let suite = ClipboardClassifierTests()
        try? suite.setUpWithError()
        runTest(name) { try body(suite) }
        try? suite.tearDownWithError()
        count += 1
    }

    run("testPlainTextCaptured") { try $0.testPlainTextCaptured() }
    run("testMultipleStringsJoined") { try $0.testMultipleStringsJoined() }
    run("testWhitespaceOnlyStringSkipped") { try $0.testWhitespaceOnlyStringSkipped() }
    run("testRichTextSidecarsAttached") { try $0.testRichTextSidecarsAttached() }
    run("testConcealedSkippedByDefault") { try $0.testConcealedSkippedByDefault() }
    run("testConcealedCapturedAsSensitiveWhenAllowed") { try $0.testConcealedCapturedAsSensitiveWhenAllowed() }
    run("testTransientAlwaysSkipped") { try $0.testTransientAlwaysSkipped() }
    run("testIgnoredSourceAppSkipped") { try $0.testIgnoredSourceAppSkipped() }
    run("testNonIgnoredSourceCaptured") { try $0.testNonIgnoredSourceCaptured() }
    run("testOTPSkipToggle") { try $0.testOTPSkipToggle() }
    run("testSingleImageFileIngestedAsPixels") { try $0.testSingleImageFileIngestedAsPixels() }
    run("testFinderStyleImageFileWithFilenameStringIngested") { try $0.testFinderStyleImageFileWithFilenameStringIngested() }
    run("testFileReferenceWithRealTextKeepsText") { try $0.testFileReferenceWithRealTextKeepsText() }
    run("testNonImageFileSkipped") { try $0.testNonImageFileSkipped() }
    run("testMultipleFileCopiesSkipped") { try $0.testMultipleFileCopiesSkipped() }
    run("testCorruptImageFileSkipped") { try $0.testCorruptImageFileSkipped() }
    run("testImageCapturedWithDimensionsAndThumbnail") { try $0.testImageCapturedWithDimensionsAndThumbnail() }
    run("testOversizedImageRefused") { try $0.testOversizedImageRefused() }
    run("testHashDistinguishesContent") { try $0.testHashDistinguishesContent() }
    run("testConcealedImageIsCapturedAsSensitive") { try $0.testConcealedImageIsCapturedAsSensitive() }
    run("testConcealedImageFileIsCapturedAsSensitive") { try $0.testConcealedImageFileIsCapturedAsSensitive() }
    MainActor.assumeIsolated {
        run("testSettingsDefaultsMatchProductDecisions") { try $0.testSettingsDefaultsMatchProductDecisions() }
        run("testRetentionNeverSurvivesRelaunch") { $0.testRetentionNeverSurvivesRelaunch() }
        run("testOutOfRangePersistedSettingsAreRepaired") { $0.testOutOfRangePersistedSettingsAreRepaired() }
        run("testEveryRetentionChoiceRoundTrips") { $0.testEveryRetentionChoiceRoundTrips() }
    }

    return count
}

// MARK: - Entry

let totalSuites = runClipStoreTests() + runClipboardClassifierTests() + runUpdateCheckerTests()

print("")
print("─────────────────────────────────────")
print(" \(TestContext.passed)/\(totalSuites) tests passed, \(TestContext.failed) failed")
print("─────────────────────────────────────")
if !TestContext.failures.isEmpty {
    print("\nFailures:")
    TestContext.failures.forEach { print(" • \($0)") }
}
exit(TestContext.failed > 0 ? 1 : 0)
