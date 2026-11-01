import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XMPViewCore

@MainActor
struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var isDropTarget = false
    @State private var selectedTab: MetadataTab = .basic

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                VSplitView {
                    HSplitView {
                        previewPane(document)
                            .frame(minWidth: 290, idealWidth: 440)
                        editorPane(document)
                            .frame(minWidth: 390, idealWidth: 560)
                    }
                    .frame(minHeight: 350)
                    metadataPane(document)
                        .frame(minHeight: 200, idealHeight: 270)
                }
            } else {
                emptyState
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: receiveDrop)
        .alert("无法完成操作", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("XMP View").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("图片元数据 · 本地查看与编辑")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDirty {
                Label("未保存", systemImage: "circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Button { model.chooseFile() } label: {
                Label("打开图片", systemImage: "folder")
            }
            .disabled(model.isBusy)
            Menu {
                Button("另存为…") { model.saveAs() }.disabled(!model.canSaveAs)
                Button("撤销本次编辑") { model.revert() }.disabled(!model.isDirty || model.isBusy)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            Button { model.save() } label: {
                Label("保存", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 55, weight: .ultraLight))
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 112)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 28))
            VStack(spacing: 8) {
                Text("让图片里的信息，看得见")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("将一张图片拖到这里，或选择本地文件")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Button("选择图片…") { model.chooseFile() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
            HStack(spacing: 12) {
                ForEach(["JPEG", "PNG", "HEIC"], id: \.self) { format in
                    Text(format).font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
            }
            Text("无需账号 · 无需联网 · 编辑文件自身的 XMP")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func previewPane(_ document: ImageDocument) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                sectionLabel("图片预览", symbol: "photo")
                Spacer()
                Text(document.format.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable().scaledToFit()
                        .padding(16)
                        .accessibilityLabel("当前图片预览")
                } else {
                    Label("系统无法显示此图片预览", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text(document.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(document.url.path)
                    .textSelection(.enabled)
                Text("\(document.width) × \(document.height) 像素")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    private func editorPane(_ document: ImageDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    sectionLabel("基础编辑", symbol: "slider.horizontal.3")
                    Spacer()
                    xmpBadge(document.xmpState)
                }
                fieldHeader("标题", standard: "XMP-dc:Title")
                TextField("为图片添加标题", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Title 标题")
                fieldHeader("描述", standard: "XMP-dc:Description")
                TextEditor(text: $model.descriptionText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 90)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("Description 描述")
                fieldHeader("关键词", standard: "XMP-dc:Subject")
                TextField("例如：旅行, 海边, 日落", text: $model.keywordsText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Keywords 关键词")
                Text("用逗号或换行分隔；保存为多值关键词。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.top, -10)
                    .help("关键词本身含逗号时，请用双引号包围。")
                Label(document.canWrite
                      ? "保存前保留备份，写入后重新读取校验。"
                      : document.format == .heic
                        ? "HEIC 暂为只读：无法保证辅助图像与全部元数据在写入后完整保留。"
                        : "此图片目前只读，无法安全写入元数据。",
                      systemImage: document.canWrite ? "checkmark.shield" : "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(document.canWrite ? Color.secondary : Color.orange)
                    .padding(.top, 2)
            }
            .padding(22)
            .disabled(model.isBusy || !document.canWrite)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func metadataPane(_ document: ImageDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                sectionLabel("元数据", symbol: "list.bullet.rectangle")
                Picker("元数据分类", selection: $selectedTab) {
                    ForEach(MetadataTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22).padding(.vertical, 13)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    if selectedTab == .raw {
                        if let xml = document.rawXMP, !xml.isEmpty {
                            Text(xml).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).padding(18)
                        } else {
                            metadataEmpty(document.xmpState == .unavailable
                                          ? "该格式或系统接口无法提供可读取的 XMP XML。"
                                          : "此文件没有可读取的原始 XMP XML。")
                        }
                    } else {
                        let entries = document.metadata[selectedTab.group] ?? []
                        if entries.isEmpty {
                            metadataEmpty(selectedTab == .xmp
                                          ? xmpExplanation(document.xmpState)
                                          : "没有可读取的\(selectedTab.title)字段。")
                        } else {
                            ForEach(entries) { entry in
                                metadataRow(key: entry.path, value: entry.value)
                                Divider().padding(.leading, 20)
                            }
                        }
                        if selectedTab == .basic {
                            metadataRow(key: "Finder Comments（macOS 文件注释）",
                                        value: document.finderComment ?? "无可读取的文件注释")
                            Text("Finder 注释是 macOS 文件属性，与图片内部的 XMP 不同。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(.horizontal, 20).padding(.bottom, 14)
                        }
                    }
                }
                .frame(minWidth: 810, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small).scaleEffect(0.75)
            } else {
                Image(systemName: model.isDirty ? "pencil.circle" : "info.circle")
                    .foregroundStyle(model.isDirty ? Color.orange : Color.secondary)
            }
            Text(model.isDirty && !model.isBusy ? "已修改 · 尚未保存到图片" : model.status)
                .lineLimit(1).truncationMode(.middle)
                .help(model.status)
            Spacer()
            Text("嵌入式 XMP").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 22).padding(.vertical, 10)
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func fieldHeader(_ title: String, standard: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(standard).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.bottom, -10)
    }

    private func xmpBadge(_ state: XMPReadState) -> some View {
        Text(state == .present ? "含 XMP" : state == .absent ? "无 XMP" : "XMP 不可读取")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(state == .unavailable ? Color.orange : Color.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((state == .unavailable ? Color.orange : Color.accentColor).opacity(0.08), in: Capsule())
            .help(xmpExplanation(state))
    }

    private func xmpExplanation(_ state: XMPReadState) -> String {
        switch state {
        case .present: return "此文件包含可读取的嵌入式 XMP。"
        case .absent: return "此文件未包含 XMP；支持安全写入时，保存会创建 XMP。"
        case .unavailable: return "该格式或系统接口无法读取 XMP，不能据此判定文件没有 XMP。"
        }
    }

    private func metadataEmpty(_ text: String) -> some View {
        Label(text, systemImage: "text.magnifyingglass")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(22)
    }

    private func metadataRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(key).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)
                .textSelection(.enabled)
            Text(value).font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            } else if let value = item as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            Task { @MainActor in
                if let url { model.open(url) }
                else { model.errorMessage = error?.localizedDescription ?? "无法读取拖入的文件。" }
            }
        }
        return true
    }
}

private enum MetadataTab: String, CaseIterable, Identifiable {
    case basic, xmp, exif, iptc, raw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: return "基础"
        case .xmp: return "XMP"
        case .exif: return "EXIF"
        case .iptc: return "IPTC"
        case .raw: return "原始 XMP"
        }
    }
    var group: MetadataGroup {
        switch self {
        case .basic, .raw: return .basic
        case .xmp: return .xmp
        case .exif: return .exif
        case .iptc: return .iptc
        }
    }
}
