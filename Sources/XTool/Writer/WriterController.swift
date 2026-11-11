import AppKit
import Observation
import XToolCore

/// Formatting + persistence for one Writer tab. Documents are .docx (readable by Word).
/// Text is stored in real points (11 pt body text); the editor view is magnified ×1.33 for a comfortable size on screen.
@MainActor
@Observable
final class WriterController {
    static let creator = "xTool"

    var name: String
    var nodeId: String?
    var folderId: String?
    var tabId = ""
    var dirty = false
    var ours = true
    var stats = ""
    var pageInfo = ""
    var page = PageSetup()
    var imageSelected = false
    var headings: [(range: NSRange, level: Int, text: String)] = []
    var painterArmed = false
    /// New document from a template: its file is created as soon as the editor is ready.
    @ObservationIgnored var createOnOpen = false
    /// Kept strongly: the tab saves on close, after SwiftUI already removed the editor view.
    @ObservationIgnored var textView: PageTextView?
    /// Owns the text system of the editor. Goes away with this controller, so no decrypted text stays in memory.
    @ObservationIgnored var textStorage: NSTextStorage?
    @ObservationIgnored var initialText: NSAttributedString
    @ObservationIgnored private var painter: [NSAttributedString.Key: Any]?

    init(name: String, folderId: String?, text: NSAttributedString, nodeId: String? = nil, ours: Bool = true, page: PageSetup = PageSetup()) {
        self.name = name
        self.folderId = folderId
        self.nodeId = nodeId
        self.ours = ours
        self.page = page
        initialText = text
        #if DEBUG
        WriterController.lastCreated = self
        #endif
    }

    #if DEBUG
    /// For the development tour only.
    @ObservationIgnored static weak var lastCreated: WriterController?
    #endif

    // MARK: load / save

    static func load(docx data: Data) throws -> (NSAttributedString, Bool, PageSetup) {
        let page = DocxPage.read(data)
        // Documents saved by xTool 1.1/1.2 for Mac could be unreadable for macOS itself (the header/footer patch
        // damaged the zip). Re-pack them, and if needed leave out the header/footer parts – the text is kept.
        var lastError: Error?
        for candidate in [Optional(data), DocxPage.repaired(data, withoutExtras: false), DocxPage.repaired(data, withoutExtras: true)] {
            guard let candidate else { continue }
            do {
                let (text, author) = try parse(candidate)
                return (text, author == creator, page)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileReadCorruptFile)
    }

    private static func parse(_ data: Data) throws -> (NSAttributedString, String?) {
        var attrs: NSDictionary?
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: &attrs)
        return (text, attrs?[NSAttributedString.DocumentAttributeKey.author] as? String)
    }

    enum WriterError: LocalizedError {
        case editorClosed
        var errorDescription: String? { "The editor is no longer open." }
    }

    func docxData() throws -> Data {
        // Without the editor there is nothing to save – never write an empty file over the document.
        guard let storage = textView?.textStorage else { throw WriterError.editorClosed }
        let raw = try storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
            .author: WriterController.creator,
            .paperSize: page.paperSize,
            .leftMargin: PageSetup.pt(page.left), .rightMargin: PageSetup.pt(page.right),
            .topMargin: PageSetup.pt(page.top), .bottomMargin: PageSetup.pt(page.bottom),
        ])
        let patched = DocxPage.apply(raw, page)
        // Only keep the header/footer patch if macOS can read the result back; otherwise save the plain document.
        if patched != raw, (try? WriterController.parse(patched)) == nil { return raw }
        return patched
    }

    @discardableResult
    func save(model: AppModel, silent: Bool = false) -> Bool {
        guard let drive = model.drive else { return false }
        do {
            let data = try docxData()
            if let id = nodeId, ours, let node = drive.get(id), !drive.isDeleted(node) {
                try drive.updateContent(id, data)
            } else {
                let folder = folderId.flatMap { drive.get($0) }.flatMap { drive.isDeleted($0) ? nil : $0.id }
                let node = try drive.addFile(in: folder, name: name + ".docx", content: data)
                nodeId = node.id
                name = (node.name as NSString).deletingPathExtension
                ours = true
            }
            if let id = nodeId { drive.touch(id) }
            model.save()
            dirty = false
            model.updateTab(tabId, title: name, nodeId: nodeId, dirty: false)
            if !silent { model.showToast("Document saved") }
            return true
        } catch {
            model.showToast("Saving failed: \(error.localizedDescription)")
            return false
        }
    }

    func markDirty(_ model: AppModel) {
        if !dirty {
            dirty = true
            model.updateTab(tabId, dirty: true)
        }
    }

    // MARK: PDF (real text, header/footer, page numbers)

    func pdfData() -> Data {
        guard let storage = textView?.textStorage else { return Data() }
        // the same sheets as on screen, on a copy, so the editor's selection and spelling marks stay out
        let (printView, printStorage) = PageTextView.make(page: page)
        printView.appearance = NSAppearance(named: .aqua)
        printStorage.setAttributedString(storage)
        printView.fitToPages()
        return withExtendedLifetime(printStorage) { printView.pdfData() }
    }

    // MARK: stats & navigation

    func updateStats() {
        let s = textView?.string ?? ""
        let words = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        stats = "\(words) words · \(s.filter { !$0.isNewline }.count) characters · encrypted in xTool"
        updateHeadings()
        updatePageInfo()
    }

    /// "Seite 2 von 5" for the status bar.
    func updatePageInfo() {
        guard let tv = textView else { return }
        pageInfo = "Page \(tv.currentPage) of \(tv.pageCount)"
    }

    private func updateHeadings() {
        guard let storage = textView?.textStorage else { return }
        var result: [(range: NSRange, level: Int, text: String)] = []
        let ns = storage.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { text, range, _, _ in
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty, range.length > 0,
                  let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
            let level = !bold ? 0 : font.pointSize >= 19 ? 1 : font.pointSize >= 15 ? 2 : font.pointSize >= 12.5 ? 3 : 0
            if level > 0, font.pointSize < 25 { result.append((range: range, level: level, text: text)) }
        }
        headings = result
    }

    func jump(to range: NSRange) {
        guard let tv = textView else { return }
        tv.setSelectedRange(NSRange(location: range.location, length: 0))
        tv.scrollRangeToVisible(range)
        tv.window?.makeFirstResponder(tv)
    }

    func insertTableOfContents() {
        updateHeadings()
        guard !headings.isEmpty, let tv = textView else { return }
        let result = NSMutableAttributedString(string: "Contents" + "\n", attributes: [.font: DocStyle.h2.font, .foregroundColor: DocStyle.h2.color])
        for h in headings {
            let p = NSMutableParagraphStyle()
            p.headIndent = CGFloat(h.level - 1) * 18
            p.firstLineHeadIndent = p.headIndent
            p.paragraphSpacing = 3
            let font = h.level == 1 ? DocStyle.normal.font.bold : DocStyle.normal.font
            result.append(NSAttributedString(string: h.text + "\n", attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: p]))
        }
        tv.insertText(result, replacementRange: tv.selectedRange())
    }

    // MARK: formatting helpers

    private var selection: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    private func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let tv = textView, let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        tv.didChangeText()
    }

    private func transformFont(_ f: (NSFont) -> NSFont) {
        guard let tv = textView else { return }
        let range = selection
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? DocStyle.normal.font
            tv.typingAttributes[.font] = f(font)
            return
        }
        edit(range) { storage in
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                storage.addAttribute(.font, value: f(value as? NSFont ?? DocStyle.normal.font), range: sub)
            }
        }
    }

    private func selectionHas(_ trait: NSFontTraitMask) -> Bool {
        guard let tv = textView else { return false }
        let range = selection
        if range.length == 0 {
            return (tv.typingAttributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(trait) } ?? false
        }
        var all = true
        tv.textStorage?.enumerateAttribute(.font, in: range) { value, _, stop in
            if let f = value as? NSFont, !NSFontManager.shared.traits(of: f).contains(trait) { all = false; stop.pointee = true }
        }
        return all
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        let remove = selectionHas(trait)
        transformFont { remove ? NSFontManager.shared.convert($0, toNotHaveTrait: trait) : NSFontManager.shared.convert($0, toHaveTrait: trait) }
    }

    func setFontFamily(_ family: String) { transformFont { NSFontManager.shared.convert($0, toFamily: family) } }
    func setFontSize(_ pt: CGFloat) { transformFont { NSFontManager.shared.convert($0, toSize: pt) } }
    func growFont(_ delta: CGFloat) { transformFont { NSFontManager.shared.convert($0, toSize: max(6, $0.pointSize + delta)) } }

    func toggleAttribute(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let range = selection
        if range.length == 0 {
            let on = (tv.typingAttributes[key] as? Int ?? 0) != 0
            tv.typingAttributes[key] = on ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        var on = true
        tv.textStorage?.enumerateAttribute(key, in: range) { value, _, _ in if (value as? Int ?? 0) == 0 { on = false } }
        edit(range) { storage in
            if on { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
    }

    func setColor(_ color: NSColor?, key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let range = selection
        if range.length == 0 {
            tv.typingAttributes[key] = color
            return
        }
        edit(range) { storage in
            if let color { storage.addAttribute(key, value: color, range: range) } else { storage.removeAttribute(key, range: range) }
        }
    }

    func raiseText() { textView?.superscript(nil) }
    func lowerText() { textView?.subscript(nil) }
    func baselineText() { textView?.unscript(nil) }

    func changeCase(_ mode: Int) {
        guard let tv = textView, selection.length > 0 else { return }
        switch mode {
        case 0: tv.uppercaseWord(nil)
        case 1: tv.lowercaseWord(nil)
        default: tv.capitalizeWord(nil)
        }
    }

    // format painter: copy formatting, apply it to the next selection
    func armPainter() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let at = min(selection.location, max(0, storage.length - 1))
        let attrs = storage.length > 0 ? storage.attributes(at: at, effectiveRange: nil) : tv.typingAttributes
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .superscript, .baselineOffset]
        painter = attrs.filter { keys.contains($0.key) }
        painterArmed = true
    }

    func applyPainterIfArmed() {
        guard painterArmed, let painter, selection.length > 0, NSEvent.pressedMouseButtons == 0 else { return }
        let range = selection
        edit(range) { storage in
            for key in [NSAttributedString.Key.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .superscript, .baselineOffset] {
                storage.removeAttribute(key, range: range)
            }
            storage.addAttributes(painter, range: range)
        }
        painterArmed = false
        self.painter = nil
    }

    func clearFormatting() {
        let range = selection
        guard range.length > 0 else { return }
        edit(range) { storage in storage.setAttributes([.font: DocStyle.normal.font, .foregroundColor: NSColor.black], range: range) }
    }

    // MARK: paragraphs

    private func paragraphRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        return (tv.string as NSString).paragraphRange(for: selection)
    }

    private func updateParagraphs(_ body: @escaping (NSMutableParagraphStyle) -> Void) {
        guard let tv = textView else { return }
        let range = paragraphRange()
        if range.length == 0 {
            let style = (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            body(style)
            tv.typingAttributes[.paragraphStyle] = style
            return
        }
        edit(range) { storage in
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                body(style)
                storage.addAttribute(.paragraphStyle, value: style, range: sub)
            }
        }
    }

    func align(_ alignment: NSTextAlignment) { updateParagraphs { $0.alignment = alignment } }

    func indent(_ delta: CGFloat) {
        updateParagraphs { s in
            s.headIndent = max(0, s.headIndent + delta)
            s.firstLineHeadIndent = max(0, s.firstLineHeadIndent + delta)
        }
    }

    func lineSpacing(_ factor: CGFloat) { updateParagraphs { $0.lineHeightMultiple = factor } }
    func paragraphSpacing(before: CGFloat?, after: CGFloat?) {
        updateParagraphs { s in
            if let before { s.paragraphSpacingBefore = before }
            if let after { s.paragraphSpacing = after }
        }
    }

    func applyStyle(_ style: DocStyle) {
        guard let tv = textView else { return }
        let range = paragraphRange()
        if range.length == 0 {
            tv.typingAttributes[.font] = style.font
            tv.typingAttributes[.foregroundColor] = style.color
            return
        }
        edit(range) { storage in
            storage.addAttribute(.font, value: style.font, range: range)
            storage.addAttribute(.foregroundColor, value: style.color, range: range)
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
                let s = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                s.paragraphSpacingBefore = style.spaceBefore
                s.paragraphSpacing = style.spaceAfter
                storage.addAttribute(.paragraphStyle, value: s, range: sub)
            }
        }
        updateHeadings()
    }

    /// Bullet or numbered list (markers live in the text, like TextEdit).
    func toggleList(_ format: NSTextList.MarkerFormat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = paragraphRange()
        let ns = tv.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: range, options: .byParagraphs) { _, _, enclosing, _ in paragraphs.append(enclosing) }
        if paragraphs.isEmpty { paragraphs = [range] }
        let probe = min(range.location, max(0, storage.length - 1))
        let alreadyList = storage.length > 0 && (storage.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle)?.textLists.isEmpty == false
        let list = NSTextList(markerFormat: format, options: 0)
        edit(range) { storage in
            for (i, p) in paragraphs.enumerated().reversed() {
                let text = (storage.string as NSString).substring(with: p) as NSString
                let style = (storage.attribute(.paragraphStyle, at: min(p.location, max(0, storage.length - 1)), effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                if alreadyList {
                    style.textLists = []
                    style.headIndent = 0
                    style.firstLineHeadIndent = 0
                    var markerLength = 0
                    if text.hasPrefix("\t") {
                        let second = text.range(of: "\t", options: [], range: NSRange(location: 1, length: max(0, text.length - 1)))
                        if second.location != NSNotFound { markerLength = second.location + 1 }
                    }
                    if markerLength > 0 { storage.deleteCharacters(in: NSRange(location: p.location, length: markerLength)) }
                    storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: p.location, length: max(0, p.length - markerLength)))
                } else {
                    style.textLists = [list]
                    style.headIndent = 36
                    style.firstLineHeadIndent = 0
                    style.tabStops = [NSTextTab(textAlignment: .left, location: 14), NSTextTab(textAlignment: .left, location: 36)]
                    let marker = "\t" + list.marker(forItemNumber: i + 1) + "\t"
                    let attrs = storage.length > 0 ? storage.attributes(at: min(p.location, storage.length - 1), effectiveRange: nil) : [:]
                    storage.insert(NSAttributedString(string: marker, attributes: attrs), at: p.location)
                    storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: p.location, length: p.length + (marker as NSString).length))
                }
            }
        }
    }

    // MARK: inserts

    func insertImage(_ image: NSImage) {
        guard let tv = textView else { return }
        let scale = min(1, page.contentWidth * 0.6 / max(image.size.width, 1), page.contentHeight / max(image.size.height, 1))
        let attachment = NSTextAttachment()
        attachment.image = resized(image, to: NSSize(width: image.size.width * scale, height: image.size.height * scale))
        attachment.bounds = NSRect(origin: .zero, size: attachment.image!.size)
        tv.insertText(NSAttributedString(attachment: attachment), replacementRange: tv.selectedRange())
    }

    func insertTable(rows: Int, columns: Int) {
        guard let tv = textView else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let result = NSMutableAttributedString(string: "\n")
        let font = tv.typingAttributes[.font] as? NSFont ?? DocStyle.normal.font
        for r in 0..<rows {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setBorderColor(NSColor(calibratedWhite: 0.8, alpha: 1))
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = NSColor(calibratedRed: 0.945, green: 0.953, blue: 0.969, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let cellFont = r == 0 ? font.bold : font
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: cellFont, .foregroundColor: NSColor.black]))
            }
        }
        tv.insertText(result, replacementRange: tv.selectedRange())
    }

    func insertText(_ text: String) { textView?.insertText(text, replacementRange: selection) }

    func showFind(replace: Bool = false) {
        let item = NSMenuItem()
        item.tag = (replace ? NSTextFinder.Action.showReplaceInterface : NSTextFinder.Action.showFindInterface).rawValue
        textView?.performTextFinderAction(item)
    }

    // MARK: images

    /// The attachment at the selection (if exactly one image is selected).
    private func selectedAttachment() -> (NSTextAttachment, NSRange)? {
        guard let storage = textView?.textStorage else { return nil }
        let r = selection
        guard r.length == 1, r.location < storage.length, let att = storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment else { return nil }
        return (att, r)
    }

    func refreshImageSelection() { imageSelected = selectedAttachment() != nil }

    private func resized(_ image: NSImage, to size: NSSize) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = size
        return copy
    }

    func resizeImage(fraction: CGFloat) {
        guard let (att, range) = selectedAttachment(), let image = att.image else { return }
        let ratio = image.size.height / max(image.size.width, 1)
        // never taller than a page: it has to fit on a sheet
        let width = min(page.contentWidth * fraction, page.contentHeight / max(ratio, 0.001))
        let size = NSSize(width: width, height: width * ratio)
        edit(range) { storage in
            att.image = resized(image, to: size)
            att.bounds = NSRect(origin: .zero, size: size)
            storage.addAttribute(.attachment, value: att, range: range)
        }
    }

    func rotateImage() {
        guard let (att, range) = selectedAttachment(), let image = att.image else { return }
        let old = image.size
        let rotated = NSImage(size: NSSize(width: old.height, height: old.width), flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.width / 2, yBy: rect.height / 2)
            t.rotate(byDegrees: -90)
            t.translateX(by: -old.width / 2, yBy: -old.height / 2)
            t.concat()
            image.draw(in: NSRect(origin: .zero, size: old))
            return true
        }
        edit(range) { storage in
            att.image = rotated
            att.bounds = NSRect(origin: .zero, size: rotated.size)
            storage.addAttribute(.attachment, value: att, range: range)
        }
    }

    func alignImage(_ alignment: NSTextAlignment) {
        guard selectedAttachment() != nil else { return }
        align(alignment)
    }

    func deleteImage() {
        guard let (_, range) = selectedAttachment(), let tv = textView else { return }
        tv.insertText("", replacementRange: range)
        imageSelected = false
    }

    // MARK: page setup

    func applyPage() {
        textView?.apply(page)
        updatePageInfo()
    }
}

/// Paragraph styles.
struct DocStyle: Identifiable, Hashable {
    let name: String
    let size: CGFloat      // pt
    let bold: Bool
    let italic: Bool
    let colorHex: UInt32?
    let spaceBefore: CGFloat
    let spaceAfter: CGFloat
    var id: String { name }

    var color: NSColor {
        guard let hex = colorHex else { return .black }
        return NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var font: NSFont {
        var f = NSFont(name: "Calibri", size: size) ?? NSFont.systemFont(ofSize: size)
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static let normal = DocStyle(name: "Normal", size: 11, bold: false, italic: false, colorHex: nil, spaceBefore: 0, spaceAfter: 6)
    static let title = DocStyle(name: "Title", size: 26, bold: true, italic: false, colorHex: 0x1E293B, spaceBefore: 0, spaceAfter: 12)
    static let h1 = DocStyle(name: "Heading 1", size: 20, bold: true, italic: false, colorHex: 0x1E293B, spaceBefore: 12, spaceAfter: 6)
    static let h2 = DocStyle(name: "Heading 2", size: 16, bold: true, italic: false, colorHex: 0x1E293B, spaceBefore: 10, spaceAfter: 4)
    static let h3 = DocStyle(name: "Heading 3", size: 13, bold: true, italic: false, colorHex: 0x1E293B, spaceBefore: 8, spaceAfter: 4)
    static let quote = DocStyle(name: "Quote", size: 11, bold: false, italic: true, colorHex: 0x555B66, spaceBefore: 6, spaceAfter: 6)
    static let small = DocStyle(name: "Small", size: 9, bold: false, italic: false, colorHex: 0x6B7280, spaceBefore: 0, spaceAfter: 4)
    static let all = [normal, title, h1, h2, h3, quote, small]
}
