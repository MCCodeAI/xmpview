import Foundation
import XCTest
@testable import XMPViewCore

final class EditableFieldsTests: XCTestCase {
    func testSeparatorsWhitespaceAndDuplicateKeywords() {
        let parsed = EditableFields.parseKeywords(" 风景, 上海，旅行\n风景\r\n  ,City,city  ")
        XCTAssertEqual(parsed, ["风景", "上海", "旅行", "City", "city"])
    }

    func testQuotedKeywordsRoundTripWithoutLosingEmbeddedCommasOrQuotes() {
        let original = EditableFields(keywords: ["城市, 夜色", "中文，逗号", "line\nbreak", "a \"quote\"", "普通"])
        XCTAssertEqual(EditableFields.parseKeywords(original.keywordsText), original.keywords)
    }

    func testEmptyAndQuotedText() {
        XCTAssertEqual(EditableFields.parseKeywords(" ,，\n\r\n \"\""), [])
        XCTAssertEqual(EditableFields.parseKeywords("\"street, night\", portrait"), ["street, night", "portrait"])
        XCTAssertEqual(EditableFields.parseKeywords("rock'n'roll, 3\" print"), ["rock'n'roll", "3\" print"])
    }

    func testKeywordsTextSetter() {
        var fields = EditableFields(title: "标题", description: "描述")
        fields.keywordsText = "one，two,one"
        XCTAssertEqual(fields, EditableFields(title: "标题", description: "描述", keywords: ["one", "two"]))
    }

    func testSupportedExtensions() {
        for (file, format) in [("a.JPG", ImageFormat.jpeg), ("a.jpeg", .jpeg), ("a.PNG", .png), ("a.heic", .heic), ("a.HEIF", .heic)] {
            XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: file)), format)
        }
        XCTAssertNil(ImageFormat(url: URL(fileURLWithPath: "a.gif")))
        XCTAssertNil(ImageFormat(url: URL(fileURLWithPath: "a.jpg.exe")))
    }

    func testXMPAbsentAndUnavailableAreDistinct() {
        XCTAssertNotEqual(XMPReadState.absent, .unavailable)
        XCTAssertNotEqual(XMPReadState.absent.label, XMPReadState.unavailable.label)
        XCTAssertTrue(XMPReadState.unavailable.detail.contains("不能据此判断"))
    }
}
