import CryptoKit
import Foundation

/// Chunked AES-256-GCM file format. Everything streams one chunk at a time, so file size is limited
/// by the disk, not by memory.
///
///     "XTB1" | salt(32) | chunkSize(int32 LE) | records…
///     record: final(1) | length(int32 LE) | ciphertext | tag(16)
///
/// Each blob has its own key (HKDF of the master key and a random salt), so the nonce can be the chunk
/// index. The AAD binds blob id, chunk index and final flag: swapped, reordered or cut-off data is detected.
public enum BlobCipher {
    public static let defaultChunkSize = 1024 * 1024
    private static let magic = Data("XTB1".utf8)
    private static let saltSize = 32
    private static let headerSize = 4 + saltSize + 4
    private static let maxChunkSize = 64 * 1024 * 1024

    /// Returns up to `count` bytes; empty at the end of the input.
    public typealias Reader = (_ count: Int) throws -> Data
    public typealias Writer = (Data) throws -> Void
    /// Called after every chunk with the plaintext bytes so far. Throw to cancel.
    public typealias Progress = (Int64) throws -> Void

    // MARK: streaming

    /// Returns the number of plaintext bytes.
    @discardableResult
    public static func encrypt(read: Reader, write: Writer, masterKey: Data, blobId: String,
                               chunkSize: Int = defaultChunkSize, progress: Progress? = nil) throws -> Int64 {
        let salt = Aead.randomBytes(saltSize)
        let key = blobKey(masterKey: masterKey, salt: salt, blobId: blobId)
        try write(header(salt: salt, chunkSize: chunkSize))

        var current = try readFull(read, chunkSize)
        var index: Int64 = 0
        var total: Int64 = 0
        var done = false
        while !done {
            try autoreleasepool {
                let next = current.count == chunkSize ? try readFull(read, chunkSize) : Data()
                let isFinal = next.isEmpty
                try write(try sealRecord(current, key: key, blobId: blobId, index: index, isFinal: isFinal))
                total += Int64(current.count)
                try progress?(total)
                current = next
                index += 1
                done = isFinal
            }
        }
        return total
    }

    /// Hands over each decrypted chunk only after it was authenticated. Returns the number of plaintext bytes.
    @discardableResult
    public static func decrypt(read: Reader, write: Writer, masterKey: Data, blobId: String, progress: Progress? = nil) throws -> Int64 {
        let (key, chunkSize) = try openHeader(read: read, masterKey: masterKey, blobId: blobId)
        var index: Int64 = 0
        var total: Int64 = 0
        var done = false
        while !done {
            try autoreleasepool {
                let (plain, isFinal) = try openRecord(read: read, key: key, blobId: blobId, index: index, chunkSize: chunkSize)
                try write(plain)
                total += Int64(plain.count)
                try progress?(total)
                index += 1
                done = isFinal
            }
        }
        guard try read(1).isEmpty else { throw XToolCryptoError.corrupted("fremde Daten") }
        return total
    }

    /// Re-encrypts under a new blob id and salt without ever holding more than one chunk in plaintext.
    @discardableResult
    public static func reencrypt(read: Reader, write: Writer, masterKey: Data, fromBlobId: String, toBlobId: String, progress: Progress? = nil) throws -> Int64 {
        let (oldKey, chunkSize) = try openHeader(read: read, masterKey: masterKey, blobId: fromBlobId)
        let salt = Aead.randomBytes(saltSize)
        let newKey = blobKey(masterKey: masterKey, salt: salt, blobId: toBlobId)
        try write(header(salt: salt, chunkSize: chunkSize))
        var index: Int64 = 0
        var total: Int64 = 0
        var done = false
        while !done {
            try autoreleasepool {
                let (plain, isFinal) = try openRecord(read: read, key: oldKey, blobId: fromBlobId, index: index, chunkSize: chunkSize)
                try write(try sealRecord(plain, key: newKey, blobId: toBlobId, index: index, isFinal: isFinal))
                total += Int64(plain.count)
                try progress?(total)
                index += 1
                done = isFinal
            }
        }
        return total
    }

    /// Decrypts only the first chunk, for recognising a file type without reading all of it.
    public static func firstChunk(read: Reader, masterKey: Data, blobId: String) throws -> (data: Data, isWholeFile: Bool) {
        let (key, chunkSize) = try openHeader(read: read, masterKey: masterKey, blobId: blobId)
        let (plain, isFinal) = try openRecord(read: read, key: key, blobId: blobId, index: 0, chunkSize: chunkSize)
        return (plain, isFinal)
    }

    /// Plaintext size from the record headers, without decrypting. Not authenticated: informational only.
    public static func plaintextSize(of handle: FileHandle) throws -> Int64 {
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: headerSize), head.count == headerSize else { throw XToolCryptoError.corrupted("Header") }
        var total: Int64 = 0
        var position = UInt64(headerSize)
        while true {
            guard let rec = try handle.read(upToCount: 5), rec.count == 5 else { throw XToolCryptoError.corrupted("unvollständig") }
            let bytes = [UInt8](rec)
            let length = Int(int32(bytes, 1))
            guard length >= 0 else { throw XToolCryptoError.corrupted("Länge") }
            total += Int64(length)
            position += UInt64(5 + length + Aead.tagSize)
            if bytes[0] == 1 { return total }
            try handle.seek(toOffset: position)
        }
    }

    // MARK: in memory (small data: documents, thumbnails)

    public static func encrypt(_ plaintext: Data, masterKey: Data, blobId: String, chunkSize: Int = defaultChunkSize) throws -> Data {
        var out = Data()
        out.reserveCapacity(plaintext.count + plaintext.count / chunkSize * 21 + 64)
        var offset = plaintext.startIndex
        try encrypt(read: { count in
            let end = min(offset + count, plaintext.endIndex)
            defer { offset = end }
            return plaintext.subdata(in: offset..<end)
        }, write: { out.append($0) }, masterKey: masterKey, blobId: blobId, chunkSize: chunkSize)
        return out
    }

    public static func decrypt(_ data: Data, masterKey: Data, blobId: String) throws -> Data {
        var out = Data()
        var offset = data.startIndex
        try decrypt(read: { count in
            let end = min(offset + count, data.endIndex)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }, write: { out.append($0) }, masterKey: masterKey, blobId: blobId)
        return out
    }

    // MARK: pieces

    private static func header(salt: Data, chunkSize: Int) -> Data {
        var out = magic
        out.append(salt)
        out.appendInt32(Int32(chunkSize))
        return out
    }

    private static func openHeader(read: Reader, masterKey: Data, blobId: String) throws -> (SymmetricKey, Int) {
        let head = [UInt8](try readFull(read, headerSize))
        guard head.count == headerSize, Data(head[0..<4]) == magic else { throw XToolCryptoError.corrupted("Header") }
        let salt = Data(head[4..<(4 + saltSize)])
        let chunkSize = Int(int32(head, 4 + saltSize))
        guard chunkSize > 0, chunkSize <= maxChunkSize else { throw XToolCryptoError.corrupted("Blockgröße") }
        return (blobKey(masterKey: masterKey, salt: salt, blobId: blobId), chunkSize)
    }

    private static func sealRecord(_ plain: Data, key: SymmetricKey, blobId: String, index: Int64, isFinal: Bool) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(index), authenticating: aad(blobId, index, isFinal))
        var record = Data(capacity: 5 + plain.count + Aead.tagSize)
        record.append(isFinal ? 1 : 0)
        record.appendInt32(Int32(plain.count))
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }

    private static func openRecord(read: Reader, key: SymmetricKey, blobId: String, index: Int64, chunkSize: Int) throws -> (Data, Bool) {
        let rec = [UInt8](try readFull(read, 5))
        guard rec.count == 5 else { throw XToolCryptoError.corrupted("unvollständig") }
        let isFinal = rec[0] == 1
        let length = Int(int32(rec, 1))
        guard length >= 0, length <= chunkSize else { throw XToolCryptoError.corrupted("unvollständig") }
        let body = try readFull(read, length + Aead.tagSize)
        guard body.count == length + Aead.tagSize else { throw XToolCryptoError.corrupted("unvollständig") }
        let split = body.startIndex + length
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce(index), ciphertext: body[body.startIndex..<split], tag: body[split..<body.endIndex])
            return (try AES.GCM.open(box, using: key, authenticating: aad(blobId, index, isFinal)), isFinal)
        } catch {
            throw XToolCryptoError.wrongKey
        }
    }

    private static func readFull(_ read: Reader, _ count: Int) throws -> Data {
        var data = try read(count)
        while data.count < count {
            let more = try read(count - data.count)
            if more.isEmpty { break }
            data.append(more)
        }
        return data
    }

    private static func blobKey(masterKey: Data, salt: Data, blobId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: salt,
            info: Data("xtool-blob-v1:\(blobId)".utf8),
            outputByteCount: 32
        )
    }

    private static func nonce(_ index: Int64) throws -> AES.GCM.Nonce {
        var n = Data(count: 12)
        var le = index.littleEndian
        withUnsafeBytes(of: &le) { n.replaceSubrange(0..<8, with: $0) }
        return try AES.GCM.Nonce(data: n)
    }

    private static func aad(_ blobId: String, _ index: Int64, _ isFinal: Bool) -> Data {
        var d = Data(blobId.utf8)
        var le = index.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        d.append(isFinal ? 1 : 0)
        return d
    }

    private static func int32(_ b: [UInt8], _ at: Int) -> Int32 {
        let b0 = UInt32(b[at]), b1 = UInt32(b[at + 1]) << 8
        let b2 = UInt32(b[at + 2]) << 16, b3 = UInt32(b[at + 3]) << 24
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }
}

extension Data {
    mutating func appendInt32(_ v: Int32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
