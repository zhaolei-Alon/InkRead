//
//  BookImporter.swift
//  墨读 InkRead —— 导入总闸门：按扩展名分派解析器，产出可直接落盘的 BookDraft
//
//  职责：
//    · 声明支持的扩展名与 UTTypes，供 LibraryView 的 fileImporter 过滤可选文件
//    · 申请安全作用域访问、检查 120MB 体积上限、读取原始字节
//    · 按扩展名分派：EPUB → EPUBImporter；HTML/RTF/Markdown/TXT → TextProcessing + ChapterSplitter
//    · 把解析出的 [RawChapter] 装配成连续正文 + UTF-16 偏移的 [Chapter]，封装为 BookDraft
//  上层调用者：LibraryView（fileImporter 回调）、LibraryStore（导入后 add 落盘）、单元测试 / 内置示例
//  下层依赖：EPUBImporter.load(url:)、ZipReader（经 EPUBImporter 间接使用）、TextProcessing、ChapterSplitter、ImportError、BookDraft / Chapter / RawChapter / BookFormat
//  关键流程：url → load(url:) 分派 → 文本 → ChapterSplitter 切章 → assemble 拼接正文并计算偏移 → BookDraft → LibraryStore.add 写入 AppPaths 的 Books/<uuid>/
//

import Foundation // 引入 Foundation：URL、Data、FileManager、NSAttributedString
import UIKit // 引入 UIKit：NSAttributedString.DocumentType.rtf 依赖 UIKit/TextKit 类型
import UniformTypeIdentifiers // 引入 UTType：为 fileImporter 提供可接受的内容类型

/// 导入器命名空间：纯静态方法，不持有状态
enum BookImporter { // 导入链路的统一入口，LibraryView 只与它打交道

    static let supportedExtensions: Set<String> = ["txt", "text", "epub", "md", "markdown", "html", "htm", "xhtml", "rtf"] // 允许导入的扩展名集合（小写），用于快速判断与测试断言

    static var supportedContentTypes: [UTType] { // fileImporter 的内容类型白名单
        var types: [UTType] = [.plainText, .html, .rtf] // 基础类型：纯文本、HTML、RTF
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) } // 追加 EPUB 类型（系统可能未注册该扩展）
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) } // 追加 Markdown 类型
        return types // 返回最终白名单
    } // 结束 supportedContentTypes

    /// 读取并解析指定文件，生成待落盘的书籍草稿
    /// - Parameter url: 用户通过 fileImporter 选中的文件 URL（可能位于安全作用域沙盒外）
    /// - Returns: 已装配好的 BookDraft（正文、章节偏移、标题作者、来源文件名）
    /// - Throws: ImportError.tooLarge / .emptyFile / .encodingFailed / .damagedEPUB
    static func load(url: URL) throws -> BookDraft { // 导入主流程
        let accessed = url.startAccessingSecurityScopedResource() // 申请安全作用域访问权限
        defer { if accessed { url.stopAccessingSecurityScopedResource() } } // 函数退出时释放权限，避免泄漏

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) // 取文件属性（失败不致命）
        if let size = attributes?[.size] as? Int, size > 120 * 1024 * 1024 { // 体积超过 120MB 时拒绝导入
            throw ImportError.tooLarge // 抛出体积超限错误
        } // 结束体积检查

        let ext = url.pathExtension.lowercased() // 取小写扩展名作为分派键
        let fallbackTitle = TextProcessing.cleanTitle(url.deletingPathExtension().lastPathComponent) // 用文件名清洗出兜底书名
        let data = try Data(contentsOf: url) // 一次性读入全部字节（已在体积上限内）
        guard !data.isEmpty else { throw ImportError.emptyFile } // 空文件直接报错

        switch ext { // 按扩展名分派解析策略
        case "epub": // EPUB 电子书：交给专门的 EPUBImporter
            let result = try EPUBImporter.load(url: url) // 解析出书名、作者与章节
            let cleanTitle = (result.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) // 清洗 OPF 中的书名
            return makeDraft( // 装配草稿
                title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle, // OPF 书名缺失时用文件名兜底
                author: result.author ?? "未知", // 作者缺失填“未知”
                format: .epub, // 标记格式为 EPUB
                chapters: result.chapters, // 直接使用 EPUB 章节
                source: url.lastPathComponent // 记录来源文件名
            ) // 结束 EPUB 分支的 makeDraft 调用

        case "html", "htm", "xhtml": // 独立 HTML 文件
            let html = try TextProcessing.decode(data) // 先识别编码
            let text = TextProcessing.plainText(fromHTML: html) // 再把 HTML 降级为纯文本
            let title = TextProcessing.title(fromHTML: html) ?? fallbackTitle // 优先用 <h1>/<title>，否则用文件名
            return makeDraft(title: title, author: authorOrUnknown(in: text), format: .html, // 装配 HTML 格式草稿
                             chapters: ChapterSplitter.split(text), source: url.lastPathComponent) // 对纯文本切章并记录来源

        case "rtf": // RTF 富文本文档
            let attributed = try? NSAttributedString( // 借助系统 RTF 解析得到富文本
                data: data, // 原始字节
                options: [.documentType: NSAttributedString.DocumentType.rtf], // 指定按 RTF 解析
                documentAttributes: nil // 不需要文档属性
            ) // 结束 NSAttributedString 初始化
            guard let raw = attributed?.string else { throw ImportError.encodingFailed } // 解析失败视为编码/格式错误
            let text = TextProcessing.normalize(raw) // 富文本的纯文本部分再做规范化
            return makeDraft(title: fallbackTitle, author: authorOrUnknown(in: text), format: .rtf, // 装配 RTF 格式草稿
                             chapters: ChapterSplitter.split(text), source: url.lastPathComponent) // 切章并记录来源

        case "md", "markdown": // Markdown 文档
            let markdown = try TextProcessing.decode(data) // 先识别编码
            let text = TextProcessing.plainText(fromMarkdown: markdown) // 去掉 Markdown 标记
            return makeDraft(title: fallbackTitle, author: authorOrUnknown(in: text), format: .markdown, // 装配 Markdown 格式草稿
                             chapters: ChapterSplitter.split(text, markdownHeadings: containsMarkdownHeading(markdown)), // 有 >=2 个 # 标题时按 Markdown 标题切章
                             source: url.lastPathComponent) // 记录来源文件名

        default: // 其余（txt/text 及未知扩展名）
            // 未识别扩展名：先嗅探 EPUB，再按纯文本处理
            if data.starts(with: [0x50, 0x4B]) { // PK 是 ZIP 文件头，说明很可能是改了后缀的 EPUB
                let result = try EPUBImporter.load(url: url) // 按 EPUB 解析
                return makeDraft( // 装配草稿
                    title: result.title?.nilIfEmpty ?? fallbackTitle, // OPF 书名空串时用文件名兜底
                    author: result.author ?? "未知", // 作者缺失填“未知”
                    format: .epub, // 标记格式为 EPUB
                    chapters: result.chapters, // 使用 EPUB 章节
                    source: url.lastPathComponent // 记录来源文件名
                ) // 结束嗅探 EPUB 分支的 makeDraft 调用
            } // 结束 ZIP 文件头判断
            let raw = try TextProcessing.decode(data) // 非 ZIP 则按文本解码
            let text = TextProcessing.normalize(raw) // 规范化文本
            guard !text.isEmpty else { throw ImportError.emptyFile } // 规范化后为空说明无有效内容
            return makeDraft(title: fallbackTitle, author: authorOrUnknown(in: text), format: .txt, // 装配纯文本格式草稿
                             chapters: ChapterSplitter.split(text), source: url.lastPathComponent) // 切章并记录来源
        } // 结束扩展名分派
    } // 结束 load(url:)

    /// 仅用于测试 / 内置示例：直接从字符串生成书籍
    /// - Parameters:
    ///   - title: 书名
    ///   - author: 作者
    ///   - format: 书籍格式标记
    ///   - text: 完整正文（内部会自动切章）
    ///   - source: 来源文件名，默认 nil
    /// - Returns: 装配好的 BookDraft
    static func makeDraft(title: String, author: String, format: BookFormat, // 字符串入参的便捷重载
                          text: String, source: String? = nil) -> BookDraft { // 交给章节版重载完成装配
        makeDraft( // 复用章节版实现
            title: title, // 透传书名
            author: author, // 透传作者
            format: format, // 透传格式
            chapters: ChapterSplitter.split(text), // 先把整篇文本切章
            source: source // 透传来源
        ) // 结束 makeDraft 调用
    } // 结束字符串版 makeDraft

    /// 由章节数组装配 BookDraft：拼接正文并清洗标题/作者字段
    /// - Parameters:
    ///   - title: 书名（空白时用“未命名书籍”）
    ///   - author: 作者（空白时用“未知”）
    ///   - format: 书籍格式标记
    ///   - chapters: 已切好的原始章节
    ///   - source: 来源文件名
    /// - Returns: 可直接交给 LibraryStore.add 的 BookDraft
    static func makeDraft(title: String, author: String, format: BookFormat, // 章节入参的核心重载
                          chapters: [RawChapter], source: String?) -> BookDraft { // 所有 load 分支最终都汇聚到这里
        let (text, assembled) = assemble(chapters) // 拼接正文并计算每章的 UTF-16 偏移
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines) // 清洗书名首尾空白
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines) // 清洗作者首尾空白
        return BookDraft( // 构造草稿对象
            title: normalizedTitle.isEmpty ? "未命名书籍" : normalizedTitle, // 空书名兜底
            author: normalizedAuthor.isEmpty ? "未知" : normalizedAuthor, // 空作者兜底
            format: format, // 格式标记
            text: text, // 拼接后的完整正文
            chapters: assembled, // 带偏移的章节列表
            sourceFileName: source // 来源文件名
        ) // 结束 BookDraft 初始化
    } // 结束章节版 makeDraft

    /// 把各章正文用两个换行拼接成连续正文，同时生成以 UTF-16 计的章节偏移
    /// - Parameter raws: 原始章节数组（可能含空白正文）
    /// - Returns: 元组（完整正文, 章节列表）；章节的 start 为起始 UTF-16 下标，length 为正文 UTF-16 长度
    static func assemble(_ raws: [RawChapter]) -> (text: String, chapters: [Chapter]) { // 偏移计算的唯一实现处
        var parts: [String] = [] // 正文分片，最后一次性 join 以避免 O(n²) 拼接
        var chapters: [Chapter] = [] // 输出章节列表
        var cursor = 0 // 当前写入位置（UTF-16 下标）

        for raw in raws { // 逐章处理
            let body = raw.body.trimmingCharacters(in: .whitespacesAndNewlines) // 去掉本章正文首尾空白
            guard !body.isEmpty else { continue } // 空正文跳过，避免产生零长度章节
            let length = body.utf16.count // 本章正文的 UTF-16 长度（与 NSString/NSAttributedString 一致）
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines) // 清洗本章标题
            chapters.append(Chapter( // 记录章节元信息
                index: chapters.count, // 章节序号从 0 递增
                title: title.isEmpty ? "第 \(chapters.count + 1) 章" : title, // 空标题按序号补齐
                start: cursor, // 本章正文在全文中的起始 UTF-16 下标
                length: length // 本章正文的 UTF-16 长度
            )) // 结束 Chapter 初始化
            parts.append(body) // 追加正文
            cursor += length + 2 // 游标前进：正文长度 + 两个换行符
            parts.append("\n\n") // 追加章节间分隔符（两字符，需计入偏移）
        } // 结束章节遍历

        return (parts.joined(), chapters) // 拼接并返回结果
    } // 结束 assemble

    /// 识别作者，未识别到统一返回“未知”
    /// - Parameter text: 待搜索的纯文本
    /// - Returns: 作者名或“未知”
    private static func authorOrUnknown(in text: String) -> String { // 供 HTML/RTF/Markdown/TXT 分支复用
        TextProcessing.detectAuthor(in: text) ?? "未知" // 调用 TextProcessing 的正则识别，空则兜底
    } // 结束 authorOrUnknown

    /// 判断 Markdown 中是否存在至少两个 # 标题（决定是否按标题切章）
    /// - Parameter markdown: 原始 Markdown 文本
    /// - Returns: true 表示标题数量 >= 2
    private static func containsMarkdownHeading(_ markdown: String) -> Bool { // 避免只有一个 # 时误判
        guard let regex = try? NSRegularExpression(pattern: "(?m)^[ \\t]*#{1,6}[ \\t]+\\S", options: []) else { return false } // 标题行正则：行首 # 后必须有可见字符
        let ns = markdown as NSString // 转 NSString 以计算 UTF-16 范围
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: ns.length)) // 统计标题行数量
        return matches.count >= 2 // 至少两个标题才认为该文档按标题组织
    } // 结束 containsMarkdownHeading
} // 结束 BookImporter

/// 字符串便捷扩展：空串视为 nil，便于 `??` 兜底
extension String { // 供 BookImporter 及调用方使用
    var nilIfEmpty: String? { // 空串返回 nil，否则返回自身
        isEmpty ? nil : self // 三元判断
    } // 结束 nilIfEmpty
} // 结束 String 扩展
