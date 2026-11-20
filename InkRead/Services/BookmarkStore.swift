//
//  BookmarkStore.swift
//  墨读 InkRead —— 书签的内存列表与 JSON 持久化
//
//  职责：
//    · 维护全部书籍共享的书签数组，按书筛选并按创建时间倒序展示
//    · 负责书签的新增 / 取消（toggle）、单条删除、整书清理
//    · 任何变更后异步写入 bookmarks.json
//  上层调用者：InkReadApp（创建并注入环境）、LibraryView（书签列表/跳转）、ReaderViewModel 与 ReaderSheets（阅读中打点与书签面板）
//  下层依赖：AppPaths（bookmarksFile 路径与 JSON 编解码）、Bookmark 模型、DispatchQueue 全局队列
//  关键流程：阅读器点击「加书签/去书签」→ toggle() 判定同位置是否已存在 → 增删内存数组 → save() 后台写 bookmarks.json
//

import Foundation // 引入 Foundation：Data、UUID、DispatchQueue 与 JSON 编解码

/// 书签仓库：全 App 唯一实例，供书架与阅读器共享书签数据
final class BookmarkStore: ObservableObject { // 可观察对象：bookmarks 变化时驱动书签面板刷新
    /// 全部书签数组，对外只读；新书签插入首位，删除按 id 过滤
    @Published private(set) var bookmarks: [Bookmark] = [] // 发布属性，读写均通过本类方法完成

    /// 初始化时从磁盘载入已有书签
    init() { // 由 InkReadApp 在启动时构造
        load() // 读取 bookmarks.json 到内存
    } // 结束 init()

    /// 取某本书的书签，按创建时间从新到旧排序
    /// - Parameter bookID: 书籍 id
    /// - Returns: 该书全部书签（新的在前）
    func bookmarks(for bookID: UUID) -> [Bookmark] { // 由 LibraryView 书签页与 ReaderSheets 书签列表调用
        bookmarks.filter { $0.bookID == bookID }.sorted { $0.createdAt > $1.createdAt } // 先按书过滤，再按创建时间倒序
    } // 结束 bookmarks(for:)

    /// 判断某位置是否已有书签
    /// - Parameters:
    ///   - bookID: 书籍 id
    ///   - chapterIndex: 章节索引
    ///   - charOffset: 章节内 UTF-16 偏移
    /// - Returns: 存在同位置书签则返回 true
    /// - 说明：偏移差小于 8 个 UTF-16 单元即视为同一位置，容忍轻微落点误差
    func contains(bookID: UUID, chapterIndex: Int, charOffset: Int) -> Bool { // 由 ReaderView 决定书签按钮的选中态
        bookmarks.contains { // 是否存在满足条件的书签
            $0.bookID == bookID && $0.chapterIndex == chapterIndex && abs($0.charOffset - charOffset) < 8 // 同书、同章且偏移足够接近
        } // 结束 书签匹配闭包
    } // 结束 contains(bookID:chapterIndex:charOffset:)

    /// 切换书签：已存在则删除，不存在则新增
    /// - Parameters:
    ///   - bookID: 书籍 id
    ///   - chapterIndex: 章节索引
    ///   - chapterTitle: 章节标题（用于书签列表展示）
    ///   - charOffset: 章节内 UTF-16 偏移
    ///   - snippet: 书签位置附近的文本摘要
    /// - 副作用：修改内存数组并异步写入 bookmarks.json
    func toggle(bookID: UUID, chapterIndex: Int, chapterTitle: String, charOffset: Int, snippet: String) { // 由阅读器点击书签按钮调用
        if let existing = bookmarks.first(where: { // 先查找同一位置是否已存在书签
            $0.bookID == bookID && $0.chapterIndex == chapterIndex && abs($0.charOffset - charOffset) < 8 // 判定条件与 contains 保持一致
        }) { // 查找闭包结束，命中则走删除分支
            bookmarks.removeAll { $0.id == existing.id } // 已存在则移除，实现「取消书签」
        } else { // 未命中则新建书签
            let bookmark = Bookmark( // 构造书签模型（id 与 createdAt 由模型默认值生成）
                bookID: bookID, // 所属书籍 id
                chapterIndex: chapterIndex, // 所属章节索引
                chapterTitle: chapterTitle, // 章节标题
                charOffset: charOffset, // 章节内 UTF-16 偏移
                snippet: snippet // 位置附近的文本摘要
            ) // 结束 Bookmark 构造
            bookmarks.insert(bookmark, at: 0) // 插入首位，保证列表新的在前
        } // 结束 新增/删除分支
        save() // 变更后立即持久化
    } // 结束 toggle(bookID:chapterIndex:chapterTitle:charOffset:snippet:)

    /// 删除单条书签
    /// - Parameter bookmark: 待删除的书签
    /// - 副作用：移除内存记录并异步写盘
    func remove(_ bookmark: Bookmark) { // 由书签列表左滑删除调用
        bookmarks.removeAll { $0.id == bookmark.id } // 按 id 精确移除
        save() // 变更后立即持久化
    } // 结束 remove(_:)

    /// 清空某本书的全部书签
    /// - Parameter bookID: 书籍 id
    /// - 副作用：移除该书所有书签并异步写盘（删除书籍时同步调用）
    func removeAll(for bookID: UUID) { // 由书架删除书籍流程调用，避免残留孤儿书签
        bookmarks.removeAll { $0.bookID == bookID } // 过滤掉该书的所有书签
        save() // 变更后立即持久化
    } // 结束 removeAll(for:)

    /// 从 bookmarks.json 载入书签列表
    /// - 说明：文件缺失或解码失败时保持空数组，不抛错
    private func load() { // 仅在 init() 中调用
        guard let data = try? Data(contentsOf: AppPaths.bookmarksFile), // 读取书签文件
              let list = try? JSONDecoder.ink.decode([Bookmark].self, from: data) else { return } // 解码书签数组，失败则直接返回
        bookmarks = list // 载入成功则覆盖内存数组
    } // 结束 load()

    /// 异步持久化书签列表
    /// - 副作用：后台队列原子写入 bookmarks.json；使用快照避免线程竞争
    private func save() { // 由 toggle / remove / removeAll 调用
        let snapshot = bookmarks // 值类型快照，隔离主线程后续修改
        DispatchQueue.global(qos: .utility).async { // 后台低优先级队列执行 I/O
            guard let data = try? JSONEncoder.ink.encode(snapshot) else { return } // 编码快照，失败则放弃本次写入
            try? data.write(to: AppPaths.bookmarksFile, options: .atomic) // 原子写入 bookmarks.json
        } // 结束 后台写书签闭包
    } // 结束 save()
} // 结束 BookmarkStore 类
