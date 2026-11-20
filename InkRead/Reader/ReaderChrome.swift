//
//  ReaderChrome.swift
//  墨读 InkRead —— 阅读器呼出菜单（顶栏 + 底部进度与工具条）
//
//  职责：
//    · 顶栏：返回按钮、书名/章节名、书签开关
//    · 中部：透明遮罩层，点击空白处收起菜单
//    · 底栏：全书进度滑杆（ReaderProgressSlider）+ 目录/书签/设置入口
//  上层调用者：ReaderView 在 vm.showChrome 为 true 时以 ZStack 叠加本视图，并传入 onClose（dismiss）
//  下层依赖： ReaderViewModel（title、chapterTitle、isBookmarked、toggleBookmark、bookProgress、
//             bookProgressPercentText、jump(toProgress:)、showTOC/showBookmarks/showSettings/showChrome）；
//             ReaderTheme 提供 background / text / secondary 颜色
//  关键流程： 点击中央（PagePagerView → delegate → vm.showChrome 切换）显示本菜单，
//             菜单内的操作直接写回 ReaderViewModel，再由 @Published 驱动 ReaderSheets / 翻页刷新
//
import SwiftUI // 引入 SwiftUI：VStack/HStack、Button、Slider、动画与 @ObservedObject 等

/// 阅读器呼出菜单：覆盖在翻页视图之上的一整套「顶栏 + 底部工具」界面
/// 本身不持有阅读状态，所有数据与操作都通过 vm 转发到 ReaderViewModel
struct ReaderChrome: View { // 呼出菜单视图：顶栏 + 中部遮罩 + 底栏
    @ObservedObject var vm: ReaderViewModel // 观察阅读视图模型，其 @Published 变化会触发布局刷新
    let theme: ReaderTheme // 当前主题，用于统一的背景色、文字色与次级文字色
    let onClose: () -> Void // 关闭阅读页的回调，由 ReaderView 传入 dismiss（退出整个阅读界面）

    /// 视图主体：自上而下为顶栏、可点击空白区、底栏
    /// 外层 VStack 占满全屏，配合 ReaderView 的 transition(.opacity) 淡入淡出
    var body: some View { // 菜单主体布局
        VStack(spacing: 0) { // 三段式纵向布局，段间无额外间距
            HStack(spacing: 12) { // 顶栏：返回 + 标题信息 + 书签按钮
                Button(action: onClose) { // 返回按钮，动作即关闭阅读页
                    Image(systemName: "chevron.left") // 左侧 chevron 图标
                        .font(.system(size: 18, weight: .semibold)) // 图标字号 18、半粗
                        .frame(width: 34, height: 34) // 固定点击区域尺寸，保证触控目标足够大
                        .contentShape(Rectangle()) // 把透明的 frame 区域也纳入点击热区
                } // 结束返回按钮 label
                .buttonStyle(.plain) // 去掉系统按钮高亮样式，保持自绘观感

                VStack(alignment: .leading, spacing: 2) { // 标题区：书名 + 章节名两行
                    Text(vm.title) // 显示书名（来自 ReaderViewModel.title = book.title）
                        .font(.system(size: 15, weight: .semibold)) // 书名 15 号半粗
                        .lineLimit(1) // 只显示一行，超出截断
                    Text(vm.chapterTitle) // 显示当前章节名（ReaderViewModel.chapterTitle）
                        .font(.system(size: 11)) // 章节名 11 号常规
                        .foregroundStyle(theme.secondary.color) // 使用主题次级色，弱化视觉层级
                        .lineLimit(1) // 单行显示
                } // 结束标题 VStack

                Spacer(minLength: 8) // 弹性占位，把书签按钮推到右侧，最小保留 8pt 间隔

                Button { // 书签开关按钮（无参 action 形式）
                    vm.toggleBookmark() // 切换当前页书签，写入 BookmarkStore 并更新 isBookmarked
                } label: { // 按钮内容
                    Image(systemName: vm.isBookmarked ? "bookmark.fill" : "bookmark") // 已加书签显示实心图标
                        .font(.system(size: 17, weight: .medium)) // 图标 17 号中等字重
                        .frame(width: 36, height: 34) // 固定点击区域
                        .contentShape(Rectangle()) // 扩大点击热区到整个 frame
                } // 结束书签按钮 label
                .buttonStyle(.plain) // 同样去掉系统按钮样式
            } // 结束顶栏 HStack
            .foregroundStyle(theme.text.color) // 顶栏文字/图标统一使用主题正文色
            .padding(.horizontal, 12) // 左右内边距 12pt
            .frame(height: 54) // 顶栏固定高度 54pt，与整体阅读布局约定一致
            .background(theme.background.color) // 顶栏底色与页面背景一致，避免色块断层
            .overlay(alignment: .bottom) { // 底边叠加一条细分隔线
                Rectangle() // 纯色矩形作为分隔线
                    .fill(theme.secondary.color.opacity(0.18)) // 次级色 18% 透明度，弱对比
                    .frame(height: 0.5) // 0.5pt 细线，接近系统 hairline
            } // 结束顶栏分隔线 overlay

            Color.clear // 全透明占位，占据顶栏与底栏之间的剩余空间
                .contentShape(Rectangle()) // 透明视图默认不响应点击，这里显式声明矩形热区
                .onTapGesture { // 点击空白区域收起菜单
                    withAnimation(.easeInOut(duration: 0.2)) { vm.showChrome = false } // 以 0.2s 缓动动画隐藏菜单
                } // 结束点击手势

            VStack(spacing: 14) { // 底栏容器：进度滑杆 + 工具按钮行
                ReaderProgressSlider(vm: vm, theme: theme) // 全书进度滑杆，拖动松手后调用 vm.jump(toProgress:)

                HStack(spacing: 0) { // 三个工具按钮等宽排列
                    toolButton("目录", icon: "list.bullet.rectangle") { vm.showTOC = true } // 打开目录弹层（ReaderSheets）
                    toolButton("书签", icon: "bookmark") { vm.showBookmarks = true } // 打开书签列表弹层
                    toolButton("设置", icon: "textformat.size") { vm.showSettings = true } // 打开排版/主题设置弹层
                } // 结束工具按钮行
            } // 结束底栏 VStack
            .padding(.horizontal, 20) // 底栏左右内边距 20pt
            .padding(.top, 14) // 顶部内边距 14pt，与滑杆留白
            .padding(.bottom, 12) // 底部内边距 12pt
            .background(theme.background.color) // 底栏底色与页面背景一致
            .overlay(alignment: .top) { // 顶边叠加一条细分隔线
                Rectangle() // 分隔线矩形
                    .fill(theme.secondary.color.opacity(0.18)) // 次级色 18% 透明度
                    .frame(height: 0.5) // hairline 高度
            } // 结束底栏分隔线 overlay
        } // 结束外层 VStack
        .foregroundStyle(theme.text.color) // 整个菜单默认文字色统一为主题正文色
    } // 结束 body

    /// 构造一个「图标 + 文案」的底部工具按钮
    /// - Parameters:
    ///   - title: 按钮下方文案（目录 / 书签 / 设置）
    ///   - icon: SF Symbols 图标名
    ///   - action: 点击回调，通常用于把 vm.showXXX 置 true 以弹出对应面板
    /// - Returns: 等宽排列的按钮视图
    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View { // 构建底部工具按钮
        Button(action: action) { // 绑定外部传入的动作
            VStack(spacing: 6) { // 图标在上、文字在下
                Image(systemName: icon) // SF Symbols 图标
                    .font(.system(size: 19, weight: .regular)) // 图标 19 号常规字重
                Text(title) // 按钮文案
                    .font(.system(size: 11)) // 文案 11 号
            } // 结束图标+文字 VStack
            .frame(maxWidth: .infinity) // 宽度撑满，三个按钮均分整行
            .padding(.vertical, 4) // 上下各留 4pt，增加可点高度
            .contentShape(Rectangle()) // 整块区域可点击
        } // 结束按钮 label
        .buttonStyle(.plain) // 去掉系统按钮样式
        .foregroundStyle(theme.text.color.opacity(0.9)) // 略降透明度的正文色，与主标题区分
    } // 结束 toolButton(_:icon:action:)
} // 结束 ReaderChrome 结构体

/// 底栏的全书进度滑杆（私有子视图，仅在本文件内使用）
/// 拖动期间以本地 @State 暂存数值，松手时才真正跳转，避免连续触发重新分页
private struct ReaderProgressSlider: View { // 全书进度滑杆子视图
    @ObservedObject var vm: ReaderViewModel // 用于读取进度文本并执行跳转
    let theme: ReaderTheme // 主题配色

    @State private var value: Double = 0 // 滑杆当前值（0...1），拖动时由用户控制
    @State private var isEditing = false // 是否正在拖动；为 true 时忽略外部进度回流，防止滑杆跳动

    /// 视图主体：标题行 + 滑杆
    var body: some View { // 滑杆主体布局
        VStack(spacing: 2) { // 标题与滑杆纵向排列，间距 2pt
            HStack { // 左右两端文字
                Text("全书进度") // 左侧说明文案
                    .font(.system(size: 11)) // 11 号字号
                    .foregroundStyle(theme.secondary.color) // 次级色
                Spacer() // 弹性占位，把百分比推到右侧
                Text(vm.bookProgressPercentText) // 右侧百分比文本（如 "42.7%"）
                    .font(.system(size: 11, weight: .medium)) // 11 号中等字重
                    .foregroundStyle(theme.secondary.color) // 次级色
            } // 结束标题行 HStack
            Slider(value: $value, in: 0...1) { editing in // 0~1 的进度滑杆，回调参数表示是否处于拖动中
                isEditing = editing // 同步拖动状态，供 onChange 判断是否回流外部值
                if !editing { // 拖动结束（松手）时
                    vm.jump(toProgress: value) // 按比例跳转到全书对应位置（内部会重新定位章节与页）
                } // 结束松手判断
            } // 结束 Slider 构造
            .tint(theme.text.color.opacity(0.65)) // 滑杆主色使用正文色 65% 透明度
        } // 结束外层 VStack
        .onAppear { value = vm.bookProgress } // 首次出现时用模型进度初始化滑杆
        .onChange(of: vm.bookProgress) { _, newValue in // 观察模型进度变化（翻页、跳转后都会更新）
            if !isEditing { value = newValue } // 非拖动状态下同步滑杆，拖动时不打断用户操作
        } // 结束 onChange 监听
    } // 结束 body
} // 结束 ReaderProgressSlider 结构体
