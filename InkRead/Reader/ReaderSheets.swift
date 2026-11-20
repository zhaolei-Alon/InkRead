//
//  ReaderSheets.swift
//  墨读 InkRead —— 阅读器三个面板：阅读设置 / 目录 / 书签
//
//  职责：
//    · ReaderSettingsSheet：3 套样式模板、背景与主题（含自定义取色）、字体与排版、
//      翻页方式、亮度与常亮开关、恢复默认设置
//    · ReaderTOCSheet：列出 vm.chapters，点击调用 vm.jumpToChapter 后关闭面板
//    · ReaderBookmarksSheet：列出 BookmarkStore 中本书书签，点击调用 vm.jumpToBookmark，
//      支持侧滑删除并同步阅读页书签状态
//  上层调用者：ReaderView（通过 .sheet(isPresented: $vm.showSettings / showTOC / showBookmarks) 挂载）
//  下层依赖：ReaderSettingsStore / ReaderSettings / ReaderStylePreset / ReaderTheme / ReaderFont /
//            PageTurnMode / CodableColor；ReaderViewModel / Bookmark / BookmarkStore
//  关键流程：设置面板每个控件直接写 store.settings（或子结构），ReaderViewModel 的 theme/typography
//            计算属性据此刷新阅读页；目录与书签面板通过 vm 的跳转方法驱动 PagerContainer 换页。
//

import SwiftUI   // 引入 SwiftUI：本文件所有面板均由该框架的视图与修饰符构建
import UIKit     // 引入 UIKit：需要 UIColor / UIScreen 处理取色与系统亮度

// MARK: - 阅读设置
// 该分组实现阅读设置面板：分区卡片式布局，全部状态最终落到 ReaderSettingsStore.settings。

/// 阅读设置面板：集中调校模板、主题、排版、翻页方式与亮度
struct ReaderSettingsSheet: View {   // 声明设置面板视图
    @ObservedObject var store: ReaderSettingsStore   // 观察设置存储，任何字段变化都会驱动面板重绘
    @Environment(\.dismiss) private var dismiss   // 读取环境中的 dismiss 动作，用于关闭面板

    @State private var customBackground: Color   // 自定义背景色的取色器本地状态
    @State private var customText: Color   // 自定义文字色的取色器本地状态

    /// 构造设置面板
    /// - Parameter store: 阅读设置存储（面板内所有修改都会写回该 store）
    /// - 副作用：用 store 中已有的自定义主题色初始化两个取色器的本地状态
    init(store: ReaderSettingsStore) {   // 自定义构造器：接收设置存储
        _store = ObservedObject(wrappedValue: store)   // 用 ObservedObject 包装外部传入的 store
        let custom = store.settings.customTheme   // 取出当前自定义主题，作为取色器初值
        _customBackground = State(initialValue: Color(   // 初始化背景色取色器状态
            red: custom.background.red, green: custom.background.green,   // 红色与绿色分量
            blue: custom.background.blue   // 蓝色分量
        ))   // 结束背景色初始 State
        _customText = State(initialValue: Color(   // 初始化文字色取色器状态
            red: custom.text.red, green: custom.text.green, blue: custom.text.blue   // 文字色的 RGB 分量
        ))   // 结束文字色初始 State
    }   // 结束 init

    /// 当前设置快照，便于各分区直接读取
    private var settings: ReaderSettings { store.settings }   // 透传 store 中的设置对象

    /// 视图主体：导航栈 + 可滚动分区列表
    var body: some View {   // 设置面板视图树入口
        NavigationStack {   // 用导航栈提供标题与「完成」按钮
            ScrollView {   // 整页可滚动
                VStack(alignment: .leading, spacing: 16) {   // 纵向堆叠各设置分区，间距 16
                    presetSection   // 一键样式模板区
                    themeSection   // 背景与主题区
                    typographySection   // 字体与排版区
                    turnModeSection   // 翻页方式区
                    brightnessSection   // 亮度区
                    resetSection   // 恢复默认设置区
                }   // 结束分区 VStack
                .padding(18)   // 内容整体内边距 18
            }   // 结束 ScrollView
            .background(Color(.systemGroupedBackground))   // 使用系统分组背景色
            .navigationTitle("阅读设置")   // 导航标题
            .navigationBarTitleDisplayMode(.inline)   // 标题使用行内小标题样式
            .toolbar {   // 配置导航栏按钮
                ToolbarItem(placement: .confirmationAction) {   // 右上角确认位
                    Button("完成") { dismiss() }   // 点击关闭面板
                }   // 结束 ToolbarItem
            }   // 结束 toolbar
        }   // 结束 NavigationStack
        .presentationDetents([.large])   // 以全高卡片形式呈现
        .presentationDragIndicator(.visible)   // 显示顶部拖拽指示条
    }   // 结束 body

    // MARK: 一键模板
    // 该分区展示 ReaderStylePreset.all 三套模板，点击后由 store.apply 一次性写入排版与主题。

    /// 快速样式模板分区
    /// - 返回值：横向排列的模板卡片列表
    private var presetSection: some View {   // 计算属性：模板分区
        card {   // 套用通用卡片容器（圆角、系统分组背景）
            sectionTitle("快速样式模板")   // 分区标题
            HStack(spacing: 10) {   // 横向排列各模板按钮
                ForEach(ReaderStylePreset.all) { preset in   // 遍历全部内置模板
                    let active = settings.typography == preset.typography &&   // 排版与模板一致
                        settings.themeID == preset.themeID   // 且主题也一致 → 视为选中态
                    Button {   // 模板按钮
                        store.apply(preset)   // 应用模板（同时写入排版与主题）
                        syncCustomColors()   // 同步自定义取色器，避免切换后颜色显示过期
                    } label: {   // 按钮外观
                        VStack(alignment: .leading, spacing: 8) {   // 模板卡片内部纵向布局
                            HStack {   // 顶部：示例字与选中对勾
                                Text("Aa")   // 模板示例字
                                    .font(.system(size: 18, weight: .semibold))   // 18pt 半粗
                                Spacer()   // 把对勾推到右侧
                                if active {   // 当前模板被选中
                                    Image(systemName: "checkmark.circle.fill")   // 显示实心对勾
                                        .font(.system(size: 13))   // 对勾字号 13
                                }   // 结束选中对勾条件块
                            }   // 结束顶部 HStack
                            VStack(alignment: .leading, spacing: 2) {   // 模板名称与副标题
                                Text(preset.name)   // 模板名称
                                    .font(.system(size: 13, weight: .semibold))   // 13pt 半粗
                                Text(preset.subtitle)   // 模板副标题（如「宋体 · 宽松」）
                                    .font(.system(size: 9))   // 字号 9
                                    .opacity(0.7)   // 弱化显示
                                    .lineLimit(1)   // 最多一行
                            }   // 结束名称/副标题 VStack
                        }   // 结束模板卡片 VStack
                        .padding(10)   // 卡片内边距 10
                        .frame(maxWidth: .infinity, alignment: .leading)   // 撑满可用宽度并左对齐
                        .foregroundStyle(theme(for: preset.themeID).text.color)   // 文字色取该模板主题的正文色
                        .background(   // 卡片背景
                            RoundedRectangle(cornerRadius: 12)   // 12 圆角矩形
                                .fill(theme(for: preset.themeID).background.color)   // 用该模板主题背景色填充
                        )   // 结束卡片背景
                        .overlay(   // 叠加描边以表达选中态
                            RoundedRectangle(cornerRadius: 12)   // 与背景同圆角的描边层
                                .stroke(active ? Color.accentColor : Color.black.opacity(0.06), lineWidth: active ? 1.6 : 0.6)   // 选中用强调色粗描边，否则用极淡细描边
                        )   // 结束 overlay
                    }   // 结束 label 构建器
                    .buttonStyle(.plain)   // 使用无样式按钮，保持自定义外观
                }   // 结束 ForEach
            }   // 结束模板 HStack
        }   // 结束卡片容器
    }   // 结束 presetSection

    // MARK: 背景主题
    // 该分区列出 ReaderTheme.presets 与「自定义」色卡；选中自定义时额外显示两个 ColorPicker，实时改写 customTheme。

    /// 背景与主题分区
    /// - 返回值：主题色卡行 + 自定义取色行（条件显示）
    private var themeSection: some View {   // 计算属性：主题分区
        card {   // 卡片容器
            sectionTitle("背景与主题")   // 分区标题
            HStack(spacing: 10) {   // 横向排列色卡
                ForEach(ReaderTheme.presets) { preset in   // 遍历内置主题
                    themeChip(id: preset.id, name: preset.name, theme: preset)   // 单个主题色卡
                }   // 结束 ForEach
                themeChip(id: ReaderTheme.customID, name: "自定义", theme: settings.customTheme)   // 自定义主题色卡（预览当前自定义配色）
            }   // 结束色卡 HStack

            if settings.themeID == ReaderTheme.customID {   // 仅当选中「自定义」时展示取色器
                HStack(spacing: 18) {   // 两个取色器横向排列
                    ColorPicker("背景色", selection: $customBackground, supportsOpacity: false)   // 自定义背景色取色器
                        .onChange(of: customBackground) { _, newValue in   // 背景色变化回调
                            store.settings.customTheme.background = CodableColor(newValue)   // 写回可编码背景色
                            store.settings.customTheme.isDark = luminance(of: newValue) < 0.5   // 按亮度自动判定明暗主题
                            refreshCustomSecondary()   // 重算次要色，保证与背景有合理对比
                        }   // 结束背景色 onChange
                    ColorPicker("文字色", selection: $customText, supportsOpacity: false)   // 自定义文字色取色器
                        .onChange(of: customText) { _, newValue in   // 文字色变化回调
                            store.settings.customTheme.text = CodableColor(newValue)   // 写回可编码文字色
                            store.settings.themeID = ReaderTheme.customID   // 确保当前主题停留在自定义
                            refreshCustomSecondary()   // 重算次要色（由文字色与背景色插值得到）
                        }   // 结束文字色 onChange
                }   // 结束取色器 HStack
                .font(.system(size: 13))   // 取色器标签字号 13
            }   // 结束自定义取色条件块
        }   // 结束卡片容器
    }   // 结束 themeSection

    /// 生成单个主题色卡按钮
    /// - Parameters:
    ///   - id: 主题标识（用于判断选中态与写回 themeID）
    ///   - name: 色卡下方显示的名称
    ///   - theme: 用于预览的背景色/文字色
    /// - Returns: 圆形预览 + 名称的按钮视图
    /// - 副作用：点击后写入 store.settings.themeID（自定义分支还会同步取色器）
    private func themeChip(id: String, name: String, theme: ReaderTheme) -> some View {   // 返回不透明视图的私有方法
        let active = settings.themeID == id   // 当前主题是否等于该色卡
        return Button {   // 构造色卡按钮并直接返回
            if id == ReaderTheme.customID {   // 点击的是「自定义」色卡
                store.settings.themeID = ReaderTheme.customID   // 切到自定义主题
                syncCustomColors()   // 用 store 中的自定义色刷新取色器
            } else {   // 点击的是内置主题
                store.settings.themeID = id   // 仅更新主题标识
            }   // 结束点击分支
        } label: {   // 按钮外观
            VStack(spacing: 6) {   // 圆形预览与名称纵向排列
                ZStack {   // 用 ZStack 把示例字叠在圆形背景上
                    Circle()   // 圆形预览底
                        .fill(theme.background.color)   // 填充该主题背景色
                    Text("Aa")   // 示例字
                        .font(.system(size: 14, weight: .semibold))   // 14pt 半粗
                        .foregroundStyle(theme.text.color)   // 使用该主题正文色
                }   // 结束 ZStack
                .frame(width: 42, height: 42)   // 圆形尺寸 42×42
                .overlay(Circle().stroke(active ? Color.accentColor : Color.black.opacity(0.08), lineWidth: active ? 2 : 0.6))   // 选中时强调色粗描边，否则极淡细描边
                Text(name)   // 色卡名称
                    .font(.system(size: 11))   // 字号 11
                    .foregroundStyle(.primary)   // 使用系统主文字色
            }   // 结束色卡 VStack
            .frame(maxWidth: .infinity)   // 让每个色卡均分宽度
        }   // 结束 label 构建器
        .buttonStyle(.plain)   // 使用无样式按钮
    }   // 结束 themeChip

    // MARK: 字体排版
    // 该分区提供 ReaderFont 切换、实时预览、四个滑杆（字号/行距/段距/页边距）与两个开关，全部写入 settings.typography 或 settings 顶层。

    /// 字体与排版分区
    /// - 返回值：字体选择、预览样板、滑杆与开关组成的卡片
    private var typographySection: some View {   // 计算属性：排版分区
        card {   // 卡片容器
            sectionTitle("字体与排版")   // 分区标题

            HStack(spacing: 8) {   // 横向排列字体选项
                ForEach(ReaderFont.all) { font in   // 遍历全部可用字体
                    let active = settings.typography.fontID == font.id   // 该字体是否为当前选中
                    Button {   // 字体按钮
                        store.settings.typography.fontID = font.id   // 切换字体
                    } label: {   // 按钮外观
                        Text(font.name)   // 字体名称
                            .font(.system(size: 13, weight: active ? .semibold : .regular))   // 选中时半粗，否则常规
                            .foregroundStyle(active ? Color.accentColor : Color.primary)   // 选中时强调色
                            .frame(maxWidth: .infinity)   // 均分宽度
                            .padding(.vertical, 8)   // 上下内边距 8
                            .background(   // 选中态背景
                                RoundedRectangle(cornerRadius: 9)   // 9 圆角矩形
                                    .fill(active ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))   // 选中淡强调色，否则系统三级填充
                            )   // 结束背景
                    }   // 结束 label 构建器
                    .buttonStyle(.plain)   // 使用无样式按钮
                }   // 结束 ForEach
            }   // 结束字体 HStack

            Text("山色空蒙雨亦奇，水光潋滟晴方好。")   // 排版实时预览样板句
                .font(Font(settings.typography.uiFont()))   // 用当前排版换算出的 UIFont 渲染
                .lineLimit(1)   // 最多一行
                .minimumScaleFactor(0.7)   // 最小可缩放到 0.7 倍，避免截断
                .frame(maxWidth: .infinity, alignment: .leading)   // 撑满宽度并左对齐
                .padding(10)   // 内边距 10
                .background(   // 预览块背景
                    RoundedRectangle(cornerRadius: 10)   // 10 圆角矩形
                        .fill(settings.theme.background.color)   // 填充当前主题背景色
                )   // 结束背景
                .foregroundStyle(settings.theme.text.color)   // 预览文字使用当前主题正文色

            sliderRow(   // 字号滑杆行
                title: "字号",   // 行标题
                leading: "A-",   // 左端提示：更小
                trailing: "A+",   // 右端提示：更大
                value: binding(get: { settings.typography.fontSize }, set: { store.settings.typography.fontSize = $0 }),   // 双向绑定字号
                range: 14...32,   // 取值范围 14–32
                step: 1,   // 步长 1pt
                display: "\(Int(settings.typography.fontSize)) pt"   // 右侧数值展示
            )   // 结束字号滑杆行

            sliderRow(   // 行间距滑杆行
                title: "行间距",   // 行标题
                leading: "紧",   // 左端提示：更紧
                trailing: "松",   // 右端提示：更松
                value: binding(get: { settings.typography.lineSpacing }, set: { store.settings.typography.lineSpacing = $0 }),   // 双向绑定行距倍数
                range: 1.0...2.4,   // 取值范围 1.0–2.4 倍
                step: 0.05,   // 步长 0.05
                display: String(format: "%.2fx", settings.typography.lineSpacing)   // 以 x 倍数格式展示
            )   // 结束行间距滑杆行

            sliderRow(   // 段间距滑杆行
                title: "段间距",   // 行标题
                leading: "小",   // 左端提示：段距更小
                trailing: "大",   // 右端提示：段距更大
                value: binding(get: { settings.typography.paragraphSpacing }, set: { store.settings.typography.paragraphSpacing = $0 }),   // 双向绑定段距倍数
                range: 0...1.2,   // 取值范围 0–1.2 倍
                step: 0.05,   // 步长 0.05
                display: String(format: "%.2fx", settings.typography.paragraphSpacing)   // 以 x 倍数格式展示
            )   // 结束段间距滑杆行

            sliderRow(   // 页边距（文字宽度）滑杆行
                title: "页边距（文字宽度）",   // 行标题
                leading: "宽",   // 左端提示：边距更大、正文更窄
                trailing: "窄",   // 右端提示：边距更小、正文更宽
                value: binding(get: { settings.typography.horizontalMargin }, set: { store.settings.typography.horizontalMargin = $0 }),   // 双向绑定水平边距
                range: 8...56,   // 取值范围 8–56
                step: 1,   // 步长 1pt
                display: "\(Int(settings.typography.horizontalMargin)) pt"   // 右侧数值展示
            )   // 结束页边距滑杆行

            Toggle("首行缩进", isOn: binding(   // 首行缩进开关
                get: { settings.typography.indentFirstLine },   // 读取当前开关值
                set: { store.settings.typography.indentFirstLine = $0 }   // 写入开关值
            ))   // 结束首行缩进绑定
            .font(.system(size: 14))   // 开关文字字号 14

            Toggle("阅读时屏幕常亮", isOn: binding(   // 屏幕常亮开关
                get: { settings.keepScreenOn },   // 读取常亮设置
                set: { store.settings.keepScreenOn = $0 }   // 写入常亮设置
            ))   // 结束常亮绑定
            .font(.system(size: 14))   // 开关文字字号 14
        }   // 结束卡片容器
    }   // 结束 typographySection

    /// 翻页方式分区
    /// - 返回值：分段选择器与操作说明组成的卡片
    /// - 副作用：选择结果写入 settings.turnMode，由视图模型驱动 PagerContainer 切换翻页效果
    private var turnModeSection: some View {   // 计算属性：翻页方式分区
        card {   // 卡片容器
            sectionTitle("翻页方式")   // 分区标题
            Picker("翻页方式", selection: binding(   // 分段选择器，双向绑定翻页模式
                get: { settings.turnMode },   // 读取当前翻页模式
                set: { store.settings.turnMode = $0 }   // 写回翻页模式
            )) {   // Picker 内容构建器
                ForEach(PageTurnMode.allCases) { mode in   // 遍历所有翻页模式
                    Text(mode.displayName).tag(mode)   // 每个模式一项，tag 用于绑定选中值
                }   // 结束 ForEach
            }   // 结束 Picker
            .pickerStyle(.segmented)   // 使用分段控件样式
            Text("点击屏幕左右两侧或上下区域翻页，也可按住页面拖动翻页。")   // 操作说明文案
                .font(.system(size: 11))   // 字号 11
                .foregroundStyle(.secondary)   // 使用次要色
        }   // 结束卡片容器
    }   // 结束 turnModeSection

    /// 亮度分区
    /// - 返回值：亮度滑杆与「跟随系统亮度」开关组成的卡片
    /// - 副作用：拖动滑杆会写入 settings.brightness 并关闭跟随系统亮度
    private var brightnessSection: some View {   // 计算属性：亮度分区
        card {   // 卡片容器
            sectionTitle("亮度")   // 分区标题
            HStack(spacing: 10) {   // 图标 - 滑杆 - 图标横向排列
                Image(systemName: "sun.min")   // 低亮度端图标
                    .font(.system(size: 12))   // 图标字号 12
                    .foregroundStyle(.secondary)   // 次要色
                Slider(value: brightnessBinding, in: 0.1...1.0)   // 亮度滑杆，范围 0.1–1.0
                Image(systemName: "sun.max.fill")   // 高亮度端图标
                    .font(.system(size: 14))   // 图标字号 14
                    .foregroundStyle(.secondary)   // 次要色
            }   // 结束亮度 HStack
            Toggle("跟随系统亮度", isOn: binding(   // 跟随系统亮度开关
                get: { settings.followSystemBrightness },   // 读取跟随状态
                set: { store.settings.followSystemBrightness = $0 }   // 写入跟随状态
            ))   // 结束跟随亮度绑定
            .font(.system(size: 14))   // 开关文字字号 14
        }   // 结束卡片容器
    }   // 结束 brightnessSection

    /// 恢复默认设置分区
    /// - 返回值：单个全宽按钮
    /// - 副作用：重置排版与亮度跟随，主题回到 paper，并同步取色器
    private var resetSection: some View {   // 计算属性：恢复默认分区
        Button {   // 恢复默认按钮
            store.resetTypography()   // 重置字体与排版为默认值
            store.settings.themeID = ReaderTheme.paper.id   // 主题恢复为「纸白」
            store.settings.followSystemBrightness = true   // 亮度恢复为跟随系统
            syncCustomColors()   // 同步取色器，避免残留旧的自定义色
        } label: {   // 按钮外观
            Text("恢复默认设置")   // 按钮文案
                .font(.system(size: 14, weight: .medium))   // 14pt 中等字重
                .frame(maxWidth: .infinity)   // 撑满宽度
                .padding(.vertical, 12)   // 上下内边距 12
                .background(   // 按钮背景
                    RoundedRectangle(cornerRadius: 12)   // 12 圆角矩形
                        .fill(Color(.secondarySystemGroupedBackground))   // 系统分组二级背景色
                )   // 结束背景
        }   // 结束 label 构建器
        .buttonStyle(.plain)   // 使用无样式按钮
        .foregroundStyle(.red.opacity(0.85))   // 文字使用偏淡的红色，提示这是重置操作
    }   // 结束 resetSection

    // MARK: 组件
    // 该分组提供面板内复用的 UI 构件与辅助函数：卡片、分区标题、滑杆行、绑定工厂、亮度绑定及颜色工具。

    /// 通用卡片容器
    /// - Parameter content: 卡片内的视图内容
    /// - Returns: 圆角、内边距与背景已配置好的容器
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {   // 泛型方法，使用 ViewBuilder 接收内容
        VStack(alignment: .leading, spacing: 14, content: content)   // 纵向堆叠卡片内容，间距 14
            .padding(16)   // 卡片内边距 16
            .background(   // 卡片背景
                RoundedRectangle(cornerRadius: 16)   // 16 圆角矩形
                    .fill(Color(.secondarySystemGroupedBackground))   // 系统分组二级背景色
            )   // 结束背景
    }   // 结束 card

    /// 分区标题文本
    /// - Parameter text: 标题文案
    /// - Returns: 小号半粗次要色文本
    private func sectionTitle(_ text: String) -> some View {   // 生成分区标题
        Text(text)   // 展示标题文案
            .font(.system(size: 13, weight: .semibold))   // 13pt 半粗
            .foregroundStyle(.secondary)   // 次要色
    }   // 结束 sectionTitle

    /// 通用滑杆行：标题 + 当前值 + 左右端点提示 + 滑杆
    /// - Parameters:
    ///   - title: 行标题
    ///   - leading: 滑杆左端（最小值侧）提示文字
    ///   - trailing: 滑杆右端（最大值侧）提示文字
    ///   - value: 与设置字段双向绑定的值
    ///   - range: 允许的取值范围
    ///   - step: 拖动步长
    ///   - display: 右上角展示的当前值文本
    /// - Returns: 两行布局的滑杆组件
    private func sliderRow(title: String, leading: String, trailing: String,   // 方法签名：标题与左右提示
                           value: Binding<Double>, range: ClosedRange<Double>, step: Double,   // 方法签名：绑定值、范围与步长
                           display: String) -> some View {   // 方法签名：展示文本，返回视图
        VStack(spacing: 4) {   // 两行内容纵向排列，间距 4
            HStack {   // 第一行：标题与当前值
                Text(title)   // 行标题
                    .font(.system(size: 14))   // 字号 14
                Spacer()   // 把当前值推到右侧
                Text(display)   // 右上角显示当前数值
                    .font(.system(size: 12))   // 字号 12
                    .foregroundStyle(.secondary)   // 次要色
            }   // 结束标题行 HStack
            HStack(spacing: 8) {   // 第二行：左提示 + 滑杆 + 右提示
                Text(leading)   // 左端提示文字
                    .font(.system(size: 11))   // 字号 11
                    .foregroundStyle(.secondary)   // 次要色
                    .frame(width: 18)   // 固定宽度 18，保证对齐
                Slider(value: value, in: range, step: step)   // 实际滑杆控件
                Text(trailing)   // 右端提示文字
                    .font(.system(size: 11))   // 字号 11
                    .foregroundStyle(.secondary)   // 次要色
                    .frame(width: 18)   // 固定宽度 18，保证对齐
            }   // 结束滑杆行 HStack
        }   // 结束滑杆行 VStack
    }   // 结束 sliderRow

    /// 手写 Binding 的便捷工厂
    /// - Parameters:
    ///   - get: 读取值的闭包
    ///   - set: 写入值的闭包
    /// - Returns: 由闭包构成的 Binding，用于绕开 $store.settings.xxx 的嵌套投影限制
    private func binding<T>(get: @escaping () -> T, set: @escaping (T) -> Void) -> Binding<T> {   // 泛型绑定构造方法
        Binding(get: get, set: set)   // 直接返回自定义 Binding
    }   // 结束 binding

    /// 亮度滑杆的绑定
    /// - 读取：跟随系统时返回 UIScreen 实际亮度，否则返回设置值
    /// - 写入：保存亮度并自动关闭「跟随系统亮度」（因为用户已手动覆盖）
    private var brightnessBinding: Binding<Double> {   // 计算属性：亮度绑定
        Binding(   // 构造自定义绑定
            get: {   // 读取分支
                settings.followSystemBrightness ? Double(UIScreen.main.brightness) : settings.brightness   // 跟随系统取实际亮度，否则取设置值
            },   // 结束 get 闭包
            set: { newValue in   // 写入分支
                store.settings.brightness = newValue   // 保存用户设定的亮度
                store.settings.followSystemBrightness = false   // 手动调整后关闭跟随系统
            }   // 结束 set 闭包
        )   // 结束 Binding 构造
    }   // 结束 brightnessBinding

    /// 按主题标识解析出主题对象，用于模板卡片取色
    /// - Parameter id: 主题标识
    /// - Returns: 自定义主题或匹配的内置主题；未匹配时回退到 .paper
    private func theme(for id: String) -> ReaderTheme {   // 辅助方法：id → ReaderTheme
        if id == ReaderTheme.customID { return settings.customTheme }   // 自定义主题直接从设置中取
        return ReaderTheme.presets.first { $0.id == id } ?? .paper   // 在内置主题中查找，找不到则回退纸白
    }   // 结束 theme(for:)

    /// 用 store 中的自定义主题色刷新两个取色器的本地状态
    /// - 副作用：会写入 @State customBackground / customText，触发面板重绘
    private func syncCustomColors() {   // 辅助方法：同步取色器状态
        let custom = store.settings.customTheme   // 取出当前自定义主题
        customBackground = Color(red: custom.background.red, green: custom.background.green, blue: custom.background.blue)   // 用背景色 RGB 重建 Color
        customText = Color(red: custom.text.red, green: custom.text.green, blue: custom.text.blue)   // 用文字色 RGB 重建 Color
    }   // 结束 syncCustomColors

    /// 根据自定义背景色与文字色插值重算次要色（用于页脚、状态栏等次要文字）
    /// - 副作用：写入 customTheme.secondary 并把 themeID 锁定为自定义
    private func refreshCustomSecondary() {   // 辅助方法：刷新自定义次要色
        let custom = store.settings.customTheme   // 取出当前自定义主题
        let bg = custom.background   // 背景色分量
        let text = custom.text   // 文字色分量
        let ratio = 0.55   // 文字色在插值中的权重（越大越接近正文色）
        store.settings.customTheme.secondary = CodableColor(   // 写入新的次要色
            red: text.red * ratio + bg.red * (1 - ratio),   // 红色分量按权重插值
            green: text.green * ratio + bg.green * (1 - ratio),   // 绿色分量按权重插值
            blue: text.blue * ratio + bg.blue * (1 - ratio)   // 蓝色分量按权重插值
        )   // 结束 CodableColor 构造
        store.settings.themeID = ReaderTheme.customID   // 确保当前主题为自定义
    }   // 结束 refreshCustomSecondary

    /// 计算颜色的相对亮度，用于判断自定义主题是否为深色
    /// - Parameter color: 待计算的 SwiftUI 颜色
    /// - Returns: 0…1 的亮度值（小于 0.5 视为深色）
    private func luminance(of color: Color) -> Double {   // 辅助方法：求亮度
        let ui = UIColor(color)   // 先把 SwiftUI Color 转成 UIColor 以读取分量
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0   // 承载 RGBA 分量的变量
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)   // 提取颜色分量（失败时保持 0）
        return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)   // 按感知权重加权求和
    }   // 结束 luminance(of:)
}   // 结束 ReaderSettingsSheet

// MARK: - 目录
// 该分组实现目录面板：用 List 展示 ReaderViewModel.chapters，并在出现时自动滚动到当前章节。

/// 目录面板：列出全部章节，点击即跳转并关闭面板
struct ReaderTOCSheet: View {   // 声明目录面板视图
    @ObservedObject var vm: ReaderViewModel   // 观察视图模型，章节与当前章节变化时刷新列表
    @Environment(\.dismiss) private var dismiss   // 读取 dismiss 动作，用于跳转后关闭面板

    /// 视图主体：导航栈 + 可滚动章节列表
    var body: some View {   // 目录面板视图树入口
        NavigationStack {   // 导航栈提供标题与「完成」按钮
            ScrollViewReader { reader in   // 拿到滚动代理，用于定位当前章节
                List {   // 章节列表
                    ForEach(vm.chapters) { chapter in   // 遍历全部章节
                        Button {   // 章节行按钮
                            vm.jumpToChapter(chapter.index)   // 请求视图模型跳转到该章节
                            dismiss()   // 关闭目录面板
                        } label: {   // 行外观
                            HStack(spacing: 10) {   // 章节名与「阅读中」标记横向排列
                                Text(chapter.title)   // 章节标题
                                    .font(.system(size: 15))   // 字号 15
                                    .foregroundStyle(chapter.index == vm.chapterIndex ? Color.accentColor : Color.primary)   // 当前章节用强调色
                                    .lineLimit(1)   // 最多一行
                                Spacer()   // 把标记推到右侧
                                if chapter.index == vm.chapterIndex {   // 该行是当前阅读章节
                                    Text("阅读中")   // 显示「阅读中」标记
                                        .font(.system(size: 10, weight: .medium))   // 字号 10 中等字重
                                        .foregroundStyle(Color.accentColor)   // 强调色
                                }   // 结束阅读中标记条件块
                            }   // 结束行 HStack
                            .padding(.vertical, 3)   // 行内上下留白 3
                        }   // 结束 label 构建器
                        .id(chapter.index)   // 以章节序号作为滚动定位 id
                    }   // 结束 ForEach
                }   // 结束 List
                .listStyle(.plain)   // 使用无分组的分明列表样式
                .onAppear {   // 列表出现时执行
                    reader.scrollTo(vm.chapterIndex, anchor: .center)   // 自动滚动到当前章节并居中
                }   // 结束 onAppear
            }   // 结束 ScrollViewReader
            .navigationTitle("目录 · \(vm.chapters.count) 章")   // 标题显示章节总数
            .navigationBarTitleDisplayMode(.inline)   // 行内小标题样式
            .toolbar {   // 配置导航栏按钮
                ToolbarItem(placement: .confirmationAction) {   // 右上角确认位
                    Button("完成") { dismiss() }   // 点击关闭面板
                }   // 结束 ToolbarItem
            }   // 结束 toolbar
        }   // 结束 NavigationStack
        .presentationDetents([.medium, .large])   // 支持半屏与全屏两档高度
        .presentationDragIndicator(.visible)   // 显示顶部拖拽指示条
    }   // 结束 body
}   // 结束 ReaderTOCSheet

// MARK: - 书签
// 该分组实现书签面板：从 BookmarkStore 读取本书书签，支持跳转与侧滑删除，并同步阅读页书签按钮状态。

/// 书签面板：展示本书书签列表，点击跳转、侧滑删除；无书签时展示空态引导
struct ReaderBookmarksSheet: View {   // 声明书签面板视图
    @ObservedObject var vm: ReaderViewModel   // 观察视图模型，书签变化时刷新列表
    @Environment(\.dismiss) private var dismiss   // 读取 dismiss 动作，用于跳转后关闭面板

    /// 本书全部书签
    /// - Returns: 按 BookmarkStore 记录的顺序返回的 [Bookmark]
    private var bookmarks: [Bookmark] {   // 计算属性：书签数组
        vm.bookmarkStore.bookmarks(for: vm.book.id)   // 按书 id 从书签存储中查询
    }   // 结束 bookmarks

    /// 视图主体：导航栈 + 空态/列表二选一
    var body: some View {   // 书签面板视图树入口
        NavigationStack {   // 导航栈提供标题与「完成」按钮
            Group {   // 用 Group 在空态与列表之间切换而不影响外层修饰符
                if bookmarks.isEmpty {   // 没有任何书签
                    VStack(spacing: 12) {   // 空态内容纵向排列
                        Image(systemName: "bookmark.slash")   // 空态图标
                            .font(.system(size: 34))   // 图标字号 34
                            .foregroundStyle(.secondary)   // 次要色
                        Text("还没有书签")   // 空态主文案
                            .font(.system(size: 15, weight: .medium))   // 字号 15 中等字重
                        Text("阅读时点击右上角书签按钮即可添加")   // 空态引导文案
                            .font(.system(size: 12))   // 字号 12
                            .foregroundStyle(.secondary)   // 次要色
                    }   // 结束空态 VStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)   // 撑满区域使其居中
                } else {   // 存在书签
                    List {   // 书签列表
                        ForEach(bookmarks) { bookmark in   // 遍历每条书签
                            Button {   // 书签行按钮
                                vm.jumpToBookmark(bookmark)   // 请求视图模型跳转到该书签位置
                                dismiss()   // 关闭书签面板
                            } label: {   // 行外观
                                VStack(alignment: .leading, spacing: 5) {   // 三行信息纵向排列
                                    Text(bookmark.chapterTitle)   // 书签所在章节标题
                                        .font(.system(size: 14, weight: .medium))   // 字号 14 中等字重
                                        .foregroundStyle(.primary)   // 主文字色
                                    Text(bookmark.snippet.isEmpty ? "（本页无内容摘要）" : bookmark.snippet)   // 内容摘要，空时给占位文案
                                        .font(.system(size: 12))   // 字号 12
                                        .foregroundStyle(.secondary)   // 次要色
                                        .lineLimit(2)   // 最多两行
                                    Text(Self.dateFormatter.string(from: bookmark.createdAt))   // 书签创建时间
                                        .font(.system(size: 10))   // 字号 10
                                        .foregroundStyle(.tertiary)   // 三级弱化色
                                }   // 结束信息 VStack
                                .padding(.vertical, 4)   // 行内上下留白 4
                            }   // 结束 label 构建器
                            .swipeActions {   // 配置侧滑操作
                                Button(role: .destructive) {   // 破坏性删除按钮
                                    vm.bookmarkStore.remove(bookmark)   // 从书签存储中删除该书签
                                    vm.updateBookmarkState()   // 同步阅读页工具栏的书签状态
                                } label: {   // 删除按钮外观
                                    Label("删除", systemImage: "trash")   // 垃圾桶图标 + 「删除」文字
                                }   // 结束 label 构建器
                            }   // 结束 swipeActions
                        }   // 结束 ForEach
                    }   // 结束 List
                    .listStyle(.plain)   // 使用无分组的分明列表样式
                }   // 结束书签列表条件块
            }   // 结束 Group
            .navigationTitle("书签")   // 导航标题
            .navigationBarTitleDisplayMode(.inline)   // 行内小标题样式
            .toolbar {   // 配置导航栏按钮
                ToolbarItem(placement: .confirmationAction) {   // 右上角确认位
                    Button("完成") { dismiss() }   // 点击关闭面板
                }   // 结束 ToolbarItem
            }   // 结束 toolbar
        }   // 结束 NavigationStack
        .presentationDetents([.medium, .large])   // 支持半屏与全屏两档高度
        .presentationDragIndicator(.visible)   // 显示顶部拖拽指示条
    }   // 结束 body

    /// 书签时间格式化器：MM-dd HH:mm，进程内复用
    private static let dateFormatter: DateFormatter = {   // 静态初始化块，只执行一次
        let formatter = DateFormatter()   // 创建日期格式化器
        formatter.dateFormat = "MM-dd HH:mm"   // 输出「月-日 时:分」
        return formatter   // 返回配置好的格式化器
    }()   // 闭包立即执行完成初始化
}   // 结束 ReaderBookmarksSheet
