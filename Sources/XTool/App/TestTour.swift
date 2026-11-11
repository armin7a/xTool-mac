#if DEBUG
import AppKit
import PDFKit
import SwiftUI
import XToolCore

/// Development only: walks through every screen and saves a picture of each, against a test vault
/// (see Scripts/run_dev.sh). Not part of the release build.
@MainActor
enum TestTour {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { env["XTOOL_TEST_TOUR"] == "1" }
    private static var password: String? { env["XTOOL_TEST_PASSWORD"] }
    private static var folder: String? { env["XTOOL_TEST_OUT"] }

    private static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// A real screen picture of the window (materials and the sidebar included). Needs the Screen Recording
    /// permission for the terminal; falls back to drawing the window, which leaves translucent areas empty.
    private static func snap(_ name: String) {
        print("TOUR \(name)"); fflush(stdout)
        guard let folder, let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        let path = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png").path
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: path) { return }
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// A bare binary doesn't come to the front by itself.
    private static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
    }

    static func unlockIfRequested(_ model: AppModel) async {
        guard enabled, model.state == .locked else { return }
        activate()
        await wait(2)
        snap("01-login")
        if let password { _ = try? await model.unlock(password: password) }
    }

    /// The setup screen; then a vault is really created with a suggested password and default key strength.
    static func showSetup(_ model: AppModel) async {
        guard enabled else { return }
        activate()
        await wait(2)
        snap("00-setup")
        let password = PasswordGenerator.passphrase()
        print("INFO password acceptable: \(PasswordPolicy.evaluate(password).isAcceptable)")
        do { try await model.createVault(password: password) } catch { print("FAIL create: \(error)") }
    }

    private static func waitForTransfer(_ model: AppModel) async {
        await wait(0.2)
        while model.transfer != nil { await wait(0.2) }
    }

    /// Types past the end of a page, the way a user does, and looks at what happened.
    private static func pagingCheck(_ model: AppModel) async {
        model.openTab(DocTab(id: "new-paging", kind: .writer, title: "Seiten", writer: WriterRequest(nodeId: nil, folderId: nil, template: "blank")))
        await wait(2)
        guard let controller = WriterController.lastCreated, let tv = controller.textView,
              let lm = tv.layoutManager, let container = tv.textContainer as? PageTextContainer else { print("FAIL paging setup"); return }
        controller.page.pageNumbers = true
        controller.page.footer = "Footer"
        controller.page.header = "Header"
        controller.applyPage()
        await wait(1.5)
        print("INFO empty document pages: \(tv.pageCount), size: \(Int(tv.frame.width))×\(Int(tv.frame.height))")
        snap("25-leeres-a4")
        print("INFO header in pdf of the empty sheet: \(PDFDocument(data: tv.pdfData())?.page(at: 0)?.string ?? "nil")")

        var n = 0
        while tv.pageCount < 2 && n < 500 {
            n += 1
            tv.insertText("Zeile \(n): Dies ist ein normaler Absatz, wie er beim Schreiben entsteht.\n", replacementRange: tv.selectedRange())
        }
        print("INFO second page after \(n) lines, caret on page \(tv.currentPage) of \(tv.pageCount), status \(controller.pageInfo)")
        tv.insertText("Einfach weitergeschrieben.\n", replacementRange: tv.selectedRange())
        while tv.pageCount < 3 && n < 1000 {
            n += 1
            tv.insertText("Zeile \(n): Noch ein Absatz, damit auch die dritte Seite entsteht.\n", replacementRange: tv.selectedRange())
        }
        // a table across the page end, an image-free worst case
        tv.insertText(DocTemplates.table(["Pos.", "Text", "Preis"], (1...24).map { ["\($0)", "Tabellenzeile \($0)", "10,00 €"] }, widths: [1, 4, 1]), replacementRange: tv.selectedRange())
        tv.insertText("Nach der Tabelle.\n", replacementRange: tv.selectedRange())
        await wait(0.5)
        lm.ensureLayout(for: container)

        // nothing may lie in the space between two sheets
        var outside = 0
        var glyph = 0
        while glyph < lm.numberOfGlyphs {
            var range = NSRange()
            let rect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
            let top = floor(rect.minY / container.pageStride) * container.pageStride
            if rect.maxY > top + container.pageContentHeight + 0.5 { outside += 1 }
            glyph = max(NSMaxRange(range), glyph + 1)
        }
        print("INFO pages: \(tv.pageCount), lines outside the text area: \(outside)")

        // what the context menu offers, and what the clipboard gets
        tv.setSelectedRange(NSRange(location: 0, length: 8))
        if let window = tv.window, let event = NSEvent.mouseEvent(with: .rightMouseDown, location: tv.convert(NSPoint(x: 100, y: 100), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), let menu = tv.menu(for: event) {
            func titles(_ m: NSMenu, _ depth: Int) -> [String] { m.items.flatMap { i -> [String] in i.isSeparatorItem ? [] : [String(repeating: ">", count: depth) + i.title] + (i.submenu.map { titles($0, depth + 1) } ?? []) } }
            print("INFO menu: \(titles(menu, 0).joined(separator: " | "))")
        }
        // overwrites the real clipboard, so only on request
        if env["XTOOL_TEST_CLIPBOARD"] == "1" {
            tv.setSelectedRange(NSRange(location: 0, length: 8))
            let before = NSPasteboard.general.changeCount
            tv.copy(nil)
            let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
            print("INFO copied: changed \(NSPasteboard.general.changeCount != before), text ok \(NSPasteboard.general.string(forType: .string)?.hasPrefix("Zeile") == true), concealed \(types.contains("org.nspasteboard.ConcealedType"))")
            ClipboardGuard.shared.clearIfOurs()
            print("INFO clipboard after lock: \(NSPasteboard.general.string(forType: .string) == nil ? "empty" : "NOT EMPTY")")
        }
        if #available(macOS 15.0, *) { print("INFO writing tools off: \(tv.writingToolsBehavior == .none), spelling off: \(!tv.isContinuousSpellCheckingEnabled), restorable: \(tv.window?.isRestorable == true)") }
        print("INFO services for this text: \(tv.validRequestor(forSendType: .string, returnType: nil) == nil ? "none" : "PRESENT")")

        // scroll to the end of page 1, where the break can be seen
        let breakY = container.pageStride - 200
        tv.scroll(NSPoint(x: 0, y: breakY))
        await wait(0.8)
        snap("26-seitenumbruch")
        tv.scrollRangeToVisible(tv.selectedRange())
        await wait(0.5)
        snap("27-ende")

        let pdf = controller.pdfData()
        let doc = PDFDocument(data: pdf)
        let pageSize = doc?.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        print("INFO pdf pages: \(doc?.pageCount ?? -1) (editor \(tv.pageCount)), size \(Int(pageSize.width))×\(Int(pageSize.height)), footer on page 2: \(doc?.page(at: 1)?.string?.contains("Page 2 of") == true), first page ends with line: \(doc?.page(at: 0)?.string?.contains("Zeile \(n > 3 ? 3 : 1)") == true)")
        if let folder, let pdfData = doc?.dataRepresentation() {
            try? pdfData.write(to: URL(fileURLWithPath: folder).appendingPathComponent("paging.pdf"))
        }

        // at the very end of a full page the insertion point moves on to a new sheet, and back
        let pagesBefore = tv.pageCount
        var filler = 0
        tv.setSelectedRange(NSRange(location: tv.textStorage?.length ?? 0, length: 0))
        while tv.pageCount == max(pagesBefore, tv.currentPage), filler < 200 {
            filler += 1
            tv.insertText("Bis zum Seitenende.\n", replacementRange: tv.selectedRange())
        }
        print("INFO typed to the next sheet: page \(tv.currentPage) of \(tv.pageCount) (status \(controller.pageInfo))")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        print("INFO caret back at the start: page \(tv.currentPage) of \(tv.pageCount)")

        // saved and opened again: same sheets
        let pages = tv.pageCount
        controller.save(model: model, silent: true)
        await wait(0.5)
        let saved = controller.nodeId
        model.closeTab("new-paging")
        await wait(1)
        if let node = model.drive?.get(saved) {
            Opener.open(node, model: model)
            await wait(2)
            let reopened = WriterController.lastCreated?.textView
            print("INFO reopened: \(reopened?.pageCount ?? -1) pages (saved with \(pages))")
            snap("28-wieder-geoeffnet")
            model.closeTab(node.id)
            await wait(1)
        }
    }

    /// Upload, copy and export through the same code the buttons use, with a real file, compared byte by byte.
    private static func transferCheck(_ model: AppModel) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-tour-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = dir.appendingPathComponent("Ordner")
        let outbox = dir.appendingPathComponent("Export")
        try? FileManager.default.createDirectory(at: inbox.appendingPathComponent("Unterordner"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        var bytes = Data(count: 1 << 20)
        bytes.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 31) } }
        let big = inbox.appendingPathComponent("Film.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: big) {
            for _ in 0..<400 { try? h.write(contentsOf: bytes) }
            try? h.close()
        }
        try? Data("Hallo".utf8).write(to: inbox.appendingPathComponent("Unterordner/klein.txt"))

        model.importFiles([inbox], into: nil)
        await wait(0.3)
        snap("24-upload-laeuft")
        await waitForTransfer(model)
        guard let drive = model.drive, let folder = drive.children(of: nil).first(where: { $0.name == "Ordner" }) else { print("FAIL import"); return }
        let film = drive.children(of: folder.id).first { $0.name == "Film.mov" }
        print("INFO imported size ok: \(film?.size == 400 << 20)")

        model.copyNodes([folder.id], to: nil)
        await waitForTransfer(model)
        print("INFO copied: \(drive.children(of: nil).contains { $0.name == "Ordner (2)" })")

        model.exportNodes([folder.id], to: outbox)
        await waitForTransfer(model)
        let exported = outbox.appendingPathComponent("Ordner/Film.mov")
        let same = FileManager.default.contentsEqual(atPath: exported.path, andPath: big.path)
        let small = try? String(contentsOf: outbox.appendingPathComponent("Ordner/Unterordner/klein.txt"), encoding: .utf8)
        print("INFO export identical: \(same), small file: \(small == "Hallo")")

        // a name that exists is never overwritten
        model.exportNodes([folder.id], to: outbox)
        await waitForTransfer(model)
        print("INFO second export kept apart: \(FileManager.default.fileExists(atPath: outbox.appendingPathComponent("Ordner (2)/Film.mov").path))")

        // a new master key: the window is blocked meanwhile, afterwards everything is still there and identical
        if let password, let vault = model.vault {
            let header = try? Data(contentsOf: vault.headerURL)
            model.renewMasterKey(password: password)
            await wait(0.6)
            snap("32-neuer-schluessel")
            print("INFO renewing blocks the window: \(model.renewingKey)")
            await waitForTransfer(model)
            print("INFO new key: \(model.alert?.title ?? "no message")")
            model.alert = nil
            let changed = (try? Data(contentsOf: vault.headerURL)) != header
            let again = outbox.appendingPathComponent("after-new-key")
            try? FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
            model.exportNodes([folder.id], to: again)
            await waitForTransfer(model)
            let identical = FileManager.default.contentsEqual(atPath: again.appendingPathComponent("Ordner/Film.mov").path, andPath: big.path)
            let staging = FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("rekey").path)
            let stray = Set(vault.allBlobIds()) != Set(vault.referencedBlobIds())
            print("INFO after new key: key file changed \(changed), unlocked \(model.state == .unlocked), export identical \(identical), staging left \(staging), stray blobs \(stray)")
        }

        // locking in the middle of an upload: stops cleanly, the half-written blob disappears
        let before = model.vault?.allBlobIds().count ?? 0
        let vault = model.vault
        let name = "Film 2.mov"
        try? FileManager.default.copyItem(at: big, to: dir.appendingPathComponent(name))
        model.importFiles([dir.appendingPathComponent(name)], into: nil)
        await wait(0.15)
        model.lock(.automatic)
        await waitForTransfer(model)
        await wait(0.5)
        print("INFO locked mid-upload, state locked: \(model.state == .locked), notice: \(model.lockNotice != nil), no new blob: \((vault?.allBlobIds().count ?? -1) == before)")
        await wait(0.5)
        snap("31-gesperrt-mit-hinweis")
    }

    static func run(model: AppModel) async {
        guard enabled else { return }
        activate()
        model.settings.autoLockMinutes = 0 // nobody touches the mouse during the tour
        if let theme = env["XTOOL_TEST_THEME"] {
            model.settings.theme = theme
            Theme.apply(theme)
        }
        await wait(2.5)
        snap("02-dateien-kacheln")
        model.settings.gridView = false
        await wait(1.5)
        snap("03-dateien-liste")
        model.settings.gridView = true
        if let any = model.drive?.children(of: nil).first {
            model.selection = [any.id]
            await wait(1)
            snap("04-auswahl")
            model.selection = []
        }
        for (i, section) in [AppSection.recent, .notes, .todo, .trash, .settings].enumerated() {
            model.show(section)
            await wait(1.5)
            snap("1\(i)-\(section.rawValue)")
        }
        model.show(.drive)
        model.openTab(DocTab(id: "new-tour", kind: .writer, title: "Invoice", writer: WriterRequest(nodeId: nil, folderId: nil, template: "invoice")))
        await wait(3)
        snap("20-writer")
        await pagingCheck(model)
        model.closeTab("new-tour")
        await wait(1)
        if let txt = model.drive?.allFiles().first(where: { $0.ext == "txt" }) {
            Opener.open(txt, model: model)
            await wait(1.5)
            snap("21-text")
            model.activeTabId = nil
        }
        if let other = model.drive?.allFiles().first(where: { FileTypes.previewLimit(FileTypes.category($0)) == nil }) {
            Opener.open(other, model: model)
            await wait(1.5)
            snap("22-keine-vorschau")
            model.activeTabId = nil
        }
        model.transfer = TransferState(title: "Encrypting files", detail: "3 of 12: Film.mov", fraction: 0.42)
        await wait(1)
        snap("23-fortschritt")
        model.transfer = nil
        await transferCheck(model)
        if model.isUnlocked { model.lock() }
        await wait(1.5)
        snap("30-gesperrt")
        print("TOUR done"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
#endif
