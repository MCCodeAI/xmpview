import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import XMPViewCore

final class XMPEditorTests: XCTestCase {
    private let dc = "http://purl.org/dc/elements/1.1/"
    private let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    private func packet(_ properties: String) -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(rdf)"><rdf:Description xmlns:dc="\(dc)" xmlns:custom="urn:test:custom" rdf:about="">
        \(properties)
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """.utf8)
    }

    func testNewPacketRoundTripsAllFields() throws {
        let expected = EditableFields(title: "台北 🌅", description: "A & B\n<第二行>", keywords: ["海边", "城市, 夜色", "\"quoted\""])
        let result = try XMPEditor.replacingFields(in: nil, with: expected)
        XCTAssertEqual(try XMPParser.readFields(from: result), expected)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("rdf:Bag"))
    }

    func testUnknownPropertiesAndLanguageAlternativesSurvive() throws {
        let original = packet("""
        <!-- keep this comment -->
        <custom:camera custom:id="a-1"><custom:model>Example &amp; Camera</custom:model></custom:camera>
        <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© Photographer</rdf:li></rdf:Alt></dc:rights>
        <dc:title><rdf:Alt><rdf:li xml:lang="en">Old English</rdf:li><rdf:li xml:lang="x-default">Old default</rdf:li><rdf:li xml:lang="zh-TW" custom:quality="original">舊標題</rdf:li></rdf:Alt></dc:title>
        <dc:description><rdf:Alt><rdf:li xml:lang="fr">Description française</rdf:li></rdf:Alt></dc:description>
        """)
        let fields = EditableFields(title: "新标题", description: "新描述", keywords: ["新关键词"])
        let result = try XMPEditor.replacingFields(in: original, with: fields)
        let document = try XMLDocument(data: result)
        XCTAssertEqual(try XMPParser.readFields(from: result), fields)
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='model' and namespace-uri()='urn:test:custom']").first?.stringValue, "Example & Camera")
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='camera']/@*[local-name()='id']").first?.stringValue, "a-1")
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='title']//*[local-name()='li'][@xml:lang='en']").first?.stringValue, "Old English")
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='title']//*[local-name()='li'][@xml:lang='zh-TW']/@*[local-name()='quality']").first?.stringValue, "original")
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='description']//*[local-name()='li'][@xml:lang='fr']").first?.stringValue, "Description française")
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("keep this comment"))
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='rights']//*[local-name()='li']").first?.stringValue, "© Photographer")
    }

    func testClearingFieldsDoesNotDeleteOtherLanguages() throws {
        let original = packet("""
        <dc:title><rdf:Alt><rdf:li xml:lang="en">Keep English</rdf:li><rdf:li xml:lang="x-default">Remove default</rdf:li></rdf:Alt></dc:title>
        <dc:description>Old description</dc:description><dc:subject><rdf:Bag><rdf:li>Old</rdf:li></rdf:Bag></dc:subject>
        """)
        let result = try XMPEditor.replacingFields(in: original, with: EditableFields())
        XCTAssertEqual(try XMPParser.readFields(from: result), EditableFields())
        XCTAssertEqual(try XMLDocument(data: result).nodes(forXPath: "//*[local-name()='title']//*[local-name()='li'][@xml:lang='en']").first?.stringValue, "Keep English")
    }

    func testAttributePropertiesAreRemovedToAvoidConflicts() throws {
        let original = Data("""
        <r:RDF xmlns:r="\(rdf)" xmlns:d="\(dc)"><r:Description d:title="Old" d:description="Old description" d:subject="Old keyword"/></r:RDF>
        """.utf8)
        let fields = EditableFields(title: "New", description: "New description", keywords: ["New keyword"])
        let result = try XMPEditor.replacingFields(in: original, with: fields)
        XCTAssertEqual(try XMPParser.readFields(from: result), fields)
        XCTAssertEqual(try XMLDocument(data: result).nodes(forXPath: "//@*[namespace-uri()='\(dc)']").count, 0)
    }

    func testDuplicateDescriptionsAndTranslationsAreConsolidated() throws {
        let original = Data("""
        <r:RDF xmlns:r="\(rdf)" xmlns:d="\(dc)">
        <r:Description><d:title><r:Alt><r:li xml:lang="en">English</r:li><r:li xml:lang="x-default">Old 1</r:li></r:Alt></d:title></r:Description>
        <r:Description xmlns:qual="urn:test:qualifier"><d:title><r:Alt><r:li xml:lang="fr" qual:source="original">Français</r:li><r:li xml:lang="x-default">Old 2</r:li></r:Alt></d:title><qual:keep>Retained</qual:keep></r:Description>
        </r:RDF>
        """.utf8)
        let result = try XMPEditor.replacingFields(in: original, with: EditableFields(title: "New"))
        let document = try XMLDocument(data: result)
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='title' and namespace-uri()='\(dc)']").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='title']//*[local-name()='li'][@xml:lang='fr']/@*[local-name()='source' and namespace-uri()='urn:test:qualifier']").first?.stringValue, "original")
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='keep' and namespace-uri()='urn:test:qualifier']").first?.stringValue, "Retained")
    }

    func testNamespacePrefixCollisionDoesNotChangeUnrelatedNamespace() throws {
        let original = Data("""
        <r:RDF xmlns:r="\(rdf)" xmlns:dc="urn:not:dublin-core"><r:Description><dc:title>Unrelated</dc:title></r:Description></r:RDF>
        """.utf8)
        let result = try XMPEditor.replacingFields(in: original, with: EditableFields(title: "Actual title"))
        XCTAssertEqual(try XMPParser.readFields(from: result).title, "Actual title")
        XCTAssertEqual(try XMLDocument(data: result).nodes(forXPath: "//*[local-name()='title' and namespace-uri()='urn:not:dublin-core']").first?.stringValue, "Unrelated")
    }

    func testEmptyRDFGetsADescription() throws {
        let original = Data("<r:RDF xmlns:r=\"\(rdf)\"/>".utf8)
        let fields = EditableFields(title: "New")
        XCTAssertEqual(try XMPParser.readFields(from: XMPEditor.replacingFields(in: original, with: fields)), fields)
    }

    func testEditingOnlyTitleKeepsUntouchedPropertiesAndOtherResources() throws {
        let original = Data("""
        <r:RDF xmlns:r="\(rdf)" xmlns:d="\(dc)" xmlns:q="urn:qualifier">
        <r:Description r:about="" d:description="Keep attribute form">
        <d:title>Old title</d:title><d:subject q:origin="camera"><r:Seq><r:li>First</r:li><r:li>Second</r:li></r:Seq></d:subject>
        </r:Description>
        <r:Description r:about="urn:other:resource"><d:title>Unrelated title</d:title><d:description>Unrelated description</d:description></r:Description>
        </r:RDF>
        """.utf8)
        var fields = try XMPParser.readFields(from: original)
        XCTAssertEqual(fields.description, "Keep attribute form")
        XCTAssertEqual(fields.keywords, ["First", "Second"])
        fields.title = "New title"
        let result = try XMPEditor.replacingFields(in: original, with: fields)
        let before = try XMLDocument(data: original)
        let after = try XMLDocument(data: result)
        XCTAssertEqual(try XMPParser.readFields(from: result), fields)
        let subjectXPath = "//*[local-name()='subject' and namespace-uri()='\(dc)']"
        XCTAssertEqual(try before.nodes(forXPath: subjectXPath).first?.xmlString, try after.nodes(forXPath: subjectXPath).first?.xmlString)
        let otherXPath = "//*[local-name()='Description'][@*[local-name()='about']='urn:other:resource']"
        XCTAssertEqual(try before.nodes(forXPath: otherXPath).first?.xmlString, try after.nodes(forXPath: otherXPath).first?.xmlString)
        XCTAssertEqual(try after.nodes(forXPath: "//@*[local-name()='description' and namespace-uri()='\(dc)']").first?.stringValue, "Keep attribute form")
    }

    func testNoOpPreservesUneditedRepresentation() throws {
        let original = packet("""
        <dc:title>Simple title</dc:title><dc:description>Simple description</dc:description>
        <dc:subject><rdf:Seq><rdf:li>Keep sequence</rdf:li></rdf:Seq></dc:subject>
        """)
        let fields = try XMPParser.readFields(from: original)
        let result = try XMPEditor.replacingFields(in: original, with: fields)
        XCTAssertEqual(try XMPParser.readFields(from: result), fields)
        XCTAssertEqual(try XMLDocument(data: result).nodes(forXPath: "//*[local-name()='Seq']").count, 1)
        XCTAssertEqual(try XMLDocument(data: result).nodes(forXPath: "//*[local-name()='Alt']").count, 0)
    }

    func testMalformedNonRDFAndEntityPacketsAreRejected() {
        for original in [Data("<root/>".utf8), Data("<broken>".utf8), Data("<!DOCTYPE root><root/>".utf8)] {
            XCTAssertThrowsError(try XMPEditor.replacingFields(in: original, with: EditableFields(title: "New")))
        }
    }
}
