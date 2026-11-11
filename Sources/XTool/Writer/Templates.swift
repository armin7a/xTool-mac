import AppKit
import SwiftUI

struct DocTemplate: Identifiable {
    let id: String
    let name: String
    let description: String
    let defaultName: String
    let symbol: String
    let build: () -> NSAttributedString
}

enum DocTemplates {
    static let all: [DocTemplate] = [
        DocTemplate(id: "blank", name: "Blank", description: "Empty page", defaultName: "Untitled Document", symbol: "doc", build: blank),
        DocTemplate(id: "letter", name: "Letter", description: "Formal letter", defaultName: "Letter", symbol: "envelope", build: letter),
        DocTemplate(id: "invoice", name: "Invoice", description: "With line items", defaultName: "Invoice", symbol: "doc.text.below.ecg", build: invoice),
        DocTemplate(id: "cv", name: "Résumé", description: "Clear sections", defaultName: "Résumé", symbol: "person.text.rectangle", build: cv),
        DocTemplate(id: "minutes", name: "Minutes", description: "Meeting notes", defaultName: "Minutes", symbol: "list.clipboard", build: minutes),
    ]

    private static func p(_ text: String, _ style: DocStyle = .normal, _ align: NSTextAlignment = .left) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.paragraphSpacingBefore = style.spaceBefore
        para.paragraphSpacing = style.spaceAfter
        return NSAttributedString(string: text + "\n", attributes: [.font: style.font, .foregroundColor: style.color, .paragraphStyle: para])
    }

    private static func labeled(_ label: String, _ value: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: label + " ", attributes: [.font: DocStyle.normal.font.bold, .foregroundColor: NSColor.black, .paragraphStyle: spacing(6)])
        s.append(NSAttributedString(string: value + "\n", attributes: [.font: DocStyle.normal.font, .foregroundColor: NSColor.black, .paragraphStyle: spacing(6)]))
        return s
    }

    private static func spacing(_ after: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = after
        return p
    }

    static func table(_ header: [String], _ rows: [[String]], widths: [CGFloat]? = nil) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = header.count
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let total = (widths ?? header.map { _ in 1 }).reduce(0, +)
        let result = NSMutableAttributedString()
        for (r, row) in ([header] + rows).enumerated() {
            for (c, text) in row.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setBorderColor(NSColor(calibratedWhite: 0.8, alpha: 1))
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                if let widths { block.setContentWidth(widths[c] / total * 100, type: .percentageValueType) }
                if r == 0 { block.backgroundColor = NSColor(calibratedRed: 0.945, green: 0.953, blue: 0.969, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let font = r == 0 ? DocStyle.normal.font.bold : DocStyle.normal.font
                result.append(NSAttributedString(string: text + "\n", attributes: [.paragraphStyle: style, .font: font, .foregroundColor: NSColor.black]))
            }
        }
        return result
    }

    private static func doc(_ parts: [NSAttributedString]) -> NSAttributedString {
        let d = NSMutableAttributedString()
        parts.forEach { d.append($0) }
        return d
    }

    private static var today: String { Date().formatted(date: .long, time: .omitted) }
    private static var todayShort: String { Date().formatted(date: .numeric, time: .omitted) }

    static func blank() -> NSAttributedString { p("") }

    static func letter() -> NSAttributedString {
        doc([
            p("Alex Sample · 1 Sample Street · Sampletown 12345", .small), p(""),
            p("Example Company Ltd"), p("Ms Erica Example"), p("12 Example Road"), p("Exampletown 54321"), p(""),
            p("Sampletown, \(today)", .normal, .right), p(""),
            p("Subject: Your request", .h3), p(""),
            p("Dear Ms Example,"),
            p("This is where the text of your letter goes. State your request clearly and politely."), p(""),
            p("Kind regards"), p(""), p(""), p("Alex Sample"),
        ])
    }

    static func invoice() -> NSAttributedString {
        doc([
            p("Invoice", .title),
            labeled("Invoice number:", "2026-001"),
            labeled("Date:", todayShort),
            labeled("Customer:", "Example Company Ltd, 12 Example Road, Exampletown 54321"),
            p(""),
            table(["No.", "Description", "Qty", "Unit price", "Total"],
                  [["1", "Service A", "1", "100.00", "100.00"], ["2", "Service B", "2", "50.00", "100.00"], ["", "", "", "", ""]],
                  widths: [0.6, 3, 0.8, 1.3, 1.3]),
            p(""),
            p("Subtotal: 200.00", .normal, .right),
            p("Tax 10 %: 20.00", .normal, .right),
            p("Total due: 220.00", .h3, .right), p(""),
            p("Please transfer the amount within 14 days to the following account:"),
            p("IBAN: XX00 0000 0000 0000 0000 00 · BIC: XXXXXXXX"),
            p("Thank you for your business!", .small),
        ])
    }

    static func cv() -> NSAttributedString {
        doc([
            p("Alex Sample", .title),
            p("1 Sample Street · Sampletown 12345 · alex@example.com · 0123 456789", .small),
            p("Experience", .h2),
            table(["Period", "Position"], [["2022 – today", "Position, company, place: tasks and results"], ["2019 – 2022", "Position, company, place: tasks and results"]], widths: [1, 3]),
            p("Education", .h2),
            table(["Period", "Qualification"], [["2015 – 2019", "Degree or training, institution, place"]], widths: [1, 3]),
            p("Skills", .h2),
            p("•  Languages: English (native), German (fluent)"),
            p("•  Software: Office, …"),
            p("•  Other skills"), p(""),
            p("Sampletown, \(todayShort)"),
        ])
    }

    static func minutes() -> NSAttributedString {
        doc([
            p("Minutes", .title),
            labeled("Date:", todayShort), labeled("Place:", ""), labeled("Attendees:", ""), labeled("Minutes by:", ""),
            p("Agenda", .h2),
            p("1.  Welcome"), p("2.  Topic 1"), p("3.  Topic 2"), p("4.  Any other business"),
            p("Decisions", .h2), p(""),
            p("Action items", .h2),
            table(["Task", "Owner", "Due"], [["", "", ""], ["", "", ""]], widths: [3, 1.5, 1]),
        ])
    }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

struct TemplatePicker: View {
    let onPick: (DocTemplate?) -> Void

    var body: some View {
        SheetLayout(title: "New Document", width: 520) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(DocTemplates.all) { t in
                    Button { onPick(t) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: t.symbol).font(.system(size: 20, weight: .light)).foregroundStyle(XColor.accent).frame(height: 34)
                            Text(t.name).font(.system(size: 13, weight: .medium))
                            Text(t.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous).strokeBorder(XColor.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } buttons: {
            Button("Cancel") { onPick(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
        }
    }
}
