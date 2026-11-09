import SwiftUI
import XToolCore

/// Kanban board – columns with cards, drag & drop between and within columns.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var editing: CardRef?
    @State private var renameBoard = false
    @State private var newBoard = false
    @State private var nameInput = ""
    @State private var newColumn = false

    struct CardRef: Identifiable { let card: TaskCard; let columnId: String; var id: String { card.id } }

    private var boards: [Board] { model.vault?.index.boards ?? [] }

    private var boardIndex: Int? {
        guard let vault = model.vault, !vault.index.boards.isEmpty else { return nil }
        return vault.index.boards.firstIndex { $0.id == vault.index.settings.lastBoardId } ?? 0
    }

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 0) {
            if let bi = boardIndex, let vault = model.vault {
                let board = vault.index.boards[bi]
                PageHeader(title: board.name) { summary(board) }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(board.columns) { col in
                            ColumnView(column: col, boardIndex: bi, filter: filter, onEdit: { card in editing = CardRef(card: card, columnId: col.id) })
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            } else {
                EmptyState(symbol: "checklist", title: "Kein Board", message: "Lege oben ein neues Board an.")
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Suchen")
        .toolbar {
            ToolbarItemGroup {
                Button { nameInput = "Neue Spalte"; newColumn = true } label: { Label("Spalte", systemImage: "rectangle.split.3x1") }
                    .help("Neue Spalte")
                Menu {
                    if boards.count > 1 {
                        Picker("Board", selection: Binding(get: { boardIndex.map { boards[$0].id } ?? "" }, set: { id in
                            model.vault?.index.settings.lastBoardId = id
                            model.save()
                        })) {
                            ForEach(boards) { b in Text(b.name).tag(b.id) }
                        }
                        .pickerStyle(.inline)
                    }
                    Button("Neues Board …") { nameInput = "Neues Board"; newBoard = true }
                    Button("Board umbenennen …") { nameInput = boardIndex.map { boards[$0].name } ?? ""; renameBoard = true }
                    if boards.count > 1 {
                        Button("Board löschen", role: .destructive) {
                            if let bi = boardIndex { model.vault?.index.boards.remove(at: bi); model.vault?.index.settings.lastBoardId = nil; model.save() }
                        }
                    }
                } label: { Label("Board", systemImage: "rectangle.stack") }
                .menuIndicator(.hidden)
                .tint(.primary)
                .help("Boards")
            }
        }
        .alert("Neues Board", isPresented: $newBoard) {
            TextField("Name", text: $nameInput)
            Button("Erstellen") {
                let b = Board.makeDefault(nameInput.isEmpty ? "Board" : nameInput)
                model.vault?.index.boards.append(b)
                model.vault?.index.settings.lastBoardId = b.id
                model.save()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Board umbenennen", isPresented: $renameBoard) {
            TextField("Name", text: $nameInput)
            Button("Umbenennen") { if let bi = boardIndex { model.vault?.index.boards[bi].name = nameInput; model.save() } }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Neue Spalte", isPresented: $newColumn) {
            TextField("Name", text: $nameInput)
            Button("Hinzufügen") { if let bi = boardIndex { model.vault?.index.boards[bi].columns.append(BoardColumn(name: nameInput)); model.save() } }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(item: $editing) { ref in
            if let bi = boardIndex {
                CardEditor(card: ref.card, columns: boards[bi].columns, columnId: ref.columnId) { result in
                    editing = nil
                    apply(result, boardIndex: bi, originalColumn: ref.columnId)
                }
            }
        }
    }

    private func summary(_ board: Board) -> some View {
        let cards = board.columns.flatMap { col in col.cards.map { (col, $0) } }
        let open = cards.filter { !$0.0.isDone }.count
        let due = cards.filter { !$0.0.isDone && ($0.1.due.map { Calendar.current.startOfDay(for: $0) <= Calendar.current.startOfDay(for: Date()) } ?? false) }.count
        let done = cards.filter { $0.0.isDone }.count
        return HStack(spacing: 12) {
            chip("\(open) offen", .secondary)
            if due > 0 { chip("\(due) fällig", XColor.warning) }
            chip("\(done) erledigt", .secondary)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color)
    }

    private func apply(_ result: CardResult, boardIndex bi: Int, originalColumn: String) {
        guard let vault = model.vault else { return }
        var board = vault.index.boards[bi]
        guard let ci = board.columns.firstIndex(where: { $0.id == originalColumn }) else { return }
        switch result {
        case .cancel: return
        case .delete(let id):
            board.columns[ci].cards.removeAll { $0.id == id }
        case .save(let card, let columnId):
            if columnId == originalColumn, let k = board.columns[ci].cards.firstIndex(where: { $0.id == card.id }) {
                board.columns[ci].cards[k] = card
            } else {
                board.columns[ci].cards.removeAll { $0.id == card.id }
                if let target = board.columns.firstIndex(where: { $0.id == columnId }) { board.columns[target].cards.append(card) }
            }
        }
        vault.index.boards[bi] = board
        model.save()
    }
}

/// Moves a card (drag & drop): removes it from its column and inserts it at `index` in the target column.
@MainActor
func moveCard(_ cardId: String, to columnId: String, at index: Int?, boardIndex bi: Int, model: AppModel) -> Bool {
    guard let vault = model.vault, bi < vault.index.boards.count else { return false }
    var board = vault.index.boards[bi]
    guard let from = board.columns.firstIndex(where: { $0.cards.contains { $0.id == cardId } }),
          let to = board.columns.firstIndex(where: { $0.id == columnId }),
          let k = board.columns[from].cards.firstIndex(where: { $0.id == cardId }) else { return false }
    let card = board.columns[from].cards.remove(at: k)
    var insertAt = index ?? board.columns[to].cards.count
    if from == to, k < insertAt { insertAt -= 1 }
    insertAt = max(0, min(insertAt, board.columns[to].cards.count))
    board.columns[to].cards.insert(card, at: insertAt)
    withAnimation(.spring(duration: 0.3)) {
        vault.index.boards[bi] = board
        model.save()
    }
    return true
}

private struct ColumnView: View {
    @Environment(AppModel.self) private var model
    let column: BoardColumn
    let boardIndex: Int
    let filter: String
    let onEdit: (TaskCard) -> Void
    @State private var quickAdd = ""
    @State private var targeted = false
    @State private var renaming = false
    @State private var nameInput = ""

    var body: some View {
        let cards = column.cards.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(column.name).font(.system(size: 12, weight: .semibold))
                Text("\(column.cards.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button("Umbenennen …") { nameInput = column.name; renaming = true }
                    Toggle("Zählt als erledigt", isOn: Binding(get: { column.isDone }, set: { v in updateColumn { $0.isDone = v } }))
                    Button("Nach links") { shiftColumn(-1) }
                    Button("Nach rechts") { shiftColumn(1) }
                    Divider()
                    Button("Spalte löschen", role: .destructive) {
                        model.vault?.index.boards[boardIndex].columns.removeAll { $0.id == column.id }
                        model.save()
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .tint(.secondary)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                        CardView(card: card, done: column.isDone)
                            .onTapGesture { onEdit(card) }
                            .draggable("card:" + card.id)
                            .dropDestination(for: String.self) { items, _ in
                                guard let item = items.first, item.hasPrefix("card:") else { return false }
                                let realIndex = column.cards.firstIndex { $0.id == card.id } ?? i
                                return moveCard(String(item.dropFirst(5)), to: column.id, at: realIndex, boardIndex: boardIndex, model: model)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(2)
            }
            TextField("+ Karte hinzufügen", text: $quickAdd)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .onSubmit {
                    let t = quickAdd.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    withAnimation(.spring(duration: 0.3)) {
                        updateColumn { $0.cards.append(TaskCard(title: t)) }
                    }
                    quickAdd = ""
                }
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? XColor.accent.opacity(0.08) : XColor.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix("card:") else { return false }
            return moveCard(String(item.dropFirst(5)), to: column.id, at: nil, boardIndex: boardIndex, model: model)
        } isTargeted: { targeted = $0 }
        .alert("Spalte umbenennen", isPresented: $renaming) {
            TextField("Name", text: $nameInput)
            Button("Umbenennen") { updateColumn { $0.name = nameInput } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func updateColumn(_ body: (inout BoardColumn) -> Void) {
        guard let vault = model.vault, let ci = vault.index.boards[boardIndex].columns.firstIndex(where: { $0.id == column.id }) else { return }
        body(&vault.index.boards[boardIndex].columns[ci])
        model.save()
    }

    private func shiftColumn(_ delta: Int) {
        guard let vault = model.vault, let ci = vault.index.boards[boardIndex].columns.firstIndex(where: { $0.id == column.id }) else { return }
        let target = ci + delta
        guard target >= 0, target < vault.index.boards[boardIndex].columns.count else { return }
        vault.index.boards[boardIndex].columns.swapAt(ci, target)
        model.save()
    }
}

private struct CardView: View {
    @Environment(AppModel.self) private var model
    let card: TaskCard
    let done: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(priorityColor(card.priority)).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title).font(.system(size: 12)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                if !card.description.isEmpty {
                    Text(card.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if card.priority != .none { tag("flag.fill", ["", "Niedrig", "Mittel", "Hoch"][card.priority.rawValue], priorityColor(card.priority)) }
                    if let due = card.due {
                        let today = Calendar.current.startOfDay(for: Date())
                        let day = Calendar.current.startOfDay(for: due)
                        let overdue = !done && day < today
                        let isToday = !done && day == today
                        tag("calendar", overdue ? "Überfällig · \(due.formatted(.dateTime.day().month()))" : isToday ? "Heute" : due.formatted(.dateTime.day().month()),
                            overdue ? .red : isToday ? .orange : .secondary)
                    }
                    if !card.checklist.isEmpty {
                        let n = card.checklist.filter(\.done).count
                        tag("checklist", "\(n)/\(card.checklist.count)", n == card.checklist.count ? XColor.accent : .secondary)
                    }
                    if let id = card.linkedNodeId, let node = model.drive?.get(id) {
                        tag("paperclip", String(node.name.prefix(16)), .secondary)
                    }
                }
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.small + 2, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: XRadius.small + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.small + 2, style: .continuous).strokeBorder(XColor.line))
        .contentShape(RoundedRectangle(cornerRadius: XRadius.small + 2, style: .continuous))
    }

    private func tag(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10)).foregroundStyle(color).labelStyle(.titleAndIcon)
    }
}

func priorityColor(_ p: Priority) -> Color {
    switch p {
    case .high: return Color(red: 0.90, green: 0.28, blue: 0.30)
    case .medium: return Color(red: 0.96, green: 0.65, blue: 0.14)
    case .low: return Color(red: 0.23, green: 0.51, blue: 0.96)
    case .none: return .clear
    }
}

enum CardResult { case save(TaskCard, String), delete(String), cancel }

struct CardEditor: View {
    @Environment(AppModel.self) private var model
    @State var card: TaskCard
    let columns: [BoardColumn]
    @State var columnId: String
    let done: (CardResult) -> Void
    @State private var hasDue = false
    @State private var dueDate = Date()
    @State private var newItem = ""
    @State private var pickingFile = false

    init(card: TaskCard, columns: [BoardColumn], columnId: String, done: @escaping (CardResult) -> Void) {
        _card = State(initialValue: card)
        self.columns = columns
        _columnId = State(initialValue: columnId)
        self.done = done
        _hasDue = State(initialValue: card.due != nil)
        _dueDate = State(initialValue: card.due ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Titel", text: $card.title).font(.system(size: 15, weight: .semibold)).textFieldStyle(.plain)
            TextField("Beschreibung", text: $card.description, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            Picker("Priorität", selection: $card.priority) {
                Text("Keine").tag(Priority.none)
                Text("Niedrig").tag(Priority.low)
                Text("Mittel").tag(Priority.medium)
                Text("Hoch").tag(Priority.high)
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Fällig am", isOn: $hasDue)
                DatePicker("", selection: $dueDate, displayedComponents: .date).labelsHidden().disabled(!hasDue)
                Spacer()
                Picker("Spalte", selection: $columnId) {
                    ForEach(columns) { c in Text(c.name).tag(c.id) }
                }
                .frame(width: 200)
            }
            Text("Checkliste").font(.system(size: 12, weight: .medium))
            ForEach($card.checklist) { $item in
                HStack {
                    Toggle("", isOn: $item.done).labelsHidden()
                    TextField("", text: $item.text).textFieldStyle(.plain)
                    Button { card.checklist.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
            TextField("Punkt hinzufügen (Enter)", text: $newItem)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let t = newItem.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { card.checklist.append(ChecklistItem(text: t)) }
                    newItem = ""
                }
            Text("Verknüpfte Datei").font(.system(size: 12, weight: .medium))
            HStack {
                if let id = card.linkedNodeId, let node = model.drive?.get(id) {
                    Button { Opener.open(node, model: model) } label: {
                        Label(node.name, systemImage: FileTypes.symbol(FileTypes.category(node)))
                    }
                    Button { card.linkedNodeId = nil } label: { Image(systemName: "xmark") }.help("Verknüpfung entfernen")
                } else {
                    Button { pickingFile = true } label: { Label("Datei verknüpfen", systemImage: "paperclip") }
                }
            }
            HStack {
                IconButton(symbol: "trash", help: "Karte löschen") { done(.delete(card.id)) }
                Spacer()
                Button("Abbrechen") { done(.cancel) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                Button("Speichern") {
                    card.due = hasDue ? dueDate : nil
                    card.checklist = card.checklist.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    if card.title.trimmingCharacters(in: .whitespaces).isEmpty { card.title = "Ohne Titel" }
                    done(.save(card, columnId))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.xPrimary)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 540)
        .sheet(isPresented: $pickingFile) {
            VaultFileList { node in
                pickingFile = false
                if let node { card.linkedNodeId = node.id }
            }
        }
    }
}

struct VaultFileList: View {
    @Environment(AppModel.self) private var model
    let done: (Node?) -> Void
    @State private var search = ""
    @State private var selected: String?

    var body: some View {
        let files = (model.drive?.allFiles() ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Datei verknüpfen").font(.system(size: 15, weight: .semibold))
            TextField("Suchen", text: $search).textFieldStyle(.roundedBorder)
            List(files, selection: $selected) { node in
                Label(node.name, systemImage: FileTypes.symbol(FileTypes.category(node))).tag(node.id)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                Button("Verknüpfen") { done(selected.flatMap { model.drive?.get($0) }) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.xPrimary).disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
