import Foundation

public enum EmbeddedXMPError: LocalizedError, Equatable {
    case invalidJPEG
    case invalidPNG
    case invalidPNGChecksum
    case duplicateXMP
    case extendedXMP
    case compressedXMP
    case unsupportedXMPStorage
    case unsupportedPNGChunk(String)
    case unsupportedFormat
    case packetTooLarge
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidJPEG: return "JPEG 文件结构无效或数据不完整，无法安全读写 XMP。"
        case .invalidPNG: return "PNG 文件结构无效或区块顺序错误，无法安全读写 XMP。"
        case .invalidPNGChecksum: return "PNG 区块校验失败，无法安全读写 XMP。"
        case .duplicateXMP: return "图片包含多个 XMP 数据包，无法确定应编辑哪一个。"
        case .extendedXMP: return "暂不支持 JPEG 扩展 XMP，已禁止写入以保护原有元数据。"
        case .compressedXMP: return "暂不支持压缩的 PNG XMP，已禁止写入以保护原有元数据。"
        case .unsupportedXMPStorage: return "XMP 使用了非标准 PNG 文本区块，无法安全编辑。"
        case let .unsupportedPNGChunk(name): return "PNG 包含不支持的关键区块 \(name)，无法安全编辑。"
        case .unsupportedFormat: return "暂不支持直接读写 HEIC 内嵌 XMP。"
        case .packetTooLarge: return "XMP 数据过大，无法写入此格式的元数据区块。"
        case .invalidUTF8: return "XMP 文本不是有效的 UTF-8 编码，无法安全编辑。"
        }
    }
}

/// Changes only the XMP container. JPEG scan data and every other segment or
/// PNG chunk retain their original bytes; no image decoder or encoder is used.
public enum EmbeddedXMP {
    private static let jpegPrefix = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    private static let extendedPrefix = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let pngKeyword = Array("XML:com.adobe.xmp".utf8)

    public static func extract(from data: Data, format: ImageFormat) throws -> Data? {
        let bytes = Array(data)
        switch format {
        case .jpeg:
            return try jpegPacket(in: bytes).map { Data(bytes[$0.content]) }
        case .png:
            return try pngLayout(in: bytes).packet.map { Data(bytes[$0.content]) }
        case .heic:
            throw EmbeddedXMPError.unsupportedFormat
        }
    }

    public static func replacing(in data: Data, format: ImageFormat, xmp: Data) throws -> Data {
        if case .heic = format { throw EmbeddedXMPError.unsupportedFormat }
        guard String(data: xmp, encoding: .utf8) != nil else { throw EmbeddedXMPError.invalidUTF8 }
        let bytes = Array(data)
        switch format {
        case .jpeg:
            guard xmp.count <= 65_533 - jpegPrefix.count else { throw EmbeddedXMPError.packetTooLarge }
            let packet = try jpegPacket(in: bytes)
            let payloadLength = jpegPrefix.count + xmp.count + 2
            var segment = Data([0xff, 0xe1, UInt8(payloadLength >> 8), UInt8(payloadLength & 255)])
            segment.append(contentsOf: jpegPrefix)
            segment.append(xmp)
            let range: Range<Int>
            if let packet {
                range = packet.container
            } else {
                let insertion = try jpegInsertionOffset(in: bytes)
                range = insertion..<insertion
            }
            return replacing(bytes, range: range, with: segment)
        case .png:
            // PNG chunk lengths are limited to 2^31 - 1 bytes by the format.
            guard xmp.count <= 0x7fff_ffff - pngKeyword.count - 5 else {
                throw EmbeddedXMPError.packetTooLarge
            }
            let layout = try pngLayout(in: bytes)
            var payload = pngKeyword
            // Keyword terminator, no compression, method 0, empty language and
            // empty translated keyword. The remaining bytes are UTF-8 XMP.
            payload.append(contentsOf: [0, 0, 0, 0, 0])
            payload.append(contentsOf: xmp)
            let chunk = pngChunk(type: Array("iTXt".utf8), payload: payload)
            return replacing(bytes, range: layout.packet?.container ?? (layout.iend..<layout.iend), with: chunk)
        case .heic:
            throw EmbeddedXMPError.unsupportedFormat
        }
    }

    private struct Packet {
        var container: Range<Int>
        var content: Range<Int>
    }

    private static func replacing(_ bytes: [UInt8], range: Range<Int>, with replacement: Data) -> Data {
        var result = Data(bytes[..<range.lowerBound])
        result.append(replacement)
        result.append(contentsOf: bytes[range.upperBound...])
        return result
    }

    private static func jpegInsertionOffset(in bytes: [UInt8]) throws -> Int {
        // JFIF requires its APP0 marker immediately after SOI. Keep the leading
        // APP0 sequence (including any JFXX extension and fill bytes) first.
        var offset = 2
        while offset < bytes.count {
            var marker = offset
            while marker < bytes.count, bytes[marker] == 0xff { marker += 1 }
            guard marker < bytes.count else { throw EmbeddedXMPError.invalidJPEG }
            guard bytes[marker] == 0xe0 else { return offset }
            let lengthStart = marker + 1
            guard bytes.count - lengthStart >= 2 else { throw EmbeddedXMPError.invalidJPEG }
            let length = Int(bytes[lengthStart]) << 8 | Int(bytes[lengthStart + 1])
            guard length >= 2, length <= bytes.count - lengthStart else { throw EmbeddedXMPError.invalidJPEG }
            offset = lengthStart + length
        }
        throw EmbeddedXMPError.invalidJPEG
    }

    private static func jpegPacket(in bytes: [UInt8]) throws -> Packet? {
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw EmbeddedXMPError.invalidJPEG
        }
        var cursor = 2
        var packet: Packet?
        var inScan = false
        while cursor < bytes.count {
            var cameFromScan = false
            if inScan {
                // Skip entropy-coded bytes, preserving escaped FF bytes and
                // restart markers. Other markers terminate this scan.
                while cursor < bytes.count {
                    guard bytes[cursor] == 0xff else { cursor += 1; continue }
                    let start = cursor
                    while cursor < bytes.count, bytes[cursor] == 0xff { cursor += 1 }
                    guard cursor < bytes.count else { throw EmbeddedXMPError.invalidJPEG }
                    let marker = bytes[cursor]
                    if marker == 0 || marker == 1 || (0xd0...0xd7).contains(marker) {
                        cursor += 1
                    } else {
                        cursor = start
                        break
                    }
                }
                inScan = false
                cameFromScan = true
            }
            guard cursor < bytes.count, bytes[cursor] == 0xff else { throw EmbeddedXMPError.invalidJPEG }
            while cursor < bytes.count, bytes[cursor] == 0xff { cursor += 1 }
            guard cursor < bytes.count else { throw EmbeddedXMPError.invalidJPEG }
            let marker = bytes[cursor]
            // Keep any preceding FF fill bytes outside the replaced segment.
            let markerStart = cursor - 1
            cursor += 1
            if marker == 0xd9 { return packet }
            if marker == 1 { continue }
            guard marker >= 0xc0, marker != 0xd8, !(0xd0...0xd7).contains(marker),
                  bytes.count - cursor >= 2 else { throw EmbeddedXMPError.invalidJPEG }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            guard length >= 2, length <= bytes.count - cursor else { throw EmbeddedXMPError.invalidJPEG }
            let payload = (cursor + 2)..<(cursor + length)
            if marker == 0xda {
                guard payload.count >= 4 else { throw EmbeddedXMPError.invalidJPEG }
                let components = Int(bytes[payload.lowerBound])
                guard (1...4).contains(components), length == 6 + 2 * components else {
                    throw EmbeddedXMPError.invalidJPEG
                }
            }
            if marker == 0xdc, length != 4 { throw EmbeddedXMPError.invalidJPEG }
            if marker == 0xe1 {
                if bytes[payload].starts(with: extendedPrefix) { throw EmbeddedXMPError.extendedXMP }
                if bytes[payload].starts(with: jpegPrefix) {
                    guard packet == nil else { throw EmbeddedXMPError.duplicateXMP }
                    packet = Packet(container: markerStart..<(cursor + length),
                                    content: (payload.lowerBound + jpegPrefix.count)..<payload.upperBound)
                }
            }
            cursor += length
            // DNL may be inserted inside an entropy-coded scan and does not
            // terminate it. SOS begins a scan (including progressive scans).
            inScan = marker == 0xda || (marker == 0xdc && cameFromScan)
        }
        throw EmbeddedXMPError.invalidJPEG
    }

    private static func pngLayout(in bytes: [UInt8]) throws -> (packet: Packet?, iend: Int) {
        guard bytes.starts(with: pngSignature) else { throw EmbeddedXMPError.invalidPNG }
        var cursor = pngSignature.count
        var packet: Packet?
        var sawHeader = false
        var sawPalette = false
        var sawData = false
        var endedData = false
        var colorType: UInt8 = 0
        var bitDepth: UInt8 = 0
        while cursor < bytes.count {
            guard bytes.count - cursor >= 12 else { throw EmbeddedXMPError.invalidPNG }
            let length = Int(uint32(bytes, at: cursor))
            guard length <= 0x7fff_ffff, length <= bytes.count - cursor - 12 else {
                throw EmbeddedXMPError.invalidPNG
            }
            let typeRange = (cursor + 4)..<(cursor + 8)
            let typeBytes = bytes[typeRange]
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (65...90).contains(bytes[cursor + 6]) else { throw EmbeddedXMPError.invalidPNG }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let payload = (cursor + 8)..<(cursor + 8 + length)
            let end = cursor + length + 12
            guard crc32(bytes[(cursor + 4)..<(end - 4)]) == uint32(bytes, at: end - 4) else {
                throw EmbeddedXMPError.invalidPNGChecksum
            }
            guard sawHeader || type == "IHDR" else { throw EmbeddedXMPError.invalidPNG }
            if sawData, type != "IDAT" { endedData = true }
            switch type {
            case "IHDR":
                guard !sawHeader, length == 13 else { throw EmbeddedXMPError.invalidPNG }
                let width = uint32(bytes, at: payload.lowerBound)
                let height = uint32(bytes, at: payload.lowerBound + 4)
                bitDepth = bytes[payload.lowerBound + 8]
                colorType = bytes[payload.lowerBound + 9]
                let legalDepths: [UInt8: Set<UInt8>] = [0: [1, 2, 4, 8, 16], 2: [8, 16],
                                                      3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
                guard width > 0, width <= 0x7fff_ffff, height > 0, height <= 0x7fff_ffff,
                      legalDepths[colorType]?.contains(bitDepth) == true,
                      bytes[payload.lowerBound + 10] == 0, bytes[payload.lowerBound + 11] == 0,
                      bytes[payload.lowerBound + 12] <= 1 else { throw EmbeddedXMPError.invalidPNG }
                sawHeader = true
            case "PLTE":
                guard !sawPalette, !sawData, colorType != 0, colorType != 4,
                      length > 0, length <= 768, length % 3 == 0,
                      colorType != 3 || length / 3 <= 1 << Int(bitDepth) else {
                    throw EmbeddedXMPError.invalidPNG
                }
                sawPalette = true
            case "IDAT":
                guard !endedData, colorType != 3 || sawPalette else { throw EmbeddedXMPError.invalidPNG }
                sawData = true
            case "IEND":
                guard sawData, length == 0, end == bytes.count else { throw EmbeddedXMPError.invalidPNG }
                return (packet, cursor)
            case "iTXt":
                let xmpContent = try internationalText(bytes, payload: payload)
                if let content = xmpContent {
                    guard packet == nil else { throw EmbeddedXMPError.duplicateXMP }
                    packet = Packet(container: cursor..<end, content: content)
                }
            case "tEXt", "zTXt":
                if let separator = bytes[payload].firstIndex(of: 0),
                   bytes[payload.lowerBound..<separator].elementsEqual(pngKeyword) {
                    throw EmbeddedXMPError.unsupportedXMPStorage
                }
            case "cHRM", "gAMA", "iCCP", "sBIT", "sRGB":
                guard !sawPalette, !sawData else { throw EmbeddedXMPError.invalidPNG }
            case "bKGD", "hIST", "tRNS":
                guard !sawData, colorType != 3 || sawPalette else { throw EmbeddedXMPError.invalidPNG }
            case "pHYs", "sPLT":
                guard !sawData else { throw EmbeddedXMPError.invalidPNG }
            default:
                guard bytes[cursor + 4] & 32 != 0 else {
                    throw EmbeddedXMPError.unsupportedPNGChunk(type)
                }
            }
            cursor = end
        }
        throw EmbeddedXMPError.invalidPNG
    }

    private static func internationalText(_ bytes: [UInt8], payload: Range<Int>) throws -> Range<Int>? {
        guard let keywordEnd = bytes[payload].firstIndex(of: 0) else { throw EmbeddedXMPError.invalidPNG }
        let keyword = bytes[payload.lowerBound..<keywordEnd]
        guard (1...79).contains(keyword.count), keyword.first != 32, keyword.last != 32,
              keyword.allSatisfy({ (32...126).contains($0) || $0 >= 161 }),
              !zip(keyword, keyword.dropFirst()).contains(where: { pair in pair.0 == 32 && pair.1 == 32 }),
              payload.upperBound - keywordEnd >= 5 else { throw EmbeddedXMPError.invalidPNG }
        let compression = bytes[keywordEnd + 1]
        guard compression <= 1, bytes[keywordEnd + 2] == 0 else { throw EmbeddedXMPError.invalidPNG }
        let languageStart = keywordEnd + 3
        guard let languageEnd = bytes[languageStart..<payload.upperBound].firstIndex(of: 0),
              bytes[languageStart..<languageEnd].allSatisfy({ $0 < 128 }),
              let translatedEnd = bytes[(languageEnd + 1)..<payload.upperBound].firstIndex(of: 0),
              String(bytes: bytes[(languageEnd + 1)..<translatedEnd], encoding: .utf8) != nil else {
            throw EmbeddedXMPError.invalidPNG
        }
        let content = (translatedEnd + 1)..<payload.upperBound
        if compression == 0, String(bytes: bytes[content], encoding: .utf8) == nil {
            throw EmbeddedXMPError.invalidUTF8
        }
        guard keyword.elementsEqual(pngKeyword) else { return nil }
        guard compression == 0 else { throw EmbeddedXMPError.compressedXMP }
        return content
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func pngChunk(type: [UInt8], payload: [UInt8]) -> Data {
        var result = bigEndian(UInt32(payload.count))
        result.append(contentsOf: type)
        result.append(contentsOf: payload)
        result.append(contentsOf: bigEndian(crc32(result[4...])))
        return Data(result)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
         UInt8((value >> 8) & 255), UInt8(value & 255)]
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return crc ^ 0xffff_ffff
    }
}
