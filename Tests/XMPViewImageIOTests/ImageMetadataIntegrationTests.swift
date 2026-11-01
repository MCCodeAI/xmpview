#if os(macOS)
import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XMPViewCore
@testable import XMPViewImageIO

/// These tests execute Apple's actual encoders and readers. They must run on macOS.
final class ImageMetadataIntegrationTests: XCTestCase {
    private var directory: URL!
    private let service = ImageMetadataService()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMPViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testPNGRoundTrip() throws { try roundTrip(type: .png, extension: "png") }
    func testJPEGRoundTrip() throws { try roundTrip(type: .jpeg, extension: "jpg") }

    func testHEICIsReadOnlyWithoutChangingSource() throws {
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard supported.contains(UTType.heic.identifier) else {
            throw XCTSkip("This Mac does not expose an HEIC encoder to generate a read-only fixture.")
        }
        let url = try fixture(type: .heic, extension: "heic", withXMP: false)
        let bytes = try Data(contentsOf: url)
        let document = try service.read(url)
        XCTAssertFalse(document.canWrite)
        XCTAssertThrowsError(try service.save(document,
            fields: EditableFields(title: "unsupported edit", description: "", keywords: []), to: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAbsentXMPIsDistinctFromUnreadableFile() throws {
        let url = try fixture(type: .png, extension: "png", withXMP: false)
        let document = try service.read(url)
        switch document.xmpState {
        case .absent: break
        default: XCTFail("A readable PNG with no XMP must be reported as absent.")
        }
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("This is not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try service.read(invalid))
    }

    func testSaveAsLeavesOriginalUntouchedAndRefusesExistingTarget() throws {
        let source = try fixture(type: .jpeg, extension: "jpg")
        let originalBytes = try Data(contentsOf: source)
        let document = try service.read(source)
        let fields = EditableFields(title: "副本", description: "Original stays intact", keywords: ["copy"])
        let target = directory.appendingPathComponent("copy.jpg")
        let result = try service.save(document, fields: fields, to: target)
        XCTAssertEqual(result.document.fields, fields)
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        let savedBytes = try Data(contentsOf: target)
        XCTAssertThrowsError(try service.save(document, fields: fields, to: target))
        XCTAssertEqual(try Data(contentsOf: target), savedBytes)
    }

    func testStaleSourceIsNotOverwritten() throws {
        let url = try fixture(type: .png, extension: "png")
        let document = try service.read(url)
        // Change the source externally after opening it in the editor.
        let replacement = try fixture(type: .png, extension: "png", withXMP: false)
        let replacementBytes = try Data(contentsOf: replacement)
        try replacementBytes.write(to: url, options: .atomic)
        XCTAssertThrowsError(try service.save(document,
            fields: EditableFields(title: "stale edit", description: "", keywords: []), to: url))
        XCTAssertEqual(try Data(contentsOf: url), replacementBytes)
    }

    func testMismatchedExtensionIsRejectedWithoutCreatingOutput() throws {
        let url = try fixture(type: .jpeg, extension: "jpg")
        let document = try service.read(url)
        let target = directory.appendingPathComponent("misleading.png")
        XCTAssertThrowsError(try service.save(document,
            fields: EditableFields(title: "edit", description: "", keywords: []), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    private func roundTrip(type: UTType, extension fileExtension: String) throws {
        let url = try fixture(type: type, extension: fileExtension)
        let beforeBytes = try Data(contentsOf: url)
        let beforeProperties = try properties(url)
        let beforePixels = try decodedPixels(url)
        let document = try service.read(url)
        XCTAssertEqual(document.width, 12)
        XCTAssertEqual(document.height, 9)
        let fields = EditableFields(title: "台湾 · 山与海 🌊", description: "第一行\nSecond line <&> \"quoted\"",
                                    keywords: ["山", "travel", "台北"])
        let result = try service.save(document, fields: fields, to: url)
        XCTAssertEqual(result.document.fields, fields)
        XCTAssertEqual(try service.read(url).fields, fields)
        let backup = try XCTUnwrap(result.backupURL, "Replacing the original requires a backup.")
        XCTAssertEqual(try Data(contentsOf: backup), beforeBytes)
        XCTAssertEqual(try decodedPixels(url), beforePixels, "Editing metadata must not change decoded pixels.")
        try assertUnrelatedPropertiesPreserved(before: beforeProperties, after: properties(url))
        XCTAssertTrue(result.document.rawXMP?.contains("retained-marker") == true,
                      "Custom XMP outside the three edited fields must survive.")

        let cleared = EditableFields(title: "", description: "", keywords: [])
        let clearResult = try service.save(result.document, fields: cleared, to: url)
        XCTAssertEqual(clearResult.document.fields, cleared)
        XCTAssertEqual(try service.read(url).fields, cleared)
        XCTAssertEqual(try decodedPixels(url), beforePixels)
    }

    private func fixture(type: UTType, extension fileExtension: String, withXMP: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).\(fileExtension)")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 9, bitsPerComponent: 8,
            bytesPerRow: 12 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 9))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: 5, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            type.identifier as CFString, 1, nil))
        let options: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:04:05 06:07:08"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 25.033, kCGImagePropertyGPSLatitudeRef: "N",
                                           kCGImagePropertyGPSLongitude: 121.5654, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCredit: "Preserved credit"],
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        if withXMP {
            let xml = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:custom="https://xmpview.example/metadata/1.0/">
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Original title</rdf:li></rdf:Alt></dc:title>
            <custom:marker>retained-marker</custom:marker></rdf:Description></rdf:RDF></x:xmpmeta>
            """
            let metadata = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData))
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination), "Fixture encoder failed for \(type.identifier).")
        if withXMP {
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(reader, 0, nil),
                "Fixture must actually embed XMP for \(type.identifier).")
            let xmp = try XCTUnwrap(CGImageMetadataCreateXMPData(metadata, nil))
            XCTAssertTrue(String(decoding: xmp as Data, as: UTF8.self).contains("retained-marker"))
        }
        return url
    }

    private func properties(_ url: URL) throws -> NSDictionary {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) as NSDictionary
    }

    private func assertUnrelatedPropertiesPreserved(before: NSDictionary, after: NSDictionary) throws {
        // Different formats expose different properties; every property that was
        // actually encoded must remain, rather than assuming JPEG behavior for PNG/HEIC.
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let original = before[key] as? NSDictionary {
                let saved = try XCTUnwrap(after[key] as? NSDictionary, "Lost metadata group \(key)")
                for (field, value) in original {
                    let fieldName = try XCTUnwrap(field as? String)
                    XCTAssertTrue((saved[fieldName] as? NSObject)?.isEqual(value) == true,
                                  "Changed unrelated metadata \(key).\(fieldName)")
                }
            }
        }
    }

    private func decodedPixels(_ url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data)
        return Data(bytes: pointer, count: image.height * context.bytesPerRow)
    }
}
#endif
