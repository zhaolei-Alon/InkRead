//
//  ReaderView.swift
//  墨读 InkRead —— 阅读器主界面：分页阅读 + 自定义状态栏/页脚 + 三个面板入口
//
//  职责：
//    · 组装阅读页 ZStack 层级：主题背景、PagerContainer、ReaderChrome、排版加载层、Toast
//    · 用 safeAreaInset 在顶部挂载自定义状态栏（时间/网络/电量 + 书名），底部挂载页脚（章节名/页码/百分比）
//    · 以 PagerContainer(UIViewRepresentable) + Coordinator 把 UIKit 的 PagePagerView 事件桥接给 ReaderViewModel
//    · 监听 scenePhase 落盘进度，onDisappear 结束阅读会话，并挂载设置/目录/书签三个 sheet
//  上层调用者：阅读入口（如 LibraryView 中的书架跳转）以 ReaderView(book:library:settingsStore:bookmarkStore:) 构造
//  下层依赖：ReaderViewModel、ReaderTheme、AppTheme、ReaderChrome、PagerContainer/PagePagerView/PagePagerDelegate、
//            ReaderStatusBar、NetworkMonitor、ReaderSettingsSheet、ReaderTOCSheet、ReaderBookmarksSheet
//  关键流程：PagerContainer 的翻页/点击/边界回调 → ReaderViewModel 更新 pagerModel 与 showChrome → SwiftUI 重渲染
//            （页脚页码随之刷新）；scenePhase 非 active 时调用 vm.saveProgress() 与 library.flush() 落盘。
//

import SwiftUI   // 引入 SwiftUI：本文件的视图、状态包装器与修饰符均来自该框架
import UIKit     // 引入 UIKit：需要 UIDevice 电量监听、UIViewRepresentable 等 UIKit 能力

/// 阅读器主视图：把分页控件、阅读工具栏、自定义状态栏与页脚组合成一屏阅读界面
struct ReaderView: View {   // 定义阅读器主视图，遵循 View 协议参与 SwiftUI 渲染
    @StateObject private var vm: ReaderViewModel   // 持有阅读视图模型（StateObject 保证本视图生命周期内唯一实例）
    @Environment(\.dismiss) private var dismiss   // 读取环境中的 dismiss 动作，用于关闭当前阅读页
    @Environment(\.scenePhase) private var scenePhase   // 订阅 App 前后台状态，用于切后台时保存进度

    /// 初始化阅读器视图
    /// - Parameters:
    ///   - book: 当前打开的书籍模型
    ///   - library: 书库存储，负责书籍元数据与阅读进度落盘
    ///   - settingsStore: 阅读设置存储，提供主题与排版参数
    ///   - bookmarkStore: 书签存储，供工具栏与书签面板读写
    /// - 副作用：把依赖注入 ReaderViewModel，并以 StateObject 形式绑定到 self._vm
    init(book: Book, library: LibraryStore, settingsStore: ReaderSettingsStore, bookmarkStore: BookmarkStore) {   // 自定义构造器：集中注入四项依赖
        _vm = StateObject(wrappedValue: ReaderViewModel(   // 用 StateObject 包装新建的视图模型并赋给属性包装器
            book: book,   // 传入书籍
            library: library,   // 传入书库存储
            settingsStore: settingsStore,   // 传入设置存储
            bookmarkStore: bookmarkStore   // 传入书签存储
        ))   // 结束 ReaderViewModel 构造参数
    }   // 结束 init

    /// 当前阅读主题（背景色、正文色、次要色等），由视图模型统一提供
    private var theme: ReaderTheme { vm.theme }   // 透传视图模型的主题，供本文件各图层取色

    /// 视图主体：组合阅读页所有图层与系统级修饰符
    var body: some View {   // 声明 SwiftUI 视图树入口
        ZStack {   // 用 ZStack 叠放背景、分页内容与浮层（书写顺序即层级顺序）
            theme.background.color   // 主题背景色铺满整屏
                .ignoresSafeArea()   // 让背景延伸到安全区外，避免上下出现白边

            GeometryReader { proxy in   // 读取可用尺寸，用于驱动分页排版所需容器宽高
                ZStack(alignment: .top) {   // 顶部对齐的内层叠层，容纳分页与浮层
                    PagerContainer(vm: vm)   // 承载 UIKit 分页控件的桥接视图
                        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 让分页视图撑满可用区域

                    if vm.showChrome {   // 工具栏显隐开关由视图模型控制
                        ReaderChrome(vm: vm, theme: theme, onClose: { dismiss() })   // 阅读工具栏（含关闭阅读页回调）
                            .transition(.opacity)   // 出现/消失时使用淡入淡出过渡
                            .zIndex(2)   // 置于分页之上、加载层与 Toast 之下
                    }   // 结束 showChrome 条件块

                    if vm.pagerModel.current == nil {   // 分页结果尚未就绪（首次排版中）时展示占位
                        loadingView   // 加载/排版中的视图
                            .zIndex(3)   // 覆盖在分页与工具栏之上
                    }   // 结束加载占位条件块

                    if let toast = vm.toast {   // 视图模型存在非空提示文案时展示
                        Text(toast)   // 展示提示文案
                            .font(.system(size: 13, weight: .medium))   // 13pt 中等字重系统字体
                            .foregroundStyle(.white)   // 白色文字
                            .padding(.horizontal, 16)   // 水平内边距 16
                            .padding(.vertical, 9)   // 垂直内边距 9
                            .background(Capsule().fill(Color.black.opacity(0.75)))   // 黑色半透明胶囊背景
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)   // 撑满可用区域并居中
                            .allowsHitTesting(false)   // 不拦截触摸，避免影响翻页
                            .transition(.opacity)   // 淡入淡出过渡
                            .zIndex(4)   // 位于最上层
                    }   // 结束 toast 条件块
                }   // 结束内层 ZStack
                .animation(.easeInOut(duration: 0.2), value: vm.showChrome)   // 工具栏显隐使用 0.2s 缓动动画
                .animation(.easeInOut(duration: 0.18), value: vm.toast)   // Toast 显隐使用 0.18s 缓动动画
                .onAppear {   // 视图出现时的初始化回调
                    UIDevice.current.isBatteryMonitoringEnabled = true   // 打开电量监听，供自定义状态栏读取电量
                    NetworkMonitor.shared.start()   // 启动网络状态监听
                    vm.prepare(containerSize: proxy.size)   // 按当前容器尺寸触发首次分页排版
                }   // 结束 onAppear
                .onChange(of: proxy.size) { _, newSize in   // 容器尺寸变化（旋转/分屏）时重新排版
                    vm.prepare(containerSize: newSize)   // 用新尺寸重新计算分页
                }   // 结束 onChange
            }   // 结束 GeometryReader
            .safeAreaInset(edge: .top, spacing: 0) {   // 在顶部安全区插入自定义系统状态栏
                ReaderStatusBar(theme: theme, bookTitle: vm.title)   // 自定义状态栏（时间/网络/电量 + 书名）
                    .frame(height: 24)   // 固定高度 24
                    .padding(.horizontal, 18)   // 左右留白 18
                    .padding(.bottom, 2)   // 底部留白 2
                    .allowsHitTesting(false)   // 状态栏不响应触摸
            }   // 结束顶部 safeAreaInset
            .safeAreaInset(edge: .bottom, spacing: 0) {   // 在底部安全区插入页脚
                HStack(spacing: 10) {   // 页脚横向排列：左章节名、右页码百分比
                    Text(vm.chapterTitle)   // 左侧显示当前章节名
                        .lineLimit(1)   // 最多一行
                        .truncationMode(.tail)   // 溢出时尾部省略
                    Spacer(minLength: 8)   // 中间弹性留白，最小 8
                    Text(vm.footerText)   // 右侧显示页码与百分比文案
                        .lineLimit(1)   // 最多一行
                }   // 结束页脚 HStack
                .font(.system(size: 11))   // 页脚字号 11
                .foregroundStyle(theme.secondary.color)   // 使用主题次要色
                .padding(.horizontal, 18)   // 左右留白 18
                .frame(height: 22)   // 固定高度 22
                .padding(.top, 2)   // 顶部留白 2
                .allowsHitTesting(false)   // 页脚不响应触摸
            }   // 结束底部 safeAreaInset
        }   // 结束外层 ZStack
        .statusBarHidden(true)   // 隐藏系统状态栏，改用自定义状态栏
        .persistentSystemOverlays(.hidden)   // 隐藏 Home 指示器等常驻系统浮层
        .tint(AppTheme.accent)   // 全局强调色使用 AppTheme.accent
        .preferredColorScheme(theme.isDark ? .dark : .light)   // 按主题明暗同步系统配色方案
        .onChange(of: scenePhase) { _, phase in   // 监听前后台切换
            if phase != .active {   // 进入非活跃状态（退到后台/被遮挡）
                vm.saveProgress()   // 保存当前阅读进度
                vm.library.flush()   // 立即把书库数据刷写落盘
            }   // 结束非活跃状态分支
        }   // 结束 scenePhase 监听
        .onDisappear { vm.endSession() }   // 阅读页消失时结束阅读会话（停止计时并收尾）
        .sheet(isPresented: $vm.showSettings) {   // 绑定设置面板的显隐状态
            ReaderSettingsSheet(store: vm.settingsStore)   // 阅读设置面板
        }   // 结束设置 sheet
        .sheet(isPresented: $vm.showTOC) {   // 绑定目录面板的显隐状态
            ReaderTOCSheet(vm: vm)   // 目录面板
        }   // 结束目录 sheet
        .sheet(isPresented: $vm.showBookmarks) {   // 绑定书签面板的显隐状态
            ReaderBookmarksSheet(vm: vm)   // 书签面板
        }   // 结束书签 sheet
    }   // 结束 body

    /// 排版加载占位视图：分页结果尚未生成时覆盖在阅读区上
    /// - 返回值：包含进度环与「正在排版…」文案的视图
    private var loadingView: some View {   // 计算属性：加载占位视图
        VStack(spacing: 12) {   // 纵向排列进度环与文案，间距 12
            ProgressView()   // 系统菊花进度指示器
                .tint(theme.secondary.color)   // 指示器颜色使用主题次要色
            Text("正在排版…")   // 提示文案
                .font(.system(size: 13))   // 字号 13
                .foregroundStyle(theme.secondary.color)   // 使用主题次要色
        }   // 结束加载 VStack
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 撑满可用区域
        .background(theme.background.color.opacity(0.92))   // 覆盖近乎不透明的主题背景，遮住未完成的分页
    }   // 结束 loadingView
}   // 结束 ReaderView

// MARK: - 分页容器
// 该分组把 UIKit 的分页控件 PagePagerView 包装成 SwiftUI 视图，并由 Coordinator 把翻页/点击/边界事件回传给 ReaderViewModel。

/// SwiftUI ⇄ UIKit 桥接视图：托管 PagePagerView，并把用户手势转成 ReaderViewModel 的方法调用
private struct PagerContainer: UIViewRepresentable {   // 遵循 UIViewRepresentable，把 UIKit 视图嵌入 SwiftUI
    @ObservedObject var vm: ReaderViewModel   // 观察视图模型：分页模型变化时触发 updateUIView

    /// 创建底层 UIKit 分页视图
    /// - Parameter context: SwiftUI 提供的上下文，可取得 Coordinator
    /// - Returns: 已绑定代理与初始分页数据的 PagePagerView
    /// - 副作用：设置 pager.delegate（弱引用回调），并把当前分页模型应用到控件
    func makeUIView(context: Context) -> PagePagerView {   // 首次创建 UIKit 视图
        let pager = PagePagerView()   // 实例化底层分页控件
        pager.delegate = context.coordinator   // 指定 Coordinator 作为翻页事件代理
        pager.apply(vm.pagerModel)   // 应用视图模型里的分页模型（页面数据、翻页模式等）
        return pager   // 返回创建好的分页控件
    }   // 结束 makeUIView

    /// SwiftUI 状态变化时把最新数据同步到底层 UIKit 视图
    /// - Parameters:
    ///   - uiView: 已存在的分页控件
    ///   - context: 上下文，用于同步 Coordinator 持有的视图模型
    /// - 副作用：把最新 vm 写回 Coordinator，并重新 apply 分页模型
    func updateUIView(_ uiView: PagePagerView, context: Context) {   // 每次 SwiftUI 刷新都会调用
        context.coordinator.vm = vm   // 让 Coordinator 始终持有最新的视图模型
        uiView.apply(vm.pagerModel)   // 把最新分页模型同步给 UIKit 控件
    }   // 结束 updateUIView

    /// 创建与 UIKit 视图配套的协调器
    /// - Returns: 持有视图模型的 Coordinator 实例
    func makeCoordinator() -> Coordinator {   // SwiftUI 调用以创建代理对象
        Coordinator(vm: vm)   // 用当前视图模型构造协调器
    }   // 结束 makeCoordinator

    /// 翻页事件协调器：把 PagePagerDelegate 的回调转成 ReaderViewModel 的方法调用
    final class Coordinator: NSObject, PagePagerDelegate {   // 继承 NSObject 以适配 UIKit 代理，并遵循分页代理协议
        var vm: ReaderViewModel   // 当前视图模型引用，由 updateUIView 持续刷新

        /// 构造协调器
        /// - Parameter vm: 需要接收翻页事件的视图模型
        init(vm: ReaderViewModel) {   // 指定构造器
            self.vm = vm   // 保存视图模型引用
        }   // 结束 init

        /// 用户完成一次翻页
        /// - Parameters:
        ///   - pager: 触发事件的控件
        ///   - direction: 翻页方向
        /// - 副作用：交给视图模型更新当前页，进而刷新页脚与工具栏
        func pager(_ pager: PagePagerView, didTurn direction: PageTurnDirection) {   // 代理：翻页完成
            vm.handleTurn(direction)   // 交给视图模型处理翻页（更新页码与进度）
        }   // 结束 pager(_:didTurn:)

        /// 用户点击了页面中部
        /// - Parameter pager: 触发事件的控件
        /// - 副作用：以动画切换阅读工具栏显隐
        func pagerDidTapCenter(_ pager: PagePagerView) {   // 代理：点击内容区中央
            withAnimation(.easeInOut(duration: 0.2)) {   // 用 0.2s 缓动动画包裹状态修改
                vm.showChrome.toggle()   // 切换工具栏显隐
            }   // 结束 withAnimation
        }   // 结束 pagerDidTapCenter

        /// 用户翻到章节或内容的边界
        /// - Parameters:
        ///   - pager: 触发事件的控件
        ///   - direction: 边界方向
        /// - 副作用：由视图模型决定是否跨章或给出提示
        func pagerDidReachBoundary(_ pager: PagePagerView, direction: PageTurnDirection) {   // 代理：到达边界
            vm.handleBoundaryReached(direction)   // 交给视图模型处理边界逻辑（如加载下一章）
        }   // 结束 pagerDidReachBoundary
    }   // 结束 Coordinator
}   // 结束 PagerContainer

// MARK: - 状态栏（时间 / 网络 / 电量）
// 该分组实现 safeAreaInset 顶部插入的自定义状态栏：时间由 TimelineView 定期刷新，网络来自 NetworkMonitor，电量靠 UIDevice 通知驱动刷新。

/// 自定义状态栏：左侧时间、中间书名、右侧网络与电量
struct ReaderStatusBar: View {   // 声明状态栏视图
    let theme: ReaderTheme   // 主题，用于取次要色
    let bookTitle: String   // 书名，居中展示

    @ObservedObject private var network = NetworkMonitor.shared   // 观察全局网络监听单例，网络变化时刷新图标与文案
    @State private var batteryRefresh = 0   // 电量刷新计数器：仅用于触发视图重算（数值本身不参与渲染）

    /// 时间格式化器：HH:mm，进程内复用避免重复创建
    private static let timeFormatter: DateFormatter = {   // 静态初始化块，进程内只执行一次
        let formatter = DateFormatter()   // 创建日期格式化器
        formatter.locale = Locale.current   // 使用当前设备区域设置
        formatter.dateFormat = "HH:mm"   // 输出 24 小时制时分
        return formatter   // 返回配置好的格式化器
    }()   // 闭包立即执行完成初始化

    /// 视图主体：横向排列时间、书名、网络与电量
    var body: some View {   // 状态栏视图树
        HStack(spacing: 8) {   // 横向布局，间距 8
            TimelineView(.periodic(from: .now, by: 20)) { context in   // 每 20 秒刷新一次时间，降低刷新频率以省电
                Text(Self.timeFormatter.string(from: context.date))   // 用当前时间点格式化出 HH:mm
                    .font(.system(size: 13, weight: .semibold, design: .rounded))   // 13pt 半粗圆体
            }   // 结束 TimelineView

            Spacer(minLength: 8)   // 时间与书名之间的弹性留白

            Text(bookTitle)   // 居中显示书名
                .font(.system(size: 11))   // 字号 11
                .lineLimit(1)   // 最多一行
                .truncationMode(.middle)   // 过长时中间省略
                .opacity(0.65)   // 降低不透明度，弱化视觉权重
                .frame(maxWidth: .infinity, alignment: .center)   // 占满中间区域并居中对齐

            HStack(spacing: 4) {   // 网络状态图标 + 文案
                Image(systemName: network.symbolName)   // 根据网络类型显示对应 SF Symbol
                    .font(.system(size: 11, weight: .semibold))   // 图标字号 11 半粗
                Text(network.label)   // 网络类型文案（Wi-Fi / 5G / 无网络等）
                    .font(.system(size: 10, weight: .medium))   // 字号 10 中等字重
            }   // 结束网络状态 HStack

            batteryView   // 电量图标与百分比
        }   // 结束状态栏 HStack
        .foregroundStyle(theme.secondary.color)   // 整体使用主题次要色
        .accessibilityHidden(true)   // 状态栏为装饰性信息，对辅助功能隐藏
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in   // 订阅电量变化通知
            batteryRefresh += 1   // 自增计数以触发视图刷新
        }   // 结束电量变化监听
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in   // 订阅充电状态变化通知
            batteryRefresh += 1   // 自增计数以触发视图刷新（充电图标随之更新）
        }   // 结束充电状态监听
        .onAppear {   // 状态栏出现
            UIDevice.current.isBatteryMonitoringEnabled = true   // 开启电量监听
            network.start()   // 启动网络监听（内部引用计数，重复调用安全）
        }   // 结束 onAppear
        .onDisappear {   // 状态栏消失
            network.stop()   // 停止网络监听
            UIDevice.current.isBatteryMonitoringEnabled = false   // 关闭电量监听，节省资源
        }   // 结束 onDisappear
    }   // 结束 body

    /// 电量展示视图：充电时叠加闪电图标，并显示百分比
    /// - 返回值：由闪电（可选）、电池图标与百分比组成的视图
    private var batteryView: some View {   // 计算属性：电量区域
        HStack(spacing: 3) {   // 横向排列，间距 3
            if UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full {   // 正在充电或已充满
                Image(systemName: "bolt.fill")   // 叠加闪电图标表示充电中
                    .font(.system(size: 8, weight: .bold))   // 小号粗体，避免喧宾夺主
            }   // 结束充电图标条件块
            Image(systemName: batterySymbol)   // 按电量档位显示的电池图标
                .font(.system(size: 12, weight: .regular))   // 电池图标字号 12
            if batteryPercent >= 0 {   // 电量未知（如模拟器）时不显示百分比
                Text("\(batteryPercent)%")   // 显示电量百分比
                    .font(.system(size: 10, weight: .medium))   // 字号 10 中等字重
            }   // 结束百分比条件块
        }   // 结束电量 HStack
    }   // 结束 batteryView

    /// 当前电量百分比
    /// - Returns: 0…100 的整数；电量不可用时返回 -1 作为哨兵值
    private var batteryPercent: Int {   // 计算属性：电量百分比
        let level = UIDevice.current.batteryLevel   // 读取原始电量（0…1，未知为 -1）
        guard level >= 0 else { return -1 }   // 未知电量直接返回 -1
        return Int((level * 100).rounded())   // 换算并四舍五入为整数百分比
    }   // 结束 batteryPercent

    /// 电池图标名
    /// - Returns: 对应电量档位的 SF Symbol 名称
    private var batterySymbol: String {   // 计算属性：电池图标名
        let percent = batteryPercent   // 取当前百分比
        switch percent {   // 按区间映射到系统电池图标
        case ..<0: return "battery.0percent"   // 电量未知时也显示空电池
        case 0..<13: return "battery.0percent"   // 0–12%
        case 13..<38: return "battery.25percent"   // 13–37%
        case 38..<63: return "battery.50percent"   // 38–62%
        case 63..<88: return "battery.75percent"   // 63–87%
        default: return "battery.100percent"   // 88% 及以上
        }   // 结束 switch
    }   // 结束 batterySymbol
}   // 结束 ReaderStatusBar
