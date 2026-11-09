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
        DocTemplate(id: "blank", name: "Leeres Dokument", description: "Weißes Blatt", defaultName: "Unbenanntes Dokument", symbol: "doc", build: blank),
        DocTemplate(id: "letter", name: "Brief", description: "DIN 5008", defaultName: "Brief", symbol: "envelope", build: letter),
        DocTemplate(id: "invoice", name: "Rechnung", description: "Mit Positionen", defaultName: "Rechnung", symbol: "doc.text.below.ecg", build: invoice),
        DocTemplate(id: "cv", name: "Lebenslauf", description: "Tabellarisch", defaultName: "Lebenslauf", symbol: "person.text.rectangle", build: cv),
        DocTemplate(id: "minutes", name: "Protokoll", description: "Besprechung", defaultName: "Protokoll", symbol: "list.clipboard", build: minutes),
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
            p("Max Mustermann · Musterstraße 1 · 12345 Musterstadt", .small), p(""),
            p("Firma Beispiel GmbH"), p("Frau Erika Beispiel"), p("Beispielweg 12"), p("54321 Beispielstadt"), p(""),
            p("Musterstadt, \(today)", .normal, .right), p(""),
            p("Betreff: Ihr Anliegen", .h3), p(""),
            p("Sehr geehrte Frau Beispiel,"),
            p("hier steht der Text Ihres Briefes. Formulieren Sie Ihr Anliegen klar und freundlich."), p(""),
            p("Mit freundlichen Grüßen"), p(""), p(""), p("Max Mustermann"),
        ])
    }

    static func invoice() -> NSAttributedString {
        doc([
            p("Rechnung", .title),
            labeled("Rechnungsnummer:", "2026-001"),
            labeled("Datum:", todayShort),
            labeled("Kunde:", "Firma Beispiel GmbH, Beispielweg 12, 54321 Beispielstadt"),
            p(""),
            table(["Pos.", "Beschreibung", "Menge", "Einzelpreis", "Gesamt"],
                  [["1", "Leistung A", "1", "100,00 €", "100,00 €"], ["2", "Leistung B", "2", "50,00 €", "100,00 €"], ["", "", "", "", ""]],
                  widths: [0.6, 3, 0.8, 1.3, 1.3]),
            p(""),
            p("Zwischensumme: 200,00 €", .normal, .right),
            p("MwSt. 19 %: 38,00 €", .normal, .right),
            p("Gesamtbetrag: 238,00 €", .h3, .right), p(""),
            p("Bitte überweisen Sie den Betrag innerhalb von 14 Tagen auf folgendes Konto:"),
            p("IBAN: DE00 0000 0000 0000 0000 00 · BIC: XXXXXXXX"),
            p("Vielen Dank für Ihren Auftrag!", .small),
        ])
    }

    static func cv() -> NSAttributedString {
        doc([
            p("Max Mustermann", .title),
            p("Musterstraße 1 · 12345 Musterstadt · max@beispiel.de · 0123 456789", .small),
            p("Berufserfahrung", .h2),
            table(["Zeitraum", "Position"], [["2022 – heute", "Position, Firma, Ort – Aufgaben und Erfolge"], ["2019 – 2022", "Position, Firma, Ort – Aufgaben und Erfolge"]], widths: [1, 3]),
            p("Ausbildung", .h2),
            table(["Zeitraum", "Abschluss"], [["2015 – 2019", "Studium / Ausbildung, Institution, Ort"]], widths: [1, 3]),
            p("Kenntnisse", .h2),
            p("•  Sprachen: Deutsch (Muttersprache), Englisch (fließend)"),
            p("•  EDV: Office, …"),
            p("•  Weitere Fähigkeiten"), p(""),
            p("Musterstadt, \(todayShort)"),
        ])
    }

    static func minutes() -> NSAttributedString {
        doc([
            p("Protokoll", .title),
            labeled("Datum:", todayShort), labeled("Ort:", ""), labeled("Teilnehmende:", ""), labeled("Protokoll:", ""),
            p("Tagesordnung", .h2),
            p("1.  Begrüßung"), p("2.  Thema 1"), p("3.  Thema 2"), p("4.  Verschiedenes"),
            p("Ergebnisse", .h2), p(""),
            p("Aufgaben", .h2),
            table(["Aufgabe", "Verantwortlich", "Bis"], [["", "", ""], ["", "", ""]], widths: [3, 1.5, 1]),
        ])
    }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

struct TemplatePicker: View {
    let onPick: (DocTemplate?) -> Void

    var body: some View {
        SheetLayout(title: "Neues Dokument", width: 520) {
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
            Button("Abbrechen") { onPick(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
        }
    }
}
