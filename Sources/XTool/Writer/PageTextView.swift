import AppKit
import PDFKit
import XToolCore

/// One long text area with the space between two pages left out: a line that doesn't fit on a page
/// is moved to the top of the next one. That is the whole trick behind the page view.
final class PageTextContainer: NSTextContainer {
    /// Height of the text area of one page (paper minus top and bottom margin).
    var pageContentHeight: CGFloat = 700
    /// Distance from one page's text area to the next.
    var pageStride: CGFloat = 860

    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = proposedRect
        let top = floor(rect.minY / pageStride) * pageStride
        // A line taller than a whole page (a large image) stays at the top of its page instead of moving on forever.
        if rect.maxY > top + pageContentHeight, rect.minY > top + 0.5 {
            rect.origin.y = top + pageStride
        }
        return super.lineFragmentRect(forProposedRect: rect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

/// The editor: white sheets of paper with text flowing from one to the next. Header, footer and page numbers
/// are drawn on every sheet, and printing or PDF export uses exactly these sheets, so the screen shows the result.
final class PageTextView: PrivateTextView {
    /// Grey space between two sheets, in points of the page.
    static let pageGap: CGFloat = 14

    private(set) var page = PageSetup()
    private(set) var pageCount = 1
    private let decoration = PageDecorationView()

    /// Builds the text system. The caller keeps the returned storage: it owns everything else and
    /// nothing may hold it back after the tab is closed, because it contains the decrypted document.
    static func make(page: PageSetup) -> (view: PageTextView, storage: NSTextStorage) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = PageTextContainer(size: NSSize(width: page.contentWidth, height: 10_000_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        let view = PageTextView(frame: NSRect(origin: .zero, size: page.paperSize), textContainer: container)
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.drawsBackground = false
        view.applyPrivacy()
        view.decoration.owner = view
        view.addSubview(view.decoration)
        view.apply(page)
        return (view, storage)
    }

    private var stride: CGFloat { page.paperSize.height + Self.pageGap }

    private func sheetRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * stride, width: page.paperSize.width, height: page.paperSize.height)
    }

    /// Takes over format and margins, then lays the text out on the new sheets.
    func apply(_ newPage: PageSetup) {
        let old = page
        page = newPage
        textContainerInset = NSSize(width: PageSetup.pt(newPage.left), height: PageSetup.pt(newPage.top))
        if let container = textContainer as? PageTextContainer {
            let width = newPage.contentWidth, height = newPage.contentHeight, newStride = newPage.paperSize.height + Self.pageGap
            if container.size.width != width || container.pageContentHeight != height || container.pageStride != newStride || old != newPage {
                container.size = NSSize(width: width, height: 10_000_000)
                container.pageContentHeight = height
                container.pageStride = newStride
                if let storage = textStorage {
                    layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                }
            }
        }
        fitToPages()
        needsDisplay = true
        decoration.needsDisplay = true
    }

    /// Adds or removes sheets to match the text. Called after every change.
    func fitToPages() {
        guard let layoutManager, let container = textContainer else { return }
        layoutManager.ensureLayout(for: container)
        // A sheet exists if there is text on it or the insertion point is there. The empty line after a final
        // line break alone must not add a blank page at the end of a document.
        var bottom: CGFloat = 0
        if layoutManager.numberOfGlyphs > 0 {
            bottom = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil).maxY
        }
        if selectedRange().location >= (textStorage?.length ?? 0), layoutManager.extraLineFragmentTextContainer != nil {
            bottom = max(bottom, layoutManager.extraLineFragmentRect.maxY)
        }
        let count = max(1, Int(ceil(bottom / stride)))
        if count != pageCount {
            pageCount = count
            decoration.needsDisplay = true // the page numbers change on every sheet
        }
        let size = NSSize(width: page.paperSize.width, height: CGFloat(pageCount) * stride - Self.pageGap)
        minSize = size
        maxSize = size
        if frame.size != size { setFrameSize(size) }
        decoration.frame = NSRect(origin: .zero, size: size)
    }

    /// The sheet the insertion point is on, counted from 1.
    var currentPage: Int {
        guard let layoutManager, layoutManager.numberOfGlyphs > 0 else { return 1 }
        let location = selectedRange().location
        let length = textStorage?.length ?? 0
        let rect: NSRect
        if location >= length, layoutManager.extraLineFragmentTextContainer != nil {
            rect = layoutManager.extraLineFragmentRect // the empty last line
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, length - 1)))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return min(pageCount, Int(floor(rect.midY / stride)) + 1)
    }

    // MARK: drawing

    fileprivate func sheets(in rect: NSRect) -> Range<Int> {
        let first = max(0, Int(floor(rect.minY / stride)))
        let last = min(pageCount - 1, Int(floor(rect.maxY / stride)))
        return first..<max(first, last + 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = sheets(in: dirtyRect)
        if NSGraphicsContext.currentContextDrawingToScreen() {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            for index in visible { sheetRect(index).fill() }
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(dirtyRect)
    }

    fileprivate func drawHeaderAndFooter(sheet index: Int) {
        guard !page.header.isEmpty || !page.footer.isEmpty || page.pageNumbers else { return }
        let sheet = sheetRect(index)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Calibri", size: 9) ?? NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
        ]
        let left = sheet.minX + PageSetup.pt(page.left), right = sheet.maxX - PageSetup.pt(page.right)
        if !page.header.isEmpty {
            (page.header as NSString).draw(at: NSPoint(x: left, y: sheet.minY + PageSetup.pt(page.top) * 0.4), withAttributes: attrs)
        }
        let footerY = sheet.maxY - PageSetup.pt(page.bottom) * 0.55
        if !page.footer.isEmpty {
            (page.footer as NSString).draw(at: NSPoint(x: left, y: footerY), withAttributes: attrs)
        }
        if page.pageNumbers {
            let text = "Seite \(index + 1) von \(pageCount)" as NSString
            text.draw(at: NSPoint(x: right - text.size(withAttributes: attrs).width, y: footerY), withAttributes: attrs)
        }
    }

    // MARK: printing and PDF: the sheets, exactly as on screen

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ pageNumber: Int) -> NSRect { sheetRect(pageNumber - 1) }

    /// A PDF with one page per sheet. Built in memory: no decrypted file is ever written.
    func pdfData() -> Data {
        let document = PDFDocument()
        for index in 0..<pageCount {
            guard let single = PDFDocument(data: dataWithPDF(inside: sheetRect(index))), let sheet = single.page(at: 0) else { continue }
            document.insert(sheet, at: document.pageCount)
        }
        return document.dataRepresentation() ?? Data()
    }
}

/// Header, footer and page numbers, on a layer of their own above the text. A text view only repaints
/// its text area when something changes, and the header lies above that.
private final class PageDecorationView: NSView {
    weak var owner: PageTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks belong to the text

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        for index in owner.sheets(in: dirtyRect) { owner.drawHeaderAndFooter(sheet: index) }
    }
}
