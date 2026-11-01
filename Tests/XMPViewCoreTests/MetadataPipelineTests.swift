import Foundation
import XCTest
@testable import XMPViewCore

/// Tiny real, independently encoded images exercise the entire portable path.
/// Generated outputs also allow a separate decoder to verify pixel preservation.
final class MetadataPipelineTests: XCTestCase {
    func testJPEGFilePipeline() throws { try roundTrip(.jpeg, extension: "jpg") }
    func testPNGFilePipeline() throws { try roundTrip(.png, extension: "png") }

    private func roundTrip(_ format: ImageFormat, extension suffix: String) throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: suffix, subdirectory: "Fixtures"))
        let original = try Data(contentsOf: fixture)
        let packet = try XCTUnwrap(EmbeddedXMP.extract(from: original, format: format))
        XCTAssertEqual(try XMPParser.readFields(from: packet).title, "Original title")
        let expected = EditableFields(title: "山与海 🌊", description: "中文\n<&> \"quoted\"",
                                      keywords: ["台北", "city, night", "photo"])
        let editedPacket = try XMPEditor.replacingFields(in: packet, with: expected)
        let saved = try EmbeddedXMP.replacing(in: original, format: format, xmp: editedPacket)
        let reopened = try XCTUnwrap(EmbeddedXMP.extract(from: saved, format: format))
        XCTAssertEqual(try XMPParser.readFields(from: reopened), expected)
        XCTAssertTrue(String(decoding: reopened, as: UTF8.self).contains("preserve-me"))
        // Restoring the exact old XMP must restore the entire original file.
        XCTAssertEqual(try EmbeddedXMP.replacing(in: saved, format: format, xmp: packet), original)
        let clearedPacket = try XMPEditor.replacingFields(in: reopened, with: EditableFields())
        let cleared = try EmbeddedXMP.replacing(in: saved, format: format, xmp: clearedPacket)
        XCTAssertEqual(try XMPParser.readFields(from: XCTUnwrap(EmbeddedXMP.extract(from: cleared, format: format))), EditableFields())
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/smoke-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try saved.write(to: output.appendingPathComponent("edited.\(suffix)"))
        try cleared.write(to: output.appendingPathComponent("cleared.\(suffix)"))
    }
}
