import Foundation

/// Where a vault lives: on this Mac (inside the app's container) or on a USB stick or other drive,
/// in the folder "xTool Vault" at the top of the drive. The format is the same everywhere.
public struct VaultLocation: Hashable, Identifiable {
    public enum Kind: Hashable { case thisMac, drive }

    public static let folderName = "xTool Vault"

    public let kind: Kind
    /// The vault folder (vault.json, index.bin, blobs/).
    public let root: URL
    /// The drive's mount point, nil on this Mac.
    public let volume: URL?
    public let name: String

    public var id: String { root.path }
    public var exists: Bool { Vault.exists(at: root) }

    public static var thisMac: VaultLocation {
        VaultLocation(kind: .thisMac, root: Vault.defaultRoot, volume: nil, name: "This Mac")
    }

    public static func onDrive(_ volume: URL) -> VaultLocation {
        let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volume.lastPathComponent
        return VaultLocation(kind: .drive, root: volume.appendingPathComponent(folderName, isDirectory: true), volume: volume, name: name)
    }

    /// Writable drives other than the startup disk: USB sticks, external disks, SD cards, disk images.
    public static func drives() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.volumeIsReadOnly != true && v.volumeIsRootFileSystem != true && v.volumeIsBrowsable != false
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// This Mac and every connected drive, with or without a vault on it.
    public static func all() -> [VaultLocation] {
        [.thisMac] + drives().map(onDrive)
    }

    /// The drive a file or app is on, nil for the startup disk.
    public static func drive(containing url: URL) -> URL? {
        guard url.path.hasPrefix("/Volumes/"),
              let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
              volume.path != "/" else { return nil }
        return volume
    }

    /// FAT32 ("MS-DOS") cannot hold files over 4 GB, so large files fail on such sticks.
    public var isFAT32: Bool {
        guard let volume else { return false }
        var info = statfs()
        guard statfs(volume.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "msdos"
    }

    /// Free space on the drive (or this Mac).
    public var freeSpace: Int64? { DiskSpace.available(at: volume ?? root.deletingLastPathComponent()) }
}
