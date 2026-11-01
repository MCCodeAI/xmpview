# 当前验证记录

日期：2026-11-01。当前机器为 Linux x86_64；没有 macOS SDK 或 GUI。

## 已执行

- `./scripts/cloud-check.sh`：官方 Swift 6.0.3 容器编译成功，XCTest 共 **48 项通过、0 失败、0 跳过**。测试包括关键词 6 项、容器 16 项、真实图片完整流程 2 项、XMP 编辑 10 项、XMP 解析 14 项。Swift Testing 在 XCTest 之后打印的 0-test 行不是上述结果。
- 测试涵盖 JPEG/PNG XMP 增改与清空、未知字段和语言保留、JPEG JFIF 顺序、PNG CRC、扩展或压缩 XMP 拒绝、损坏输入及字段往返。
- 用独立 Pillow 解码器读取 `.build/smoke-output` 中已编辑和已清空的真实 JPEG/PNG，与原测试图片比较：解码像素、EXIF、原注释相同。使用 Python XML 解析器核对中文标题、多值关键词及自定义 XMP 属性，均通过。Pillow 仅用于此次独立核验，不是应用或 Swift 测试依赖。
- macOS Swift 源码通过 `swiftc -frontend -parse` 语法检查。这不等于使用 Apple SDK 编译或通过类型检查。
- Shell 脚本语法、Info.plist 解析和差异格式检查通过。

测试期间修复了 FoundationXML 命名空间节点复制崩溃、空或截断 XML 检测和无 XMP JPEG 的 JFIF 段插入顺序问题；上述通过结果来自修复后的完整运行。

## 仍需 macOS 执行

- `./scripts/check.sh`：Apple ImageIO 集成测试、SwiftUI 类型检查、release 构建及 `.app` 签名验证。
- `open "dist/XMP View.app"`：文件选择、拖放、Finder 打开、未保存修改提示和保存后重开。
- 真实相机文件的 EXIF、GPS、IPTC、ICC 和额外 XMP 保留；HEIC 预览和只读提示。
- 原图备份、只读目录、外部修改冲突和另存为拒绝覆盖。

HEIC 写入明确不支持。JPEG 扩展 XMP、PNG 压缩 XMP 等不支持的结构只读。macOS CI 文件已提供。本记录仅覆盖本地 Linux 验证，不包含后续 GitHub Actions 结果，不能据此将原生验收标记为通过。

环境的 `install_script`、`start_skill` 已保存为草稿；保存未执行发布，也没有验证全新任务恢复。
