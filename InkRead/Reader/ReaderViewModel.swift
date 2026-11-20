//
//  ReaderViewModel.swift
//  墨读 InkRead —— 阅读核心状态机（章节懒加载 · 分页缓存 · 阅读进度 · 书签）
//
//  职责：
//    · 持有 Book / LibraryStore / BookmarkStore / ReaderSettingsStore，对外暴露 @Published 阅读状态
//    · 调度 CoreText 排版请求（后台串行 + token 与签名双重校验），维护三级分页缓存
//    · 生成当前页与相邻页的 PagerModel，供翻页容器渲染
//    · 处理翻页、跳转、书签、进度保存（0.5s 防抖 + flush）、屏幕亮度与首次提示
//  上层调用者：ReaderView（创建并观察 @Published 状态、调用 prepare(containerSize:)/endSession）、
//              PagerContainer/PagePagerView（读 pagerModel，经 delegate 回调 handleTurn(_:)/handleBoundaryReached(_:)）、
//              目录与书签面板（jumpToChapter(_:)/jumpToBookmark(_:)/jump(toProgress:)、toggleBookmark()）
//  下层依赖：LibraryStore（chapters/fullText/loadLayout/saveLayout/updateProgress/flush/releaseTextCache）、
//            BookmarkStore（contains/toggle）、ReaderSettingsStore（$settings 订阅）、
//            PaginationEngine（signature/attributedString/paginate/pageContent）、
//            Pod 层的 PageSlice/CachedLayout/CachedChapterLayout、Models/Book.swift 的 Book/Chapter/ReadingProgress、
//            Models/ReaderTheme.swift 的 ReaderSettings/ReaderTheme/ReaderTypography/PageTurnMode
//  关键流程：prepare(containerSize:) → 比对排版签名 → requestLayout 后台分页 → 主线程校验 token + 签名后回写切片
//            → rebuildPager() 产出 PagerModel → 翻页/跳转 → scheduleProgressSave() 防抖落盘
//

import Foundation // 基础类型与 NSString 等
import UIKit // UIApplication/UIScreen/UIDevice/CGSize 等 UI 相关类型
import Combine // 订阅 ReaderSettingsStore 的设置变更

/// 阅读器核心：章节懒加载 + 分页缓存 + 阅读进度 + 书签。
/// 以 ObservableObject 形式向 SwiftUI 发布阅读状态，所有 @Published 变更均驱动 ReaderView 重绘。
final class ReaderViewModel: ObservableObject { // 阅读核心状态机，由 ReaderView 创建并持有
    /// 当前阅读的书籍元数据（标题、章节索引、阅读进度）。
    let book: Book // 当前阅读的书籍元数据（标题、章节、进度）
    /// 书籍库：提供章节索引、全文、布局缓存与进度读写。
    let library: LibraryStore // 书籍库：章节索引、全文、布局缓存、进度存取
    /// 阅读设置仓库（主题 / 排版 / 翻页模式），变更经 $settings 推送。
    let settingsStore: ReaderSettingsStore // 阅读设置仓库（主题/排版/翻页模式）
    /// 书签仓库，按「书籍 ID + 章节下标 + 字符偏移」存取书签。
    let bookmarkStore: BookmarkStore // 书签仓库

    /// 章节列表，供目录与全书进度计算使用。
    @Published private(set) var chapters: [Chapter] = [] // 章节列表（来自 library.chapters(for:)）
    /// 当前章节下标（0 起）。
    @Published private(set) var chapterIndex = 0 // 当前章节下标
    /// 当前章节内的页下标（0 起）。
    @Published private(set) var pageIndex = 0 // 当前章节内的页下标
    /// 当前章节总页数，驱动页脚「第 x/y 页」。
    @Published private(set) var chapterPageCount = 0 // 当前章节总页数
    /// 翻页容器渲染所需的完整快照（当前页 + 相邻页 + 样式），每次内容变化整体替换。
    @Published private(set) var pagerModel = PagerModel( // 翻页容器渲染所需的完整快照
        revision: 0, current: nil, previous: nil, next: nil, // 初始版本号 0，三页均为空
        turnMode: .horizontal, insets: .zero, theme: .paper // 初始翻页模式/内边距/主题
    ) // 结束 PagerModel(...) 初始化
    /// 是否正在后台排版：为 true 时翻页与跳转被忽略。
    @Published private(set) var isPreparing = false // 是否正在后台排版（期间屏蔽翻页与跳转）
    /// 当前页是否已加书签，驱动书签按钮高亮。
    @Published private(set) var isBookmarked = false // 当前页是否已加书签
    /// 是否显示阅读器上下工具栏。
    @Published var showChrome = false // 是否显示阅读器上下工具栏
    /// 是否显示设置面板。
    @Published var showSettings = false // 是否显示设置面板
    /// 是否显示目录面板。
    @Published var showTOC = false // 是否显示目录
    /// 是否显示书签列表面板。
    @Published var showBookmarks = false // 是否显示书签列表
    /// 轻提示文案，nil 表示不显示。
    @Published var toast: String? // 轻提示文案，nil 表示不显示

    // 布局状态：以下字段只在内部维护，不对外发布
    /// 全书正文；所有章节偏移与分页切片都以它的 UTF-16 单元为基准。
    private let fullText: NSString // 全书正文（UTF-16 单元偏移以它为基准）
    /// 阅读区域尺寸（不含工具栏），由 prepare(containerSize:) 写入。
    private var containerSize: CGSize = .zero // 阅读区域尺寸（不含工具栏），排版宽度由此推导
    /// 排版签名：排版参数与区域尺寸的指纹，用于判断缓存是否可复用。
    private var signature = "" // 排版签名：排版参数 + 区域尺寸的指纹，用于判断是否需要重排
    /// 磁盘布局缓存（layout.json）的内存镜像，签名不匹配即视为失效。
    private var layoutCache: CachedLayout? // 落盘的章节布局缓存（layout.json 的内存镜像）
    /// 一级分页缓存：章节下标 → 页切片。
    private var sliceCache: [Int: [PageSlice]] = [:] // 一级缓存：章节下标 → 页切片
    /// 富文本缓存：章节下标 → 已排版富文本，供跨章取上下页内容。
    private var attributedCache: [Int: NSAttributedString] = [:] // 章节下标 → 已排版富文本（用于跨章取上下页内容）
    /// 当前章的页切片热缓存，避免高频翻页走字典查找。
    private var chapterSlices: [PageSlice] = [] // 当前章页切片（热路径，避免字典查找）
    /// 当前章富文本热缓存。
    private var chapterAttributed: NSAttributedString? // 当前章富文本（热路径缓存）
    /// 当前章纯文本，按 UTF-16 切片取书签摘要。
    private var chapterText: NSString = "" // 当前章纯文本（按 UTF-16 切片）
    /// 已加载切片的章节下标，-1 表示尚未加载。
    private var currentChapter = -1 // 已加载切片的章节下标，-1 表示尚未加载
    /// 排版令牌：每次请求自增，用于丢弃过期排版结果。
    private var layoutToken = 0 // 排版令牌：每次请求自增，用于丢弃过期排版结果

    // 设置与生命周期：订阅、防抖任务与临时屏幕状态
    /// 本 VM 持有的设置快照，与 settingsStore 保持同步。
    private var observedSettings: ReaderSettings // 本 VM 持有的设置快照（与 settingsStore 同步）
    /// Combine 订阅回收袋，随 VM 释放自动取消订阅。
    private var cancellables = Set<AnyCancellable>() // Combine 订阅回收袋
    /// 进度保存防抖任务（0.5s），连续翻页只落盘一次。
    private var progressWork: DispatchWorkItem? // 进度保存防抖任务（0.5s）
    /// 布局缓存落盘防抖任务（1.0s），合并连续写盘。
    private var cacheSaveWork: DispatchWorkItem? // 布局缓存落盘防抖任务（1.0s）
    /// 排版参数变更防抖任务（0.22s），拖动滑杆时只在停手后重排。
    private var typographyWork: DispatchWorkItem? // 排版参数变更防抖任务（0.22s）
    /// 提示令牌：连续弹提示时只有最新一次负责清除。
    private var toastToken = 0 // 提示令牌：连续弹提示时只让最后一次负责清除
    /// 是否已记录进入阅读器前的系统亮度。
    private var brightnessCaptured = false // 是否已记录系统原始亮度
    /// 进入阅读器前的系统亮度，退出时还原。
    private var originalBrightness: CGFloat = 0 // 进入阅读器前的系统亮度，退出时还原
    /// 首次操作提示是否已展示（持久化到 UserDefaults）。
    private var didShowHint = UserDefaults.standard.bool(forKey: "inkread.reader.hint.shown") // 首次操作提示是否已展示过

    /// 正文区顶部内边距。
    private let statusTopInset: CGFloat = 8 // 正文区顶部内边距
    /// 正文区底部内边距。
    private let statusBottomInset: CGFloat = 8 // 正文区底部内边距

    /// 初始化阅读器：注入依赖、恢复上次阅读位置与系统级阅读环境。
    /// - Parameters:
    ///   - book: 待阅读书籍
    ///   - library: 书籍库
    ///   - settingsStore: 阅读设置仓库
    ///   - bookmarkStore: 书签仓库
    /// - 副作用：标记打开、开启电量监听、锁定自动锁屏、应用亮度、建立设置订阅。
    init(book: Book, library: LibraryStore, settingsStore: ReaderSettingsStore, bookmarkStore: BookmarkStore) { // 唯一初始化入口
        self.book = book // 保存书籍引用
        self.library = library // 保存书籍库引用
        self.settingsStore = settingsStore // 保存设置仓库引用
        self.bookmarkStore = bookmarkStore // 保存书签仓库引用
        self.observedSettings = settingsStore.settings // 拷贝一份当前设置作为初始快照
        self.chapters = library.chapters(for: book.id) // 同步读取章节索引（未解析时为空数组）
        self.fullText = library.fullText(for: book.id) ?? "" // 取全书正文，缺失时退化为空串避免崩溃

        let initialChapter = min(max(book.progress.chapterIndex, 0), max(chapters.count - 1, 0)) // 把历史进度夹到合法区间
        chapterIndex = initialChapter // 恢复上次所在章节
        layoutCache = nil // 布局缓存延迟到 prepare 时按签名加载

        library.markOpened(book.id) // 记录书籍最近打开时间，用于书库排序
        UIDevice.current.isBatteryMonitoringEnabled = true // 开启电量监听，供阅读器状态栏显示
        UIApplication.shared.isIdleTimerDisabled = observedSettings.keepScreenOn // 按设置决定是否常亮
        applyBrightness() // 按设置应用屏幕亮度
        observeSettings() // 订阅后续设置变更
    } // 结束 init

    /// 退出阅读器时恢复全局 UI 状态。
    /// - 副作用：解除自动锁屏禁用、还原屏幕亮度（避免影响其他 App）。
    deinit { // 视图销毁时清理
        UIApplication.shared.isIdleTimerDisabled = false // 解除常亮，防止全局生效
        if brightnessCaptured { // 只有确实改过亮度才还原
            UIScreen.main.brightness = originalBrightness // 还原进入前的系统亮度
        } // 结束 if brightnessCaptured
    } // 结束 deinit

    // MARK: - 对外状态

    // 供 ReaderView/子视图直接读取的只读派生状态，避免它们直接接触 SettingsStore。

    /// 当前主题（配色）。
    var theme: ReaderTheme { observedSettings.theme } // 从设置快照取主题
    /// 当前排版参数（字号/行距/边距等）。
    var typography: ReaderTypography { observedSettings.typography } // 从设置快照取排版参数
    /// 当前翻页模式（左右/上下）。
    var turnMode: PageTurnMode { observedSettings.turnMode } // 从设置快照取翻页模式
    /// 完整设置快照，供设置面板回显。
    var settings: ReaderSettings { observedSettings } // 返回整体设置
    /// 书籍标题。
    var title: String { book.title } // 直接取书籍标题

    /// 当前章节标题；章节索引未就绪时回退为书名。
    var chapterTitle: String { // 顶部栏显示的章节名
        guard chapters.indices.contains(chapterIndex) else { return book.title } // 越界保护：回退书名
        return chapters[chapterIndex].title // 返回当前章节标题
    } // 结束 chapterTitle

    /// 底部状态文案：「第 x/y 页 · 全书 xx.x%」。
    var footerText: String { // 阅读器页脚
        let total = max(chapterPageCount, 1) // 总页数至少为 1，避免除零式展示
        let page = min(pageIndex + 1, total) // 展示用页码（从 1 开始）并夹到范围内
        return "第 \(page)/\(total) 页 · 全书 \(bookProgressPercentText)" // 拼接页码与全书进度
    } // 结束 footerText

    /// 全书阅读进度（0...1）：由「章节起点 + 页内起点」在全文中的 UTF-16 偏移换算。
    var bookProgress: Double { // 用于进度条
        guard chapters.indices.contains(chapterIndex), // 章节下标有效
              chapterSlices.indices.contains(pageIndex) else { return 0 } // 且当前页切片存在，否则记 0
        let offset = chapters[chapterIndex].start + chapterSlices[pageIndex].start // 当前页在全文中的绝对偏移
        let total = max(fullText.length, 1) // 全文长度，兜底 1 防除零
        return min(max(Double(offset) / Double(total), 0), 1) // 归一化并夹到 0...1
    } // 结束 bookProgress

    /// 全书进度的百分比文本，如 "12.3%"。
    var bookProgressPercentText: String { // 供页脚与进度条复用
        String(format: "%.1f%%", bookProgress * 100) // 百分比保留一位小数
    } // 结束 bookProgressPercentText

    // MARK: - 准备与排版

    // 排版入口与尺寸推导：prepare 由 ReaderView 在几何尺寸确定后调用，再交给 requestLayout 后台计算。

    /// 准备排版：记录容器尺寸，比较排版签名，命中缓存则复用，否则发起后台分页。
    /// - Parameter containerSize: 阅读区域尺寸（由 ReaderView 的 GeometryReader 提供）
    /// - 副作用：更新 containerSize/signature，可能清理各级缓存并触发 requestLayout。
    func prepare(containerSize: CGSize) { // 视图出现或尺寸变化时调用
        guard containerSize.width > 80, containerSize.height > 80 else { return } // 尺寸无效（未完成布局）时忽略，避免算出错误分页
        self.containerSize = containerSize // 记录容器尺寸，供 textSize/textInsets 使用
        let newSignature = PaginationEngine.signature(typography: observedSettings.typography, textSize: textSize) // 计算新排版签名
        guard newSignature != signature else { return } // 签名一致说明排版无需重做，直接复用现有缓存

        let anchor = currentCharOffset() // 记录当前阅读位置的字符偏移，重排后据此回到原位置
        signature = newSignature // 生效新签名（后续异步结果都用它校验）
        if layoutCache?.signature != newSignature { // 磁盘缓存签名与当前不一致，说明缓存作废
            sliceCache.removeAll() // 清空一级分页缓存
            attributedCache.removeAll() // 清空富文本缓存
            chapterSlices = [] // 清空当前章热缓存
            layoutCache = library.loadLayout(for: book.id) // 重新从 layout.json 加载缓存镜像
            if layoutCache?.signature != newSignature { // 磁盘缓存同样不匹配
                layoutCache = CachedLayout(signature: newSignature, chapters: []) // 新建空缓存容器，等待排版回填
            } // 结束磁盘签名校验
        } // 结束内存缓存签名校验
        requestLayout(chapter: chapterIndex, anchorOffset: anchor, targetPage: nil) // 触发后台排版，按字符偏移定位页
    } // 结束 prepare(containerSize:)

    /// 章节排版 + 绘制所需尺寸
    var textSize: CGSize { // 正文可分页区域尺寸（扣除左右边距与上下内边距）
        CGSize( // 构造排版尺寸
            width: max(40, containerSize.width - CGFloat(observedSettings.typography.horizontalMargin) * 2), // 宽度扣掉左右边距，最少 40
            height: max(40, containerSize.height - statusTopInset - statusBottomInset) // 高度扣掉上下内边距，最少 40
        ) // 结束 CGSize(...)
    } // 结束 textSize

    /// 正文相对容器四周的内边距，与 textSize 的计算保持同一套边距参数。
    var textInsets: UIEdgeInsets { // 传给 PagerModel 作为排版内边距
        UIEdgeInsets( // 构造内边距
            top: statusTopInset, // 上内边距
            left: CGFloat(observedSettings.typography.horizontalMargin), // 左边距
            bottom: statusBottomInset, // 下内边距
            right: CGFloat(observedSettings.typography.horizontalMargin) // 右边距
        ) // 结束 UIEdgeInsets(...)
    } // 结束 textInsets

    /// 后台串行排版指定章节并把结果回写主线程状态。
    /// - Parameters:
    ///   - chapter: 目标章节下标
    ///   - anchorOffset: 章节内的字符偏移，用于排版完成后定位到包含它的页
    ///   - targetPage: 指定页下标（跳章时用），为 nil 时按 anchorOffset 推算
    /// - 副作用：翻转 isPreparing/isBusy，更新章节切片、页码、PagerModel、书签态与进度。
    /// - 并发说明：后台线程只做纯计算，所有状态写回都在主线程完成，
    ///   并用 token（同一时刻只有最新一次请求生效）与签名（排版参数未被改动）双重校验，丢弃过期结果。
    private func requestLayout(chapter: Int, anchorOffset: Int, targetPage: Int?) { // prepare/jump 系列的统一排版入口
        guard chapters.indices.contains(chapter), containerSize.width > 80 else { // 章节越界或容器未就绪
            isPreparing = false // 复位准备态，避免 UI 永久转圈
            return // 直接返回
        } // 结束入参校验
        layoutToken += 1 // 递增令牌：之前发出的排版结果全部作废
        let token = layoutToken // 捕获本次令牌，供回调比对
        let text = chapterText(at: chapter) // 取出章节纯文本
        let typography = observedSettings.typography // 捕获排版参数快照，避免后台期间被改
        let theme = observedSettings.theme // 捕获主题快照
        let size = textSize // 捕获排版尺寸快照
        let sig = signature // 捕获签名快照，用于回写校验
        let cachedSlices = cachedSlices(for: chapter) // 先查缓存（内存 → layout.json），命中可跳过分页
        isPreparing = true // 标记正在准备，屏蔽翻页/跳转
        setBusy(true) // 让翻页容器进入忙碌态（显示加载）

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in // 后台高优先级队列执行耗时的 CoreText 排版
            let attributed = PaginationEngine.attributedString(text: text, typography: typography, theme: theme) // 生成富文本（属性字典较慢，放到后台）
            let slices = cachedSlices ?? PaginationEngine.paginate(attributed: attributed, size: size) // 缓存命中直接用，否则真正分页
            DispatchQueue.main.async { // 回到主线程写状态（@Published 必须在主线程）
                guard let self, token == self.layoutToken, sig == self.signature else { return } // 双重校验：令牌过期或排版参数已变则丢弃结果
                self.chapterIndex = chapter // 生效章节下标
                self.currentChapter = chapter // 标记已加载章节，供切片快路径判断
                self.chapterText = text as NSString // 缓存当前章纯文本
                self.chapterAttributed = attributed // 缓存当前章富文本
                self.chapterSlices = slices // 缓存当前章页切片
                self.chapterPageCount = slices.count // 更新总页数（驱动页脚显示）
                self.attributedCache[chapter] = attributed // 写入富文本缓存，供跨章取页内容
                self.sliceCache[chapter] = slices // 写入一级分页缓存
                self.recordLayout(chapter: chapter, slices: slices) // 写入布局缓存并防抖落盘

                if let targetPage { // 跳转场景：直接使用指定页
                    self.pageIndex = min(max(targetPage, 0), max(slices.count - 1, 0)) // 页码范围夹取
                } else { // 普通场景：按字符偏移定位
                    self.pageIndex = self.pageIndex(containing: anchorOffset, in: slices) // 找到包含该偏移的页
                } // 结束页码定位分支
                self.isPreparing = false // 解除准备态，恢复可交互
                self.rebuildPager() // 重建当前页与相邻页快照
                self.updateBookmarkState() // 刷新当前页书签状态
                self.scheduleProgressSave() // 防抖保存阅读进度
                self.prefetchNeighbors() // 预取相邻章节，保证跨章翻页不闪烁
                if !self.didShowHint { // 首次进入阅读器只提示一次
                    self.didShowHint = true // 内存标记，避免重复提示
                    UserDefaults.standard.set(true, forKey: "inkread.reader.hint.shown") // 持久化标记，下次启动不再提示
                    self.flashToast("轻点中间呼出菜单 · 左右/上下点击或按住拖动翻页") // 弹出操作引导
                } // 结束首次提示
            } // 结束主线程回写闭包
        } // 结束后台排版闭包
    } // 结束 requestLayout(chapter:anchorOffset:targetPage:)

    /// 查一级缓存（内存 sliceCache → 磁盘 layoutCache）。
    /// - Parameter chapter: 章节下标
    /// - Returns: 命中则返回页切片，未命中返回 nil（调用方需真正分页）
    private func cachedSlices(for chapter: Int) -> [PageSlice]? { // 三级缓存中的前两级查询
        if let cached = sliceCache[chapter] { return cached } // 一级：内存缓存直接命中
        if layoutCache?.signature == signature, let slices = layoutCache?.slices(for: chapter) { // 二级：磁盘缓存且签名一致才可用
            return slices // 返回磁盘缓存中的切片（不写回内存，交由调用方决定）
        } // 结束磁盘缓存判断
        return nil // 两级均未命中
    } // 结束 cachedSlices(for:)

    /// 切换 PagerModel 的忙碌标记，仅在值真正变化时才递增 revision（避免无效重绘）。
    /// - Parameter busy: 是否忙碌
    private func setBusy(_ busy: Bool) { // 供翻页容器显示加载态
        guard pagerModel.isBusy != busy else { return } // 状态未变则跳过
        pagerModel.isBusy = busy // 更新忙碌标记
        pagerModel.revision += 1 // 提升版本号，通知容器刷新
    } // 结束 setBusy(_:)

    /// 把某章分页结果写入布局缓存，并以 1s 防抖异步落盘。
    /// - Parameters:
    ///   - chapter: 章节下标
    ///   - slices: 该章的页切片
    /// - 副作用：可能替换 layoutCache，并调度 library.saveLayout。
    private func recordLayout(chapter: Int, slices: [PageSlice]) { // 缓存写入的唯一入口
        guard var cache = layoutCache, cache.signature == signature else { return } // 无缓存或签名已过期则不记录（防止污染新签名的缓存）
        cache.chapters.removeAll { $0.index == chapter } // 先移除该章旧记录，保证一章一条
        cache.chapters.append(CachedChapterLayout(index: chapter, slices: slices)) // 追加新记录
        layoutCache = cache // 写回内存镜像
        cacheSaveWork?.cancel() // 取消上一次待执行的落盘，合并连续写入
        let snapshot = cache // 捕获快照，避免闭包执行时读到后续变更
        let bookID = book.id // 捕获书籍 ID，避免持有 self
        let work = DispatchWorkItem { [weak self] in // 构造落盘任务，弱引用避免泄漏
            self?.library.saveLayout(snapshot, for: bookID) // 写入 layout.json
        } // 结束 DispatchWorkItem 构造
        cacheSaveWork = work // 记录当前任务，供下次取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work) // 1s 防抖后执行，减少频繁 IO
    } // 结束 recordLayout(chapter:slices:)

    /// 预取上下相邻章节的分页结果，写入一级缓存。
    /// - 副作用：后台 low 优先级队列计算，主线程校验签名与令牌后回填。
    /// - 目的：跨章翻页时可直接命中缓存，走 loadChapterDirect 同步切章，避免白屏闪烁。
    private func prefetchNeighbors() { // 排版完成后调用
        for chapter in [chapterIndex - 1, chapterIndex + 1] where chapters.indices.contains(chapter) { // 仅处理存在的相邻章
            guard cachedSlices(for: chapter) == nil else { continue } // 已有缓存则跳过，避免重复计算
            let text = chapterText(at: chapter) // 取该章文本
            let typography = observedSettings.typography // 捕获排版参数
            let size = textSize // 捕获排版尺寸
            let sig = signature // 捕获签名，用于回写校验
            let token = layoutToken // 捕获当前令牌，用于丢弃过期预取
            DispatchQueue.global(qos: .utility).async { [weak self] in // 低优先级后台队列，不抢占主排版
                let attributed = PaginationEngine.attributedString(text: text, typography: typography, theme: .paper) // 预取只需分页，主题用固定值省开销
                let slices = PaginationEngine.paginate(attributed: attributed, size: size) // 执行分页
                DispatchQueue.main.async { // 回主线程写入缓存（字典非线程安全）
                    guard let self, sig == self.signature, token == self.layoutToken else { return } // 签名或令牌变化说明已过期，丢弃
                    if self.sliceCache[chapter] == nil { // 二次确认缓存仍为空（可能已被主流程写入）
                        self.sliceCache[chapter] = slices // 写入一级缓存
                        self.recordLayout(chapter: chapter, slices: slices) // 同步写入布局缓存，纳管落盘
                    } // 结束写入判断
                } // 结束主线程回写闭包
            } // 结束后台预取闭包
        } // 结束相邻章遍历
    } // 结束 prefetchNeighbors()

    // MARK: - 页面构建

    // PagerModel 构建：把「当前章切片 + 相邻页/相邻章」组装成容器可渲染的三页快照。

    /// 依据当前页下标重建 PagerModel（当前页 + 上一页 + 下一页），并递增版本号触发容器刷新。
    /// - 副作用：替换 pagerModel（@Published，触发 ReaderView 重绘）。
    private func rebuildPager() { // 页码变化后必须调用
        guard chapterSlices.indices.contains(pageIndex) else { return } // 当前页无效则保持原样
        let page = makePage(chapter: chapterIndex, page: pageIndex) // 当前页内容
        var previous: PagerPage? // 上一页（可能为空）
        var next: PagerPage? // 下一页（可能为空）

        if pageIndex > 0 { // 章内还有上一页
            previous = makePage(chapter: chapterIndex, page: pageIndex - 1) // 取同章前一页
        } else if chapterIndex > 0 { // 本章首页，尝试跨到上一章末页
            let slices = slices(for: chapterIndex - 1) // 取上一章切片（可能触发同步补算/读缓存）
            if !slices.isEmpty { // 上一章切片有效
                previous = makePage(chapter: chapterIndex - 1, page: slices.count - 1) // 取上一章最后一页
            } // 结束上一章切片判断
        } // 结束上一页构建

        if pageIndex + 1 < chapterSlices.count { // 章内还有下一页
            next = makePage(chapter: chapterIndex, page: pageIndex + 1) // 取同章后一页
        } else if chapterIndex + 1 < chapters.count { // 本章末页，尝试跨到下一章首页
            let slices = slices(for: chapterIndex + 1) // 取下一章切片
            if !slices.isEmpty { // 下一章切片有效
                next = makePage(chapter: chapterIndex + 1, page: 0) // 取下一章第一页
            } // 结束下一章切片判断
        } // 结束下一页构建

        let revision = pagerModel.revision + 1 // 版本号自增，通知容器本次内容已更新
        pagerModel = PagerModel( // 整体替换快照（值类型，便于容器做 diff）
            revision: revision, // 新版本号
            current: page, // 当前页
            previous: previous, // 上一页
            next: next, // 下一页
            turnMode: observedSettings.turnMode, // 翻页模式
            insets: textInsets, // 正文内边距
            theme: observedSettings.theme // 配色主题
        ) // 结束 PagerModel(...)
    } // 结束 rebuildPager()

    /// 构造单页渲染数据。
    /// - Parameters:
    ///   - chapter: 章节下标
    ///   - page: 章内页下标
    /// - Returns: 页快照；下标越界时返回 nil
    /// - 副作用：可能触发该章的富文本/分页缓存加载。
    private func makePage(chapter: Int, page: Int) -> PagerPage? { // 单页组装
        let slices = slices(for: chapter) // 取该章切片（三级缓存）
        guard slices.indices.contains(page) else { return nil } // 页码越界则无内容
        let text = chapterText(at: chapter) as NSString // 取该章纯文本（无需缓存，切页时开销可接受）
        let attributed = attributedString(for: chapter, text: text) // 取该章富文本（带缓存）
        let slice = slices[page] // 当前页切片
        let content = PaginationEngine.pageContent( // 由切片裁剪出实际要绘制的富文本
            chapterAttributed: attributed, // 整章富文本
            chapterText: text, // 整章纯文本（用于 CTFramesetter 定位）
            slice: slice, // 该页的字符范围
            typography: observedSettings.typography // 排版参数（字距/行距等）
        ) // 结束 pageContent(...)
        return PagerPage(key: "\(chapter)-\(slice.start)", text: content) // key 用「章-起始偏移」唯一标识一页，便于容器复用
    } // 结束 makePage(chapter:page:)

    /// 取章节富文本，带两级缓存（当前章热缓存 → 字典缓存），必要时现场生成。
    /// - Parameters:
    ///   - chapter: 章节下标
    ///   - text: 该章纯文本
    /// - Returns: 已应用排版参数的富文本
    private func attributedString(for chapter: Int, text: NSString) -> NSAttributedString { // 富文本缓存策略
        if chapter == currentChapter, let chapterAttributed { return chapterAttributed } // 当前章直接命中热缓存
        if let cached = attributedCache[chapter] { return cached } // 其余章命中字典缓存
        let attributed = PaginationEngine.attributedString( // 未命中则现场生成
            text: text as String, // 转成 String 交给排版引擎
            typography: observedSettings.typography, // 排版参数
            theme: observedSettings.theme // 当前主题
        ) // 结束 attributedString(...)
        if attributedCache.count > 3 { attributedCache.removeAll() } // 简易容量上限：超过 3 章整体清空，防止内存膨胀
        attributedCache[chapter] = attributed // 写入字典缓存
        if chapter == currentChapter { chapterAttributed = attributed } // 当前章额外写入热缓存
        return attributed // 返回结果
    } // 结束 attributedString(for:text:)

    /// 取章节页切片，三级缓存策略：当前章热缓存 → 内存/磁盘缓存 → 同步现场分页。
    /// - Parameter chapter: 章节下标
    /// - Returns: 页切片；章节非法或容器未就绪时返回空数组
    /// - 说明：同步分页会阻塞主线程，只在极端情况（缓存缺失）发生，正常路径由预取覆盖。
    private func slices(for chapter: Int) -> [PageSlice] { // 切片获取的统一入口
        if chapter == currentChapter, !chapterSlices.isEmpty { return chapterSlices } // 一级：当前章热缓存
        if let cached = cachedSlices(for: chapter) { // 二级：内存缓存 / layout.json
            sliceCache[chapter] = cached // 顺带写回内存缓存，下次直接命中
            return cached // 返回缓存切片
        } // 结束二级缓存判断
        guard chapters.indices.contains(chapter), containerSize.width > 80 else { return [] } // 三级兜底前的合法性校验
        let text = chapterText(at: chapter) // 取章节文本
        let attributed = PaginationEngine.attributedString( // 现场生成富文本
            text: text, // 章节纯文本
            typography: observedSettings.typography, // 排版参数
            theme: observedSettings.theme // 当前主题
        ) // 结束 attributedString(...)
        let result = PaginationEngine.paginate(attributed: attributed, size: textSize) // 同步分页（可能阻塞主线程）
        sliceCache[chapter] = result // 结果写入一级缓存
        recordLayout(chapter: chapter, slices: result) // 写入布局缓存，纳管落盘
        return result // 返回切片
    } // 结束 slices(for:)

    /// 按章节索引从全文裁出章节文本。
    /// - Parameter index: 章节下标
    /// - Returns: 章节纯文本；下标越界返回空串
    private func chapterText(at index: Int) -> String { // 章节文本按需裁剪，避免为每章常驻字符串
        guard chapters.indices.contains(index) else { return "" } // 越界保护
        let chapter = chapters[index] // 取章节元数据
        let start = min(max(chapter.start, 0), fullText.length) // 起点夹取到全文范围
        let length = min(max(chapter.length, 0), fullText.length - start) // 长度夹取，防止越界崩溃
        return fullText.substring(with: NSRange(location: start, length: length)) // 按 UTF-16 偏移截取
    } // 结束 chapterText(at:)

    /// 在页切片数组中找到包含指定字符偏移的页下标。
    /// - Parameters:
    ///   - offset: 章节内字符偏移
    ///   - slices: 该章页切片（按起点升序）
    /// - Returns: 页下标；无切片时返回 0
    private func pageIndex(containing offset: Int, in slices: [PageSlice]) -> Int { // 重排后恢复阅读位置
        guard !slices.isEmpty else { return 0 } // 空切片兜底
        var result = 0 // 默认第一页
        for (idx, slice) in slices.enumerated() { // 顺序扫描
            if slice.start <= offset { result = idx } else { break } // 最后一个起点不大于偏移的页即为目标页（切片有序，可提前结束）
        } // 结束遍历
        return result // 返回页下标
    } // 结束 pageIndex(containing:in:)

    /// 当前阅读位置的字符偏移：优先用当前页切片起点，否则回退到已保存进度。
    private func currentCharOffset() -> Int { // 重排/切章时用于锚定位置
        if chapterSlices.indices.contains(pageIndex) { // 已有有效切片
            return chapterSlices[pageIndex].start // 用当前页起点
        } // 结束切片判断
        return book.progress.charOffset // 无切片时用持久化进度
    } // 结束 currentCharOffset()

    // MARK: - 翻页

    // 翻页入口与章节切换：同章内翻页只改 pageIndex，跨章走同步切章以避免闪烁。

    /// 翻页统一入口，由翻页手势/点击触发。
    /// - Parameter direction: 翻页方向
    /// - 副作用：排版进行中直接忽略，防止状态错乱。
    func handleTurn(_ direction: PageTurnDirection) { // PagerContainer 的 delegate 回调入口
        guard !isPreparing else { return } // 排版中禁止翻页
        switch direction { // 按方向分发
        case .next: advance() // 向后翻
        case .previous: retreat() // 向前翻
        } // 结束 switch
    } // 结束 handleTurn(_:)

    /// 向后翻一页；已在全书末尾则不动。
    /// - 副作用：更新 pageIndex、PagerModel、书签态与进度；跨章时走同步切章。
    private func advance() { // 下一页
        if pageIndex + 1 < chapterSlices.count { // 本章还有下一页
            pageIndex += 1 // 页下标前进
            rebuildPager() // 重建三页快照
            updateBookmarkState() // 刷新书签状态
            scheduleProgressSave() // 防抖保存进度
        } else if chapterIndex + 1 < chapters.count { // 本章末页且存在下一章
            loadChapterDirect(chapter: chapterIndex + 1, page: 0) // 同步切到下一章首页
        } // 结束翻页分支
    } // 结束 advance()

    /// 向前翻一页；已在全书开头则不动。
    /// - 副作用：与 advance() 对称。
    private func retreat() { // 上一页
        if pageIndex > 0 { // 本章还有上一页
            pageIndex -= 1 // 页下标后退
            rebuildPager() // 重建三页快照
            updateBookmarkState() // 刷新书签状态
            scheduleProgressSave() // 防抖保存进度
        } else if chapterIndex > 0 { // 本章首页且存在上一章
            let target = chapterIndex - 1 // 目标章
            let slices = slices(for: target) // 取上一章切片（预取命中则零成本）
            loadChapterDirect(chapter: target, page: max(0, slices.count - 1)) // 定位到上一章最后一页
        } // 结束翻页分支
    } // 结束 retreat()

    /// 章节切换走同步路径：相邻章分页已预取，保证翻页动画结束后无闪烁
    private func loadChapterDirect(chapter: Int, page: Int) { // 同步切章
        guard chapters.indices.contains(chapter) else { return } // 章节越界保护
        let text = chapterText(at: chapter) // 取目标章文本
        let attributed = PaginationEngine.attributedString( // 生成富文本（预取只存了切片，这里需现算富文本）
            text: text, // 章节纯文本
            typography: observedSettings.typography, // 排版参数
            theme: observedSettings.theme // 当前主题
        ) // 结束 attributedString(...)
        let slices = slices(for: chapter) // 取目标章切片（命中预取缓存）
        guard !slices.isEmpty else { return } // 无切片则放弃切换，避免进入空章

        chapterIndex = chapter // 生效章节下标
        currentChapter = chapter // 标记已加载章节
        chapterText = text as NSString // 缓存目标章纯文本
        chapterAttributed = attributed // 缓存目标章富文本
        attributedCache[chapter] = attributed // 写入富文本字典缓存
        chapterSlices = slices // 缓存目标章切片
        chapterPageCount = slices.count // 更新总页数
        pageIndex = min(max(page, 0), slices.count - 1) // 页码夹取到合法范围
        isPreparing = false // 清空准备态（同步路径无需等待）
        rebuildPager() // 重建三页快照
        updateBookmarkState() // 刷新书签状态
        scheduleProgressSave() // 防抖保存进度
        prefetchNeighbors() // 继续预取新的相邻章，保持缓存链路
    } // 结束 loadChapterDirect(chapter:page:)

    /// 跳转到指定章节首页（目录点击）。
    /// - Parameter index: 目标章节下标
    /// - 副作用：触发后台排版（targetPage 固定为 0），并关闭目录面板。
    func jumpToChapter(_ index: Int) { // 目录跳转
        guard chapters.indices.contains(index), !isPreparing else { return } // 下标合法且不在排版中
        requestLayout(chapter: index, anchorOffset: 0, targetPage: 0) // 后台排版并落到首页
        showTOC = false // 关闭目录
    } // 结束 jumpToChapter(_:)

    /// 跳转到某条书签位置（书签列表点击）。
    /// - Parameter bookmark: 目标书签（含章节下标与字符偏移）
    /// - 副作用：触发后台排版，并按偏移定位页；关闭书签面板。
    func jumpToBookmark(_ bookmark: Bookmark) { // 书签跳转
        guard !isPreparing else { return } // 排版中禁止跳转
        requestLayout(chapter: bookmark.chapterIndex, anchorOffset: bookmark.charOffset, targetPage: nil) // 按书签偏移定位页
        showBookmarks = false // 关闭书签面板
    } // 结束 jumpToBookmark(_:)

    /// 按全书进度比例跳转（进度条拖动）。
    /// - Parameter percent: 0...1 的进度比例
    /// - 副作用：触发后台排版，并按章节内偏移定位页。
    func jump(toProgress percent: Double) { // 进度条跳转
        guard !isPreparing, !chapters.isEmpty else { return } // 排版中或章节未加载则不处理
        let target = Int(Double(fullText.length) * min(max(percent, 0), 1)) // 比例换算为全文 UTF-16 偏移
        var chapter = 0 // 目标章节，默认第 0 章
        for (idx, item) in chapters.enumerated() { // 顺序扫描章节起点
            if item.start <= target { chapter = idx } else { break } // 最后一个起点不大于目标的章节即为目标章
        } // 结束遍历
        let offset = max(0, target - chapters[chapter].start) // 换算为章节内偏移
        requestLayout(chapter: chapter, anchorOffset: offset, targetPage: nil) // 后台排版并定位
    } // 结束 jump(toProgress:)

    // MARK: - 书签

    // 书签增删与状态同步：以「章下标 + 页起始偏移」作为唯一键。

    /// 切换当前页书签：已存在则移除，否则添加，并弹出提示。
    /// - 副作用：写入 BookmarkStore、刷新 isBookmarked、弹出 toast。
    func toggleBookmark() { // 书签按钮回调
        guard chapterSlices.indices.contains(pageIndex) else { return } // 当前页无效则不处理
        let slice = chapterSlices[pageIndex] // 当前页切片
        let wasBookmarked = bookmarkStore.contains( // 记录操作前状态，用于提示文案
            bookID: book.id, // 书籍 ID
            chapterIndex: chapterIndex, // 章节下标
            charOffset: slice.start // 页起始偏移（书签键）
        ) // 结束 contains(...)
        let snippet = bookmarkSnippet() // 生成书签摘要（前若干字符）
        bookmarkStore.toggle( // 执行添加/移除
            bookID: book.id, // 书籍 ID
            chapterIndex: chapterIndex, // 章节下标
            chapterTitle: chapterTitle, // 章节标题
            charOffset: slice.start, // 页起始偏移
            snippet: snippet // 摘要文本
        ) // 结束 toggle(...)
        updateBookmarkState() // 同步按钮状态
        flashToast(wasBookmarked ? "已移除书签" : "已添加书签") // 提示操作结果
    } // 结束 toggleBookmark()

    /// 重新计算当前页是否已加书签。
    /// - 副作用：更新 @Published isBookmarked。
    func updateBookmarkState() { // 翻页/切章/增删书签后调用
        guard chapterSlices.indices.contains(pageIndex) else { // 当前页无效
            isBookmarked = false // 视为未收藏
            return // 提前返回
        } // 结束有效性判断
        isBookmarked = bookmarkStore.contains( // 查询书签仓库
            bookID: book.id, // 书籍 ID
            chapterIndex: chapterIndex, // 章节下标
            charOffset: chapterSlices[pageIndex].start // 页起始偏移
        ) // 结束 contains(...)
    } // 结束 updateBookmarkState()

    /// 生成书签摘要：取当前页前 42 个字符，换行替换为空格并去除首尾空白。
    /// - Returns: 摘要文本；页面无效返回空串，内容为空时回退章节标题。
    private func bookmarkSnippet() -> String { // 书签列表展示用摘要
        guard chapterSlices.indices.contains(pageIndex) else { return "" } // 当前页无效
        let slice = chapterSlices[pageIndex] // 当前页切片
        let available = max(0, min(slice.length, chapterText.length - slice.start)) // 可用字符数（防止越过章末）
        let length = min(available, 42) // 最多取 42 个字符
        guard length > 0 else { return chapterTitle } // 取不到内容时回退章节标题
        let raw = chapterText.substring(with: NSRange(location: slice.start, length: length)) // 截取原始文本
        return raw // 对原始文本做清洗
            .replacingOccurrences(of: "\n", with: " ") // 换行替换为空格，避免列表错位
            .trimmingCharacters(in: .whitespacesAndNewlines) // 去掉首尾空白
    } // 结束 bookmarkSnippet()

    // MARK: - 进度保存

    // 进度持久化：翻页高频，采用 0.5s 防抖合并写；退出时立即 flush。

    /// 防抖保存进度：取消上一次任务，0.5s 后若无新翻页再真正落盘。
    /// - 副作用：重新设置 progressWork 并调度主队列延时任务。
    func scheduleProgressSave() { // 每次翻页/切章调用
        progressWork?.cancel() // 取消尚未执行的保存，合并连续翻页
        let work = DispatchWorkItem { [weak self] in self?.saveProgress() } // 构造保存任务
        progressWork = work // 记录当前任务，供下次取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work) // 0.5s 防抖
    } // 结束 scheduleProgressSave()

    /// 立即把当前阅读位置写入 LibraryStore（内存），并计算全书百分比。
    /// - 副作用：更新书籍进度。
    func saveProgress() { // 防抖任务与 endSession 共用
        guard chapters.indices.contains(chapterIndex), // 章节下标有效
              chapterSlices.indices.contains(pageIndex) else { return } // 且当前页切片存在
        let slice = chapterSlices[pageIndex] // 当前页切片
        let percent = min(max(Double(chapters[chapterIndex].start + slice.start) / Double(max(fullText.length, 1)), 0), 1) // 全书百分比并夹取 0...1
        library.updateProgress( // 写入进度
            bookID: book.id, // 书籍 ID
            progress: ReadingProgress(chapterIndex: chapterIndex, charOffset: slice.start, percent: percent) // 章下标 + 页内偏移 + 百分比
        ) // 结束 updateProgress(...)
    } // 结束 saveProgress()

    /// 结束本次阅读会话：立即保存并 flush，还原屏幕状态，释放缓存。
    /// - 副作用：取消防抖任务、落盘、恢复锁屏与亮度、释放全书文本缓存、令在途排版结果失效。
    func endSession() { // ReaderView 消失时调用
        progressWork?.cancel() // 取消未执行的防抖保存
        saveProgress() // 立即保存最终进度
        library.flush() // 立即落盘（flush 保证不丢）
        UIApplication.shared.isIdleTimerDisabled = false // 恢复系统自动锁屏
        restoreBrightness() // 还原进入前的屏幕亮度
        library.releaseTextCache() // 释放全书文本缓存，回收内存
        layoutToken += 1 // 递增令牌，使退出后到达的排版结果全部作废
    } // 结束 endSession()

    // MARK: - 设置

    // 设置订阅与应用：订阅 SettingsStore 的变化，按变更维度选择「只重绘 / 延迟重排」。

    /// 订阅设置变更：跳过当前值（dropFirst），在主线程回调 apply(_:)。
    /// - 副作用：把订阅存入 cancellables，随 VM 释放自动取消。
    private func observeSettings() { // init 中调用一次
        settingsStore.$settings // @Published 设置发布者
            .dropFirst() // 丢弃初始值，避免 init 阶段重复应用
            .receive(on: RunLoop.main) // 保证在主线程处理 UI 相关副作用
            .sink { [weak self] newSettings in // 订阅闭包
                self?.apply(newSettings) // 应用新设置
            } // 结束 sink 闭包
            .store(in: &cancellables) // 保存订阅，防止被立即释放
    } // 结束 observeSettings()

    /// 应用新设置：按变更维度分别处理。
    /// - Parameter newSettings: 新的设置快照
    /// - 副作用：调整亮度/常亮；排版参数变更走 0.22s 防抖重排（拖动滑杆时避免频繁重排）；
    ///   主题变更只清富文本缓存并重绘；翻页模式变更只重绘。
    private func apply(_ newSettings: ReaderSettings) { // 设置变更的统一处理点
        let old = observedSettings // 记录旧值用于差异比较
        observedSettings = newSettings // 先更新快照，后续计算使用新值

        if old.followSystemBrightness != newSettings.followSystemBrightness || // 跟随系统亮度开关变化
            old.brightness != newSettings.brightness { // 或自定义亮度值变化
            applyBrightness() // 重新应用亮度
        } // 结束亮度判断
        if old.keepScreenOn != newSettings.keepScreenOn { // 常亮开关变化
            UIApplication.shared.isIdleTimerDisabled = newSettings.keepScreenOn // 同步系统锁屏策略
        } // 结束常亮判断

        if old.typography != newSettings.typography { // 排版参数变化（字号/行距/边距等）：需要整体重排
            let anchor = currentCharOffset() // 记录当前位置，重排后回到原处
            typographyWork?.cancel() // 取消上一次待执行的重排
            let work = DispatchWorkItem { [weak self] in // 构造重排任务
                self?.relayoutForTypography(anchor: anchor) // 执行重排
            } // 结束 DispatchWorkItem 构造
            typographyWork = work // 记录任务，供下次取消
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work) // 0.22s 防抖：滑杆拖动时只在停手后重排
        } else if old.themeID != newSettings.themeID || old.customTheme != newSettings.customTheme { // 仅主题变化：分页不变，只需重绘
            attributedCache.removeAll() // 清空富文本缓存（颜色已变）
            chapterAttributed = nil // 清空当前章富文本热缓存
            rebuildPager() // 用新主题重建三页快照
        } else if old.turnMode != newSettings.turnMode { // 仅翻页模式变化：分页不变，只需重绘
            rebuildPager() // 重建快照让容器切换翻页动画
        } // 结束差异处理链
    } // 结束 apply(_:)

    /// 排版参数变更后的整体重排：重建签名与缓存，再按锚点位置重新分页。
    /// - Parameter anchor: 重排前的字符偏移
    /// - 副作用：清空签名相关各级缓存，触发 requestLayout。
    private func relayoutForTypography(anchor: Int) { // 防抖后执行
        guard containerSize.width > 80 else { return } // 容器未就绪则跳过（等 prepare 再排）
        signature = PaginationEngine.signature(typography: observedSettings.typography, textSize: textSize) // 计算新签名
        layoutCache = CachedLayout(signature: signature, chapters: []) // 旧缓存对新签名无效，直接换新容器
        sliceCache.removeAll() // 清空一级分页缓存
        attributedCache.removeAll() // 清空富文本缓存
        chapterSlices = [] // 清空当前章热缓存
        requestLayout(chapter: chapterIndex, anchorOffset: anchor, targetPage: nil) // 按锚点重新排版
    } // 结束 relayoutForTypography(anchor:)

    /// 应用亮度设置：首次调用时记录系统原始亮度，之后按其决定是否覆盖。
    /// - 副作用：写入 UIScreen.main.brightness。
    private func applyBrightness() { // 设置变更与 init 时调用
        if !brightnessCaptured { // 首次进入阅读器
            originalBrightness = UIScreen.main.brightness // 记录原始亮度，供退出还原
            brightnessCaptured = true // 标记已记录
        } // 结束记录判断
        if observedSettings.followSystemBrightness { // 跟随系统：恢复原始亮度
            UIScreen.main.brightness = originalBrightness // 使用原始亮度
        } else { // 自定义亮度：夹到 0.05...1，避免全黑不可读
            UIScreen.main.brightness = CGFloat(min(max(observedSettings.brightness, 0.05), 1)) // 应用自定义亮度
        } // 结束亮度分支
    } // 结束 applyBrightness()

    /// 还原进入阅读器前的屏幕亮度。
    /// - 副作用：写入 UIScreen.main.brightness 并清除已捕获标记。
    private func restoreBrightness() { // endSession/deinit 调用
        guard brightnessCaptured else { return } // 未改过亮度则无需还原
        UIScreen.main.brightness = originalBrightness // 还原原始亮度
        brightnessCaptured = false // 清除标记，避免重复还原
    } // 结束 restoreBrightness()

    // MARK: - 提示

    // 轻提示与边界反馈：用令牌保证只有最新一条提示负责自动消失。

    /// 弹出轻提示，1.6s 后自动消失。
    /// - Parameter message: 提示文案
    /// - 副作用：更新 toast；递减令牌机制确保连续提示时只有最后一次能清除。
    func flashToast(_ message: String) { // 供阅读器各处调用
        toast = message // 显示提示
        toastToken += 1 // 递增令牌，作废此前尚未执行的清除任务
        let token = toastToken // 捕获本次令牌
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in // 延时清除
            guard let self, self.toastToken == token else { return } // 非最新提示则不清除（避免误清新提示）
            self.toast = nil // 隐藏提示
        } // 结束延时闭包
    } // 结束 flashToast(_:)

    /// 翻到全书首/末页时的边界反馈。
    /// - Parameter direction: 用户尝试的翻页方向
    /// - 副作用：弹出对应提示。
    func handleBoundaryReached(_ direction: PageTurnDirection) { // 容器在无更多页时回调
        flashToast(direction == .next ? "已经是最后一页" : "已经是第一页") // 按方向给出提示
    } // 结束 handleBoundaryReached(_:)
} // 结束 ReaderViewModel
