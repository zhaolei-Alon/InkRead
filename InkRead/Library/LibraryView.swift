//
//  LibraryView.swift
//  墨读 InkRead —— 书架首页：展示、导入与删除
//
//  职责：
//    · 渲染书架首页：头部标题与导入按钮、继续阅读卡、自适应封面网格、空状态
//    · 通过 fileImporter 多选导入本地书籍，交由 BookImporter 解析后写入 LibraryStore
//    · 提供删除确认流程，并联动 BookmarkStore 清理该书书签
//  上层调用者：InkReadApp（作为根视图挂载，并注入 LibraryStore / ReaderSettingsStore / BookmarkStore 三个环境对象）
//  下层依赖：LibraryStore（books / add / delete）、ReaderSettingsStore、BookmarkStore（removeAll(for:)）、BookImporter（supportedContentTypes / load(url:)）、BookDraft、BookCoverView / BookShelfCell、ReaderView、AppTheme
//  关键流程：fileImporter 选中 URL → BookImporter.load 产出 BookDraft → LibraryStore.add 落盘 → @Published books 变更驱动书架网格刷新
//

import SwiftUI // 引入 SwiftUI：View、@State、@EnvironmentObject 与各类视图修饰符
import UniformTypeIdentifiers // 引入 UTType：fileImporter 需要允许导入的内容类型

/// 书架首页视图：展示全部书籍、继续阅读入口，并负责文件导入与删除确认。
/// 依赖环境中的 LibraryStore 读写书库、ReaderSettingsStore 透传给阅读器、BookmarkStore 清理书签。
struct LibraryView: View { // 声明书架首页视图，遵循 View 协议
    @EnvironmentObject private var library: LibraryStore // 书库数据源：书籍列表来自这里，导入与删除也都调用它
    @EnvironmentObject private var settings: ReaderSettingsStore // 阅读设置：仅透传给 ReaderView
    @EnvironmentObject private var bookmarks: BookmarkStore // 书签仓库：删除书籍时清理对应书签

    @State private var showImporter = false // 是否弹出系统文件选择器（fileImporter 的绑定开关）
    @State private var isImporting = false // 是否正在后台解析导入，用于显示导入遮罩
    @State private var importError: String? // 导入失败时收集的错误文案，nil 表示当前无错误
    @State private var pendingDelete: Book? // 等待用户确认删除的书籍，nil 表示未处于删除确认中

    /// 最近阅读的书籍，用于「继续阅读」卡片。
    /// - Returns: lastOpenedAt 最晚的一本书；所有书都未打开过时返回 nil。
    private var continueBook: Book? { // 计算属性：由 library.books 派生，不额外存储状态
        library.books // 以书库列表作为候选集合
            .filter { $0.lastOpenedAt != nil } // 只保留打开过的书，避免把新导入的书当成续读
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) } // 取最后打开时间最晚的一本
    } // 结束 continueBook 计算属性

    /// 书架网格的列定义。
    /// - Returns: 单列自适应 GridItem，由 LazyVGrid 根据容器宽度决定每行放几个封面。
    private var columns: [GridItem] { // 计算属性：交给 LazyVGrid 决定列数
        [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 16, alignment: .top)] // 自适应列：单元最小 104、最大 150，列距 16，顶部对齐
    } // 结束 columns 计算属性

    /// 视图主体：导航容器 + 纸色背景 + 可滚动内容，并挂载导入/错误/删除等修饰符。
    var body: some View { // View 协议要求的入口属性
        NavigationStack { // 导航容器：为 NavigationLink(value:) 提供 value 式导航栈
            ZStack { // 叠层容器：纸色背景在下、内容居中、导入遮罩最上
                AppTheme.paper.ignoresSafeArea() // 铺满全屏的纸色背景，忽略安全区

                ScrollView { // 纵向滚动容器：承载头部、续读卡与书架网格
                    VStack(alignment: .leading, spacing: 22) { // 纵向主栈：左对齐，块间距 22
                        header // 头部：品牌标题与「导入」按钮
                        if library.books.isEmpty { // 书库为空时走空状态分支
                            emptyState // 空状态：插画式图标与「导入第一本书」按钮
                        } else { // 书库非空时展示续读卡与书架网格
                            if let book = continueBook { // 存在可续读的书才渲染续读卡
                                continueCard(book) // 续读卡：封面、书名、进度与进入箭头
                            } // 结束 续读卡条件分支
                            shelfSection // 书架区块：标题、数量徽标与 LazyVGrid
                        } // 结束 空状态 / 书架分支
                    } // 结束 主 VStack
                    .padding(.horizontal, 20) // 左右留白 20，避免内容贴边
                    .padding(.top, 8) // 顶部留白 8，与状态栏拉开距离
                    .padding(.bottom, 40) // 底部留白 40，滚到底部不显拥挤
                } // 结束 ScrollView
                .scrollIndicators(.hidden) // 隐藏滚动指示条，保持界面干净

                if isImporting { // 后台导入进行中时叠加遮罩
                    importOverlay // 导入遮罩：转圈与提示文案
                } // 结束 导入遮罩条件分支
            } // 结束 ZStack
            .toolbar(.hidden, for: .navigationBar) // 隐藏系统导航栏，改用自定义头部
            .navigationDestination(for: Book.self) { book in // 注册 Book 类型的导航目的地
                ReaderView(book: book, library: library, settingsStore: settings, bookmarkStore: bookmarks) // 进入阅读器，并注入书库、设置与书签
                    .navigationBarBackButtonHidden(true) // 隐藏系统返回按钮，由阅读器自定义返回
                    .toolbar(.hidden, for: .navigationBar) // 阅读器内同样隐藏系统导航栏
            } // 结束 navigationDestination 修饰符
        } // 结束 NavigationStack
        .tint(AppTheme.accent) // 全局强调色：导航与控件统一着朱砂红
        .preferredColorScheme(.light) // 固定浅色外观，保证纸色主题一致
        .fileImporter( // 系统文件选择器修饰符：多选导入本地书籍
            isPresented: $showImporter, // 与 showImporter 双向绑定，控制选择器显隐
            allowedContentTypes: BookImporter.supportedContentTypes, // 允许的类型：由导入器统一声明
            allowsMultipleSelection: true, // 允许一次选择多个文件
            onCompletion: handleImport // 选择完成后的回调，交给 handleImport 处理
        ) // 结束 fileImporter 修饰符
        .alert("导入失败", isPresented: Binding( // 错误提示弹窗：由 importError 是否为空驱动显隐
            get: { importError != nil }, // 读取：存在错误文案即弹出
            set: { if !$0 { importError = nil } } // 写入：关闭弹窗时清空错误文案
        )) { // 结束 Binding 构造，进入弹窗按钮闭包
            Button("好", role: .cancel) {} // 唯一按钮，仅关闭弹窗
        } message: { // 弹窗正文闭包
            Text(importError ?? "") // 展示具体错误描述，兜底空串
        } // 结束 「导入失败」alert 修饰符
        .alert("删除书籍", isPresented: Binding( // 删除确认弹窗：由 pendingDelete 是否为空驱动
            get: { pendingDelete != nil }, // 读取：有待删除书籍即弹出
            set: { if !$0 { pendingDelete = nil } } // 写入：关闭弹窗时清空待删除书籍
        ), presenting: pendingDelete) { book in // 把待删除书籍传入操作闭包
            Button("删除", role: .destructive) { // 破坏性按钮：确认删除
                bookmarks.removeAll(for: book.id) // 先清理该书全部书签，避免残留孤儿数据
                library.delete(book) // 再从书库删除书籍及其正文、章节与布局文件
                pendingDelete = nil // 重置状态，驱动弹窗关闭
            } // 结束 删除按钮闭包
            Button("取消", role: .cancel) { pendingDelete = nil } // 取消按钮：仅关闭弹窗
        } message: { book in // 弹窗正文闭包，接收待删除书籍
            Text("确定要删除《\(book.title)》吗？阅读进度与书签也会一并删除。") // 以书名做二次确认，说明连带影响
        } // 结束 「删除书籍」alert 修饰符
    } // 结束 body

    // MARK: 头部
    // 头部区：左侧「墨读」大标题、右侧胶囊「导入」按钮，下方为支持格式说明

    /// 页面头部：品牌标题 + 导入入口 + 支持格式说明。
    /// 点击导入按钮会把 showImporter 置为 true，从而唤起 fileImporter。
    private var header: some View { // 计算属性：纯展示，不持有状态
        VStack(alignment: .leading, spacing: 6) { // 纵向栈：左对齐，行间距 6
            HStack(alignment: .firstTextBaseline) { // 横向栈：标题与按钮按首行文字基线对齐
                Text("墨读") // 品牌名
                    .font(.system(size: 34, weight: .bold, design: .serif)) // 34 号粗体衬线，呼应「墨读」气质
                    .foregroundStyle(AppTheme.ink) // 使用墨色作为文字颜色
                Spacer() // 弹性空白：把导入按钮推到最右侧
                Button { // 导入按钮：点击后打开系统文件选择器
                    showImporter = true // 置位开关，触发 fileImporter 弹出
                } label: { // 结束 action 闭包，开始 label 外观闭包
                    HStack(spacing: 5) { // 图标与文字横向排列，间距 5
                        Image(systemName: "plus") // 加号图标
                        Text("导入") // 按钮文案
                    } // 结束 按钮内容 HStack
                    .font(.system(size: 13, weight: .semibold)) // 13 号半粗体
                    .foregroundStyle(.white) // 文字与图标为白色
                    .padding(.horizontal, 14) // 水平内边距 14
                    .padding(.vertical, 8) // 垂直内边距 8
                    .background(Capsule().fill(AppTheme.accent)) // 胶囊强调色底，突出主操作
                } // 结束 label 外观闭包
                .buttonStyle(.plain) // 移除系统按钮高亮样式，避免底色被冲淡
            } // 结束 头部 HStack
            Text("支持 TXT · EPUB · Markdown · HTML · RTF，本地阅读更安心") // 支持格式说明文案
                .font(.system(size: 12)) // 12 号说明文字
                .foregroundStyle(AppTheme.ink.opacity(0.55)) // 墨色半透明，弱化次要信息
        } // 结束 header 的 VStack
        .padding(.top, 6) // 顶部留白 6，与屏顶拉开距离
    } // 结束 header 计算属性

    // MARK: 继续阅读
    // 续读区：取最近打开的一本书，展示封面、书名与进度，点击进入 ReaderView

    /// 「继续阅读」卡片。
    /// - Parameter book: 最近打开的书籍，由 continueBook 计算属性提供。
    /// - Returns: 可点击卡片视图，经 NavigationLink(value:) 进入 ReaderView。
    private func continueCard(_ book: Book) -> some View { // 成员方法：入参为待续读的书籍
        NavigationLink(value: book) { // 值驱动导航：把书籍作为目的地参数压入导航栈
            HStack(spacing: 14) { // 横向布局：封面 + 信息 + 箭头
                BookCoverView(book: book, compact: true) // 紧凑版封面：隐藏底部格式标签
                    .frame(width: 66, height: 88) // 固定封面尺寸 66×88
                VStack(alignment: .leading, spacing: 6) { // 右侧信息区：左对齐，行距 6
                    Text("继续阅读") // 卡片小标题
                        .font(.system(size: 11, weight: .semibold)) // 11 号半粗体
                        .foregroundStyle(AppTheme.accent) // 强调色，点明这是主要操作入口
                    Text(book.title) // 书名
                        .font(.system(size: 17, weight: .semibold, design: .serif)) // 17 号半粗衬线，与书架标题呼应
                        .foregroundStyle(AppTheme.ink) // 墨色正文
                        .lineLimit(1) // 单行省略，避免卡片高度抖动
                    Text(book.progress.percent > 0 ? "已读 \(Int(book.progress.percent * 100))%" : "尚未开始") // 进度文案：已读百分比或「尚未开始」
                        .font(.system(size: 11)) // 11 号小字
                        .foregroundStyle(AppTheme.ink.opacity(0.55)) // 半透明墨色，弱化次要信息
                    ProgressView(value: min(max(book.progress.percent, 0), 1)) // 线性进度条：百分比钳制到 0…1
                        .tint(AppTheme.accent) // 进度条着色为强调色
                } // 结束 信息区 VStack
                Spacer(minLength: 0) // 弹性空白：把箭头推到最右侧
                Image(systemName: "chevron.right") // 右侧箭头，暗示可进入阅读
                    .font(.system(size: 13, weight: .semibold)) // 13 号半粗体
                    .foregroundStyle(AppTheme.ink.opacity(0.3)) // 很淡的墨色，仅作装饰
            } // 结束 卡片内容 HStack
            .padding(14) // 卡片内边距 14
            .background( // 卡片背景修饰符
                RoundedRectangle(cornerRadius: 18) // 18 圆角矩形
                    .fill(Color.white.opacity(0.72)) // 半透明白底，浮在纸色背景之上
            ) // 结束 background
            .overlay( // 叠加描边修饰符
                RoundedRectangle(cornerRadius: 18) // 与背景同尺寸的圆角矩形
                    .stroke(AppTheme.ink.opacity(0.06), lineWidth: 1) // 1pt 极淡墨色描边，勾勒卡片边界
            ) // 结束 overlay
        } // 结束 NavigationLink 内容闭包
        .buttonStyle(.plain) // 去掉链接默认高亮，保持自绘样式
    } // 结束 continueCard

    // MARK: 书架
    // 书架区：标题 + 数量徽标 + 自适应 LazyVGrid，每格为 BookShelfCell，长按可删除

    /// 书架区块：标题行与封面网格。
    /// 网格数据来自 library.books；每格 NavigationLink(value:) 进入 ReaderView，
    /// contextMenu 中的删除只设置 pendingDelete，由 body 内的 alert 二次确认。
    private var shelfSection: some View { // 计算属性：依赖 library.books 与 columns
        VStack(alignment: .leading, spacing: 12) { // 纵向栈：左对齐，区块间距 12
            HStack { // 标题行：标题、数量徽标与弹性空白
                Text("我的书架") // 区块标题
                    .font(.system(size: 17, weight: .semibold, design: .serif)) // 17 号半粗衬线
                    .foregroundStyle(AppTheme.ink) // 墨色
                Text("\(library.books.count)") // 书籍数量文本
                    .font(.system(size: 11, weight: .semibold)) // 11 号半粗体
                    .foregroundStyle(AppTheme.ink.opacity(0.5)) // 半透明墨色
                    .padding(.horizontal, 7) // 水平内边距 7，形成徽标外形
                    .padding(.vertical, 2) // 垂直内边距 2
                    .background(Capsule().fill(AppTheme.ink.opacity(0.07))) // 极淡墨色胶囊底
                Spacer() // 弹性空白：让标题组靠左
            } // 结束 标题行 HStack

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) { // 懒加载网格：按 columns 自适应列数，行距 20
                ForEach(library.books) { book in // 遍历书库，Book 需实现 Identifiable
                    NavigationLink(value: book) { // 每格都是导航链接，点击进入 ReaderView
                        BookShelfCell(book: book) // 书架单元格：封面、书名、格式与进度
                    } // 结束 NavigationLink 内容闭包
                    .buttonStyle(.plain) // 去掉默认按钮样式
                    .contextMenu { // 长按菜单
                        Button(role: .destructive) { // 破坏性「删除」按钮：此处不做真正删除
                            pendingDelete = book // 仅记录待删除书籍，交给 alert 二次确认
                        } label: { // 结束 action 闭包，开始菜单项外观闭包
                            Label("删除", systemImage: "trash") // 文字与垃圾桶图标
                        } // 结束 label 外观闭包
                    } // 结束 contextMenu
                } // 结束 ForEach
            } // 结束 LazyVGrid
        } // 结束 shelfSection 的 VStack
    } // 结束 shelfSection 计算属性

    // MARK: 空状态
    // 空状态区：书库为空时展示图标、说明文案与「导入第一本书」按钮

    /// 空状态：书库无书时替代书架展示。
    /// 点击按钮置位 showImporter，直接唤起导入流程。
    private var emptyState: some View { // 计算属性：纯展示 + 一个导入入口
        VStack(spacing: 16) { // 纵向栈：元素间距 16
            ZStack { // 叠层：圆角底与书本 SF Symbol
                RoundedRectangle(cornerRadius: 22) // 22 圆角矩形底
                    .fill(Color.white.opacity(0.6)) // 半透明白底
                    .frame(width: 96, height: 96) // 固定 96×96
                Image(systemName: "books.vertical") // 竖向书架图标
                    .font(.system(size: 38, weight: .light)) // 38 号细体，视觉更轻
                    .foregroundStyle(AppTheme.accent.opacity(0.75)) // 半透明强调色
            } // 结束 图标 ZStack
            Text("书架还空着") // 主标题
                .font(.system(size: 18, weight: .semibold, design: .serif)) // 18 号半粗衬线
                .foregroundStyle(AppTheme.ink) // 墨色
            Text("从「文件」导入本地小说，\n支持 TXT / EPUB / Markdown / HTML / RTF") // 说明文案，内含换行符
                .font(.system(size: 12)) // 12 号小字
                .multilineTextAlignment(.center) // 多行居中对齐
                .foregroundStyle(AppTheme.ink.opacity(0.55)) // 半透明墨色
            Button { // 主操作按钮：导入第一本书
                showImporter = true // 置位开关，唤起 fileImporter
            } label: { // 结束 action 闭包，开始 label 外观闭包
                Text("导入第一本书") // 按钮文案
                    .font(.system(size: 14, weight: .semibold)) // 14 号半粗体
                    .foregroundStyle(.white) // 白字
                    .padding(.horizontal, 22) // 水平内边距 22
                    .padding(.vertical, 11) // 垂直内边距 11
                    .background(Capsule().fill(AppTheme.accent)) // 胶囊强调色底
            } // 结束 label 外观闭包
            .buttonStyle(.plain) // 去掉默认高亮
            .padding(.top, 6) // 与说明文案拉开 6 的间距
        } // 结束 emptyState 的 VStack
        .frame(maxWidth: .infinity) // 占满可用宽度，保证内部居中
        .padding(.vertical, 50) // 上下留白 50，改善空状态的观感
    } // 结束 emptyState 计算属性

    /// 导入遮罩：后台解析期间覆盖在内容上的毛玻璃卡片。
    /// 只读取 isImporting，无副作用。
    private var importOverlay: some View { // 计算属性：由 body 在 isImporting 为真时插入
        VStack(spacing: 12) { // 纵向栈：转圈与文案间距 12
            ProgressView() // 系统菊花，表示处理中
            Text("正在解析并导入…") // 状态文案
                .font(.system(size: 13)) // 13 号字
                .foregroundStyle(.secondary) // 次要文字色
        } // 结束 遮罩内容 VStack
        .padding(26) // 卡片内边距 26
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)) // 16 圆角毛玻璃底
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6) // 柔和投影，与背景分层
    } // 结束 importOverlay 计算属性

    // MARK: 导入
    // 导入区：fileImporter 回调入口，后台解析全部 URL，回主线程写库并汇报失败项

    /// 处理 fileImporter 的回调结果。
    /// - Parameter result: 用户选择结果；成功时附带已授权访问的 URL 数组，失败时为错误。
    /// 副作用：切换 isImporting 显示遮罩；调用 BookImporter.load 解析文件；
    /// 在后台线程解析、主线程调用 LibraryStore.add 落盘，并把失败信息写入 importError。
    private func handleImport(_ result: Result<[URL], Error>) { // 作为 onCompletion 传入 fileImporter
        switch result { // 按选择结果分流
        case .failure(let error): // 选择器报错或用户取消
            importError = error.localizedDescription // 直接把系统描述作为弹窗文案
        case .success(let urls): // 拿到用户选中的文件 URL 列表
            guard !urls.isEmpty else { return } // 空选择直接返回，不做任何 IO
            isImporting = true // 打开遮罩，反馈「正在解析」
            DispatchQueue.global(qos: .userInitiated).async { // 切到后台线程：解析文件较慢，避免阻塞主线程
                var drafts: [BookDraft] = [] // 收集解析成功的书籍草稿
                var failures: [String] = [] // 收集失败项描述，稍后统一提示
                for url in urls { // 逐个文件解析
                    do { // 尝试解析当前文件
                        drafts.append(try BookImporter.load(url: url)) // 解析产出 BookDraft 并追加到草稿列表
                    } catch { // 单个文件失败不影响其余文件
                        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") // 记录「文件名：原因」形式的失败描述
                    } // 结束 单文件解析 do-catch
                } // 结束 文件遍历
                DispatchQueue.main.async { // 回到主线程：UI 状态与 @Published 写入都必须在主线程
                    for draft in drafts { // 逐本写入书库
                        _ = try? library.add(draft) // 写库失败静默忽略，保证批量导入不被单本打断
                    } // 结束 草稿写库循环
                    isImporting = false // 关闭遮罩
                    if !failures.isEmpty { // 有失败项才弹错误提示
                        importError = failures.joined(separator: "\n") // 合并为多行文案交给 alert 展示
                    } // 结束 失败提示条件
                } // 结束 主线程回写闭包
            } // 结束 后台解析闭包
        } // 结束 .success 分支
    } // 结束 handleImport
} // 结束 LibraryView

// MARK: - 书架单元格
// 单元格区：私有组件，被 shelfSection 的 ForEach 复用，负责单本书的封面与元信息

/// 书架单元格：封面 + 书名 + 格式标签 + 进度。
/// 仅负责展示，点击行为由外层 NavigationLink 提供。
private struct BookShelfCell: View { // 私有视图：仅在本文件内使用
    /// 要展示的书籍，由 ForEach 逐项传入
    let book: Book // 不可变入参：单元格只读

    /// 单元格主体：竖向排布封面、书名与底部元信息行。
    var body: some View { // View 协议入口
        VStack(alignment: .leading, spacing: 7) { // 纵向栈：左对齐，间距 7
            BookCoverView(book: book) // 标准封面：含格式标签与底部进度条
                .frame(maxWidth: .infinity) // 撑满网格单元宽度
                .aspectRatio(0.7, contentMode: .fit) // 固定 0.7 宽高比，保持书封视觉比例
            Text(book.title) // 书名
                .font(.system(size: 13, weight: .medium)) // 13 号中等字重
                .foregroundStyle(AppTheme.ink) // 墨色
                .lineLimit(1) // 单行省略，保持网格整齐
            HStack(spacing: 4) { // 元信息行：格式标签与进度
                Text(book.format.displayName) // 格式短名，如 TXT / EPUB
                    .font(.system(size: 9, weight: .semibold)) // 9 号半粗体
                    .foregroundStyle(AppTheme.accent) // 强调色文字
                    .padding(.horizontal, 4) // 水平内边距 4
                    .padding(.vertical, 1) // 垂直内边距 1
                    .background( // 标签背景修饰符
                        RoundedRectangle(cornerRadius: 3) // 3 圆角矩形
                            .fill(AppTheme.accent.opacity(0.1)) // 10% 强调色淡底
                    ) // 结束 background
                Text(book.progress.percent > 0 ? "\(Int(book.progress.percent * 100))%" : "未读") // 进度：百分比或「未读」
                    .font(.system(size: 9)) // 9 号小字
                    .foregroundStyle(AppTheme.ink.opacity(0.45)) // 淡墨色
                Spacer(minLength: 0) // 弹性空白：让标签靠左
            } // 结束 元信息 HStack
        } // 结束 BookShelfCell 的 VStack
    } // 结束 body
} // 结束 BookShelfCell

// MARK: - 封面
// 封面区：公开组件，供 LibraryView 续读卡、书架单元格以及外部视图复用

/// 程序化封面视图：按 coverIndex 选配色，叠加渐变、光斑、书名作者与底部进度条。
/// 不依赖网络图片，保证导入的本地书籍也有稳定视觉。
struct BookCoverView: View { // 公开视图：可被其他文件复用
    /// 封面所属书籍，提供 title / author / coverIndex / progress
    let book: Book // 只读入参
    /// 紧凑模式：用于「继续阅读」小卡，尺寸与字号更小且隐藏格式标签
    var compact: Bool = false // 带默认值的可变入参，默认非紧凑

    /// 配色表：每项为「渐变双色 + 文字色」，共 8 套，按 coverIndex 取模循环
    private static let palettes: [([Color], Color)] = [ // 静态常量：整个视图类型共享，避免每帧重复构造
        ([Color(hex: 0x6D8B74), Color(hex: 0x3F5D4E)], .white), // 松绿渐变
        ([Color(hex: 0xC0855B), Color(hex: 0x8A4F32)], .white), // 陶土橙渐变
        ([Color(hex: 0x5B6F95), Color(hex: 0x2F3E5C)], .white), // 靛蓝渐变
        ([Color(hex: 0x8C6A8E), Color(hex: 0x5C3F60)], .white), // 绛紫渐变
        ([Color(hex: 0xB09A6A), Color(hex: 0x7C6A42)], .white), // 麻金渐变
        ([Color(hex: 0x4F7A8A), Color(hex: 0x2C4C58)], .white), // 黛青渐变
        ([Color(hex: 0x9A6A5A), Color(hex: 0x6D3F35)], .white), // 赭红渐变
        ([Color(hex: 0x6B7280), Color(hex: 0x353B45)], .white) // 石墨灰渐变
    ] // 结束 palettes 配色表

    /// 封面主体：渐变底 + 光斑 + 文本层 + 进度条，最后统一裁圆角并加投影。
    var body: some View { // View 协议入口
        let palette = Self.palettes[book.coverIndex % Self.palettes.count] // 按 coverIndex 取模选中一套配色（coverIndex 由 LibraryStore 依书名哈希生成）
        ZStack(alignment: .topLeading) { // 叠层容器：左上角对齐
            LinearGradient(colors: palette.0, startPoint: .topLeading, endPoint: .bottomTrailing) // 主渐变底：左上到右下
            Circle() // 装饰光斑圆
                .fill(Color.white.opacity(0.07)) // 7% 白色，形成柔和高光
                .frame(width: compact ? 70 : 130, height: compact ? 70 : 130) // 尺寸：紧凑 70、标准 130
                .offset(x: compact ? 40 : 80, y: compact ? -22 : -40) // 偏移到右上角，营造光感
            VStack(alignment: .leading, spacing: compact ? 4 : 8) { // 文本层：左对齐，紧凑模式行距更小
                Spacer(minLength: 0) // 弹性空白：先把文本推到底部
                Text(book.title) // 书名
                    .font(.system(size: compact ? 10 : 15, weight: .semibold, design: .serif)) // 衬线半粗：紧凑 10、标准 15
                    .foregroundStyle(.white) // 白字，保证深色渐变上可读
                    .lineLimit(compact ? 3 : 4) // 最多行数：紧凑 3、标准 4
                    .multilineTextAlignment(.leading) // 多行左对齐
                Text(book.author) // 作者
                    .font(.system(size: compact ? 7 : 9)) // 字号：紧凑 7、标准 9
                    .foregroundStyle(.white.opacity(0.75)) // 75% 白，弱化处理
                    .lineLimit(1) // 单行省略
                if !compact { // 仅标准模式展示格式标签
                    Spacer(minLength: 0) // 弹性空白：撑开底部留白
                    Text(book.format.displayName) // 格式短名标签
                        .font(.system(size: 8, weight: .semibold)) // 8 号半粗体
                        .foregroundStyle(.white.opacity(0.9)) // 90% 白
                        .padding(.horizontal, 5) // 水平内边距 5
                        .padding(.vertical, 2) // 垂直内边距 2
                        .background( // 标签背景修饰符
                            RoundedRectangle(cornerRadius: 3) // 3 圆角矩形
                                .fill(Color.white.opacity(0.18)) // 18% 白色半透明底
                        ) // 结束 background
                } // 结束 标准模式格式标签条件
            } // 结束 文本层 VStack
            .padding(compact ? 8 : 12) // 文本层内边距：紧凑 8、标准 12
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) // 撑满封面，内容左上对齐

            if book.progress.percent > 0 { // 有阅读进度时才绘制底部进度条
                VStack { // 纵向栈：把进度条压到底部
                    Spacer() // 弹性空白：把进度条推向底部
                    GeometryReader { geo in // 读取可用宽度，用于按百分比计算填充长度
                        ZStack(alignment: .leading) { // 叠层：轨道在下、填充条在上
                            Rectangle().fill(Color.black.opacity(0.18)) // 进度轨道：18% 黑
                            Rectangle() // 进度填充条
                                .fill(Color.white.opacity(0.75)) // 75% 白，与深色封面形成对比
                                .frame(width: geo.size.width * min(max(book.progress.percent, 0), 1)) // 宽度 = 总宽 × 钳制后的百分比
                        } // 结束 进度条 ZStack
                    } // 结束 GeometryReader
                    .frame(height: 3) // 进度条高度 3
                } // 结束 底部进度条 VStack
            } // 结束 进度条条件分支
        } // 结束 封面 ZStack
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12)) // 按模式裁圆角：紧凑 10、标准 12
        .shadow(color: .black.opacity(0.16), radius: compact ? 5 : 8, x: 0, y: 4) // 柔和投影，模拟纸张厚度
    } // 结束 body
} // 结束 BookCoverView
