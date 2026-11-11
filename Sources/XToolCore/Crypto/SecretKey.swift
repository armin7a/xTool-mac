import Foundation

/// A key in memory of its own: locked so it isn't written to swap, overwritten when the last user is done.
/// Work in progress keeps it alive through `data`, so locking the vault can never pull it out from under a running job.
final class SecretKey: @unchecked Sendable {
    private let bytes: UnsafeMutableRawPointer
    let count: Int

    init(copying source: Data) {
        count = source.count
        var pointer: UnsafeMutableRawPointer?
        posix_memalign(&pointer, Int(getpagesize()), max(count, 1))
        bytes = pointer!
        mlock(bytes, count) // best effort: without it the key is still wiped, just not guaranteed out of swap
        _ = source.withUnsafeBytes { memcpy(bytes, $0.baseAddress!, count) }
    }

    deinit {
        memset_s(bytes, count, 0, count)
        munlock(bytes, count)
        free(bytes)
    }

    /// The key without a copy. The returned Data keeps this object, and with it the memory, alive.
    var data: Data {
        Data(bytesNoCopy: bytes, count: count, deallocator: .custom { [self] _, _ in withExtendedLifetime(self) {} })
    }
}
