import Foundation

/// File overview:
/// The text of Word, PowerPoint and Excel files (Office Open XML: `.docx`, `.pptx`, `.xlsx`), for
/// conversation memory's document sources.
///
/// Each format is a ZIP of XML parts (`ZipArchiveReader`), and its text sits in a few element kinds:
/// - Word: `word/document.xml`, runs of `w:t` inside paragraphs `w:p`.
/// - PowerPoint: `ppt/slides/slideN.xml` in slide order, runs of `a:t` inside paragraphs `a:p`;
///   speaker notes (`ppt/notesSlides`) follow their slides' text.
/// - Excel: the shared strings table (`xl/sharedStrings.xml`, items `si` holding `t`), which holds
///   every text cell of the workbook once. Numbers are left out; they carry little meaning alone.
///
/// One `XMLParser` pass per part collects the runs and starts a new line at each paragraph or item,
/// so a slide's bullets and a document's paragraphs stay apart. The text is capped
/// (`maximumCharacters`). Pure: bytes in, text out.
nonisolated enum OfficeDocumentText {
    static let maximumCharacters = 400_000

    enum Kind: String, CaseIterable, Sendable {
        case word = "docx"
        case powerPoint = "pptx"
        case excel = "xlsx"
    }

    static func text(of data: Data, kind: Kind) throws -> String {
        let archive = try ZipArchiveReader(data: data)
        var parts: [String] = []
        switch kind {
        case .word:
            if let part = try archive.contents(of: "word/document.xml") {
                parts.append(runs(in: part, text: "w:t", breaks: ["w:p", "w:br", "w:tab"]))
            }
        case .powerPoint:
            for name in ordered(archive.names, folder: "ppt/slides/slide") + ordered(archive.names, folder: "ppt/notesSlides/notesSlide") {
                if let part = try archive.contents(of: name) {
                    parts.append(runs(in: part, text: "a:t", breaks: ["a:p", "a:br"]))
                }
            }
        case .excel:
            if let part = try archive.contents(of: "xl/sharedStrings.xml") {
                parts.append(runs(in: part, text: "t", breaks: ["si"]))
            }
        }
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) : text
    }

    /// `folder` + number + ".xml" entries in numeric order ("slide2" before "slide10").
    static func ordered(_ names: [String], folder: String) -> [String] {
        names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(folder), name.hasSuffix(".xml"),
                  let number = Int(name.dropFirst(folder.count).dropLast(4)) else { return nil }
            return (number, name)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The text of every `text` element, with a line break after each `breaks` element.
    static func runs(in xml: Data, text: String, breaks: Set<String>) -> String {
        let collector = RunCollector(textElement: text, breakElements: breaks)
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false  // Never fetch anything a document points at.
        parser.delegate = collector
        parser.parse()
        return collector.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private final class RunCollector: NSObject, XMLParserDelegate {
        let textElement: String
        let breakElements: Set<String>
        private(set) var lines: [String] = [""]
        private var depth = 0
        private var characters = 0

        init(textElement: String, breakElements: Set<String>) {
            self.textElement = textElement
            self.breakElements = breakElements
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if elementName == textElement { depth += 1 }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == textElement { depth = max(0, depth - 1) }
            if breakElements.contains(elementName) { lines.append("") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard depth > 0 else { return }
            lines[lines.count - 1] += string
            characters += string.count
            if characters > OfficeDocumentText.maximumCharacters { parser.abortParsing() }
        }
    }
}
