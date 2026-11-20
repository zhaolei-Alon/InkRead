//
//  Book.swift
//  墨读 InkRead —— 书库数据模型层，集中定义书籍、章节、书签与导入中间产物的纯数据结构
//
//  职责：
//    · 声明书籍格式枚举 BookFormat，并提供界面展示用的短名称
//    · 定义阅读进度 ReadingProgress、书籍 Book、章节 Chapter、书签 Bookmark
//    · 定义导入链路中传递的草稿结构 BookDraft 与原始章节 RawChapter
//  上层调用者：LibraryStore（读写 Book / Chapter）、BookImporter / ChapterSplitter / EPUBImporter（产出 BookDraft / RawChapter）、
//              ReaderViewModel（消费 Chapter、写出 ReadingProgress）、BookmarkStore（持久化 Bookmark）、LibraryView / ReaderView（展示）
//  下层依赖：仅 Foundation（UUID、Date、Codable、Hashable），不依赖 UIKit 或任何服务层类型
//  关键流程：导入器产出 BookDraft → LibraryStore.add 由草稿生成 Book，并与 Chapter 数组分别落盘 →
//            ReaderViewModel 以 Chapter 的 UTF-16 偏移做分页，并把 ReadingProgress 回写进 Book
//

import Foundation // 引入 Foundation，提供 UUID、Date、Codable、Hashable 等基础能力

/// 电子书文件格式。
/// 作为 Book.format 的持久化标识（String 原始值），同时供导入流程选择解析器分支。
enum BookFormat: String, Codable, CaseIterable { // 声明书籍格式枚举：String 原始值、可 Codable 持久化、可 CaseIterable 遍历
    case txt // 纯文本格式，交给 TextProcessing + ChapterSplitter 处理
    case epub // EPUB 电子书包格式，交给 EPUBImporter + ZipReader 处理
    case markdown // Markdown 文本，按标题层级切分章节
    case html // HTML 文档，先剥离标签再切分
    case rtf // RTF 富文本，经文本提取后切分

    /// 面向界面的展示名（书库卡片、详情等处显示）。
    /// 返回值：格式的短名称字符串；无副作用。
    var displayName: String { // 计算属性：把格式映射为界面展示用的短名称
        switch self { // 根据当前格式分支返回对应名称
        case .txt: return "TXT" // 纯文本显示为 TXT
        case .epub: return "EPUB" // EPUB 显示为 EPUB
        case .markdown: return "MD" // Markdown 简写为 MD
        case .html: return "HTML" // HTML 显示为 HTML
        case .rtf: return "RTF" // RTF 显示为 RTF
        } // 结束 switch 分支
    } // 结束 displayName 计算属性
} // 结束 BookFormat 枚举

/// 阅读进度快照。
/// 由 ReaderViewModel 在翻页/退出时写入，经 LibraryStore.updateProgress 落到 library.json；
/// 三个字段共同定位「上次读到哪一页」，percent 仅用于书库卡片展示百分比。
struct ReadingProgress: Codable, Hashable { // 声明阅读进度结构体：可编解码、可哈希比较
    var chapterIndex: Int = 0 // 所在章节下标，对应 Chapter.index
    /// 章节内 UTF-16 偏移（取当前页起始位置）
    var charOffset: Int = 0 // 章节内以 UTF-16 计数的偏移量，取当前页首个字符的位置
    var percent: Double = 0 // 全书阅读百分比（0 ~ 1），仅用于书库卡片进度展示
    var updatedAt: Date = .distantPast // 最后一次更新该进度的时间，默认远古时间表示「从未读过」
} // 结束 ReadingProgress 结构体

/// 书库中的一本书（纯元数据，不含正文内容）。
/// 由 LibraryStore 创建与维护，持久化到 library.json；正文与章节分别存于 AppPaths 指向的文件。
struct Book: Identifiable, Codable, Hashable { // 声明书籍元数据结构体：可识别、可编解码、可哈希
    var id = UUID() // 书籍唯一标识，同时用作沙盒目录名（见 folderName）
    var title: String // 书名，导入时从文件名或 EPUB 元数据取得
    var author: String = "未知" // 作者名，缺失时显示「未知」
    var format: BookFormat = .txt // 原始文件格式，决定书库卡片上的格式标签
    var characterCount: Int = 0 // 正文字符数（UTF-16 计数），用于详情展示与阅读时长估算
    var chapterCount: Int = 0 // 章节数量，用于书库详情展示
    var addedAt: Date = Date() // 加入书库的时间，默认创建时刻
    var lastOpenedAt: Date? // 最近一次打开阅读的时间，nil 表示从未打开
    var progress = ReadingProgress() // 阅读进度，由 ReaderViewModel 计算后经 LibraryStore 回写
    var coverIndex: Int = 0 // 封面调色板下标，LibraryStore 依据书名哈希生成
    var sourceFileName: String? // 导入时的原始文件名，用于详情展示与来源追溯

    /// 该书在沙盒 Books 目录下的子目录名。
    /// 返回值：以 UUID 大写字符串命名的目录名；无副作用。
    var folderName: String { id.uuidString } // 直接把 UUID 转成字符串作为目录名
} // 结束 Book 结构体

/// 单个章节的定位信息（不含正文，正文统一存在 content.txt 中）。
/// 由 ChapterSplitter / EPUBImporter 间接产出（经 BookDraft），LibraryStore 落盘为 chapters.json，
/// ReaderViewModel 依据 start/length 从全文 NSString 中截取本章内容进行分页。
struct Chapter: Codable, Identifiable, Hashable { // 声明章节结构体：可编解码、可识别、可哈希
    var index: Int // 章节序号，从 0 开始，同时作为 id
    var title: String // 章节标题，用于目录列表与页眉展示
    /// 全文 UTF-16 偏移
    var start: Int // 章节在全文中的起始位置（UTF-16 单位）
    /// UTF-16 长度
    var length: Int // 章节在全文中的长度（UTF-16 单位），与 start 共同界定 NSRange
    var id: Int { index } // 以序号作为 Identifiable 的标识，保证目录列表稳定
} // 结束 Chapter 结构体

/// 书签。
/// 由 BookmarkStore 增删并持久化到 bookmarks.json，ReaderViewModel / ReaderView 负责定位跳转。
struct Bookmark: Identifiable, Codable, Hashable { // 声明书签结构体：可识别、可编解码、可哈希
    var id = UUID() // 书签唯一标识
    var bookID: UUID // 所属书籍的 id，用于按书筛选书签
    var chapterIndex: Int // 书签所在章节序号
    var chapterTitle: String // 冗余保存章节标题，便于书签列表直接展示（即使章节文件缺失）
    var charOffset: Int // 章节内 UTF-16 偏移，定位到具体段落
    var snippet: String // 书签处的文本摘要，供列表预览
    var createdAt = Date() // 书签创建时间，默认创建时刻
} // 结束 Bookmark 结构体

/// 导入器输出的书籍草稿
struct BookDraft { // 声明导入草稿结构体：解析完成、尚未写入磁盘的中间态
    var title: String // 解析出的书名
    var author: String // 解析出的作者名
    var format: BookFormat // 原始文件格式
    var text: String // 合并后的全文纯文本，最终写入 content.txt
    var chapters: [Chapter] // 已切分好的章节定位数组，最终写入 chapters.json
    var sourceFileName: String? // 原始文件名，导入成功后转存到 Book.sourceFileName
} // 结束 BookDraft 结构体

/// 导入过程中的原始章节
struct RawChapter { // 声明原始章节结构体：章节切分的中间产物，正文尚未拼接偏移
    var title: String // 章节标题
    var body: String // 章节正文，后续由 BookImporter.assemble 拼接全文并计算 UTF-16 偏移
} // 结束 RawChapter 结构体
