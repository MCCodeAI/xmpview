import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum XMPEditorError: LocalizedError, Equatable {
    case missingRDF
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .missingRDF: return "XMP 中没有有效的 RDF 根结构，无法安全修改。"
        case .verificationFailed: return "生成的 XMP 与编辑内容不一致，已取消保存。"
        }
    }
}

/// Updates only the three supported properties in a real RDF/XML document.
/// Unknown properties, comments and non-default language alternatives survive.
public enum XMPEditor {
    private static let dc = "http://purl.org/dc/elements/1.1/"
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    public static func replacingFields(in packet: Data?, with fields: EditableFields) throws -> Data {
        let document: XMLDocument
        let originalFields: EditableFields
        if let packet {
            // This also rejects DTD/entity declarations before XMLDocument sees
            // them, and refuses complex structures in properties we would edit.
            originalFields = try XMPParser.readFields(from: packet)
            document = try XMLDocument(data: packet, options: .nodePreserveAll)
        } else {
            originalFields = EditableFields()
            document = try XMLDocument(xmlString: """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(rdf)"><rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>
            """, options: .nodePreserveAll)
        }

        let rdfRoots = try document.nodes(forXPath: "//*[local-name()='RDF' and namespace-uri()='\(rdf)']")
            .compactMap { $0 as? XMLElement }
        // Multiple RDF roots are ambiguous to different consumers.
        guard rdfRoots.count == 1, let rdfRoot = rdfRoots.first else { throw XMPEditorError.missingRDF }
        var descriptions = (rdfRoot.children ?? []).compactMap { $0 as? XMLElement }
            .filter { $0.localName == "Description" && $0.uri == rdf }
            .filter { description in
                !(description.attributes ?? []).contains { attribute in
                    attribute.uri == rdf && ["about", "nodeID", "ID"].contains(attribute.localName ?? "")
                        && !(attribute.stringValue ?? "").isEmpty
                }
            }
        if descriptions.isEmpty {
            let description = XMLElement(name: "rdf:Description", uri: rdf)
            description.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: rdf) as! XMLNode)
            description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
            rdfRoot.addChild(description)
            descriptions = [description]
        }

        if packet == nil || originalFields.title != fields.title {
            replaceLocalizedProperty("title", value: fields.title, descriptions: descriptions)
        }
        if packet == nil || originalFields.description != fields.description {
            replaceLocalizedProperty("description", value: fields.description, descriptions: descriptions)
        }
        if packet == nil || originalFields.keywords != fields.keywords {
            replaceSubject(fields.keywords, descriptions: descriptions)
        }

        document.characterEncoding = "UTF-8"
        let result = document.xmlData(options: .nodePreserveAll)
        guard try XMPParser.readFields(from: result) == fields else { throw XMPEditorError.verificationFailed }
        return result
    }

    private static func matchingProperties(_ name: String, in descriptions: [XMLElement]) -> [XMLElement] {
        descriptions.flatMap { description in
            (description.children ?? []).compactMap { $0 as? XMLElement }
                .filter { $0.localName == name && $0.uri == dc }
        }
    }

    private static func removeAttributes(_ name: String, from descriptions: [XMLElement]) {
        for description in descriptions {
            for attribute in description.attributes ?? [] where attribute.localName == name && attribute.uri == dc {
                if let qualifiedName = attribute.name { description.removeAttribute(forName: qualifiedName) }
            }
        }
    }

    private static func replaceLocalizedProperty(_ name: String, value: String, descriptions: [XMLElement]) {
        let existing = matchingProperties(name, in: descriptions)
        var translations: [XMLElement] = []
        for property in existing {
            for container in (property.children ?? []).compactMap({ $0 as? XMLElement })
                where container.uri == rdf && container.localName == "Alt" {
                for item in (container.children ?? []).compactMap({ $0 as? XMLElement })
                    where item.uri == rdf && item.localName == "li" {
                    if item.attribute(forName: "xml:lang")?.stringValue != "x-default" {
                        translations.append(copyWithNamespaceContext(item))
                    }
                }
            }
        }

        let replacement = existing.first.map(copyWithNamespaceContext) ?? newProperty(name)
        replacement.setChildren(nil)
        let alternate = XMLElement(name: "rdf:Alt", uri: rdf)
        alternate.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: rdf) as! XMLNode)
        let defaultItem = XMLElement(name: "rdf:li", uri: rdf)
        defaultItem.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
        defaultItem.stringValue = value
        alternate.addChild(defaultItem)
        translations.forEach(alternate.addChild)
        replacement.addChild(alternate)
        removeAttributes(name, from: descriptions)
        existing.forEach { $0.detach() }
        descriptions[0].addChild(replacement)
    }

    private static func replaceSubject(_ values: [String], descriptions: [XMLElement]) {
        let existing = matchingProperties("subject", in: descriptions)
        let replacement = existing.first.map(copyWithNamespaceContext) ?? newProperty("subject")
        replacement.setChildren(nil)
        let bag = XMLElement(name: "rdf:Bag", uri: rdf)
        bag.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: rdf) as! XMLNode)
        for value in values {
            let item = XMLElement(name: "rdf:li", uri: rdf)
            item.stringValue = value
            bag.addChild(item)
        }
        replacement.addChild(bag)
        removeAttributes("subject", from: descriptions)
        existing.forEach { $0.detach() }
        descriptions[0].addChild(replacement)
    }

    private static func newProperty(_ name: String) -> XMLElement {
        let element = XMLElement(name: "dc:\(name)", uri: dc)
        element.addNamespace(XMLNode.namespace(withName: "dc", stringValue: dc) as! XMLNode)
        return element
    }

    /// A node moved out of its original ancestors still needs their namespace
    /// declarations, including custom qualifier attributes on translated items.
    private static func copyWithNamespaceContext(_ element: XMLElement) -> XMLElement {
        let copy = element.copy() as! XMLElement
        var declared = Set((copy.namespaces ?? []).compactMap(\.name))
        var ancestor = element.parent as? XMLElement
        while let current = ancestor {
            for namespace in current.namespaces ?? [] {
                guard let prefix = namespace.name, prefix != "xml", declared.insert(prefix).inserted else { continue }
                // Namespace nodes have a distinct libxml representation; copying
                // them as generic XMLNode can corrupt ownership in FoundationXML.
                copy.addNamespace(XMLNode.namespace(withName: prefix, stringValue: namespace.stringValue ?? "") as! XMLNode)
            }
            ancestor = current.parent as? XMLElement
        }
        return copy
    }
}
