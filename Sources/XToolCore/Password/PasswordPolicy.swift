import Foundation

/// How good a master password is, and why not.
public struct PasswordReport: Equatable {
    public enum Problem: Equatable {
        case tooShort(missing: Int)
        case common
        case predictable
        case sameAsPrevious
    }

    /// Estimated strength in bits: how hard guessing is, assuming the attacker knows common words and patterns.
    public let bits: Double
    /// 0 = empty, 1 = "Zu schwach", 2 = "Schwach", 3 = "Gut", 4 = "Sehr stark"
    public let score: Int
    public let problems: [Problem]

    public var isAcceptable: Bool { problems.isEmpty && score >= 3 }

    public var label: String {
        ["", "Zu schwach", "Schwach", "Gut", "Sehr stark"][score]
    }

    /// The one thing to do next. Nil if the password is fine.
    public var hint: String? {
        switch problems.first {
        case .sameAsPrevious: return "Das neue Passwort muss sich vom bisherigen unterscheiden."
        case .common: return "Das ist ein sehr häufiges Passwort und schnell erraten."
        case .tooShort(let missing): return "Noch \(missing) Zeichen. Mindestens \(PasswordPolicy.minimumLength) sind nötig."
        case .predictable: return "Zu vorhersehbar. Mehrere zufällige Wörter sind am besten – oder nimm den Vorschlag."
        case nil: return nil
        }
    }
}

/// Rules for new master passwords. Existing passwords keep working: this is only applied when one is chosen.
///
/// Counting character classes rewards "Sommer2024!", which falls in seconds. This estimates instead what an
/// attacker has to try: the cheapest way to build the password from dictionary words, keyboard rows, sequences,
/// repeats, dates and single characters (the idea behind zxcvbn).
public enum PasswordPolicy {
    public static let minimumLength = 12
    /// 2^50 guesses against Argon2id with 1 GiB per guess is out of reach even for a large rig.
    public static let minimumBits = 50.0

    public static func evaluate(_ password: String, previous: String? = nil) -> PasswordReport {
        guard !password.isEmpty else { return PasswordReport(bits: 0, score: 0, problems: []) }

        var bits = estimateBits(password)
        var problems: [PasswordReport.Problem] = []
        if let previous, !previous.isEmpty, normalizedForm(previous) == normalizedForm(password) { problems.append(.sameAsPrevious) }
        if isCommon(password) {
            problems.append(.common)
            bits = min(bits, 12)
        }
        let length = password.count
        if length < minimumLength { problems.append(.tooShort(missing: minimumLength - length)) }
        else if bits < minimumBits && !problems.contains(.common) { problems.append(.predictable) }

        let score: Int
        switch bits {
        case ..<28: score = 1
        case ..<minimumBits: score = 2
        case ..<75: score = 3
        default: score = 4
        }
        return PasswordReport(bits: bits, score: length < minimumLength ? min(score, 2) : score, problems: problems)
    }

    // MARK: estimate

    static func estimateBits(_ password: String) -> Double {
        let original = Array(password.prefix(128))
        let lower: [Character] = original.map { $0.lowercased().first ?? $0 }
        let plain = lower.map { String($0) }
        let leet = lower.map { leetMap[$0].map(String.init) ?? String($0) }
        let n = original.count
        var best = [Double](repeating: 0, count: n + 1)

        for end in 1...n {
            var cheapest = best[end - 1] + charCost(original[end - 1])
            for start in max(0, end - 32)..<(end - 1) {
                let plainSegment = plain[start..<end].joined()
                var cost = Double.infinity
                let length = end - start

                if let period = repeatPeriod(lower, start, end) {
                    let unit = (start..<(start + period)).reduce(0.0) { $0 + charCost(original[$1]) }
                    cost = unit + log2(Double(length) / Double(period)) + 1
                }
                if length >= 3, sequences.contains(where: { $0.contains(plainSegment) }) {
                    cost = min(cost, 4 + log2(Double(length)))
                }
                if let date = dateCost(plainSegment) { cost = min(cost, date) }
                if length >= 3 {
                    let leetSegment = leet[start..<end].joined()
                    if commonWords.contains(plainSegment) || commonWords.contains(leetSegment) {
                        let hasLeet = !commonWords.contains(plainSegment)
                        let capitals = original[start..<end].dropFirst().contains(where: \.isUppercase)
                        cost = min(cost, wordCost + (hasLeet ? 1 : 0) + (capitals ? 2 : 0) + (original[start].isUppercase ? 1 : 0))
                    }
                }
                cheapest = min(cheapest, best[start] + cost)
            }
            best[end] = cheapest
        }
        return best[n]
    }

    /// Letters are rated below their theoretical 4.7 bits because people pick pronounceable text, not random letters.
    private static func charCost(_ c: Character) -> Double {
        if c.isLowercase { return 3.8 }
        if c.isUppercase { return 5 }
        if c.isNumber { return 3.6 }
        return 6
    }

    private static func repeatPeriod(_ s: [Character], _ start: Int, _ end: Int) -> Int? {
        let length = end - start
        for period in 1...4 where length >= period * 2 {
            if (start + period..<end).allSatisfy({ s[$0] == s[$0 - period] }) { return period }
        }
        return nil
    }

    private static func dateCost(_ segment: String) -> Double? {
        guard segment.allSatisfy(\.isNumber), segment.allSatisfy(\.isASCII) else { return nil }
        switch segment.count {
        case 4:
            if let year = Int(segment), (1900...2099).contains(year) { return 7 }
            return 11
        case 6: return 13
        case 8:
            if let a = Int(segment.prefix(4)), (1900...2099).contains(a) { return 15 }
            if let b = Int(segment.suffix(4)), (1900...2099).contains(b) { return 15 }
            return nil
        default: return nil
        }
    }

    // MARK: common passwords

    /// True for a listed password or word, also with trailing digits/symbols or letter substitutions ("P@ssw0rt123!").
    static func isCommon(_ password: String) -> Bool {
        let form = normalizedForm(password)
        let unleet = String(form.map { leetMap[$0] ?? $0 })
        for candidate in [form, unleet] {
            if WordLists.commonPasswords.contains(candidate) { return true }
            let stem = String(candidate.reversed().drop(while: { !$0.isLetter }).reversed())
            if stem.count >= 3, stem.count < candidate.count || candidate.count < minimumLength,
               WordLists.commonPasswords.contains(stem) || commonWords.contains(stem) { return true }
        }
        return false
    }

    private static func normalizedForm(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static let leetMap: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "@": "a", "$": "s", "!": "i", "€": "e",
    ]

    private static let sequences: [String] = {
        let rows = ["abcdefghijklmnopqrstuvwxyz", "01234567890", "qwertzuiopü", "qwertyuiop", "asdfghjklöä", "asdfghjkl",
                    "yxcvbnm", "zxcvbnm", "1qaz2wsx3edc", "!\"§$%&/()=", "!@#$%^&*()"]
        return rows + rows.map { String($0.reversed()) }
    }()

    private static let commonWords: Set<String> = {
        Set(WordLists.commonPasswords.filter { $0.allSatisfy(\.isLetter) })
            .union(WordLists.commonWords)
            .union(WordLists.passphraseWords.map { $0.lowercased() })
    }()

    private static let wordCost: Double = log2(Double(commonWords.count))
}

/// Suggests a master password that is easy to remember and type: random words, chosen with a cryptographic generator.
public enum PasswordGenerator {
    public static let defaultWordCount = 6

    public static func passphrase(wordCount: Int = defaultWordCount) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<wordCount).map { _ in WordLists.passphraseWords.randomElement(using: &rng)! }.joined(separator: "-")
    }

    /// Real entropy of a suggestion. A list of 512 words gives 9 bits per word.
    public static func entropyBits(wordCount: Int = defaultWordCount) -> Double {
        Double(wordCount) * log2(Double(WordLists.passphraseWords.count))
    }
}
