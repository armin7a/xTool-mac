import AppKit
import XToolCore

/// Cancels a running job at the next chunk.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Moves progress from a worker thread to the main thread, at most ten times a second.
private final class ProgressPump: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let deliver: @MainActor (Int64) -> Void

    init(deliver: @escaping @MainActor (Int64) -> Void) { self.deliver = deliver }

    func report(_ bytes: Int64) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(last) > 0.1 else { lock.unlock(); return }
        last = now
        lock.unlock()
        let deliver = self.deliver
        Task { @MainActor in deliver(bytes) }
    }
}

/// Getting files in and out of the vault, and everything else that takes a while. One job at a time,
/// all of it streaming: a file's size only matters to the disk. The MacBook stays awake while a job runs.
@MainActor
extension AppModel {
    private func runJob(title: String, cancellable: Bool = true, _ work: @escaping @MainActor (CancelToken) async -> Void) {
        guard transfer == nil else {
            showToast("Bitte warte, bis die laufende Übertragung fertig ist.")
            return
        }
        let token = CancelToken()
        cancelToken = token
        transfer = TransferState(title: title, cancellable: cancellable)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: title)
        Task { @MainActor in
            await work(token)
            ProcessInfo.processInfo.endActivity(activity)
            transfer = nil
            cancelToken = nil
            autoLock.touch()
        }
    }

    private func setProgress(detail: String? = nil, done: Int64, total: Int64) {
        guard transfer != nil else { return }
        if let detail { transfer?.detail = detail }
        transfer?.fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    private func report(_ error: Error, title: String) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    // MARK: import

    private struct ImportItem {
        let url: URL
        let isFolder: Bool
        let parent: Int?
        let size: Int64
    }

    /// Encrypts files and folders into the vault. The originals stay untouched.
    func importFiles(_ urls: [URL], into folderId: String?) {
        guard let vault, !urls.isEmpty else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        runJob(title: "Dateien werden verschlüsselt") { [self] token in
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            var plan: [ImportItem] = []
            for url in urls { Self.collect(url, parent: nil, into: &plan) }
            let files = plan.filter { !$0.isFolder }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            do {
                try DiskSpace.ensure(total, at: vault.root)
            } catch {
                report(error, title: "Nicht genug Speicher")
                return
            }

            var folderIds: [Int: String] = [:]
            var imported = 0, failed = 0, fileIndex = 0
            var done: Int64 = 0
            var sinceLastSave: Int64 = 0
            for (i, item) in plan.enumerated() {
                guard !token.isCancelled, self.vault === vault, let drive else { break }
                let parent = item.parent.flatMap { folderIds[$0] } ?? folderId
                if item.isFolder {
                    folderIds[i] = drive.createFolder(in: parent, name: item.url.lastPathComponent).id
                    continue
                }
                fileIndex += 1
                let base = done
                let name = item.url.lastPathComponent
                setProgress(detail: files.count > 1 ? "\(fileIndex) von \(files.count): \(name)" : name, done: base, total: total)
                let pump = ProgressPump { [weak self] bytes in self?.setProgress(done: base + bytes, total: total) }
                let url = item.url
                let result: Result<(id: String, size: Int64, thumb: String?, modified: Date), Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let blob = try vault.importBlob(from: url) { bytes in
                            try token.check()
                            pump.report(bytes)
                        }
                        let thumbData = Thumbnails.make(url: url, size: blob.size)
                        let thumb = thumbData.flatMap { try? vault.writeBlob($0) }
                        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                        return .success((blob.id, blob.size, thumb, modified))
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch result {
                case .success(let file):
                    guard self.vault === vault, let drive = self.drive else {
                        // locked while the last chunk was written: this blob will never be referenced
                        Task.detached { vault.deleteBlob(file.id); vault.deleteBlob(file.thumb) }
                        return
                    }
                    drive.addFile(in: parent, name: name, blobId: file.id, size: file.size, thumbBlobId: file.thumb, modified: file.modified)
                    imported += 1
                    done += item.size
                    sinceLastSave += file.size
                    // a crash loses at most the last few files
                    if imported % 25 == 0 || sinceLastSave > 1 << 30 {
                        sinceLastSave = 0
                        save()
                    }
                case .failure(let error):
                    if error is CancellationError || token.isCancelled { break }
                    failed += 1
                    done += item.size
                }
            }
            guard self.vault === vault else { return }
            save()
            if failed > 0 {
                showToast("\(failed) Datei(en) konnten nicht gelesen werden.", isError: true)
            } else if token.isCancelled {
                showToast("Abgebrochen. \(imported) Datei(en) wurden hinzugefügt.")
            } else if imported > 0 {
                showToast(imported == 1 ? "Datei hinzugefügt" : "\(imported) Dateien hinzugefügt")
            }
        }
    }

    private static func collect(_ url: URL, parent: Int?, into plan: inout [ImportItem]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return }
        if values.isDirectory == true {
            let index = plan.count
            plan.append(ImportItem(url: url, isFolder: true, parent: parent, size: 0))
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                collect(item, parent: index, into: &plan)
            }
        } else {
            plan.append(ImportItem(url: url, isFolder: false, parent: parent, size: Int64(values.fileSize ?? 0)))
        }
    }

    // MARK: export

    private struct ExportItem {
        let node: Node
        let path: [String]   // folders below the destination, and the name
    }

    /// Asks where to, then decrypts the elements there. They stay in the vault.
    func exportWithPanel(_ ids: [String]) {
        guard !ids.isEmpty, let folder = Panels.chooseExportFolder(count: ids.count) else { return }
        exportNodes(ids, to: folder)
    }

    /// Decrypts files and folders to `destination`. Never overwrites: a name that exists gets a number.
    func exportNodes(_ ids: [String], to destination: URL) {
        guard let vault, let drive else { return }
        var plan: [ExportItem] = []
        for id in ids {
            if let node = drive.get(id) { Self.collect(node, path: [], drive: drive, into: &plan) }
        }
        let files = plan.filter { !$0.node.isFolder }
        let total = files.reduce(Int64(0)) { $0 + $1.node.size }
        guard !plan.isEmpty else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        runJob(title: "Dateien werden exportiert") { [self] token in
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do {
                try DiskSpace.ensure(total, at: destination)
            } catch {
                report(error, title: "Nicht genug Speicher")
                return
            }
            let fm = FileManager.default
            var folders: [String: URL] = [:]
            var exported = 0, failed = 0, fileIndex = 0
            var done: Int64 = 0

            /// The folder for a path, created on first use. A folder already there gets a number instead of being merged.
            @MainActor func folderURL(_ path: ArraySlice<String>) throws -> URL {
                guard let last = path.last else { return destination }
                let key = path.joined(separator: "/")
                if let url = folders[key] { return url }
                let url = Self.unusedURL(in: try folderURL(path.dropLast()), name: last)
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                folders[key] = url
                return url
            }

            for item in plan {
                guard !token.isCancelled, self.vault === vault else { break }
                if item.node.isFolder {
                    _ = try? folderURL(item.path[...])
                    continue
                }
                fileIndex += 1
                let base = done
                let name = item.path.last ?? "Datei"
                setProgress(detail: files.count > 1 ? "\(fileIndex) von \(files.count): \(name)" : name, done: base, total: total)
                let pump = ProgressPump { [weak self] bytes in self?.setProgress(done: base + bytes, total: total) }
                let node = item.node
                do {
                    let parent = try folderURL(item.path.dropLast())
                    let target = Self.unusedURL(in: parent, name: name)
                    try await Task.detached(priority: .userInitiated) {
                        if let blob = node.blobId {
                            try vault.exportBlob(blob, to: target) { bytes in
                                try token.check()
                                pump.report(bytes)
                            }
                        } else {
                            guard FileManager.default.createFile(atPath: target.path, contents: Data()) else { throw CocoaError(.fileWriteNoPermission) }
                        }
                        try? FileManager.default.setAttributes([.modificationDate: node.modified], ofItemAtPath: target.path)
                    }.value
                    exported += 1
                } catch is CancellationError {
                    break
                } catch {
                    if token.isCancelled { break }
                    failed += 1
                }
                done += node.size
            }
            if failed > 0 {
                alert = AlertInfo(title: "Export unvollständig",
                                  message: "\(failed) Datei(en) konnten nicht exportiert werden. Sie bleiben im Tresor. \(exported) Datei(en) wurden gespeichert.")
            } else if token.isCancelled {
                showToast("Abgebrochen. \(exported) Datei(en) wurden exportiert.")
            } else {
                showToast(exported == 1 ? "Datei exportiert" : "\(exported) Dateien exportiert")
            }
        }
    }

    private static func collect(_ node: Node, path: [String], drive: Drive, into plan: inout [ExportItem]) {
        let name = safeFileName(node.name)
        plan.append(ExportItem(node: node, path: path + [name]))
        guard node.isFolder else { return }
        for child in drive.children(of: node.id) { collect(child, path: path + [name], drive: drive, into: &plan) }
    }

    /// A name from the index must stay one path component.
    private static func safeFileName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return clean == "." || clean == ".." || clean.isEmpty ? "Unbenannt" : clean
    }

    private static func unusedURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let ns = name as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        var i = 2
        while true {
            let url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            if !fm.fileExists(atPath: url.path) { return url }
            i += 1
        }
    }

    // MARK: copy inside the vault

    /// Deep copy under fresh keys. Streams, so large files don't fill the memory.
    func copyNodes(_ ids: [String], to target: String?) {
        guard let vault, let drive else { return }
        var nodes: [Node] = []
        func walk(_ node: Node) {
            nodes.append(node)
            if node.isFolder { drive.children(of: node.id).forEach(walk) }
        }
        ids.compactMap { drive.get($0) }.forEach(walk)
        let total = nodes.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }

        runJob(title: "Dateien werden kopiert") { [self] token in
            do {
                try DiskSpace.ensure(total, at: vault.root)
            } catch {
                report(error, title: "Nicht genug Speicher")
                return
            }
            var done: Int64 = 0
            var failed = 0

            @MainActor func copy(_ node: Node, into parent: String?) async {
                guard !token.isCancelled, self.vault === vault, let drive = self.drive else { return }
                if node.isFolder {
                    if let parent, drive.isAncestorOrSelf(node.id, of: parent) { return } // not into itself
                    let folder = drive.createFolder(in: parent, name: node.name)
                    for child in drive.children(of: node.id) where child.id != folder.id { await copy(child, into: folder.id) }
                    return
                }
                let base = done
                setProgress(detail: node.name, done: base, total: total)
                let pump = ProgressPump { [weak self] bytes in self?.setProgress(done: base + bytes, total: total) }
                let result: Result<(id: String?, thumb: String?), Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let blob = try node.blobId.map { blob in
                            try vault.copyBlob(blob) { bytes in
                                try token.check()
                                pump.report(bytes)
                            }
                        }
                        let thumb = node.thumbBlobId.flatMap { try? vault.copyBlob($0).id }
                        return .success((blob?.id, thumb))
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch result {
                case .success(let copy):
                    guard self.vault === vault, let drive = self.drive else {
                        Task.detached { vault.deleteBlob(copy.id); vault.deleteBlob(copy.thumb) }
                        return
                    }
                    if let id = copy.id {
                        drive.addFile(in: parent, name: node.name, blobId: id, size: node.size, thumbBlobId: copy.thumb, modified: node.modified)
                    } else {
                        _ = try? drive.addFile(in: parent, name: node.name, content: Data())
                    }
                case .failure(let error):
                    if !(error is CancellationError) { failed += 1 }
                }
                done += node.size
            }

            for node in ids.compactMap({ self.drive?.get($0) }) { await copy(node, into: target) }
            guard self.vault === vault else { return }
            save()
            if failed > 0 { showToast("\(failed) Datei(en) konnten nicht kopiert werden.", isError: true) }
        }
    }

    // MARK: backup

    func createBackup(to url: URL) {
        guard let vault else { return }
        flush()
        runJob(title: "Sicherung wird erstellt", cancellable: false) { [self] _ in
            let total = Self.vaultSize(vault)
            do {
                try DiskSpace.ensure(total, at: url.deletingLastPathComponent())
                let pump = ProgressPump { [weak self] permille in self?.setProgress(done: permille, total: 1000) }
                try await Task.detached(priority: .userInitiated) {
                    vault.waitForWrites()
                    try Backup.create(vault: vault, to: url) { pump.report(Int64($0 * 1000)) }
                }.value
                showToast("Sicherung erstellt")
            } catch {
                report(error, title: "Sicherung fehlgeschlagen")
            }
        }
    }

    private nonisolated static func vaultSize(_ vault: Vault) -> Int64 {
        guard let e = FileManager.default.enumerator(at: vault.root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Checks the password first, then replaces the vault. The old vault stays next to it.
    func restoreBackup(from url: URL, password: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        runJob(title: "Sicherung wird eingespielt", cancellable: false) { [self] _ in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let ok = try await Task.detached(priority: .userInitiated) { try Backup.checkPassword(backup: url, password: password) }.value
                guard ok else {
                    alert = AlertInfo(title: "Falsches Passwort", message: "Mit diesem Passwort lässt sich die Sicherung nicht öffnen. Dein Tresor bleibt unverändert.")
                    return
                }
                lock()
                guard vault == nil else { return } // saving failed, the vault stayed open
                let root = Vault.defaultRoot
                let pump = ProgressPump { [weak self] permille in self?.setProgress(done: permille, total: 1000) }
                let result = try await Task.detached(priority: .userInitiated) {
                    try Backup.restore(backup: url, to: root, password: password) { pump.report(Int64($0 * 1000)) }
                }.value
                state = .locked
                var message = "Melde dich mit dem Passwort der Sicherung an."
                if result.missingFiles > 0 { message += " In der Sicherung fehlt der Inhalt von \(result.missingFiles) Datei(en)." }
                if result.previousVault != nil { message += " Der bisherige Tresor wurde aufbewahrt." }
                alert = AlertInfo(title: "Sicherung eingespielt", message: message)
            } catch {
                report(error, title: "Wiederherstellung fehlgeschlagen")
            }
        }
    }
}
