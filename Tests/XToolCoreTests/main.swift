import Foundation

// A deliberately tiny test runner with no dependency on XCTest or Swift Testing:
// the tests keep running whatever the installed developer tools look like.
// Add new tests to the list at the bottom.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var currentTest = ""

func fail(_ message: String, file: StaticString, line: UInt) {
    failures += 1
    print("  ✗ \(currentTest) – \((("\(file)") as NSString).lastPathComponent):\(line) \(message)")
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !condition() { fail(message(), file: file, line: line) }
    } catch {
        fail("Error: \(error) \(message())", file: file, line: line)
    }
}

func expectThrows<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    if (try? body()) != nil { fail("Expected an error", file: file, line: line) }
}

struct MissingValue: Error {}

func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        fail("Missing value", file: file, line: line)
        throw MissingValue()
    }
    return value
}

func run(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures
    let start = Date()
    do { try body() } catch { fail("Stopped: \(error)", file: #filePath, line: #line) }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print("\(failures == before ? "✓" : "✗") \(name) (\(ms) ms)")
}

run("CompatTests.readsFormat1VaultFromWindows") { try CompatTests().readsFormat1VaultFromWindows() }
run("CompatTests.readsFormat1VaultFromMac") { try CompatTests().readsFormat1VaultFromMac() }
run("CompatTests.refusesNewerFormat") { try CompatTests().refusesNewerFormat() }
run("CompatTests.blobRoundTripAndTamper") { try CompatTests().blobRoundTripAndTamper() }
run("CompatTests.vaultLifecycleTrashAndBackup") { try CompatTests().vaultLifecycleTrashAndBackup() }
run("CompatTests.versionsKeptRestoredAndEncoded") { try CompatTests().versionsKeptRestoredAndEncoded() }
run("CompatTests.damagedIndexFallsBackAndSaysSo") { try CompatTests().damagedIndexFallsBackAndSaysSo() }
run("CompatTests.lookupsSurviveRemoval") { try CompatTests().lookupsSurviveRemoval() }
run("CompatTests.dotNetDates") { try CompatTests().dotNetDates() }
run("LargeFileTests.roundTripAcrossChunkBoundaries") { try LargeFileTests().roundTripAcrossChunkBoundaries() }
run("LargeFileTests.roundTripFiveGigabytes") { try LargeFileTests().roundTripFiveGigabytes() }
run("LargeFileTests.cancelLeavesNothingBehind") { try LargeFileTests().cancelLeavesNothingBehind() }
run("LargeFileTests.tamperedExportLeavesNoPlaintext") { try LargeFileTests().tamperedExportLeavesNoPlaintext() }
run("LargeFileTests.backupHoldsLargeFile") { try LargeFileTests().backupHoldsLargeFile() }
run("LargeFileTests.orphanRecoveryIgnoresLargeBinaryLeftovers") { try LargeFileTests().orphanRecoveryIgnoresLargeBinaryLeftovers() }
run("PasswordTests.rejectsWhatLooksStrongButIsNot") { PasswordTests().rejectsWhatLooksStrongButIsNot() }
run("PasswordTests.acceptsGoodPasswords") { PasswordTests().acceptsGoodPasswords() }
run("PasswordTests.tooShortIsAlwaysRejected") { PasswordTests().tooShortIsAlwaysRejected() }
run("PasswordTests.newPasswordMustDiffer") { PasswordTests().newPasswordMustDiffer() }
run("PasswordTests.emptyIsNeutral") { PasswordTests().emptyIsNeutral() }
run("PasswordTests.suggestionsPassAndAreUnique") { PasswordTests().suggestionsPassAndAreUnique() }
run("WriterDocxTests.savedDocumentOpensAgain") { try WriterDocxTests().savedDocumentOpensAgain() }
run("WriterDocxTests.replacedContentStaysUntilIndexIsSaved") { try WriterDocxTests().replacedContentStaysUntilIndexIsSaved() }
run("WriterDocxTests.lostDocumentsAreRecovered") { try WriterDocxTests().lostDocumentsAreRecovered() }
run("WriterDocxTests.oldPatchedFilesCanBeRepaired") { try WriterDocxTests().oldPatchedFilesCanBeRepaired() }
run("KeyProtectionTests.oldVaultIsUpgradedAndStaysReadable") { try KeyProtectionTests().oldVaultIsUpgradedAndStaysReadable() }
run("KeyProtectionTests.keyStaysUsableForRunningWorkAfterLocking") { try KeyProtectionTests().keyStaysUsableForRunningWorkAfterLocking() }
run("KeyProtectionTests.olderSettingsGetDefaults") { try KeyProtectionTests().olderSettingsGetDefaults() }
run("RenewalTests.everythingStaysReadableAndTheOldKeyFileOpensNothing") { try RenewalTests().everythingStaysReadableAndTheOldKeyFileOpensNothing() }
run("RenewalTests.newPasswordReplacesTheOldOne") { try RenewalTests().newPasswordReplacesTheOldOne() }
run("RenewalTests.wrongPasswordChangesNothing") { try RenewalTests().wrongPasswordChangesNothing() }
run("RenewalTests.cancellingLeavesTheVaultAsItWas") { try RenewalTests().cancellingLeavesTheVaultAsItWas() }
run("RenewalTests.crashBeforeTheSwitchIsDiscarded") { try RenewalTests().crashBeforeTheSwitchIsDiscarded() }
run("RenewalTests.crashWhileStagingIsDiscarded") { try RenewalTests().crashWhileStagingIsDiscarded() }
run("RenewalTests.crashAfterTheSwitchIsCompletedOnNextStart") { try RenewalTests().crashAfterTheSwitchIsCompletedOnNextStart() }
run("MetadataTests.photosLoseLocationCameraAndNames") { try MetadataTests().photosLoseLocationCameraAndNames() }
run("MetadataTests.pdfLosesAuthorAndHiddenXMP") { try MetadataTests().pdfLosesAuthorAndHiddenXMP() }
run("MetadataTests.protectedPdfIsLeftAlone") { try MetadataTests().protectedPdfIsLeftAlone() }
run("MetadataTests.officeLosesAuthorsAndEditors") { try MetadataTests().officeLosesAuthorsAndEditors() }
run("MetadataTests.realWordFileStillOpensWithoutAuthor") { try MetadataTests().realWordFileStillOpensWithoutAuthor() }
run("MetadataTests.pdfTextStaysSelectable") { try MetadataTests().pdfTextStaysSelectable() }
run("MetadataTests.otherTypesAreUntouched") { try MetadataTests().otherTypesAreUntouched() }

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
