import SwiftUI
import XToolCore

/// Earlier states of a file. Restoring keeps the current state as a version, so it can be undone.
struct VersionsView: View {
    @Environment(AppModel.self) private var model
    let nodeId: String
    let done: () -> Void

    var body: some View {
        let _ = model.revision
        let node = model.drive?.get(nodeId)
        SheetLayout(title: "Versionen von „\(node?.name ?? "")“", width: 480) {
            VStack(alignment: .leading, spacing: 10) {
                Text("xTool behält beim Speichern frühere Stände: höchstens alle 10 Minuten einen, bis zu \(Drive.maxVersions).")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let node {
                    ScrollView {
                        VStack(spacing: 2) {
                            row(title: "Aktueller Stand", date: node.modified, size: node.size, version: nil)
                            let versions = (node.versions ?? []).sorted { $0.saved > $1.saved }
                            ForEach(versions, id: \.blobId) { v in row(title: nil, date: v.saved, size: v.size, version: v) }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        } buttons: {
            Button("Schließen") { done() }.keyboardShortcut(.defaultAction).buttonStyle(.xPrimary)
        }
    }

    private func row(title: String?, date: Date, size: Int64, version: FileVersion?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? friendly(date)).font(.system(size: 13, weight: title != nil ? .medium : .regular))
                Text("\(date.formatted(date: .numeric, time: .shortened)) · \(FileTypes.size(size))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let version {
                Button("Wiederherstellen") { restore(version) }.buttonStyle(.xQuiet)
                IconButton(symbol: "trash", help: "Diese Version endgültig löschen") {
                    model.drive?.deleteVersion(nodeId, version)
                    model.save()
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func restore(_ version: FileVersion) {
        // an open tab of this file must not overwrite the restored content afterwards
        // (closing first lets the tab save its last edits before the older state is put back)
        let open = model.tabs.first { $0.nodeId == nodeId }
        if let open { model.closeTab(open.id) }
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + (open == nil ? 0 : 0.5)) {
            guard let current = model.drive?.get(nodeId)?.versions?.first(where: { $0.blobId == version.blobId }) else { return }
            model.drive?.restoreVersion(nodeId, current)
            model.save()
            model.showToast("Version vom \(version.saved.formatted(date: .numeric, time: .shortened)) wiederhergestellt")
            if open != nil, let node = model.drive?.get(nodeId) { Opener.open(node, model: model) }
        }
    }

    private func friendly(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "Gerade eben" }
        if age < 3600 { return "Vor \(Int(age / 60)) Minuten" }
        if Calendar.current.isDateInToday(date) { return "Heute, \(date.formatted(date: .omitted, time: .shortened)) Uhr" }
        if Calendar.current.isDateInYesterday(date) { return "Gestern, \(date.formatted(date: .omitted, time: .shortened)) Uhr" }
        return date.formatted(date: .complete, time: .omitted)
    }
}
