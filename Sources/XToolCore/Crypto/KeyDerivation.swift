import Foundation
import Sodium

/// Argon2id parameters, stored with each vault. Default: 1 GiB, 3 passes, 1 lane, 16-byte salt.
public struct KdfParams: Equatable {
    public var memoryKiB: Int
    public var iterations: Int
    public var parallelism: Int

    public init(memoryKiB: Int, iterations: Int, parallelism: Int) {
        self.memoryKiB = memoryKiB
        self.iterations = iterations
        self.parallelism = parallelism
    }

    public static let `default` = KdfParams(memoryKiB: 1024 * 1024, iterations: 3, parallelism: 1)
    public static let saltSize = 16
}

public enum KeyDerivation {
    private static let sodium = Sodium()

    public static func deriveKey(password: String, salt: Data, params: KdfParams) throws -> Data {
        guard params.parallelism == 1 else { throw XToolCryptoError.unsupportedKdf("Argon2 with \(params.parallelism) lanes") }
        guard salt.count == KdfParams.saltSize else { throw XToolCryptoError.unsupportedKdf("salt length \(salt.count)") }
        // Unicode NFC, UTF-8: "ä" typed in any way gives the same key.
        var pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        defer { sodium.utils.zero(&pw) }
        guard var key = sodium.pwHash.hash(
            outputLength: Aead.keySize,
            passwd: pw,
            salt: Array(salt),
            opsLimit: params.iterations,
            memLimit: params.memoryKiB * 1024,
            alg: .Argon2ID13
        ) else { throw XToolCryptoError.corrupted("Argon2id") }
        defer { sodium.utils.zero(&key) }
        return Data(key)
    }
}
