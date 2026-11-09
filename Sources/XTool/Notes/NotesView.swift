import SwiftUI
import XToolCore

enum NoteColors {
    static let palette: [(key: String, color: Color)] = [
        ("Default", .clear),
        ("Yellow", Color(red: 0.96, green: 0.77, blue: 0.09)),
        ("Orange", Color(red: 0.94, green: 0.54, blue: 0.24)),
        ("Red", Color(red: 0.90, green: 0.28, blue: 0.30)),
        ("Pink", Color(red: 0.88, green: 0.36, blue: 0.72)),
        ("Purple", Color(red: 0.55, green: 0.36, blue: 0.96)),
        ("Blue", Color(red: 0.23, green: 0.51, blue: 0.96)),
        ("Teal", Color(red: 0.08, green: 0.72, blue: 0.65)),
        ("Green", Color(red: 0.13, green: 0.77, blue: 0.37)),
    ]

    static func tint(_ key: String) -> AnyShapeStyle {
        guard let c = palette.first(where: { $0.key == key })?.color, key != "Default" else {
            return AnyShapeStyle(XColor.surface)
        }
        return AnyShapeStyle(c.opacity(0.22))
    }
}

struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var editing: Note?
    @State private var isNew = false

    var body: some View {
        let _ = model.revision
        let notes = (model.vault?.index.notes ?? [])
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }
            .sorted { $0.modified > $1.modified }
        let pinned = notes.filter(\.pinned), others = notes.filter { !$0.pinned }

        VStack(spacing: 0) {
            PageHeader(title: AppSection.notes.title) {
                IconButton(symbol: "square.and.pencil", help: "Neue Notiz") { newNote() }
            }
            if notes.isEmpty {
                if search.isEmpty {
                    EmptyState(symbol: "note.text", title: "Noch keine Notizen", message: "Halte Gedanken, Listen und Ideen fest.") {
                        Button("Neue Notiz") { newNote() }.buttonStyle(.xPrimary)
                    }
                } else {
                    EmptyState(symbol: "magnifyingglass", title: "Nichts gefunden", message: "Für „\(search)“ gibt es keine Notiz.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !pinned.isEmpty { cards(pinned) }
                        if !pinned.isEmpty && !others.isEmpty { Rectangle().fill(XColor.line).frame(height: 1).padding(.vertical, 6) }
                        if !others.isEmpty { cards(others) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Suchen")
        .sheet(item: $editing) { note in
            NoteEditor(note: note, isNew: isNew) { result in
                editing = nil
                guard let vault = model.vault else { return }
                switch result {
                case .save(let n):
                    if n.title.isEmpty && n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isNew { return }
                    if let i = vault.index.notes.firstIndex(where: { $0.id == n.id }) { vault.index.notes[i] = n } else { vault.index.notes.append(n) }
                    model.save()
                case .delete(let id):
                    vault.index.notes.removeAll { $0.id == id }
                    model.save()
                case .cancel: break
                }
            }
        }
        .onAppear { if model.pendingNewNote { model.pendingNewNote = false; newNote() } }
    }

    private func newNote() {
        isNew = true
        editing = Note()
    }

    private func cards(_ notes: [Note]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        if !note.title.isEmpty { Text(note.title).font(.system(size: 13, weight: .medium)) }
                        Spacer()
                        Button { togglePin(note) } label: { Image(systemName: note.pinned ? "pin.fill" : "pin").font(.system(size: 11)).foregroundStyle(note.pinned ? XColor.accent : Color.secondary) }
                            .buttonStyle(.plain)
                            .help(note.pinned ? "Lösen" : "Anheften")
                    }
                    Text(note.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(10)
                    Text(FileTypes.date(note.modified)).font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoteColors.tint(note.color), in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous).strokeBorder(XColor.line))
                .contentShape(RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
                .onTapGesture { isNew = false; editing = note }
            }
        }
    }

    private func togglePin(_ note: Note) {
        guard let vault = model.vault, let i = vault.index.notes.firstIndex(where: { $0.id == note.id }) else { return }
        vault.index.notes[i].pinned.toggle()
        model.save()
    }
}

enum NoteResult { case save(Note), delete(String), cancel }

struct NoteEditor: View {
    @State var note: Note
    let isNew: Bool
    let done: (NoteResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Titel", text: $note.title).font(.system(size: 15, weight: .semibold)).textFieldStyle(.plain)
            PrivateTextEditor(text: $note.text)
                .frame(minHeight: 240)
            HStack(spacing: 8) {
                ForEach(NoteColors.palette, id: \.key) { item in
                    Circle()
                        .fill(item.key == "Default" ? XColor.surface : item.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(note.color == item.key ? Color.primary : XColor.line, lineWidth: note.color == item.key ? 1.5 : 1))
                        .onTapGesture { note.color = item.key }
                }
            }
            HStack {
                if !isNew {
                    IconButton(symbol: "trash", help: "Notiz löschen") { done(.delete(note.id)) }
                }
                Spacer()
                Button("Abbrechen") { done(.cancel) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                Button("Speichern") {
                    note.modified = Date()
                    note.title = note.title.trimmingCharacters(in: .whitespaces)
                    done(.save(note))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.xPrimary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(NoteColors.tint(note.color))
    }
}
