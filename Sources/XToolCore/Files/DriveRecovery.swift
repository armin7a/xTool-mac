import Foundation

extension Drive {
    /// Repairs what a failed index write left behind (xTool for Mac 1.1/1.2 deleted the previous content before the
    /// index was on disk): a document whose content is missing gets the newest matching unreferenced content back,
    /// other lost documents are put into the folder "Recovered". Returns how many were recovered.
    /// Reads only the start of each unreferenced blob, so large leftovers don't slow down unlocking.
    @discardableResult
    public func recoverLostContent() -> Int {
        var referenced = Set<String>()
        for n in vault.index.nodes {
            if let b = n.blobId { referenced.insert(b) }
            if let t = n.thumbBlobId { referenced.insert(t) }
            for v in n.versions ?? [] { referenced.insert(v.blobId) }
        }
        let orphans = vault.allBlobIds().filter { !referenced.contains($0) }
        guard !orphans.isEmpty else { return 0 }

        // documents only (thumbnails and images are not edited, so never lost)
        var found: [(id: String, kind: String, size: Int64, date: Date)] = []
        for id in orphans {
            guard let size = try? vault.blobPlaintextSize(id), let kind = documentKind(ofBlob: id, size: size) else { continue }
            found.append((id, kind, size, vault.blobModificationDate(id) ?? Date()))
        }
        guard !found.isEmpty else { return 0 }
        found.sort { $0.date > $1.date }

        var recovered = 0
        var used = Set<String>()
        // 1. files whose content is gone get the newest lost content of the same type
        let broken = vault.index.nodes.indices.filter {
            let n = vault.index.nodes[$0]
            return !n.isFolder && n.blobId != nil && !vault.blobExists(n.blobId!)
        }.sorted { vault.index.nodes[$0].modified > vault.index.nodes[$1].modified }
        for i in broken {
            let kind = Drive.kind(ofExtension: vault.index.nodes[i].ext)
            // only when it is unambiguous (one broken file, one lost content of that type); otherwise the user picks from the folder
            let sameKindBroken = broken.filter { Drive.kind(ofExtension: vault.index.nodes[$0].ext) == kind }.count
            let candidates = found.filter { $0.kind == kind && !used.contains($0.id) }
            guard sameKindBroken == 1, candidates.count == 1, let match = candidates.first else { continue }
            used.insert(match.id)
            vault.index.nodes[i].blobId = match.id
            vault.index.nodes[i].size = match.size
            vault.index.nodes[i].modified = match.date
            recovered += 1
        }
        // 2. everything else (e.g. a new document whose first save was lost) goes into a folder
        let rest = found.filter { !used.contains($0.id) }
        if !rest.isEmpty {
            let folder = children(of: nil).first { $0.isFolder && $0.name == "Recovered" } ?? createFolder(in: nil, name: "Recovered")
            for (k, item) in rest.enumerated() {
                addFile(in: folder.id, name: "Recovered \(k + 1).\(item.kind)", blobId: item.id, size: item.size, modified: item.date)
                recovered += 1
            }
        }
        return recovered
    }

    private func documentKind(ofBlob id: String, size: Int64) -> String? {
        guard let start = try? vault.readBlobStart(id) else { return nil }
        if let kind = Drive.binaryDocumentKind(start.data) { return kind }
        // plain text has no signature: it has to be read whole, so only short files qualify
        guard size > 0, size < 20_000_000 else { return nil }
        let whole = start.isWholeFile ? start.data : (try? vault.readBlob(id))
        guard let whole, !whole.contains(0), String(data: whole, encoding: .utf8) != nil else { return nil }
        return "txt"
    }

    /// "docx", "xlsx", "pptx" or "pdf" from the first bytes – nil for images, thumbnails and unknown data.
    static func binaryDocumentKind(_ data: Data) -> String? {
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let head = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
            if head.contains("word/") { return "docx" }
            if head.contains("xl/") { return "xlsx" }
            if head.contains("ppt/") { return "pptx" }
        }
        return nil
    }

    static func kind(ofExtension ext: String) -> String {
        switch ext {
        case "docx", "pdf", "xlsx", "pptx": return ext
        default: return "txt"
        }
    }
}
