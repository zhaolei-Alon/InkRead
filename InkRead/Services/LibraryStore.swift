//
//  LibraryStore.swift
//  墨读 InkRead —— 书库数据落盘与内存缓存中枢
//
//  职责：
//    · 维护书籍元数据列表（library.json），提供查询、导入、删除、阅读进度更新
//    · 按书缓存章节列表与整书正文（chapters.json / content.txt），减少重复磁盘 I/O
//    · 读写分页布局缓存（layout.json），支撑再次打开时「秒开」
//  上层调用者：InkReadApp（创建并注入环境）、LibraryView（书架展示、删除、导入后写库）、ReaderViewModel（fullText / chapters / markOpened / updateProgress / loadLayout / saveLayout / flush / releaseTextCache）
//  下层依赖：AppPaths（沙盒路径与 JSON 编解码）、BookImporter（文件解析与支持格式判定）、Book / BookDraft / Chapter / ReadingProgress / CachedLayout、UserDefaults、FileManager
//  关键流程：BookImporter 产出 BookDraft → add() 落盘 content.txt 与 chapters.json → 内存插入首行并 persist() 写 library.json → @Published 触发书架刷新
//

import Foundation // 引入 Foundation：FileManager、UserDefaults、Data 与 JSON 编解码

/// 书库：负责书籍元数据、正文文件、章节信息的落盘与读取。
final class LibraryStore: ObservableObject { // 可观察对象：books 变更时自动通知 SwiftUI 视图刷新
    /// 书籍列表，对外只读；书架按此数组顺序展示，新书插入在最前
    @Published private(set) var books: [Book] = [] // 发布属性：任何变更都会驱动 LibraryView 重绘

    /// 章节列表内存缓存，key 为书籍 id，避免反复读取 chapters.json
    private var chaptersCache: [UUID: [Chapter]] = [:] // 字典缓存，随书籍增删同步维护
    /// 当前缓存的整书正文所属的书籍 id
    private var cachedTextBookID: UUID? // 与 cachedText 成对使用，用于命中判定
    /// 当前缓存的整书正文；使用 NSString 便于按 UTF-16 偏移切片
    private var cachedText: NSString? // 全文字符串缓存，阅读器关闭时由 releaseTextCache() 释放
    /// 延迟落盘任务，用于合并高频的阅读进度写入
    private var pendingPersist: DispatchWorkItem? // 保存未执行的落盘工作项，便于取消并重新排期

    /// UserDefaults 键：标记内置示例书是否已植入，确保只生成一次
    private let seedKey = "inkread.didSeedSamples.v3" // 版本化键名：v3 新增 5 本示例书（v2 用户升级后自动补种新增项）

    /// 初始化：读取书库 → 按版本补种示例书 → 导入 Documents 下的外部书籍
    init() { // 由 InkReadApp 在启动时构造一次
        loadLibrary() // 从 library.json 恢复已有书籍列表
        seedSampleBooksIfNeeded() // 按版本标记补种缺失的示例书（升级用户也能拿到新增示例书）
        importDroppedDocuments() // 扫描 Documents 目录，导入用户经「文件」App 放入的书籍
    } // 结束 init()

    // MARK: - 读取
    // 读取区：按 id 查书、读章节、读正文、释放正文缓存，供 LibraryView 与 ReaderViewModel 调用

    /// 按 id 查找书籍
    /// - Parameter id: 书籍唯一标识
    /// - Returns: 命中则返回该书元数据，否则返回 nil
    func book(with id: UUID) -> Book? { // 只查内存列表，不触发磁盘读取
        books.first { $0.id == id } // 线性查找首个匹配项
    } // 结束 book(with:)

    /// 读取指定书籍的章节列表（带内存缓存）
    /// - Parameter bookID: 书籍 id
    /// - Returns: 章节数组；文件缺失或解码失败时返回空数组
    func chapters(for bookID: UUID) -> [Chapter] { // 由 ReaderViewModel 初始化时调用
        if let cached = chaptersCache[bookID] { return cached } // 命中内存缓存则直接返回
        guard let data = try? Data(contentsOf: AppPaths.chaptersFile(bookID)), // 尝试读取该书的 chapters.json
              let list = try? JSONDecoder.ink.decode([Chapter].self, from: data) else { // 解码章节数组，任一环节失败即走 else
            return [] // 文件缺失或内容损坏时返回空章节列表
        } // 结束 guard 读取章节块
        chaptersCache[bookID] = list // 回填内存缓存，供后续调用复用
        return list // 返回解码后的章节数组
    } // 结束 chapters(for:)

    /// 读取指定书籍的整书正文（带单本缓存）
    /// - Parameter bookID: 书籍 id
    /// - Returns: UTF-16 友好的 NSString；读取或解码失败时返回 nil
    func fullText(for bookID: UUID) -> NSString? { // 由 ReaderViewModel 打开书籍时调用
        if cachedTextBookID == bookID, let cachedText { return cachedText } // 同一本书且缓存存在时直接命中
        guard let text = try? String(contentsOf: AppPaths.textFile(bookID), encoding: .utf8) else { // 以 UTF-8 读取 content.txt
            return nil // 读取失败（文件不存在/编码不符）时返回 nil
        } // 结束 guard 读取正文块
        let ns = text as NSString // 桥接为 NSString，便于后续按 UTF-16 区间截取
        cachedTextBookID = bookID // 记录缓存归属的书籍 id
        cachedText = ns // 保存正文缓存
        return ns // 返回正文
    } // 结束 fullText(for:)

    /// 释放整书正文缓存，降低阅读器退出后的内存占用
    func releaseTextCache() { // 由 ReaderViewModel 在关闭书籍/进入后台时调用
        cachedText = nil // 丢弃正文字符串
        cachedTextBookID = nil // 清空缓存归属标记
    } // 结束 releaseTextCache()

    // MARK: - 写入
    // 写入区：新增/删除书籍、更新打开时间与进度、布局缓存读写，副作用均为磁盘 I/O 与 @Published 刷新

    /// 将导入器产出的书稿写入书库
    /// - Parameter draft: BookImporter 解析得到的书籍草稿
    /// - Returns: 已入库的书籍元数据
    /// - Throws: 书稿为空时抛 ImportError.emptyFile；编码失败时抛 ImportError.encodingFailed
    /// - 副作用：创建书籍目录、写入 content.txt 与 chapters.json、更新内存列表并异步写 library.json
    @discardableResult // 允许调用方忽略返回值（如示例书导入）
    func add(_ draft: BookDraft) throws -> Book { // 由 LibraryView 导入流程与内部示例书/外部文件导入调用
        guard !draft.text.isEmpty, !draft.chapters.isEmpty else { // 正文与章节都不能为空
            throw ImportError.emptyFile // 空文件或解析不出章节时直接报错
        } // 结束 guard 空内容校验
        var book = Book( // 以书稿信息构造书籍元数据，id/addedAt 等使用默认值
            title: draft.title, // 书名取自书稿
            author: draft.author, // 作者取自书稿
            format: draft.format, // 文件格式（txt/epub/markdown/html/rtf）
            characterCount: draft.text.utf16.count, // 字符数按 UTF-16 计数，与分页偏移口径保持一致
            chapterCount: draft.chapters.count // 章节数量
        ) // 结束 Book 构造
        book.sourceFileName = draft.sourceFileName // 记录原始文件名，便于书架展示来源
        book.coverIndex = Self.coverIndex(for: draft.title) // 依据书名计算稳定的封面配色索引

        AppPaths.ensureBookFolder(book.id) // 先创建该书的沙盒目录
        guard let data = draft.text.data(using: .utf8) else { // 正文转 UTF-8 字节，理论上不会失败
            throw ImportError.encodingFailed // 编码失败时抛出导入错误
        } // 结束 guard 正文字节化
        try data.write(to: AppPaths.textFile(book.id), options: .atomic) // 原子写入 content.txt
        let chaptersData = try JSONEncoder.ink.encode(draft.chapters) // 序列化章节数组
        try chaptersData.write(to: AppPaths.chaptersFile(book.id), options: .atomic) // 原子写入 chapters.json

        books.insert(book, at: 0) // 新书插入列表首位，触发书架刷新
        chaptersCache[book.id] = draft.chapters // 直接回填章节缓存，省去一次磁盘读取
        persist() // 异步持久化书库元数据
        return book // 返回入库后的书籍
    } // 结束 add(_:)

    /// 从书库永久删除一本书
    /// - Parameter book: 待删除的书籍
    /// - 副作用：移除内存记录与缓存、删除整本目录、异步写 library.json
    func delete(_ book: Book) { // 由 LibraryView 的删除操作调用
        books.removeAll { $0.id == book.id } // 从内存列表移除该书
        chaptersCache[book.id] = nil // 清掉章节缓存
        if cachedTextBookID == book.id { // 若删除的正是正文缓存所属书籍
            cachedText = nil // 释放正文缓存
            cachedTextBookID = nil // 清空缓存归属标记
        } // 结束 正文缓存清理条件块
        try? FileManager.default.removeItem(at: AppPaths.bookFolder(book.id)) // 递归删除该书目录下全部文件
        persist() // 异步持久化书库列表
    } // 结束 delete(_:)

    /// 记录一次打开行为，更新最近打开时间
    /// - Parameter bookID: 书籍 id
    /// - 副作用：更新内存中 lastOpenedAt，并延迟落盘（persistSoon）
    func markOpened(_ bookID: UUID) { // 由 ReaderViewModel 初始化阅读时调用
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return } // 找不到对应书籍则直接返回
        books[idx].lastOpenedAt = Date() // 记录当前时间，供书架按最近阅读排序/展示
        persistSoon() // 合并写盘，避免打开书籍时频繁 I/O
    } // 结束 markOpened(_:)

    /// 更新阅读进度
    /// - Parameters:
    ///   - bookID: 书籍 id
    ///   - progress: 章节索引、章节内 UTF-16 偏移与百分比
    /// - 副作用：覆盖该书 progress 并刷新 updatedAt，延迟落盘
    func updateProgress(bookID: UUID, progress: ReadingProgress) { // 由 ReaderViewModel 翻页/滚动时调用
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return } // 书籍不存在时忽略
        var newProgress = progress // 复制一份，避免修改调用方传入的值
        newProgress.updatedAt = Date() // 标记进度更新时间
        books[idx].progress = newProgress // 写回内存列表
        persistSoon() // 延迟合并落盘
    } // 结束 updateProgress(bookID:progress:)

    /// 保存分页结果，便于下次打开秒开
    /// - Parameters:
    ///   - layout: 含排版签名与各章 PageSlice 的布局缓存
    ///   - bookID: 书籍 id
    /// - 副作用：在后台队列原子写入 layout.json（不阻塞主线程）
    func saveLayout(_ layout: CachedLayout, for bookID: UUID) { // 由 ReaderViewModel 分页完成后调用
        DispatchQueue.global(qos: .utility).async { // 切到后台低优先级队列写文件
            AppPaths.ensureBookFolder(bookID) // 确保目标目录存在
            guard let data = try? JSONEncoder.ink.encode(layout) else { return } // 编码布局缓存，失败则放弃本次写入
            try? data.write(to: AppPaths.layoutFile(bookID), options: .atomic) // 原子写入 layout.json
        } // 结束 后台写布局闭包
    } // 结束 saveLayout(_:for:)

    /// 读取分页布局缓存
    /// - Parameter bookID: 书籍 id
    /// - Returns: 布局缓存；文件缺失或解码失败返回 nil（调用方据此重新分页）
    func loadLayout(for bookID: UUID) -> CachedLayout? { // 由 ReaderViewModel 初始化时调用，用于校验签名后复用分页结果
        guard let data = try? Data(contentsOf: AppPaths.layoutFile(bookID)) else { return nil } // 读取 layout.json，失败即返回 nil
        return try? JSONDecoder.ink.decode(CachedLayout.self, from: data) // 解码并返回，失败同样返回 nil
    } // 结束 loadLayout(for:)

    // MARK: - 私有
    // 私有区：书库读写实现、延迟落盘调度、封面索引计算，仅本类内部使用

    /// 从 library.json 载入书籍列表；文件缺失或损坏时置空
    private func loadLibrary() { // 仅在 init() 中调用
        guard let data = try? Data(contentsOf: AppPaths.libraryFile), // 读取书库索引文件
              let list = try? JSONDecoder.ink.decode([Book].self, from: data) else { // 解码书籍数组
            books = [] // 首次启动或文件损坏时使用空书库
            return // 结束载入
        } // 结束 guard 读取书库块
        books = list // 载入成功则覆盖内存列表
    } // 结束 loadLibrary()

    /// 延迟 0.4 秒合并落盘，避免翻页时高频写文件
    private func persistSoon() { // 由 markOpened / updateProgress 调用
        pendingPersist?.cancel() // 取消尚未执行的旧任务，只保留最后一次
        let item = DispatchWorkItem { [weak self] in self?.persist() } // 构造落盘工作项，弱引用避免循环持有
        pendingPersist = item // 保存引用以便下次取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item) // 主队列延迟 0.4 秒后执行
    } // 结束 persistSoon()

    /// 进入后台时立即落盘，避免阅读进度丢失
    func flush() { // 由 ReaderViewModel 在关闭书籍/收到进入后台通知时调用
        pendingPersist?.cancel() // 取消待执行的延迟任务，避免重复写入
        pendingPersist = nil // 清空任务引用
        guard let data = try? JSONEncoder.ink.encode(books) else { return } // 同步编码当前书库，失败则放弃
        try? data.write(to: AppPaths.libraryFile, options: .atomic) // 同步原子写入 library.json，确保后台前落盘
    } // 结束 flush()

    /// 异步持久化书库列表（内部调用，不做防抖）
    private func persist() { // 由 add / delete / persistSoon 调用
        let snapshot = books // 值类型快照，避免后台线程读取时与主线程写入竞争
        DispatchQueue.global(qos: .utility).async { // 后台低优先级队列执行 I/O
            guard let data = try? JSONEncoder.ink.encode(snapshot) else { return } // 编码快照，失败则放弃
            try? data.write(to: AppPaths.libraryFile, options: .atomic) // 原子写入 library.json
        } // 结束 后台写书库闭包
    } // 结束 persist()

    /// 依据书名计算封面配色索引
    /// - Parameter title: 书名
    /// - Returns: 0...7 之间的稳定索引，供书架挑选封面样式
    private static func coverIndex(for title: String) -> Int { // 纯函数，不产生副作用
        let sum = title.unicodeScalars.reduce(0) { $0 + Int($1.value) } // 累加书名各 Unicode 标量值
        return abs(sum) % 8 // 取模映射到 8 套封面配色
    } // 结束 coverIndex(for:)

    // MARK: - 内置示例书
    // 示例书区：导入沙盒 Documents 中的外部书籍与 App Bundle 内置示例书，仅在启动阶段调用

    /// 支持通过「文件」App 或 iTunes 文件共享把书放入 Documents，启动时自动导入
    private func importDroppedDocuments() { // 由 init() 调用
        let manager = FileManager.default // 取得文件管理器单例
        guard let docs = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return } // 定位沙盒 Documents 目录
        let files = (try? manager.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [] // 列出目录内文件，失败则用空数组
        for url in files where BookImporter.supportedExtensions.contains(url.pathExtension.lowercased()) { // 仅处理导入器支持的扩展名（忽略大小写）
            guard let draft = try? BookImporter.load(url: url) else { continue } // 解析为书稿，失败则跳过该文件
            if (try? add(draft)) != nil { // 成功入库存
                try? manager.removeItem(at: url) // 删除原始文件，防止下次启动重复导入
            } // 结束 导入成功处理块
        } // 结束 遍历 Documents 文件循环
    } // 结束 importDroppedDocuments()

    /// 按版本标记决定是否补种示例书：仅当当前 seedKey 版本尚未处理过时执行一次增量补种。
    /// 采用「按 sourceFileName 去重」而非「书库为空」作为条件，使得：
    ///   · 全新安装：种入全部示例书
    ///   · 老版本升级：只补种清单中缺失的那些，不动已存在的书与用户自己的书
    ///   · 用户后续删除示例书：不会在升级后再次凭空出现（因版本已标记完成）
    private func seedSampleBooksIfNeeded() { // 由 init() 调用
        guard !UserDefaults.standard.bool(forKey: seedKey) else { return } // 当前版本已补种过则直接返回
        seedSampleBooks() // 执行增量补种（内部按来源文件名去重）
        UserDefaults.standard.set(true, forKey: seedKey) // 完成后置位，保证该版本只补种一次
    } // 结束 seedSampleBooksIfNeeded()

    /// 从 App Bundle 增量补种内置示例书：书库中已存在同名来源文件的跳过，避免重复入库
    private func seedSampleBooks() { // 由 seedSampleBooksIfNeeded() 调用
        let samples: [(name: String, ext: String, title: String, author: String)] = [ // 示例书清单：资源名、扩展名、展示书名、作者
            ("Sample_StarSea", "txt", "星海拾遗", "林知远"), // 中文示例：TXT 正文
            ("Sample_MountainWind", "txt", "山风信", "苏野"), // 中文示例：短书名 TXT，测试标题截断
            ("Sample_WhaleSong", "md", "鲸歌旧录", "沈屿白"), // 中文示例：Markdown（按 # 标题切章）
            ("Sample_OldTown", "rtf", "老城旧事", "陈墨"), // 中文示例：RTF 富文本
            ("Sample_RobotDream", "html", "Robot Dreams of Electric Shepherds", "Ada Vance"), // 英文示例：HTML（长书名，测试截断）
            ("Sample_Lantern", "epub", "The Lantern Keeper", "Arthur Vale"), // 英文示例：EPUB 电子书
            ("Sample_RainCity", "txt", "雨落姑苏", "顾长明"), // 中文示例：TXT 三章，较长书名
            ("Sample_Snow", "txt", "雪", "白露"), // 中文示例：极短书名，测试截断
            ("Sample_Clock", "md", "钟楼的第四声", "陆时"), // 中文示例：Markdown 四章
            ("Sample_Lighthouse", "html", "The Lighthouse at the Edge of Memory", "Eleanor Reed"), // 英文示例：HTML 三章，超长书名测试截断
            ("Sample_Archive", "txt", "The Missing Hour of the City Archive", "Julian Vance") // 英文示例：TXT 四章，超长书名
        ] // 结束 示例书清单数组：覆盖全部支持格式、中英文、长短书名，便于测试多本书、多样本书架样式
        for sample in samples { // 逐个处理示例资源
            let sourceName = "\(sample.name).\(sample.ext)" // 该示例资源的原始文件名，用作去重依据
            if books.contains(where: { $0.sourceFileName == sourceName }) { continue } // 书库已有同名来源书则跳过，防止升级/重装重复种入
            guard let url = Bundle.main.url(forResource: sample.name, withExtension: sample.ext) else { continue } // 在 Bundle 中定位资源，缺失则跳过
            guard var draft = try? BookImporter.load(url: url) else { continue } // 解析为书稿，失败则跳过
            if draft.chapters.isEmpty { continue } // 章节为空的残缺资源不导入
            draft.title = sample.title // 覆写展示书名（避免取到文件名或残缺标题）
            draft.author = sample.author // 覆写作者
            _ = try? add(draft) // 静默入库，失败不影响应用启动
        } // 结束 遍历示例书循环
    } // 结束 seedSampleBooks()
} // 结束 LibraryStore 类
