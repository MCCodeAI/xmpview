import AppKit
import Foundation
import UniformTypeIdentifiers
import XMPViewCore
import XMPViewImageIO

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var document: ImageDocument?
    @Published private(set) var preview: NSImage?
    @Published var title = ""
    @Published var descriptionText = ""
    @Published var keywordsText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var status = "打开一张图片，查看文件内的元数据"
    @Published var errorMessage: String?
    var closeApproved = false

    private let service = ImageMetadataService()

    var editedFields: EditableFields {
        // Keep the original array byte-for-byte when the keyword editor was
        // untouched (including pre-existing duplicates or whitespace).
        let keywords: [String]
        if let document, keywordsText == document.fields.keywordsText {
            keywords = document.fields.keywords
        } else {
            keywords = EditableFields.parseKeywords(keywordsText)
        }
        return EditableFields(title: title, description: descriptionText, keywords: keywords)
    }

    var isDirty: Bool {
        guard let document else { return false }
        return editedFields != document.fields
    }

    var canSave: Bool { !isBusy && document?.canWrite == true && isDirty }
    var canSaveAs: Bool { !isBusy && document?.canWrite == true }

    func chooseFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开图片"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let document { panel.directoryURL = document.url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard !isBusy, confirmDiscardChanges() else { return }
        guard url.isFileURL else {
            errorMessage = "请从 Finder 打开本地 PNG、JPEG 或 HEIC 图片。"
            return
        }
        isBusy = true
        status = "正在读取图片和元数据…"
        let service = self.service
        Task {
            defer { isBusy = false }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try service.read(url)
                }.value
                apply(loaded)
                status = loaded.canWrite ? "已读取 · 修改后可保存至图片内部" : "已读取 · 此图片暂不支持安全写入"
            } catch {
                status = "读取失败 · 当前编辑内容已保留"
                errorMessage = error.localizedDescription
            }
        }
    }

    func save() {
        guard canSave, let document else { return }
        save(to: document.url)
    }

    func saveAs() {
        guard canSaveAs, let document else { return }
        let panel = NSSavePanel()
        panel.title = "另存图片"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.url.lastPathComponent
        panel.directoryURL = document.url.deletingLastPathComponent()
        switch document.format {
        case .jpeg: panel.allowedContentTypes = [.jpeg]
        case .png: panel.allowedContentTypes = [.png]
        case .heic: panel.allowedContentTypes = [.heic]
        }
        if panel.runModal() == .OK, let url = panel.url { save(to: url) }
    }

    private func save(to url: URL) {
        guard let document, !isBusy else { return }
        let fields = editedFields
        let service = self.service
        isBusy = true
        status = "正在保存并重新读取校验…"
        Task {
            defer { isBusy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.save(document, fields: fields, to: url)
                }.value
                apply(result.document)
                if let backup = result.backupURL {
                    status = "已保存并通过校验 · 原文件备份：\(backup.lastPathComponent)"
                } else {
                    status = "已另存并通过校验 · 原文件保留"
                }
            } catch {
                status = "保存失败 · 编辑内容已保留"
                errorMessage = error.localizedDescription
            }
        }
    }

    func revert() {
        guard let document, !isBusy, confirmDiscardChanges() else { return }
        apply(document)
        status = "已撤销本次编辑"
    }

    func confirmDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃尚未保存的修改？"
        alert.informativeText = "当前图片的标题、描述或关键词已修改。返回后可以先保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "返回编辑")
        alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func apply(_ document: ImageDocument) {
        self.document = document
        preview = NSImage(contentsOf: document.url)
        title = document.fields.title
        descriptionText = document.fields.description
        keywordsText = document.fields.keywordsText
        closeApproved = false
    }
}
