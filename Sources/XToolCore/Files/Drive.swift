import Foundation

/// Folder/file operations on the vault index. Use from the main thread.
public final class Drive {
    public static let trashRetention: TimeInterval = 30 * 24 * 3600
    public let vault: Vault

    public init(vault: Vault) { self.vault = vault }

    private var nodes: [Node] { vault.index.nodes }

    // id → position, so lookups stay instant with many thousands of files. Self-correcting: an entry is
    // checked before use, and the table is rebuilt when nodes were removed or added elsewhere.
    private var positions: [String: Int] = [:]
    private var positionsCount = -1

    private func indexOf(_ id: String) -> Int? {
        let nodes = vault.index.nodes
        if let i = positions[id], i < nodes.count, nodes[i].id == id { return i }
        if positions[id] == nil, positionsCount == nodes.count { return nil }
        positions = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        positionsCount = nodes.count
        return positions[id]
    }

    public func get(_ id: String?) -> Node? {
        guard let id, let i = indexOf(id) else { return nil }
        return vault.index.nodes[i]
    }

    public func children(of parentId: String?) -> [Node] {
        nodes.filter { $0.parentId == parentId && $0.deletedAt == nil }
    }

    public func isDeleted(_ node: Node) -> Bool {
        var cur: Node? = node
        var guardCount = 0
        while let c = cur, guardCount < 512 {
            if c.deletedAt != nil { return true }
            cur = get(c.parentId)
            guardCount += 1
        }
        return false
    }

    /// Folders from root down to (and including) the node.
    public func path(of id: String?) -> [Node] {
        var result: [Node] = []
        var cur = get(id)
        while let c = cur, result.count < 512 {
            result.insert(c, at: 0)
            cur = get(c.parentId)
        }
        return result
    }

    public func isAncestorOrSelf(_ ancestorId: String, of nodeId: String?) -> Bool {
        path(of: nodeId).contains { $0.id == ancestorId }
    }

    public static func cleanName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) })
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    public func uniqueName(in parentId: String?, _ name: String, except: String? = nil) -> String {
        let existing = Set(children(of: parentId).filter { $0.id != except }.map { $0.name.lowercased() })
        if !existing.contains(name.lowercased()) { return name }
        let ns = name as NSString
        var ext = ns.pathExtension
        var stem = ns.deletingPathExtension
        if stem.isEmpty { stem = name; ext = "" }
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !existing.contains(candidate.lowercased()) { return candidate }
            i += 1
        }
    }

    @discardableResult
    public func createFolder(in parentId: String?, name: String) -> Node {
        let node = Node(parentId: parentId, name: uniqueName(in: parentId, Drive.cleanName(name)), kind: .folder)
        vault.index.nodes.append(node)
        return node
    }

    @discardableResult
    public func addFile(in parentId: String?, name: String, blobId: String, size: Int64, thumbBlobId: String? = nil, modified: Date = Date()) -> Node {
        var node = Node(parentId: parentId, name: uniqueName(in: parentId, Drive.cleanName(name)), kind: .file)
        node.blobId = blobId
        node.size = size
        node.thumbBlobId = thumbBlobId
        node.modified = modified
        vault.index.nodes.append(node)
        return node
    }

    @discardableResult
    public func addFile(in parentId: String?, name: String, content: Data) throws -> Node {
        let blob = try vault.writeBlob(content)
        return addFile(in: parentId, name: name, blobId: blob, size: Int64(content.count))
    }

    public func readContent(_ node: Node) throws -> Data {
        guard let blob = node.blobId else { return Data() }
        return try vault.readBlob(blob)
    }

    /// At most this many earlier versions are kept per file .
    public static let maxVersions = 25
    /// An earlier state is only kept if it is this much newer than the last kept version.
    public static let versionInterval: TimeInterval = 10 * 60

    /// Replaces a file's content; the previous content becomes a version (see `versionInterval`).
    public func updateContent(_ id: String, _ content: Data) throws {
        guard let i = indexOf(id) else { return }
        let old = vault.index.nodes[i].blobId
        let oldSize = vault.index.nodes[i].size
        let oldSaved = vault.index.nodes[i].modified
        let blob = try vault.writeBlob(content)
        vault.index.nodes[i].blobId = blob
        vault.index.nodes[i].size = Int64(content.count)
        vault.index.nodes[i].modified = Date()
        guard let old else { return }
        let newestKept = vault.index.nodes[i].versions?.last?.saved ?? .distantPast
        if oldSize > 0 && oldSaved.timeIntervalSince(newestKept) >= Drive.versionInterval {
            keepVersion(i, FileVersion(blobId: old, size: oldSize, saved: oldSaved))
        } else {
            vault.retireBlob(old)
        }
    }

    private func keepVersion(_ i: Int, _ version: FileVersion) {
        var versions = vault.index.nodes[i].versions ?? []
        versions.append(version)
        versions.sort { $0.saved < $1.saved }
        while versions.count > Drive.maxVersions {
            vault.retireBlob(versions.removeFirst().blobId)
        }
        vault.index.nodes[i].versions = versions
    }

    public func readVersion(_ version: FileVersion) throws -> Data { try vault.readBlob(version.blobId) }

    /// Makes an earlier version current; the current content is kept as a version, so this can be undone.
    public func restoreVersion(_ id: String, _ version: FileVersion) {
        guard let i = indexOf(id), let k = vault.index.nodes[i].versions?.firstIndex(of: version) else { return }
        vault.index.nodes[i].versions?.remove(at: k)
        let node = vault.index.nodes[i]
        if let current = node.blobId { keepVersion(i, FileVersion(blobId: current, size: node.size, saved: node.modified)) }
        vault.index.nodes[i].blobId = version.blobId
        vault.index.nodes[i].size = version.size
        vault.index.nodes[i].modified = Date()
    }

    public func deleteVersion(_ id: String, _ version: FileVersion) {
        guard let i = indexOf(id), let k = vault.index.nodes[i].versions?.firstIndex(of: version) else { return }
        vault.index.nodes[i].versions?.remove(at: k)
        vault.retireBlob(version.blobId)
        if vault.index.nodes[i].versions?.isEmpty == true { vault.index.nodes[i].versions = nil }
    }

    public func setThumbnail(_ id: String, _ data: Data?) throws {
        guard let i = indexOf(id) else { return }
        let old = vault.index.nodes[i].thumbBlobId
        vault.index.nodes[i].thumbBlobId = try data.map { try vault.writeBlob($0) }
        vault.retireBlob(old)
    }

    public func touch(_ id: String) {
        if let i = indexOf(id) { vault.index.nodes[i].accessed = Date() }
    }

    public func rename(_ id: String, to newName: String) {
        guard let i = indexOf(id) else { return }
        let parent = vault.index.nodes[i].parentId
        vault.index.nodes[i].name = uniqueName(in: parent, Drive.cleanName(newName), except: id)
        vault.index.nodes[i].modified = Date()
    }

    /// Returns how many nodes were moved (a folder can't move into itself).
    @discardableResult
    public func move(_ ids: [String], to target: String?) -> Int {
        var moved = 0
        for id in ids {
            guard let i = indexOf(id) else { continue }
            let node = vault.index.nodes[i]
            if node.parentId == target { continue }
            if node.isFolder, let target, isAncestorOrSelf(node.id, of: target) { continue }
            vault.index.nodes[i].name = uniqueName(in: target, node.name, except: id)
            vault.index.nodes[i].parentId = target
            moved += 1
        }
        return moved
    }

    // MARK: trash

    public func trash(_ ids: [String]) {
        let now = Date()
        for id in ids { if let i = indexOf(id) { vault.index.nodes[i].deletedAt = now } }
    }

    public func trashItems() -> [Node] {
        nodes.filter { n in
            guard n.deletedAt != nil else { return false }
            if let p = get(n.parentId) { return !isDeleted(p) }
            return true
        }
    }

    public func restore(_ ids: [String]) {
        for id in ids {
            guard let i = indexOf(id) else { continue }
            vault.index.nodes[i].deletedAt = nil
            if let pid = vault.index.nodes[i].parentId, get(pid).map(isDeleted) ?? true {
                vault.index.nodes[i].parentId = nil
            }
            let n = vault.index.nodes[i]
            vault.index.nodes[i].name = uniqueName(in: n.parentId, n.name, except: n.id)
        }
    }

    public func deletePermanently(_ ids: [String]) {
        for id in ids { deleteRecursive(id) }
    }

    private func deleteRecursive(_ id: String) {
        for child in nodes.filter({ $0.parentId == id }) { deleteRecursive(child.id) }
        guard let node = get(id) else { return }
        vault.retireBlob(node.blobId)
        vault.retireBlob(node.thumbBlobId)
        for v in node.versions ?? [] { vault.retireBlob(v.blobId) }
        vault.index.nodes.removeAll { $0.id == id }
        for b in vault.index.boards.indices {
            for c in vault.index.boards[b].columns.indices {
                for k in vault.index.boards[b].columns[c].cards.indices where vault.index.boards[b].columns[c].cards[k].linkedNodeId == id {
                    vault.index.boards[b].columns[c].cards[k].linkedNodeId = nil
                }
            }
        }
    }

    public func emptyTrash() { deletePermanently(trashItems().map(\.id)) }

    @discardableResult
    public func purgeTrash(now: Date = Date()) -> Int {
        let old = trashItems().filter { now.timeIntervalSince($0.deletedAt!) > Drive.trashRetention }
        deletePermanently(old.map(\.id))
        return old.count
    }

    // MARK: queries

    public func search(_ query: String) -> [Node] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return nodes.filter { $0.name.localizedCaseInsensitiveContains(q) && !isDeleted($0) }
    }

    public func recent(_ count: Int) -> [Node] {
        Array(allFiles().sorted { ($0.accessed ?? $0.modified) > ($1.accessed ?? $1.modified) }.prefix(count))
    }

    public func allFiles() -> [Node] { nodes.filter { !$0.isFolder && !isDeleted($0) } }

    public func totalSize() -> Int64 { allFiles().reduce(0) { $0 + $1.size } }

    public func folderSize(_ folderId: String) -> Int64 {
        allFiles().filter { isAncestorOrSelf(folderId, of: $0.parentId) }.reduce(0) { $0 + $1.size }
    }
}
