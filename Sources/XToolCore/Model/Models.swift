import Foundation

// The index as JSON (docs/FORMAT.md): PascalCase keys, enums as numbers, dates as ISO 8601 with offset.
// Unknown keys are ignored, missing keys get defaults. Vaults written by the former Windows version read the same.

public enum Ids {
    public static func new() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

public enum NodeKind: Int, Codable, Hashable { case folder = 0, file = 1 }

public struct Node: Identifiable, Hashable, Codable {
    public var id: String = Ids.new()
    public var parentId: String?
    public var name: String = ""
    public var kind: NodeKind = .file
    public var size: Int64 = 0
    public var blobId: String?
    public var thumbBlobId: String?
    public var created: Date = Date()
    public var modified: Date = Date()
    public var accessed: Date?
    public var deletedAt: Date?
    /// Earlier contents of the file, oldest first (nil when there are none).
    public var versions: [FileVersion]?

    public init(parentId: String?, name: String, kind: NodeKind) {
        self.parentId = parentId
        self.name = name
        self.kind = kind
    }

    public var isFolder: Bool { kind == .folder }
    public var ext: String { isFolder ? "" : (name as NSString).pathExtension.lowercased() }

    enum CodingKeys: String, CodingKey {
        case id = "Id", parentId = "ParentId", name = "Name", kind = "Kind", size = "Size", blobId = "BlobId"
        case thumbBlobId = "ThumbBlobId", created = "Created", modified = "Modified", accessed = "Accessed", deletedAt = "DeletedAt"
        case versions = "Versions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Ids.new()
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .file
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        blobId = try c.decodeIfPresent(String.self, forKey: .blobId)
        thumbBlobId = try c.decodeIfPresent(String.self, forKey: .thumbBlobId)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        accessed = try c.decodeIfPresent(Date.self, forKey: .accessed)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        versions = try c.decodeIfPresent([FileVersion].self, forKey: .versions)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(parentId, forKey: .parentId)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(size, forKey: .size)
        try c.encode(blobId, forKey: .blobId)
        try c.encode(thumbBlobId, forKey: .thumbBlobId)
        try c.encode(created, forKey: .created)
        try c.encode(modified, forKey: .modified)
        try c.encode(accessed, forKey: .accessed)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(versions, forKey: .versions)
    }
}

/// An earlier state of a file, kept as its own encrypted blob.
public struct FileVersion: Hashable, Codable {
    public var blobId: String = ""
    public var size: Int64 = 0
    public var saved: Date = Date()

    public init(blobId: String, size: Int64, saved: Date) {
        self.blobId = blobId
        self.size = size
        self.saved = saved
    }

    enum CodingKeys: String, CodingKey { case blobId = "BlobId", size = "Size", saved = "Saved" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blobId = try c.decodeIfPresent(String.self, forKey: .blobId) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        saved = try c.decodeIfPresent(Date.self, forKey: .saved) ?? Date()
    }
}

public struct Note: Identifiable, Hashable, Codable {
    public var id: String = Ids.new()
    public var title: String = ""
    public var text: String = ""
    public var color: String = "Default"
    public var pinned: Bool = false
    public var created: Date = Date()
    public var modified: Date = Date()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id = "Id", title = "Title", text = "Text", color = "Color", pinned = "Pinned", created = "Created", modified = "Modified"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Ids.new()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "Default"
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
    }
}

public enum Priority: Int, Codable, Hashable, CaseIterable { case none = 0, low = 1, medium = 2, high = 3 }

public struct ChecklistItem: Hashable, Codable, Identifiable {
    public var id = UUID()   // UI only, not stored
    public var text: String = ""
    public var done: Bool = false

    public init(text: String, done: Bool = false) {
        self.text = text
        self.done = done
    }

    enum CodingKeys: String, CodingKey { case text = "Text", done = "Done" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(done, forKey: .done)
    }
}

public struct TaskCard: Identifiable, Hashable, Codable {
    public var id: String = Ids.new()
    public var title: String = ""
    public var description: String = ""
    public var priority: Priority = .none
    public var due: Date?
    public var checklist: [ChecklistItem] = []
    public var linkedNodeId: String?
    public var created: Date = Date()

    public init(title: String) { self.title = title }

    enum CodingKeys: String, CodingKey {
        case id = "Id", title = "Title", description = "Description", priority = "Priority", due = "Due"
        case checklist = "Checklist", linkedNodeId = "LinkedNodeId", created = "Created"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Ids.new()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .none
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
        linkedNodeId = try c.decodeIfPresent(String.self, forKey: .linkedNodeId)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(priority, forKey: .priority)
        try c.encode(due, forKey: .due)
        try c.encode(checklist, forKey: .checklist)
        try c.encode(linkedNodeId, forKey: .linkedNodeId)
        try c.encode(created, forKey: .created)
    }
}

public struct BoardColumn: Identifiable, Hashable, Codable {
    public var id: String = Ids.new()
    public var name: String = ""
    public var isDone: Bool = false
    public var cards: [TaskCard] = []

    public init(name: String, isDone: Bool = false) {
        self.name = name
        self.isDone = isDone
    }

    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", isDone = "IsDone", cards = "Cards" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Ids.new()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        cards = try c.decodeIfPresent([TaskCard].self, forKey: .cards) ?? []
    }
}

public struct Board: Identifiable, Hashable, Codable {
    public var id: String = Ids.new()
    public var name: String = ""
    public var columns: [BoardColumn] = []

    public init(name: String) { self.name = name }

    public static func makeDefault(_ name: String) -> Board {
        var b = Board(name: name)
        b.columns = [BoardColumn(name: "To do"), BoardColumn(name: "In progress"), BoardColumn(name: "Done", isDone: true)]
        return b
    }

    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", columns = "Columns" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Ids.new()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        columns = try c.decodeIfPresent([BoardColumn].self, forKey: .columns) ?? []
    }
}

public struct AppSettings: Hashable, Codable {
    public var theme: String = "System"
    public var autoLockMinutes: Int = 1
    public var gridView: Bool = true
    public var sortBy: String = "Name"
    public var sortDescending: Bool = false
    public var showDetails: Bool = false
    public var lastBoardId: String?
    /// Hide xTool windows from screenshots, recordings and screen sharing.
    public var screenProtection: Bool = true
    /// Spell checking in the Writer runs through macOS, so it is off unless chosen.
    public var spellCheck: Bool = false
    /// Exported photos, PDFs and Office files lose author, device and location data. The vault keeps the originals.
    public var stripMetadata: Bool = true
    /// Which stricter defaults this vault has already been moved to. Missing in older vaults.
    public var defaultsVersion: Int = AppSettings.currentDefaultsVersion
    public static let currentDefaultsVersion = 1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case theme = "Theme", autoLockMinutes = "AutoLockMinutes", gridView = "GridView", sortBy = "SortBy"
        case sortDescending = "SortDescending", showDetails = "ShowDetails", lastBoardId = "LastBoardId"
        case screenProtection = "ScreenProtection", spellCheck = "SpellCheck", defaultsVersion = "DefaultsVersion"
        case stripMetadata = "StripMetadataOnExport"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "System"
        autoLockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? 1
        gridView = try c.decodeIfPresent(Bool.self, forKey: .gridView) ?? true
        sortBy = try c.decodeIfPresent(String.self, forKey: .sortBy) ?? "Name"
        sortDescending = try c.decodeIfPresent(Bool.self, forKey: .sortDescending) ?? false
        showDetails = try c.decodeIfPresent(Bool.self, forKey: .showDetails) ?? false
        lastBoardId = try c.decodeIfPresent(String.self, forKey: .lastBoardId)
        screenProtection = try c.decodeIfPresent(Bool.self, forKey: .screenProtection) ?? true
        spellCheck = try c.decodeIfPresent(Bool.self, forKey: .spellCheck) ?? false
        defaultsVersion = try c.decodeIfPresent(Int.self, forKey: .defaultsVersion) ?? 0
        stripMetadata = try c.decodeIfPresent(Bool.self, forKey: .stripMetadata) ?? true
    }
}

public struct VaultIndex: Codable {
    public var version: Int = 1
    public var nodes: [Node] = []
    public var notes: [Note] = []
    public var boards: [Board] = []
    public var settings = AppSettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case version = "Version", nodes = "Nodes", notes = "Notes", boards = "Boards", settings = "Settings" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        boards = try c.decodeIfPresent([Board].self, forKey: .boards) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

public struct VaultHeader: Codable {
    public var version = 1
    public var kdf = "argon2id"
    public var memoryKiB: Int
    public var iterations: Int
    public var parallelism: Int
    public var salt: String
    public var wrappedKey: String
    public var created = Date()

    public var params: KdfParams { KdfParams(memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism) }

    public init(params: KdfParams, salt: Data, wrappedKey: Data) {
        memoryKiB = params.memoryKiB
        iterations = params.iterations
        parallelism = params.parallelism
        self.salt = salt.base64EncodedString()
        self.wrappedKey = wrappedKey.base64EncodedString()
    }

    enum CodingKeys: String, CodingKey {
        case version = "Version", kdf = "Kdf", memoryKiB = "MemoryKiB", iterations = "Iterations", parallelism = "Parallelism"
        case salt = "Salt", wrappedKey = "WrappedKey", created = "Created"
    }
}

/// JSON coders with .NET-compatible dates.
public enum XJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(DateCoding.format(date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = DateCoding.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date: \(s)")
            }
            return date
        }
        return d
    }
}

/// .NET writes "2026-10-19T03:15:22.1234567+02:00" (local), "…Z" (UTC) or "2026-12-24T00:00:00" (no zone = local).
public enum DateCoding {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    public static func format(_ date: Date) -> String { withFraction.string(from: date) }

    public static func parse(_ raw: String) -> Date? {
        var s = raw
        var fraction = 0.0
        // Split off fractional seconds (any length) and parse them ourselves.
        if let dot = s.firstIndex(of: "."), s.distance(from: s.startIndex, to: dot) == 19 {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            fraction = Double("0" + s[dot..<end]) ?? 0
            s.removeSubrange(dot..<end)
        }
        let hasZone = s.hasSuffix("Z") || (s.count > 19 && (s.dropFirst(19).contains("+") || s.dropFirst(19).contains("-")))
        let base = hasZone ? withoutFraction.date(from: s) : local.date(from: String(s.prefix(19)))
        return base.map { $0.addingTimeInterval(fraction) }
    }
}
