import Foundation
import XCTest
@testable import XMPViewCore

final class EmbeddedXMPTests: XCTestCase {
    private let packet = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">标题 🖼️</x:xmpmeta>".utf8)
    private let jpegPrefix = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    private let pngKeyword = Array("XML:com.adobe.xmp".utf8)

    func testJPEGInsertPreservesOriginalSegmentsAndEntropyBytes() throws {
        let source = jpeg()
        XCTAssertNil(try EmbeddedXMP.extract(from: source, format: .jpeg))
        let result = try EmbeddedXMP.replacing(in: source, format: .jpeg, xmp: packet)
        XCTAssertEqual(try EmbeddedXMP.extract(from: result, format: .jpeg), packet)
        let addedCount = jpegPrefix.count + packet.count + 4
        XCTAssertEqual(result.prefix(2), source.prefix(2))
        XCTAssertEqual(result.dropFirst(2 + addedCount), source.dropFirst(2))
    }

    func testJPEGInsertKeepsLeadingJFIFAndJFXXSegmentsImmediatelyAfterSOI() throws {
        let jfifPayload: [UInt8] = [74, 70, 73, 70, 0, 1, 2, 0, 0, 1, 0, 1, 0, 0]
        let jfif = jpegSegment(0xe0, jfifPayload)
        let jfxx = jpegSegment(0xe0, [74, 70, 88, 88, 0, 0x13, 1, 1, 0, 0, 0])
        var source = Data([0xff, 0xd8])
        source.append(contentsOf: jfif)
        source.append(contentsOf: jfxx)
        source.append(jpeg().dropFirst(2))
        let originalPrefixCount = 2 + jfif.count + jfxx.count
        let result = try EmbeddedXMP.replacing(in: source, format: .jpeg, xmp: packet)
        XCTAssertEqual(result.prefix(originalPrefixCount), source.prefix(originalPrefixCount))
        XCTAssertEqual(Array(result[2..<4]), [0xff, 0xe0])
        XCTAssertEqual(try EmbeddedXMP.extract(from: result, format: .jpeg), packet)
        let addedCount = jpegPrefix.count + packet.count + 4
        var restored = Data(result.prefix(originalPrefixCount))
        restored.append(result.dropFirst(originalPrefixCount + addedCount))
        XCTAssertEqual(restored, source)
    }

    func testJPEGReplaceIsByteExactOutsideXMP() throws {
        let old = jpegSegment(0xe1, joined(jpegPrefix, Array("old".utf8)))
        let original = jpeg(extra: old)
        let new = jpegSegment(0xe1, joined(jpegPrefix, Array(packet)))
        let changed = try EmbeddedXMP.replacing(in: original, format: .jpeg, xmp: packet)
        XCTAssertEqual(changed, jpeg(extra: new))
        XCTAssertEqual(try EmbeddedXMP.replacing(in: changed, format: .jpeg, xmp: packet), changed)
    }

    func testJPEGDuplicateAndExtendedXMPAreRejected() throws {
        let standard = jpegSegment(0xe1, joined(jpegPrefix, Array(packet)))
        let extended = jpegSegment(0xe1, joined(Array("http://ns.adobe.com/xmp/extension/\0".utf8), [1, 2, 3]))
        assertError(.duplicateXMP) { try EmbeddedXMP.extract(from: jpeg(extra: joined(standard, standard)), format: .jpeg) }
        assertError(.extendedXMP) { try EmbeddedXMP.extract(from: jpeg(extra: joined(standard, extended)), format: .jpeg) }
        assertError(.extendedXMP) { try EmbeddedXMP.replacing(in: jpeg(extra: extended), format: .jpeg, xmp: packet) }
    }

    func testJPEGMaximumPacketLengthAndOverflow() throws {
        let limit = 65_533 - jpegPrefix.count
        let maximum = Data(repeating: 65, count: limit)
        let result = try EmbeddedXMP.replacing(in: jpeg(), format: .jpeg, xmp: maximum)
        XCTAssertEqual(try EmbeddedXMP.extract(from: result, format: .jpeg), maximum)
        assertError(.packetTooLarge) {
            try EmbeddedXMP.replacing(in: jpeg(), format: .jpeg, xmp: Data(repeating: 65, count: limit + 1))
        }
    }

    func testJPEGTruncationMalformedMarkersAndMissingEndAreRejected() {
        let invalid: [[UInt8]] = [[], [0xff, 0xd8], [0xff, 0xd8, 0xff],
                                 [0xff, 0xd8, 0xff, 0xe1, 0, 1, 0xff, 0xd9],
                                 [0xff, 0xd8, 0xff, 0xe1, 0, 10, 0xff, 0xd9],
                                 [0xff, 0xd8, 0xff, 0x00, 0xff, 0xd9],
                                 [0xff, 0xd8, 0xff, 0xda, 0, 2, 0xff, 0xd9]]
        for bytes in invalid {
            assertError(.invalidJPEG) { try EmbeddedXMP.extract(from: Data(bytes), format: .jpeg) }
        }
        assertError(.invalidJPEG) { try EmbeddedXMP.extract(from: Data(jpeg().dropLast(2)), format: .jpeg) }
    }

    func testJPEGFindsMetadataBetweenProgressiveScansWithoutChangingScanBytes() throws {
        let old = jpegSegment(0xe1, joined(jpegPrefix, Array("old".utf8)))
        let firstScan = joined(jpegSegment(0xda, [1, 1, 0, 0, 0, 0]), [0x28, 0xff, 0x00, 0x11])
        let secondScan = joined(jpegSegment(0xda, [1, 1, 0, 1, 63, 0]), [0x31, 0xff, 0xd9])
        let source = Data(joined([0xff, 0xd8], firstScan, old, secondScan))
        let new = jpegSegment(0xe1, joined(jpegPrefix, Array(packet)))
        let expected = Data(joined([0xff, 0xd8], firstScan, new, secondScan))
        XCTAssertEqual(try EmbeddedXMP.replacing(in: source, format: .jpeg, xmp: packet), expected)
    }

    func testPNGInsertPreservesEveryOtherChunkAndAddsValidCRC() throws {
        let source = png(extra: pngChunk("tEXt", Array("Comment\0untouched".utf8)))
        XCTAssertNil(try EmbeddedXMP.extract(from: source, format: .png))
        let result = try EmbeddedXMP.replacing(in: source, format: .png, xmp: packet)
        XCTAssertEqual(try EmbeddedXMP.extract(from: result, format: .png), packet)
        let expectedChunks = joined(pngChunk("tEXt", Array("Comment\0untouched".utf8)), xmpChunk(packet))
        XCTAssertEqual(result, png(extra: expectedChunks))
        XCTAssertEqual(try EmbeddedXMP.replacing(in: result, format: .png, xmp: packet), result)
    }

    func testPNGReplaceRetainsOtherChunksExactly() throws {
        let comment = pngChunk("tEXt", Array("Description\0retain me".utf8))
        let source = png(extra: joined(xmpChunk(Data("old".utf8)), comment))
        let expected = png(extra: joined(xmpChunk(packet), comment))
        XCTAssertEqual(try EmbeddedXMP.replacing(in: source, format: .png, xmp: packet), expected)
    }

    func testPNGParsesLanguageAndTranslatedKeyword() throws {
        let payload = joined(pngKeyword, [0, 0, 0], Array("zh-TW\0标题\0".utf8), Array(packet))
        XCTAssertEqual(try EmbeddedXMP.extract(from: png(extra: pngChunk("iTXt", payload)), format: .png), packet)
    }

    func testPNGDuplicateCompressedAndNonstandardXMPAreRejected() {
        assertError(.duplicateXMP) {
            try EmbeddedXMP.extract(from: png(extra: joined(xmpChunk(packet), xmpChunk(packet))), format: .png)
        }
        let compressed = pngChunk("iTXt", joined(pngKeyword, [0, 1, 0, 0, 0, 120, 156]))
        assertError(.compressedXMP) { try EmbeddedXMP.extract(from: png(extra: compressed), format: .png) }
        assertError(.compressedXMP) {
            try EmbeddedXMP.replacing(in: png(extra: compressed), format: .png, xmp: packet)
        }
        for type in ["tEXt", "zTXt"] {
            assertError(.unsupportedXMPStorage) {
                try EmbeddedXMP.extract(from: png(extra: pngChunk(type, joined(pngKeyword, [0, 65]))), format: .png)
            }
        }
    }

    func testPNGRejectsCorruptCRCTruncationAndTrailingBytes() {
        var corrupt = png()
        corrupt[corrupt.count - 1] ^= 1
        assertError(.invalidPNGChecksum) { try EmbeddedXMP.extract(from: corrupt, format: .png) }
        assertError(.invalidPNG) { try EmbeddedXMP.extract(from: Data(png().dropLast()), format: .png) }
        assertError(.invalidPNG) { try EmbeddedXMP.extract(from: png() + Data([0]), format: .png) }
        assertError(.invalidPNG) { try EmbeddedXMP.extract(from: Data([137, 80, 78, 71]), format: .png) }
    }

    func testPNGRejectsDisorderedOrMissingRequiredChunks() {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let header = pngHeader()
        let imageData = pngIDAT()
        let end = pngChunk("IEND", [])
        var invalid: [[UInt8]] = []
        invalid.append(joined(signature, imageData, header, end))
        invalid.append(joined(signature, header, header, imageData, end))
        invalid.append(joined(signature, header, end))
        let comment = pngChunk("tEXt", Array("A\0B".utf8))
        invalid.append(joined(signature, header, imageData, comment, imageData, end))
        let palette = pngChunk("PLTE", [0, 0, 0])
        invalid.append(joined(signature, header, imageData, palette, end))
        for bytes in invalid {
            assertError(.invalidPNG) { try EmbeddedXMP.extract(from: Data(bytes), format: .png) }
        }
    }

    func testPNGRejectsUnknownCriticalChunksAndInvalidTextFields() {
        assertError(.unsupportedPNGChunk("ABCD")) {
            try EmbeddedXMP.extract(from: png(extra: pngChunk("ABCD", [])), format: .png)
        }
        let invalidSuffixes: [[UInt8]] = [[0], [0, 2, 0, 0, 0], [0, 0, 1, 0, 0], [0, 0, 0, 65]]
        for suffix in invalidSuffixes {
            assertError(.invalidPNG) {
                try EmbeddedXMP.extract(from: png(extra: pngChunk("iTXt", joined(pngKeyword, suffix))), format: .png)
            }
        }
        assertError(.invalidUTF8) {
            try EmbeddedXMP.extract(from: png(extra: xmpChunk(Data([0xff]))), format: .png)
        }
    }

    func testPNGPreservesUnrelatedCompressedInternationalText() throws {
        let text = pngChunk("iTXt", joined(Array("Description".utf8), [0, 1, 0, 0, 0, 120, 156]))
        let source = png(extra: text)
        XCTAssertNil(try EmbeddedXMP.extract(from: source, format: .png))
        let expected = png(extra: joined(text, xmpChunk(packet)))
        XCTAssertEqual(try EmbeddedXMP.replacing(in: source, format: .png, xmp: packet), expected)
    }

    func testHEICIsExplicitlyUnsupportedAndInvalidOutputEncodingIsRejected() {
        assertError(.unsupportedFormat) { try EmbeddedXMP.extract(from: Data(), format: .heic) }
        assertError(.unsupportedFormat) { try EmbeddedXMP.replacing(in: Data(), format: .heic, xmp: packet) }
        assertError(.invalidUTF8) { try EmbeddedXMP.replacing(in: jpeg(), format: .jpeg, xmp: Data([0xff])) }
        assertError(.invalidUTF8) { try EmbeddedXMP.replacing(in: png(), format: .png, xmp: Data([0xff])) }
    }

    private func assertError<T>(_ expected: EmbeddedXMPError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? EmbeddedXMPError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    private func jpeg(extra: [UInt8] = []) -> Data {
        // A marker stream with EXIF, a comment, SOF and SOS headers, escaped
        // entropy bytes and a restart marker. No decoder is used by the codec.
        let exifPayload = joined(Array("Exif\0\0".utf8), [73, 73, 42, 0, 8, 0, 0, 0])
        let exif = jpegSegment(0xe1, exifPayload)
        let comment = jpegSegment(0xfe, Array("original comment".utf8))
        let frame = jpegSegment(0xc0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0])
        let scan = jpegSegment(0xda, [1, 1, 0, 0, 63, 0])
        let entropy: [UInt8] = [0x23, 0xff, 0, 0x10, 0xff, 0xd0, 0x42, 0xff, 0xd9]
        return Data(joined([0xff, 0xd8], exif, extra, comment, frame, scan, entropy))
    }

    private func jpegSegment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        var segment: [UInt8] = [0xff, marker, UInt8(length >> 8), UInt8(length & 255)]
        segment.append(contentsOf: payload)
        return segment
    }

    private func png(extra: [UInt8] = []) -> Data {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return Data(joined(signature, pngHeader(), pngIDAT(), extra, pngChunk("IEND", [])))
    }

    private func pngHeader() -> [UInt8] {
        pngChunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
    }

    private func pngIDAT() -> [UInt8] {
        // zlib stream containing the filter byte and a transparent RGBA pixel.
        pngChunk("IDAT", [120, 156, 99, 96, 0, 2, 0, 0, 5, 0, 1])
    }

    private func xmpChunk(_ xmp: Data) -> [UInt8] {
        pngChunk("iTXt", joined(pngKeyword, [0, 0, 0, 0, 0], Array(xmp)))
    }

    private func pngChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = Array(type.utf8)
        body.append(contentsOf: payload)
        var chunk: [UInt8] = uint32(UInt32(payload.count))
        chunk.append(contentsOf: body)
        chunk.append(contentsOf: uint32(referenceCRC(body)))
        return chunk
    }

    private func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }

    private func referenceCRC(_ bytes: [UInt8]) -> UInt32 {
        // A table-based reference differs from the production bitwise loop.
        var table: [UInt32] = []
        for value in 0..<256 {
            var remainder = UInt32(value)
            for _ in 0..<8 {
                if remainder & 1 == 1 {
                    remainder = 0xedb8_8320 ^ (remainder >> 1)
                } else {
                    remainder >>= 1
                }
            }
            table.append(remainder)
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 255)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    private func joined(_ parts: [UInt8]...) -> [UInt8] {
        var bytes: [UInt8] = []
        for part in parts { bytes.append(contentsOf: part) }
        return bytes
    }
}
