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
        SheetLayout(title: "Versions of “\(node?.name ?? "")”", width: 480) {
            VStack(alignment: .leading, spacing: 10) {
                Text("xTool keeps earlier versions when you save: at most one every 10 minutes, up to \(Drive.maxVersions).")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let node {
                    ScrollView {
                        VStack(spacing: 2) {
                            row(title: "Current version", date: node.modified, size: node.size, version: nil)
                            let versions = (node.versions ?? []).sorted { $0.saved > $1.saved }
                            ForEach(versions, id: \.blobId) { v in row(title: nil, date: v.saved, size: v.size, version: v) }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        } buttons: {
            Button("Close") { done() }.keyboardShortcut(.defaultAction).buttonStyle(.xPrimary)
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
                Button("Restore") { restore(version) }.buttonStyle(.xQuiet)
                IconButton(symbol: "trash", help: "Delete this version permanently") {
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
            model.showToast("Restored the version from \(version.saved.formatted(date: .numeric, time: .shortened))")
            if open != nil, let node = model.drive?.get(nodeId) { Opener.open(node, model: model) }
        }
    }

    private func friendly(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "Just now" }
        if age < 3600 { return Int(age / 60) == 1 ? "1 minute ago" : "\(Int(age / 60)) minutes ago" }
        if Calendar.current.isDateInToday(date) { return "Today, \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(date: .complete, time: .omitted)
    }
}
