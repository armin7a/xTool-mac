import CryptoKit
import Foundation

public enum XToolCryptoError: Error, LocalizedError {
    case corrupted(String)
    case wrongKey
    case unsupportedKdf(String)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let what): return "Daten sind beschädigt (\(what))."
        case .wrongKey: return "Falscher Schlüssel oder manipulierte Daten."
        case .unsupportedKdf(let what): return "Nicht unterstütztes Tresor-Format: \(what)"
        }
    }
}

/// AES-256-GCM for small values (index, wrapped key). Sealed format: nonce(12) | ciphertext | tag(16).
public enum Aead {
    public static let keySize = 32
    public static let nonceSize = 12
    public static let tagSize = 16

    public static func seal(key: Data, plaintext: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw XToolCryptoError.corrupted("seal") }
        return combined
    }

    public static func open(key: Data, sealed: Data, aad: Data) throws -> Data {
        guard sealed.count >= nonceSize + tagSize else { throw XToolCryptoError.corrupted("zu kurz") }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw XToolCryptoError.wrongKey
        }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        guard count > 0 else { return data }
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }
}
