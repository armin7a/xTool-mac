import Foundation
@testable import XToolCore

struct PasswordTests {
    func rejectsWhatLooksStrongButIsNot() {
        for weak in ["Sommer2024!", "Summer2024!", "Passwort123!", "Password123!", "P@ssw0rt1234", "Qwertz123456", "aaaaaaaaaaaaaaaa", "abcabcabcabcabc",
                     "123456789012", "Hallo1234567", "Deutschland2024", "MeinHundIstToll", "abcdefghijklmnop"] {
            let report = PasswordPolicy.evaluate(weak)
            expect(!report.isAcceptable, "\(weak) should be rejected (\(report.bits) bit)")
            expect(report.hint != nil)
        }
    }

    func acceptsGoodPasswords() {
        for good in ["correct-horse-battery-staple", "Vulkan Tasche Regen Pinsel Kiwi", "xK7m-q2Pf-9tZr", "gH4!vPz9#Lq2", "Der Zug nach Bern fuhr um 7:42 los"] {
            let report = PasswordPolicy.evaluate(good)
            expect(report.isAcceptable, "\(good) should pass (\(report.bits) bit, \(report.problems))")
        }
    }

    func tooShortIsAlwaysRejected() {
        let report = PasswordPolicy.evaluate("xK7#q2!Pf")
        expect(report.problems.contains(.tooShort(missing: 3)))
        expect(!report.isAcceptable)
    }

    func newPasswordMustDiffer() {
        let pw = "Vulkan Tasche Regen Pinsel Kiwi"
        expect(!PasswordPolicy.evaluate(pw, previous: pw).isAcceptable)
    }

    func emptyIsNeutral() {
        let report = PasswordPolicy.evaluate("")
        expect(report.score == 0)
        expect(report.hint == nil)
    }

    func suggestionsPassAndAreUnique() {
        expect(Set(WordLists.passphraseWords).count == WordLists.passphraseWords.count)
        expect(WordLists.passphraseWords.count >= 512)
        expect(PasswordGenerator.entropyBits() >= PasswordPolicy.minimumBits)
        var seen = Set<String>()
        for _ in 0..<200 {
            let pw = PasswordGenerator.passphrase()
            expect(PasswordPolicy.evaluate(pw).isAcceptable, "\(pw)")
            seen.insert(pw)
        }
        expect(seen.count == 200)
    }
}
