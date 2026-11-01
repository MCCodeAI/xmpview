import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum XMPParserError: LocalizedError, Equatable {
    case documentTooLarge
    case prohibitedDeclaration
    case malformedXML(line: Int, column: Int)
    case unsupportedValue(field: String)

    public var errorDescription: String? {
        switch self {
        case .documentTooLarge: return "XMP 数据超过 16 MB，无法安全解析。"
        case .prohibitedDeclaration: return "为安全起见，不支持包含 DTD 或实体声明的 XMP。"
        case let .malformedXML(line, column): return "XMP XML 无效（第 \(line) 行，第 \(column) 列）。"
        case let .unsupportedValue(field): return "XMP 的 \(field) 使用了不支持的复杂结构，无法安全编辑。"
        }
    }
}

/// Reads RDF by namespace URI, rather than assuming a particular XML prefix.
/// It does not rewrite XML or flatten metadata that the editor does not own.
public enum XMPParser {
    public static let maximumByteCount = 16 * 1024 * 1024

    public static func readFields(from data: Data) throws -> EditableFields {
        guard data.count <= maximumByteCount else { throw XMPParserError.documentTooLarge }
        // Strip NUL bytes only for this safety scan so UTF-16/32 declarations
        // cannot evade it. The original bytes go to the XML parser unchanged.
        let declarationScan = String(decoding: data.filter { $0 != 0 }, as: UTF8.self).uppercased()
        guard !declarationScan.contains("<!DOCTYPE"), !declarationScan.contains("<!ENTITY") else {
            throw XMPParserError.prohibitedDeclaration
        }
        let delegate = FieldsDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        let success = parser.parse()
        if let error = delegate.failure { throw error }
        guard success, parser.parserError == nil, delegate.completeDocument else {
            throw XMPParserError.malformedXML(line: parser.lineNumber, column: parser.columnNumber)
        }
        if delegate.hasOtherResources, !delegate.hasPrimaryDescription {
            throw XMPParserError.unsupportedValue(field: "rdf:about")
        }
        return delegate.fields
    }
}

private final class FieldsDelegate: NSObject, XMLParserDelegate {
    private static let dc = "http://purl.org/dc/elements/1.1/"
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let xml = "http://www.w3.org/XML/1998/namespace"

    private enum Field: String {
        case title
        case description
        case subject
    }

    private struct Element {
        let name: String
        let namespace: String
    }

    private struct ListItem {
        var language: String?
        var text = ""
    }

    private struct Capture {
        var field: Field
        var depth: Int
        var directText = ""
        var listKind: String?
        var items: [ListItem] = []
        var itemDepth: Int?
    }

    var fields = EditableFields()
    var failure: XMPParserError?
    var hasOtherResources = false
    var hasPrimaryDescription = false
    var hasElement = false
    var completeDocument: Bool { hasElement && elements.isEmpty }
    private var elements: [Element] = []
    private var capture: Capture?
    private var completed = Set<Field>()
    private var namespaces: [String: [String]] = ["xml": [FieldsDelegate.xml]]
    private var primaryDescriptionDepth: Int?

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = namespaces[prefix]?.popLast()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let namespace = namespaceURI ?? ""
        hasElement = true
        let parent = elements.last
        elements.append(Element(name: elementName, namespace: namespace))
        let depth = elements.count

        // RDF permits simple properties as attributes of rdf:Description.
        if namespace == Self.rdf, elementName == "Description",
           parent?.namespace == Self.rdf, parent?.name == "RDF" {
            let about = attribute("about", namespace: Self.rdf, in: attributeDict) ?? ""
            let nodeID = attribute("nodeID", namespace: Self.rdf, in: attributeDict) ?? ""
            let resourceID = attribute("ID", namespace: Self.rdf, in: attributeDict) ?? ""
            guard about.isEmpty, nodeID.isEmpty, resourceID.isEmpty else {
                hasOtherResources = true
                return
            }
            primaryDescriptionDepth = depth
            hasPrimaryDescription = true
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, namespaces[parts[0]]?.last == Self.dc,
                      let field = Field(rawValue: parts[1]), !completed.contains(field) else { continue }
                assign(value, to: field)
                completed.insert(field)
            }
        }

        if capture == nil, namespace == Self.dc, let field = Field(rawValue: elementName),
           primaryDescriptionDepth.map({ depth == $0 + 1 }) == true,
           !completed.contains(field) {
            guard !hasTypedRDFAttributes(attributeDict) else {
                failure = .unsupportedValue(field: field.rawValue)
                parser.abortParsing()
                return
            }
            capture = Capture(field: field, depth: depth)
            return
        }

        guard var current = capture else { return }
        if depth == current.depth + 1, namespace == Self.rdf,
           ["Alt", "Bag", "Seq"].contains(elementName) {
            current.listKind = elementName
            capture = current
        } else if depth == current.depth + 2, namespace == Self.rdf,
                  elementName == "li", current.listKind != nil {
            guard !hasTypedRDFAttributes(attributeDict) else {
                failure = .unsupportedValue(field: current.field.rawValue)
                parser.abortParsing()
                return
            }
            let language = attributeDict["xml:lang"] ?? attributeDict.first(where: { key, _ in
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                return parts.count == 2 && parts[1] == "lang" && namespaces[parts[0]]?.last == Self.xml
            })?.value
            current.items.append(ListItem(language: language))
            current.itemDepth = depth
            capture = current
        } else {
            failure = .unsupportedValue(field: current.field.rawValue)
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var current = capture else { return }
        if let itemDepth = current.itemDepth, elements.count == itemDepth, !current.items.isEmpty {
            current.items[current.items.count - 1].text += string
        } else if elements.count == current.depth {
            current.directText += string
        }
        capture = current
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        defer {
            if primaryDescriptionDepth == elements.count { primaryDescriptionDepth = nil }
            _ = elements.popLast()
        }
        guard var current = capture else { return }
        if elements.count == current.depth {
            if current.field == .subject {
                if current.listKind != nil {
                    fields.keywords = current.items.map(\.text)
                } else {
                    fields.keywords = current.directText.isEmpty ? [] : [current.directText]
                }
            } else {
                let selected = current.items.first(where: { $0.language == "x-default" })
                    ?? current.items.first
                assign(selected?.text ?? current.directText, to: current.field)
            }
            completed.insert(current.field)
            capture = nil
        } else if current.itemDepth == elements.count {
            current.itemDepth = nil
            capture = current
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = .prohibitedDeclaration
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
        publicID: String?, systemID: String?
    ) {
        failure = .prohibitedDeclaration
        parser.abortParsing()
    }

    private func assign(_ value: String, to field: Field) {
        switch field {
        case .title: fields.title = value
        case .description: fields.description = value
        case .subject: fields.keywords = value.isEmpty ? [] : [value]
        }
    }

    private func attribute(_ name: String, namespace: String, in attributes: [String: String]) -> String? {
        attributes.first { key, _ in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[1] == name && namespaces[parts[0]]?.last == namespace
        }?.value
    }

    private func hasTypedRDFAttributes(_ attributes: [String: String]) -> Bool {
        ["resource", "parseType", "datatype", "nodeID"].contains {
            attribute($0, namespace: Self.rdf, in: attributes) != nil
        }
    }
}
