import AppKit
import XToolCore

/// xTool on USB sticks, like a portable vault: the app and the folder "xTool Vault" sit together on the stick.
/// Started from the stick, xTool uses the vault on it. Started from this Mac, it can switch to any stick with a vault.
/// Pulling out the stick locks at once.
enum AppPlace {
    /// Where the app really is. macOS may run an app from a downloaded or copied location through a hidden,
    /// randomized copy ("App Translocation"); this finds the original.
    static var bundleURL: URL {
        let url = Bundle.main.bundleURL
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(lib, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }

    /// The drive xTool was started from, nil when it runs from this Mac.
    static let launchDrive: URL? = VaultLocation.drive(containing: bundleURL)
}

@MainActor
extension AppModel {
    /// Started from a stick: its vault (or a new one there). Otherwise this Mac, unless only a stick has a vault.
    nonisolated static func startLocation() -> VaultLocation {
        if let drive = AppPlace.launchDrive { return .onDrive(drive) }
        let mac = VaultLocation.thisMac
        if mac.exists { return mac }
        let withVault = VaultLocation.drives().map(VaultLocation.onDrive).filter(\.exists)
        return withVault.count == 1 ? withVault[0] : mac
    }

    var startedFromDrive: Bool { location.volume != nil && location.volume?.path == AppPlace.launchDrive?.path }

    /// Switches to another vault. Only while locked.
    func choose(_ place: VaultLocation) {
        guard state != .unlocked else { return }
        location = place
        lockNotice = nil
        state = place.exists ? .locked : .setup
    }

    func watchDrives() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    guard let model = AppModel.current else { return }
                    if name == NSWorkspace.didUnmountNotification { model.driveGone(volume) }
                    model.refreshDrives()
                }
            }
        }
        // Eject from the Finder: lock first, so the drive is free to go
        center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { AppModel.current?.driveGone(volume) }
        }
    }

    private func isCurrent(_ volume: URL?) -> Bool {
        guard let volume, let mine = location.volume else { return false }
        return volume.standardizedFileURL.path == mine.standardizedFileURL.path
    }

    private func driveGone(_ volume: URL?) {
        guard isCurrent(volume), state == .unlocked else { return }
        lock(.automatic)
        lockNotice = "“\(location.name)” was ejected or pulled out, so xTool locked. Changes from the last moment may be missing."
    }

    func refreshDrives() {
        locations = VaultLocation.all()
        // the stick with the vault is gone: show this Mac instead
        if state != .unlocked, location.kind == .drive, !locations.contains(where: { $0.id == location.id }) {
            let notice = lockNotice
            choose(.thisMac)
            lockNotice = notice
        } else if state != .unlocked {
            state = location.exists ? .locked : .setup
        }
    }

    /// Locks, then ejects the stick. When xTool itself runs from that stick, it quits instead,
    /// and the stick is ejected in the Finder.
    func lockAndEject() {
        guard let volume = location.volume else { return }
        lock(.user)
        guard vault == nil else { return } // saving failed, the vault stayed open
        if startedFromDrive {
            NSApp.terminate(nil)
            return
        }
        let name = location.name
        Task {
            do {
                try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }.value
                showToast("You can remove “\(name)” now.")
            } catch {
                alert = AlertInfo(title: "“\(name)” could not be ejected",
                                  message: "xTool is locked. Another app may still be using the drive; close it and eject the drive in the Finder.\n\n\(error.localizedDescription)")
            }
            refreshDrives()
        }
    }

    /// Shows xTool and the stick side by side in the Finder, to drag the app over.
    /// xTool does not copy itself: macOS marks every file a sandboxed app writes as downloaded, and such a copy
    /// would start with a warning on every Mac. A copy made in the Finder starts like the original.
    func showAppForDrive(_ volume: URL) {
        let app = AppPlace.bundleURL
        let name = VaultLocation.onDrive(volume).name
        if VaultLocation.drive(containing: app)?.path == volume.path {
            showToast("xTool is already running from “\(name)”.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([app])
        NSWorkspace.shared.open(volume)
        let hasVault = VaultLocation.onDrive(volume).exists
        alert = AlertInfo(title: "Drag xTool onto “\(name)”",
                          message: "Two Finder windows are open: drag xTool.app from the first onto the stick in the second."
                          + (hasVault
                             ? " Then open xTool.app on the stick to use its vault on any Mac."
                             : " Then open xTool.app on the stick and choose a password: the vault is created on the stick. To take your files along, create a backup first and choose “Restore from a Backup” instead."))
    }
}
