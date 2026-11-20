//
//  AppPaths.swift
//  墨读 InkRead —— 沙盒路径与 JSON 编解码的统一约定
//
//  职责：
//    · 暴露应用数据根目录 root、书籍目录 booksRoot 及 library.json / bookmarks.json 的固定路径
//    · 按书籍 id 生成目录与正文、章节、分页缓存文件路径，并提供目录创建方法
//    · 提供 dateEncodingStrategy 为 ISO8601 的 JSONEncoder / JSONDecoder 静态实例
//  上层调用者：LibraryStore（读写 library.json、content.txt、chapters.json、layout.json）、BookmarkStore（读写 bookmarks.json）
//  下层依赖：Foundation（FileManager、URL、JSONEncoder、JSONDecoder）
//  关键流程：服务层把书籍数据编码为 JSON / 纯文本 → 经本文件的 URL 常量写入 Application Support/InkRead →
//           下次启动时再从同一路径读回并解码
//

import Foundation // 引入 Foundation，提供 FileManager、URL 与 JSON 编解码

/// 应用沙盒路径常量与文件定位工具。
/// 所有持久化文件都集中在 Application Support/InkRead 下，便于统一管理与备份。
enum AppPaths { // 声明路径常量命名空间枚举
    /// 应用数据根目录（Application Support/InkRead）。
    /// 首次访问时懒加载创建目录；取不到 Application Support 时退化为临时目录。
    static let root: URL = { // 用闭包延迟初始化根目录
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first // 取 Application Support 目录
            ?? URL(fileURLWithPath: NSTemporaryDirectory()) // 兜底：取不到时使用临时目录
        let url = base.appendingPathComponent("InkRead", isDirectory: true) // 在基目录下拼出 InkRead 子目录
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // 创建目录（已存在则忽略错误）
        return url // 返回根目录 URL
    }() // 立即执行闭包并作为常量值

    /// 全部书籍的子目录（InkRead/Books）。
    /// 懒加载创建目录；LibraryStore 删除书籍时以每本书的 id 作为其下级目录名。
    static let booksRoot: URL = { // 用闭包延迟初始化书籍根目录
        let url = root.appendingPathComponent("Books", isDirectory: true) // 拼出 Books 子目录
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // 创建目录（已存在则忽略错误）
        return url // 返回书籍根目录 URL
    }() // 立即执行闭包并作为常量值

    /// 书库索引文件（书籍元数据数组）。
    static let libraryFile = root.appendingPathComponent("library.json") // LibraryStore 读写该文件
    /// 书签索引文件（书签数组）。
    static let bookmarksFile = root.appendingPathComponent("bookmarks.json") // BookmarkStore 读写该文件

    /// 某本书的专属目录。
    /// - Parameter id: 书籍唯一标识。
    /// - Returns: Books/<UUID> 目录 URL；该方法不创建目录，需要时调用 ensureBookFolder。
    static func bookFolder(_ id: UUID) -> URL { // 定义书籍目录路径方法
        booksRoot.appendingPathComponent(id.uuidString, isDirectory: true) // 用 UUID 字符串作为子目录名
    } // 结束 bookFolder(_:)

    /// 某本书的正文纯文本文件。
    /// - Parameter id: 书籍唯一标识。
    /// - Returns: Books/<UUID>/content.txt 的 URL。
    static func textFile(_ id: UUID) -> URL { // 定义正文文件路径方法
        bookFolder(id).appendingPathComponent("content.txt") // 在书籍目录下拼接正文文件名
    } // 结束 textFile(_:)

    /// 某本书的章节定位文件。
    /// - Parameter id: 书籍唯一标识。
    /// - Returns: Books/<UUID>/chapters.json 的 URL。
    static func chaptersFile(_ id: UUID) -> URL { // 定义章节文件路径方法
        bookFolder(id).appendingPathComponent("chapters.json") // 在书籍目录下拼接章节文件名
    } // 结束 chaptersFile(_:)

    /// 某本书的分页缓存文件。
    /// - Parameter id: 书籍唯一标识。
    /// - Returns: Books/<UUID>/layout.json 的 URL。
    static func layoutFile(_ id: UUID) -> URL { // 定义分页缓存路径方法
        bookFolder(id).appendingPathComponent("layout.json") // 在书籍目录下拼接分页缓存文件名
    } // 结束 layoutFile(_:)

    /// 确保某本书的目录存在。
    /// - Parameter id: 书籍唯一标识。
    /// 副作用：在磁盘上创建目录（已存在或失败时静默忽略）。
    static func ensureBookFolder(_ id: UUID) { // 定义目录创建方法
        try? FileManager.default.createDirectory(at: bookFolder(id), withIntermediateDirectories: true) // 递归创建书籍目录
    } // 结束 ensureBookFolder(_:)
} // 结束 AppPaths 枚举

/// JSONEncoder 的工程内统一入口。
/// LibraryStore / BookmarkStore 用它编码书籍、章节、书签与分页缓存，保证日期格式一致。
extension JSONEncoder { // 扩展 JSONEncoder
    /// 使用 ISO8601 日期策略的编码器。
    /// 说明：每次访问都新建实例，避免共享状态；返回值可直接 encode。
    static var ink: JSONEncoder { // 定义静态便利编码器
        let encoder = JSONEncoder() // 创建编码器实例
        encoder.dateEncodingStrategy = .iso8601 // 日期按 ISO8601 字符串输出，跨版本可读
        return encoder // 返回配置好的编码器
    } // 结束 ink 计算属性
} // 结束 JSONEncoder 扩展

/// JSONDecoder 的工程内统一入口。
/// 与 JSONEncoder.ink 的日期策略配对，用于读回 library.json / chapters.json / bookmarks.json / layout.json。
extension JSONDecoder { // 扩展 JSONDecoder
    /// 使用 ISO8601 日期策略的解码器。
    /// 说明：每次访问都新建实例；返回值可直接 decode。
    static var ink: JSONDecoder { // 定义静态便利解码器
        let decoder = JSONDecoder() // 创建解码器实例
        decoder.dateDecodingStrategy = .iso8601 // 与编码端保持一致的 ISO8601 日期解析
        return decoder // 返回配置好的解码器
    } // 结束 ink 计算属性
} // 结束 JSONDecoder 扩展
