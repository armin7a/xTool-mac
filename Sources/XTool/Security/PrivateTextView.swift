import AppKit
import SwiftUI

/// A text view that keeps the text inside the app: no Writing Tools, no Services, no web search or sharing
/// from the context menu, no text prediction. What it copies stays on this Mac and is marked as confidential.
class PrivateTextView: NSTextView {
    /// Spell checking runs through macOS, so it is only on if the user chose it.
    var allowsSpelling = false {
        didSet { isContinuousSpellCheckingEnabled = allowsSpelling }
    }

    func applyPrivacy() {
        isContinuousSpellCheckingEnabled = allowsSpelling
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        if #available(macOS 15.0, *) { writingToolsBehavior = .none }
    }

    /// No Look Up popover from a firm click or three-finger tap on the trackpad.
    override func quickLook(with event: NSEvent) {}

    /// Services from other apps get nothing to work with.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        strip(menu)
        return menu
    }

    private func strip(_ menu: NSMenu) {
        for item in menu.items.reversed() {
            if let submenu = item.submenu {
                strip(submenu)
                if submenu.items.allSatisfy(\.isSeparatorItem) { menu.removeItem(item); continue }
            }
            if isBlocked(item) { menu.removeItem(item) }
        }
        // no separators left hanging
        for item in menu.items.reversed() where item.isSeparatorItem {
            let index = menu.index(of: item)
            if index == 0 || index == menu.numberOfItems - 1 || menu.items[index - 1].isSeparatorItem { menu.removeItem(item) }
        }
    }

    private func isBlocked(_ item: NSMenuItem) -> Bool {
        let target = item.target.map { String(describing: type(of: $0)) } ?? ""
        let name = ((item.action.map(NSStringFromSelector) ?? "") + " " + (item.identifier?.rawValue ?? "") + " " + target).lowercased()
        // "rvmenuitem" is what macOS uses for Look Up, Translate and web search.
        var blocked = ["rvmenuitem", "search", "lookup", "share", "sharing", "translate", "writingtools", "writing_tools", "dictation",
                       "services", "importfromdevice", "continuity", "autofill", "showwritingtools",
                       "datadetection", "linkdetection", "textreplacement", "orderfrontsubstitutions", "addlinks", "replacetext"]
        if !allowsSpelling { blocked += ["spelling", "grammar", "checkspelling", "showguesspanel"] }
        return blocked.contains { name.contains($0) }
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard super.writeSelection(to: pboard, types: types), pboard.name == .general else {
            return pboard.name != .general
        }
        // written again with options that can only be given up front
        let item = NSPasteboardItem()
        for type in pboard.types ?? [] {
            if let data = pboard.data(forType: type) { item.setData(data, forType: type) }
        }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) // clipboard managers skip it
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pboard.prepareForNewContents(with: .currentHostOnly) // not to other devices via Handoff
        pboard.writeObjects([item])
        ClipboardGuard.shared.noteCopied()
        return true
    }
}

/// Plain-text editor for notes and text files, built on PrivateTextView.
struct PrivateTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 13)
    var inset = NSSize(width: 0, height: 0)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = PrivateTextView(frame: .zero, textContainer: container)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.font = font
        view.textColor = .labelColor
        view.textContainerInset = inset
        view.applyPrivacy()
        view.string = text
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.storage = storage
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PrivateTextView else { return }
        if view.string != text { view.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// Owns the text system; goes away with the editor.
        var storage: NSTextStorage?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}
