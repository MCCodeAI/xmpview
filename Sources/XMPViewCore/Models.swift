import Foundation

/// The three editable Dublin Core properties. Other metadata is intentionally
/// outside this value so a save can merge just the user's edits.
public struct EditableFields: Equatable, Sendable {
    public var title: String
    public var description: String
    public var keywords: [String]

    public init(title: String = "", description: String = "", keywords: [String] = []) {
        self.title = title
        self.description = description
        self.keywords = keywords
    }

    /// CSV-style quoting keeps a keyword that itself contains a comma intact.
    public var keywordsText: String {
        get {
            keywords.map { value in
                if value.contains(where: { Self.separators.contains($0) || $0 == "\"" }) {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: ", ")
        }
        set { keywords = Self.parseKeywords(newValue) }
    }

    /// Accept English/Chinese commas and line breaks; retain order and case.
    /// Quotes and doubled quotes use the usual CSV convention.
    public static func parseKeywords(_ text: String) -> [String] {
        var values: [String] = []
        var seen = Set<String>()
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        func appendField() {
            let value = field.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, seen.insert(value).inserted { values.append(value) }
            field = ""
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if isQuoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = text.index(after: next)
                    continue
                }
                // A literal quote inside an unquoted word is preserved.
                if isQuoted || field.trimmingCharacters(in: .whitespaces).isEmpty {
                    isQuoted.toggle()
                } else {
                    field.append(character)
                }
            } else if separators.contains(character), !isQuoted {
                appendField()
            } else {
                field.append(character)
            }
            index = next
        }
        appendField()
        return values
    }

    private static let separators: Set<Character> = [",", "，", "\n", "\r", "\r\n"]
}

public struct MetadataEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var value: String
    public var id: String { path }

    public init(path: String, value: String) {
        self.path = path
        self.value = value
    }
}

public enum MetadataGroup: String, CaseIterable, Sendable {
    case basic
    case xmp
    case exif
    case iptc

    public var label: String {
        switch self {
        case .basic: return "Basic"
        case .xmp: return "XMP"
        case .exif: return "EXIF"
        case .iptc: return "IPTC"
        }
    }
}

public enum XMPReadState: String, Equatable, Sendable {
    case present
    case absent
    case unavailable

    public var label: String {
        switch self {
        case .present: return "包含 XMP"
        case .absent: return "未发现 XMP"
        case .unavailable: return "无法读取 XMP"
        }
    }

    public var detail: String {
        switch self {
        case .present: return "已读取图片文件内嵌的 XMP 元数据。"
        case .absent: return "已检查图片，未发现内嵌 XMP 数据。"
        case .unavailable: return "当前格式或系统接口无法可靠读取 XMP，不能据此判断文件没有 XMP。"
        }
    }
}

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png
    case heic

    public init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "heic", "heif": self = .heic
        default: return nil
        }
    }

    public var label: String { rawValue.uppercased() }
}

/// An immutable-at-load snapshot; the UI holds its editable draft separately.
public struct ImageDocument: Sendable {
    public var url: URL
    public var format: ImageFormat
    public var width: Int
    public var height: Int
    public var fields: EditableFields
    public var metadata: [MetadataGroup: [MetadataEntry]]
    public var xmpState: XMPReadState
    public var rawXMP: String?
    public var finderComment: String?
    public var canWrite: Bool
    public let sourceDigest: String

    public init(
        url: URL, format: ImageFormat, width: Int, height: Int,
        fields: EditableFields = EditableFields(),
        metadata: [MetadataGroup: [MetadataEntry]] = [:],
        xmpState: XMPReadState = .unavailable, rawXMP: String? = nil,
        finderComment: String? = nil, canWrite: Bool = false, sourceDigest: String = ""
    ) {
        self.url = url
        self.format = format
        self.width = width
        self.height = height
        self.fields = fields
        self.metadata = metadata
        self.xmpState = xmpState
        self.rawXMP = rawXMP
        self.finderComment = finderComment
        self.canWrite = canWrite
        self.sourceDigest = sourceDigest
    }
}
