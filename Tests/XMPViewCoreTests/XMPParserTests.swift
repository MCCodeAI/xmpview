import Foundation
import XCTest
@testable import XMPViewCore

final class XMPParserTests: XCTestCase {
    private func packet(_ properties: String, dcPrefix: String = "dc", rdfPrefix: String = "rdf") -> Data {
        Data("""
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <\(rdfPrefix):RDF xmlns:\(rdfPrefix)="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <\(rdfPrefix):Description xmlns:\(dcPrefix)="http://purl.org/dc/elements/1.1/">
              \(properties)
            </\(rdfPrefix):Description>
          </\(rdfPrefix):RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    func testUnicodeEntitiesMultilineAndKeywords() throws {
        let data = packet("""
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">台北 &amp; 光</rdf:li></rdf:Alt></dc:title>
        <dc:description><rdf:Alt><rdf:li xml:lang="x-default">第一行
        第二行 &lt;记录&gt; 🌅</rdf:li></rdf:Alt></dc:description>
        <dc:subject><rdf:Bag><rdf:li>城市, 夜色</rdf:li><rdf:li>旅行</rdf:li></rdf:Bag></dc:subject>
        """)
        let fields = try XMPParser.readFields(from: data)
        XCTAssertEqual(fields.title, "台北 & 光")
        XCTAssertEqual(fields.description, "第一行\n第二行 <记录> 🌅")
        XCTAssertEqual(fields.keywords, ["城市, 夜色", "旅行"])
    }

    func testNamespaceURIsWorkWithDifferentPrefixes() throws {
        let fields = try XMPParser.readFields(from: packet("""
        <content:title><r:Alt><r:li xml:lang="x-default">Alternate prefix</r:li></r:Alt></content:title>
        <content:subject><r:Seq><r:li>first</r:li><r:li>second</r:li></r:Seq></content:subject>
        """, dcPrefix: "content", rdfPrefix: "r"))
        XCTAssertEqual(fields, EditableFields(title: "Alternate prefix", keywords: ["first", "second"]))
    }

    func testDefaultLanguageWinsRegardlessOfPosition() throws {
        let fields = try XMPParser.readFields(from: packet("""
        <dc:title><rdf:Alt><rdf:li xml:lang="en">English</rdf:li><rdf:li xml:lang="x-default">默认</rdf:li></rdf:Alt></dc:title>
        <dc:description><rdf:Alt><rdf:li xml:lang="zh-TW">優先的第一項</rdf:li><rdf:li xml:lang="en">Second</rdf:li></rdf:Alt></dc:description>
        """))
        XCTAssertEqual(fields.title, "默认")
        XCTAssertEqual(fields.description, "優先的第一項")
    }

    func testExplicitlyEmptyDefaultLanguageRemainsEmpty() throws {
        let fields = try XMPParser.readFields(from: packet("""
        <dc:title><rdf:Alt><rdf:li xml:lang="en">English</rdf:li><rdf:li xml:lang="x-default"/></rdf:Alt></dc:title>
        """))
        XCTAssertEqual(fields.title, "")
    }

    func testMissingFieldsAndEmptyContainers() throws {
        XCTAssertEqual(try XMPParser.readFields(from: packet("")), EditableFields())
        XCTAssertEqual(try XMPParser.readFields(from: packet("<dc:subject><rdf:Bag/></dc:subject><dc:title/>")), EditableFields())
    }

    func testSimplePropertiesAndCDATA() throws {
        let fields = try XMPParser.readFields(from: packet("""
        <dc:title><![CDATA[A <title> & a name]]></dc:title>
        <dc:description>plain text</dc:description><dc:subject>single keyword</dc:subject>
        """))
        XCTAssertEqual(fields, EditableFields(title: "A <title> & a name", description: "plain text", keywords: ["single keyword"]))
    }

    func testSimpleRDFAttributes() throws {
        let data = Data("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:d="http://purl.org/dc/elements/1.1/">
        <rdf:Description d:title="A title" d:description="A &amp; B" d:subject="keyword"/>
        </rdf:RDF>
        """.utf8)
        XCTAssertEqual(try XMPParser.readFields(from: data), EditableFields(title: "A title", description: "A & B", keywords: ["keyword"]))
    }

    func testSameLocalNamesInOtherNamespacesAreIgnored() throws {
        let fields = try XMPParser.readFields(from: packet("""
        <other:title xmlns:other="urn:example:other">Wrong</other:title>
        <dc:title>Correct</dc:title>
        """))
        XCTAssertEqual(fields.title, "Correct")
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try XMPParser.readFields(from: packet("<dc:title>broken</dc:description>"))) { error in
            guard case XMPParserError.malformedXML = error else {
                return XCTFail("Expected malformed XML, got \(error)")
            }
        }
        XCTAssertThrowsError(try XMPParser.readFields(from: Data()))
        XCTAssertThrowsError(try XMPParser.readFields(from: Data("<broken>".utf8)))
        XCTAssertThrowsError(try XMPParser.readFields(from: Data("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>truncated
        """.utf8)))
    }

    func testStructuredFieldsAreRejectedRatherThanSilentlyFlattened() {
        XCTAssertThrowsError(try XMPParser.readFields(from: packet("""
        <dc:title><rdf:Alt><rdf:li><rdf:Description>structured</rdf:Description></rdf:li></rdf:Alt></dc:title>
        """))) { error in
            XCTAssertEqual(error as? XMPParserError, .unsupportedValue(field: "title"))
        }
    }

    func testTypedRDFPropertiesAreRejected() {
        for property in [
            "<dc:title rdf:resource=\"urn:example:value\"/>",
            "<dc:title rdf:datatype=\"http://www.w3.org/2001/XMLSchema#string\">Typed</dc:title>",
            "<dc:subject><rdf:Bag><rdf:li rdf:resource=\"urn:example:value\"/></rdf:Bag></dc:subject>"
        ] {
            XCTAssertThrowsError(try XMPParser.readFields(from: packet(property)))
        }
    }

    func testNestedDublinCorePropertiesDoNotOverridePrimaryResource() throws {
        let fields = try XMPParser.readFields(from: packet("""
        <custom:object xmlns:custom="urn:test:custom"><rdf:Description><dc:title>Nested object</dc:title></rdf:Description></custom:object>
        <dc:title>Image title</dc:title>
        """))
        XCTAssertEqual(fields.title, "Image title")
    }

    func testEntityDeclarationsAreRejectedWithoutResolvingFiles() {
        let xml = """
        <!DOCTYPE x [<!ENTITY external SYSTEM "file:///etc/passwd">]>
        <x xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>&external;</dc:title></x>
        """
        for data in [Data(xml.utf8), xml.data(using: .utf16)!, xml.data(using: .utf32)!] {
            XCTAssertThrowsError(try XMPParser.readFields(from: data)) { error in
                XCTAssertEqual(error as? XMPParserError, .prohibitedDeclaration)
            }
        }
    }

    func testOversizedPacketsAreRejected() {
        XCTAssertThrowsError(try XMPParser.readFields(from: Data(repeating: 32, count: XMPParser.maximumByteCount + 1))) { error in
            XCTAssertEqual(error as? XMPParserError, .documentTooLarge)
        }
    }
}
