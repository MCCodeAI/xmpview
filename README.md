# XMP View

一个轻量、离线的原生 macOS 图片元数据工具。使用 SwiftUI、ImageIO 和 Core Graphics，无第三方运行时、账号或后台服务。

## 本地启动

需要 macOS 13 或更新版本，以及支持 Swift 5.9 的 Xcode Command Line Tools（建议 Xcode 15 或更新版本）。

```sh
xcode-select --install  # 尚未安装开发工具时执行
git clone https://github.com/MCCodeAI/xmpview.git
cd xmpview
./scripts/check.sh
open "dist/XMP View.app"
```

已有仓库时直接在当前 checkout 中操作；云任务已隔离，无需另建 Git worktree。也可用 `swift run XMPView` 调试，或用 Xcode 打开 `Package.swift`。

原始需求保存在 [docs/requirements.html](docs/requirements.html)。推送代码后，GitHub Actions 的 `native-app` 任务会在 macOS 上运行集成测试、构建并上传应用压缩包；实际运行结果见仓库的 Actions 页面。

## 使用

1. 点击“打开图片”（⌘O）或将 PNG、JPEG、HEIC 图片拖进窗口。
2. 查看预览、格式、尺寸及分类元数据。原始 XMP 是只读视图；Finder 文件注释单独标注，不作为内嵌 XMP。
3. 编辑 Title、Description、Keywords。关键词使用逗号、中文逗号或换行分隔，保存为 XMP 多值字段。
4. “保存”（⌘S）更新原图并保留备份；“另存为”（⇧⌘S）写入新文件。重新打开文件可再次核对内容。

Title、Description、Keywords 分别映射 `dc:title`、`dc:description`、`dc:subject`。不实现图库、批量处理、AI、同步或照片库接口。

## 保存边界

PNG/JPEG 写入直接替换容器里的 XMP 数据段，不重新编码图片，其他段或块保留原始字节。写入必须经过临时文件、重新读取和字段验证。接口不能安全写入时显示错误，不将未通过验证的结果覆盖原图。原图被外部程序修改后必须重新打开；另存为不静默覆盖已有文件。备份与原图在同一目录，请确认保存结果后自行管理备份文件。

PNG、JPEG、HEIC 分别处理。PNG/JPEG 支持嵌入 XMP；HEIC 本期仅支持读取，保存会明确拒绝，因为尚未证明能完整保留 HEIC 的辅助图像等数据。不能从 JPEG 通过推断其他格式可用。多帧、动画或其他未支持的容器不应按普通单张图片写入。

目前只写入标准 JPEG APP1 XMP 与未压缩 PNG iTXt XMP。扩展 XMP、重复数据包、压缩 XMP、校验损坏或复杂 RDF 值会进入只读状态，并在 Basic 页说明原因。文件上限为 512 MB。不会同步修改 IPTC 中语义相近的字段。Finder Comments 来自系统 Spotlight 属性，索引尚未更新时可能不可读。

## 验证

```sh
./scripts/check.sh           # Mac：全部测试 + release .app；Linux：仅可移植核心测试
swift test                  # 在 Mac 上运行 ImageIO 集成测试
./scripts/build-app.sh      # 在 Mac 上单独构建 .app
./scripts/cloud-check.sh    # 云环境无 Swift 时，使用固定版本的官方 Swift Docker 镜像
```

核心测试覆盖关键词解析、XMP XML 字段读取及 PNG/JPEG 容器处理。macOS 集成测试生成真实 PNG/JPEG 样本，检查 Unicode、多值关键词、清空字段、备份原始字节、保存后重读、像素及未编辑元数据保留、外部修改冲突和另存为目标冲突。HEIC 测试检查只读和写入拒绝；没有 HEIC 编码器时仅跳过该测试样本生成，不代表 HEIC 写入受支持。

可移植端到端测试另使用本项目生成的微型真实 JPEG/PNG 样本，执行读取、编辑、写入、重新解析和清空字段，输出位于忽略目录 `.build/smoke-output`。应用运行不依赖 Docker；Docker 仅用于 Linux 云环境编译核心测试。

当前开发环境是 Linux。这里不能运行 Apple ImageIO、SwiftUI、macOS 集成测试或 `.app`；提供测试不代表这些检查已经通过。在 Mac 上完成以下手动验收后再作为可交付应用使用：

- 启动 `.app`，测试文件选择、拖放、窗口关闭时未保存提示。
- 分别用 PNG、JPEG 打开、修改三个字段、保存、退出并重开；HEIC 检查预览、元数据和只读提示。
- 对含 EXIF 拍摄时间、GPS、IPTC 和额外 XMP 的真实照片核对未编辑字段；检查备份可打开。
- 验证无 XMP、损坏图片、只读目录、外部修改和不支持写入的错误提示。
- 检查长文本、中文、特殊字符、空字段和关键词数组。

可以用 ExifTool 进行独立只读核对（可选工具，不是应用依赖）：

```sh
exiftool -G1 -a -s -XMP:All -EXIF:All -IPTC:All path/to/photo.jpg
```

## 工程结构

- `Sources/XMPViewCore`：可移植模型、关键词和 XMP 解析。
- `Sources/XMPViewImageIO`：macOS 读取、验证及安全保存。
- `Sources/XMPViewApp`：SwiftUI 单窗口界面。
- `Tests`：核心单元测试和 macOS 实际格式集成测试。
- `scripts/build-app.sh`：生成 `dist/XMP View.app`，使用本地 ad-hoc 签名。

本地签名用于本机开发。面向其他用户分发需另行配置 Developer ID 签名和 Apple 公证；此仓库不包含证书或凭据。
