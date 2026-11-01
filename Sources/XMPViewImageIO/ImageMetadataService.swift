import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CoreServices
import XMPViewCore

public struct SaveResult: Sendable {
    public let document: ImageDocument
    public let backupURL: URL?
}

public enum ImageMetadataError: LocalizedError {
    case invalidFile, unsupportedFormat, tooLarge, staleSource, destinationExists
    case readOnly, wrongExtension, invalidMetadata, verificationFailed, backupFailed
    case postSaveVerification(URL?)

    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "无法读取有效图片。请选择本地的 PNG、JPEG 或 HEIC 文件。"
        case .unsupportedFormat: return "此文件格式暂不支持。支持 PNG、JPEG，以及只读 HEIC。"
        case .tooLarge: return "文件超过 512 MB，暂不支持读取。请使用较小的单张图片。"
        case .staleSource: return "图片在打开后已被其他程序修改。为避免覆盖新内容，请重新打开图片后再编辑。"
        case .destinationExists: return "另存目标已经存在。请选择一个新文件名；如需更新当前图片，请使用“保存”。"
        case .readOnly: return "无法保证此图片的安全写入。HEIC、多帧图片、扩展或压缩 XMP 目前仅支持读取；原文件未被覆盖。"
        case .wrongExtension: return "另存文件的扩展名必须与原格式一致；此工具不转换图片格式。"
        case .invalidMetadata: return "XMP 数据无效或包含暂不支持的结构，无法安全修改。原文件未被覆盖。"
        case .verificationFailed: return "临时文件的元数据或图片数据未通过校验。原文件未被覆盖。"
        case .backupFailed: return "无法创建并核验原文件备份，已取消保存。"
        case .postSaveVerification(let backup):
            return "写入后重新读取未通过校验，请检查文件。" + (backup.map { "原文件备份位于：\($0.path)" } ?? "原始图片仍保留在原路径。")
        }
    }
}

/// ImageIO reads the image and EXIF/IPTC. JPEG/PNG writing changes only the
/// embedded XMP container bytes: no image re-encoding or metadata reconciliation.
public struct ImageMetadataService: Sendable {
    public init() {}
    private static let limit = 512 * 1024 * 1024

    public func read(_ url: URL) throws -> ImageDocument {
        guard url.isFileURL else { throw ImageMetadataError.invalidFile }
        let data = try load(url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { throw ImageMetadataError.invalidFile }
        let format: ImageFormat
        switch type as String {
        case UTType.jpeg.identifier: format = .jpeg
        case UTType.png.identifier: format = .png
        case UTType.heic.identifier, "public.heif", "public.heif-standard": format = .heic
        default: throw ImageMetadataError.unsupportedFormat
        }

        var groups: [MetadataGroup: [MetadataEntry]] = [
            .basic: [MetadataEntry(path: "文件名", value: url.lastPathComponent),
                     MetadataEntry(path: "格式", value: format.label),
                     MetadataEntry(path: "像素尺寸", value: "\(width) × \(height)"),
                     MetadataEntry(path: "文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))],
            .exif: [], .iptc: [], .xmp: []
        ]
        for (key, value) in properties {
            switch key {
            case kCGImagePropertyExifDictionary as String, kCGImagePropertyExifAuxDictionary as String,
                 kCGImagePropertyGPSDictionary as String, kCGImagePropertyTIFFDictionary as String:
                groups[.exif, default: []] += flatten(value, prefix: key)
            case kCGImagePropertyIPTCDictionary as String:
                groups[.iptc, default: []] += flatten(value, prefix: key)
            default:
                if !key.hasPrefix("{") { groups[.basic, default: []] += flatten(value, prefix: key) }
            }
        }

        var fields = EditableFields()
        var raw: String?
        var state: XMPReadState = .unavailable
        var safe = false
        var embedded: Data?
        do {
            embedded = try EmbeddedXMP.extract(from: data, format: format)
            if let packet = embedded {
                fields = try XMPParser.readFields(from: packet)
                raw = String(data: packet, encoding: .utf8)
                guard raw != nil else { throw ImageMetadataError.invalidMetadata }
                state = .present
                // Run the actual edit path before enabling Save, so unsupported
                // XMP structures remain browseable without risking a rewrite.
                _ = try XMPEditor.replacingFields(in: packet, with: fields)
            } else {
                state = .absent
            }
            safe = CGImageSourceGetCount(source) == 1 && format != .heic
        } catch {
            // An embedded packet that parsed successfully is still present even
            // if its structure is too complex to edit. No-XMP is never inferred
            // from a parser or container error.
            safe = false
            groups[.basic, default: []].append(MetadataEntry(path: "写入限制", value: error.localizedDescription))
        }

        let nativeMetadata = embedded.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
            ?? (state == .unavailable ? CGImageSourceCopyMetadataAtIndex(source, 0, nil) : nil)
        if let metadata = nativeMetadata {
            var entries: [MetadataEntry] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil,
                [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                let value = CGImageMetadataTagCopyValue(tag)
                entries.append(MetadataEntry(path: path as String, value: value.map { String(describing: $0) } ?? ""))
                return true
            }
            groups[.xmp] = entries
            if state == .unavailable, let generated = CGImageMetadataCreateXMPData(metadata, nil) {
                fields = (try? XMPParser.readFields(from: generated as Data)) ?? EditableFields()
                groups[.basic, default: []].append(MetadataEntry(path: "XMP 读取说明", value: "XMP 页包含系统映射的字段；不能据此确认原始 XMP 数据包是否存在。"))
            }
        }
        for group in MetadataGroup.allCases { groups[group]?.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
        let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString)
        let comment = item.flatMap { MDItemCopyAttribute($0, kMDItemFinderComment) as? String }
        return ImageDocument(url: url.standardizedFileURL, format: format, width: width, height: height,
            fields: fields, metadata: groups, xmpState: state, rawXMP: raw,
            finderComment: comment, canWrite: safe, sourceDigest: digest(data))
    }

    public func save(_ document: ImageDocument, fields: EditableFields, to destination: URL) throws -> SaveResult {
        guard document.canWrite, document.format != .heic else { throw ImageMetadataError.readOnly }
        guard destination.isFileURL, ImageFormat(url: destination) == document.format else { throw ImageMetadataError.wrongExtension }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<SaveResult, Error>?
        if document.url.standardizedFileURL == destination.standardizedFileURL {
            coordinator.coordinate(writingItemAt: document.url, options: .forReplacing, error: &coordinationError) { url in
                result = Result { try saveCoordinated(document, fields: fields, source: url, destination: url) }
            }
        } else {
            coordinator.coordinate(readingItemAt: document.url, options: [], writingItemAt: destination,
                options: .forReplacing, error: &coordinationError) { source, target in
                result = Result { try saveCoordinated(document, fields: fields, source: source, destination: target) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImageMetadataError.verificationFailed }
        return try result.get()
    }

    private func saveCoordinated(_ document: ImageDocument, fields: EditableFields, source: URL, destination: URL) throws -> SaveResult {
        let fm = FileManager.default
        let sameFile = source.standardizedFileURL == destination.standardizedFileURL
        // Refuse symlinks instead of silently replacing the link or its target.
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ImageMetadataError.readOnly }
        if !sameFile, fm.fileExists(atPath: destination.path) { throw ImageMetadataError.destinationExists }
        let original = try load(source)
        guard !document.sourceDigest.isEmpty, digest(original) == document.sourceDigest else { throw ImageMetadataError.staleSource }
        let oldPacket = try EmbeddedXMP.extract(from: original, format: document.format)
        let packet = try XMPEditor.replacingFields(in: oldPacket, with: fields)
        guard try XMPParser.readFields(from: packet) == fields else { throw ImageMetadataError.invalidMetadata }
        let updated = try EmbeddedXMP.replacing(in: original, format: document.format, xmp: packet)
        // Compare canonical containers with identical replacement packets: every
        // byte outside XMP must be preserved, including opaque/private metadata.
        let sentinel = Data("xmpview-preservation-check".utf8)
        guard try EmbeddedXMP.replacing(in: original, format: document.format, xmp: sentinel)
            == EmbeddedXMP.replacing(in: updated, format: document.format, xmp: sentinel) else {
            throw ImageMetadataError.verificationFailed
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".xmpview-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? fm.removeItem(at: temporary) }
        // Copy first to retain file permissions, Finder comments and other xattrs.
        try fm.copyItem(at: source, to: temporary)
        try updated.write(to: temporary)
        let candidate = try read(temporary)
        guard candidate.fields == fields, candidate.width == document.width, candidate.height == document.height,
              candidate.format == document.format, candidate.xmpState == .present,
              digest(try load(temporary)) == digest(updated) else { throw ImageMetadataError.verificationFailed }

        var backup: URL?
        if sameFile {
            let backupURL = source.deletingLastPathComponent().appendingPathComponent(
                "\(source.deletingPathExtension().lastPathComponent).xmpview-backup-\(UUID().uuidString).\(source.pathExtension)")
            try fm.copyItem(at: source, to: backupURL)
            guard digest(try load(backupURL)) == document.sourceDigest else {
                try? fm.removeItem(at: backupURL)
                throw ImageMetadataError.backupFailed
            }
            backup = backupURL
        }
        guard digest(try load(source)) == document.sourceDigest else { throw ImageMetadataError.staleSource }
        if sameFile {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            // moveItem refuses an existing path, including a target created
            // while the candidate was being validated.
            try fm.moveItem(at: temporary, to: destination)
        }
        do {
            let reopened = try read(destination)
            guard reopened.fields == fields, reopened.sourceDigest == digest(updated) else { throw ImageMetadataError.verificationFailed }
            return SaveResult(document: reopened, backupURL: backup)
        } catch { throw ImageMetadataError.postSaveVerification(backup) }
    }

    private func load(_ url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.int64Value <= Int64(Self.limit) else { throw ImageMetadataError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.limit else { throw ImageMetadataError.tooLarge }
        return data
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func flatten(_ value: Any, prefix: String) -> [MetadataEntry] {
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().flatMap { flatten(dict[$0]!, prefix: "\(prefix).\($0)") }
        }
        if let list = value as? [Any] {
            return list.enumerated().flatMap { flatten($0.element, prefix: "\(prefix)[\($0.offset)]") }
        }
        return [MetadataEntry(path: prefix, value: String(describing: value))]
    }
}
