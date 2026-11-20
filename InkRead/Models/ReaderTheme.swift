//
//  ReaderTheme.swift
//  墨读 InkRead —— 阅读外观模型层，定义颜色、主题、字体、排版参数与设置持久化
//
//  职责：
//    · 提供 Color(hex:) 便利构造，以及可 JSON 持久化的颜色 CodableColor
//    · 定义阅读主题 ReaderTheme（纸张 / 护眼 / 暗夜 / 自定义）及其预设颜色
//    · 定义字体 ReaderFont、排版参数 ReaderTypography（含分页缓存签名）
//    · 定义翻页方式 PageTurnMode、阅读设置 ReaderSettings、一键样式模板 ReaderStylePreset
//    · 实现设置的持久化仓库 ReaderSettingsStore（UserDefaults + JSON）
//  上层调用者：InkReadApp（创建 ReaderSettingsStore 注入环境）、LibraryView / ReaderSheets（读写设置、选主题与字体）、
//              ReaderViewModel（读取 typography / theme 生成分页参数与绘制样式）、PagePagerView（按 turnMode 决定滚动方向）、
//              PaginationEngine（用 ReaderTypography.signature 作为缓存键）
//  下层依赖：SwiftUI（Color、View 相关）、UIKit（UIColor、UIFont）、Foundation（UserDefaults、JSON 编解码）
//  关键流程：ReaderSheets 修改 UserDefaults 中的 ReaderSettings → @Published didSet 自动 save() →
//           ReaderViewModel 观察到变化后重新分页，PagePagerView 的 CoreText 绘制读取 ReaderTheme 与 ReaderFont
//

import SwiftUI // 引入 SwiftUI，提供 Color、View 相关类型
import UIKit // 引入 UIKit，提供 UIColor、UIFont 等跨层字体/颜色桥接

// MARK: - 颜色工具
// 该块提供从十六进制数值构造 Color / UIColor 的通道，ReaderTheme 的预设色与 CodableColor 均复用此处逻辑。

/// 为 SwiftUI Color 增加十六进制初始化入口。
/// 调用者：AppTheme（InkReadApp.swift）以及本文件 CodableColor 的便捷构造。
extension Color { // 扩展 SwiftUI 的 Color 类型
    /// 用十六进制颜色值（0xRRGGBB）构造 Color。
    /// - Parameters:
    ///   - hex: 24 位 RGB 数值，例如 0xF6F0E1。
    ///   - opacity: 不透明度，默认 1（完全不透明）。
    init(hex: UInt32, opacity: Double = 1) { // 定义十六进制构造器
        self.init( // 转调系统 sRGB 构造器
            .sRGB, // 指定使用 sRGB 色彩空间
            red: Double((hex >> 16) & 0xFF) / 255, // 取高 8 位作为红色分量并归一化
            green: Double((hex >> 8) & 0xFF) / 255, // 取中间 8 位作为绿色分量并归一化
            blue: Double(hex & 0xFF) / 255, // 取低 8 位作为蓝色分量并归一化
            opacity: opacity // 透明度直接透传
        ) // 结束 sRGB 构造参数
    } // 结束 init(hex:opacity:)
} // 结束 Color 扩展

/// Codable 颜色，便于主题持久化。
/// 以 CGFloat/Double 四通道存储，避免 Color 本身不可编码的问题；
/// 由 ReaderSheets 的颜色选择器写入，最终随 ReaderSettings 存进 UserDefaults。
struct CodableColor: Codable, Hashable { // 声明可编解码的颜色值对象
    var red: Double // 红色分量（0 ~ 1）
    var green: Double // 绿色分量（0 ~ 1）
    var blue: Double // 蓝色分量（0 ~ 1）
    var alpha: Double // 透明度（0 ~ 1）

    /// 逐通道构造。
    /// - Parameters:
    ///   - red: 红色分量（0 ~ 1）。
    ///   - green: 绿色分量（0 ~ 1）。
    ///   - blue: 蓝色分量（0 ~ 1）。
    ///   - alpha: 透明度，默认 1。
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) { // 定义逐通道构造器
        self.red = red // 写入红色分量
        self.green = green // 写入绿色分量
        self.blue = blue // 写入蓝色分量
        self.alpha = alpha // 写入透明度
    } // 结束逐通道构造器

    /// 用十六进制颜色值构造。
    /// - Parameters:
    ///   - hex: 24 位 RGB 数值。
    ///   - alpha: 透明度，默认 1。
    init(hex: UInt32, alpha: Double = 1) { // 定义十六进制构造器
        self.init( // 转调逐通道构造器
            red: Double((hex >> 16) & 0xFF) / 255, // 解析红色分量
            green: Double((hex >> 8) & 0xFF) / 255, // 解析绿色分量
            blue: Double(hex & 0xFF) / 255, // 解析蓝色分量
            alpha: alpha // 透传透明度
        ) // 结束逐通道构造参数
    } // 结束 init(hex:alpha:)

    /// 从 SwiftUI Color 反解出四通道数值。
    /// 说明：ReaderSheets 的自定义主题取色后用它回写；取色失败时退化为黑色。
    /// - Parameter color: 待转换的 SwiftUI 颜色。
    init(_ color: Color) { // 定义从 Color 转换的构造器
        let ui = UIColor(color) // 先桥接为 UIColor 以便读取通道分量
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0 // 准备四个输出参数变量
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) { // 尝试读取 sRGB 通道分量
            self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a)) // 读取成功则按真实分量构造
        } else { // 取色失败（如非 RGB 色彩空间）时走兜底
            self.init(red: 0, green: 0, blue: 0) // 兜底为不透明黑色
        } // 结束 if-else 分支
    } // 结束 init(_ color:)

    /// 转为 SwiftUI Color，供视图层直接使用。
    var color: Color { Color(red: red, green: green, blue: blue, opacity: alpha) } // 用四通道构造 SwiftUI 颜色
    /// 转为 UIColor，供 CoreText / UIKit 绘制使用。
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) } // 用四通道构造 UIKit 颜色
} // 结束 CodableColor 结构体

// MARK: - 主题
// 该块定义阅读背景配色方案；ReaderSheets 的主题选择器与 ReaderViewModel 的绘制参数都从这里取值。

/// 阅读主题：背景色、正文色、次要文字色与暗色标记。
/// ReaderSettings.theme 依据 themeID 返回对应实例，ReaderViewModel / PagePagerView 用其渲染页面与工具栏。
struct ReaderTheme: Codable, Hashable, Identifiable { // 声明阅读主题结构体
    var id: String // 主题标识，同时作为 Identifiable 主键
    var name: String // 主题显示名（羊皮纸 / 护眼绿 / 暗夜黑 / 自定义）
    var background: CodableColor // 页面背景色
    var text: CodableColor // 正文文字颜色
    var secondary: CodableColor // 次要文字颜色（页码、页眉、辅助信息）
    var isDark: Bool // 是否为暗色主题，影响状态栏与控件配色

    /// 预设主题：羊皮纸（默认）。
    static let paper = ReaderTheme( // 声明羊皮纸主题常量
        id: "paper", // 主题标识
        name: "羊皮纸", // 界面显示名
        background: CodableColor(hex: 0xF6F0E1), // 暖米色背景
        text: CodableColor(hex: 0x3A332A), // 深褐正文色
        secondary: CodableColor(hex: 0x8C8271), // 灰褐次要文字色
        isDark: false // 浅色主题
    ) // 结束 paper 主题构造

    /// 预设主题：护眼绿。
    static let eyeCare = ReaderTheme( // 声明护眼绿主题常量
        id: "green", // 主题标识
        name: "护眼绿", // 界面显示名
        background: CodableColor(hex: 0xCCE8CF), // 淡绿背景
        text: CodableColor(hex: 0x2E3A2F), // 墨绿正文色
        secondary: CodableColor(hex: 0x6F8570), // 灰绿次要文字色
        isDark: false // 浅色主题
    ) // 结束 eyeCare 主题构造

    /// 预设主题：暗夜黑。
    static let night = ReaderTheme( // 声明暗夜黑主题常量
        id: "night", // 主题标识
        name: "暗夜黑", // 界面显示名
        background: CodableColor(hex: 0x14161A), // 近黑背景
        text: CodableColor(hex: 0xB7BDC6), // 浅灰正文色
        secondary: CodableColor(hex: 0x6E7681), // 深灰次要文字色
        isDark: true // 暗色主题
    ) // 结束 night 主题构造

    /// 自定义主题的固定标识，ReaderSettings.theme 用它判断是否走 customTheme。
    static let customID = "custom" // 自定义主题的固定 ID

    /// 自定义主题的初始值（用户可在设置面板中改色）。
    static let custom = ReaderTheme( // 声明自定义主题默认值常量
        id: customID, // 使用固定的自定义 ID
        name: "自定义", // 界面显示名
        background: CodableColor(hex: 0xEFE7D8), // 初始米白背景
        text: CodableColor(hex: 0x33302B), // 初始深灰正文色
        secondary: CodableColor(hex: 0x8A8175), // 初始灰次要文字色
        isDark: false // 默认按浅色处理
    ) // 结束 custom 主题构造

    /// 内置可选主题列表（不含自定义），供 ReaderSheets 的主题网格遍历。
    static let presets: [ReaderTheme] = [.paper, .eyeCare, .night] // 三个内置主题的顺序列表
} // 结束 ReaderTheme 结构体

// MARK: - 字体
// 该块定义可选字体与从字体族名解析系统字体的逻辑；ReaderTypography.uiFont() 与 CoreText 分页都经由它取字体。

/// 可选阅读字体描述。
/// 采用「先 PostScript 名、再字体族名」的兜底策略解析系统字体，避免不同 iOS 版本字体名差异。
struct ReaderFont: Identifiable, Hashable { // 声明字体描述结构体
    let id: String // 字体标识，持久化在 ReaderTypography.fontID 中
    let name: String // 界面显示名（黑体 / 宋体 / 楷体 / 圆体）
    let postScriptNames: [String] // PostScript 字体名候选列表
    let familyNames: [String] // 字体族名候选列表

    /// 按给定字号解析出可用的 UIFont。
    /// 解析顺序：PostScript 名 → 字体族内的 Regular 字重 → 字体族内任一字重 → 系统字体。
    /// - Parameter size: 期望字号（点）。
    /// - Returns: 一定可用的 UIFont 实例（最终兜底为系统字体）。
    func uiFont(size: CGFloat) -> UIFont { // 定义字体解析方法
        for name in postScriptNames { // 优先遍历 PostScript 名候选
            if let font = UIFont(name: name, size: size) { return font } // 命中即直接返回
        } // 结束 PostScript 名遍历
        for family in familyNames { // 再遍历字体族名候选
            let names = UIFont.fontNames(forFamilyName: family) // 取出该族下所有字体名
            if let regular = names.first(where: { $0.localizedCaseInsensitiveContains("regular") }), // 优先挑 Regular 字重
               let font = UIFont(name: regular, size: size) { // 尝试用 Regular 字体名构造
                return font // 构造成功则返回
            } // 结束 Regular 优先分支
            for name in names { // 否则遍历族内全部字体名
                if let font = UIFont(name: name, size: size) { return font } // 任一可用字体即返回
            } // 结束族内字体名遍历
        } // 结束字体族遍历
        return UIFont.systemFont(ofSize: size) // 全部失败时兜底为系统字体
    } // 结束 uiFont(size:)

    /// 系统黑体（无候选名，直接落到 UIFont.systemFont）。
    static let system = ReaderFont(id: "system", name: "黑体", postScriptNames: [], familyNames: []) // 系统字体项
    /// 宋体。
    static let songti = ReaderFont( // 声明宋体字体项
        id: "songti", name: "宋体", // 标识与显示名
        postScriptNames: ["SongtiSC-Regular", "STSongti-SC-Regular"], // 宋体 PostScript 名候选
        familyNames: ["Songti SC", "STSong"] // 宋体族名候选
    ) // 结束 songti 字体项
    /// 楷体。
    static let kaiti = ReaderFont( // 声明楷体字体项
        id: "kaiti", name: "楷体", // 标识与显示名
        postScriptNames: ["KaitiSC-Regular", "STKaiti"], // 楷体 PostScript 名候选
        familyNames: ["Kaiti SC", "STKaiti"] // 楷体族名候选
    ) // 结束 kaiti 字体项
    /// 圆体。
    static let yuanti = ReaderFont( // 声明圆体字体项
        id: "yuanti", name: "圆体", // 标识与显示名
        postScriptNames: ["YuantiSC-Regular", "STYuanti"], // 圆体 PostScript 名候选
        familyNames: ["Yuanti SC", "STYuanti"] // 圆体族名候选
    ) // 结束 yuanti 字体项

    /// 全部可选字体，供 ReaderSheets 的字体选择器遍历。
    static let all: [ReaderFont] = [.system, .songti, .kaiti, .yuanti] // 字体顺序列表

    /// 按 id 查找字体。
    /// - Parameter id: ReaderTypography.fontID 中保存的标识。
    /// - Returns: 匹配的字体；找不到时退回系统字体，保证渲染不中断。
    static func named(_ id: String) -> ReaderFont { // 定义按标识查字体的方法
        all.first { $0.id == id } ?? .system // 线性查找，未命中则兜底系统字体
    } // 结束 named(_:)
} // 结束 ReaderFont 结构体

// MARK: - 排版参数
// 该块定义字号、行距、边距等可调参数，并由 signature 生成分页缓存键；ReaderSheets 逐项绑定这些字段。

/// 排版参数：字号、行距、段距、页边距与首行缩进。
/// ReaderSettings 持有它，ReaderViewModel 用它计算文本区域尺寸，PaginationEngine 用 signature 判断缓存是否失效。
struct ReaderTypography: Codable, Hashable { // 声明排版参数结构体
    var fontID: String = "system" // 字体标识，对应 ReaderFont.id
    var fontSize: Double = 19 // 正文字号（点）
    /// 行距倍数（1.0 ~ 2.5）
    var lineSpacing: Double = 1.45 // 行距倍数，1.0 表示无额外行距
    /// 段间距倍数（0 ~ 1.2）
    var paragraphSpacing: Double = 0.35 // 段间距倍数，0 表示紧排
    /// 左右页边距（决定文字宽度）
    var horizontalMargin: Double = 22 // 单侧水平页边距（点），阅读区宽度 = 屏宽 - 2 × 该值
    var indentFirstLine: Bool = true // 是否首行缩进两字

    /// 当前参数对应的字体描述。
    var font: ReaderFont { ReaderFont.named(fontID) } // 按 fontID 解析出 ReaderFont

    /// 按当前字体与字号生成 UIFont。
    /// - Returns: 供 CoreText 分页与 UIKit 绘制使用的字体实例。
    func uiFont() -> UIFont { // 定义生成 UIFont 的方法
        font.uiFont(size: CGFloat(fontSize)) // 把 Double 字号转 CGFloat 后交给 ReaderFont 解析
    } // 结束 uiFont()

    /// 用于分页缓存的签名
    var signature: String { // 定义排版签名计算属性
        String(format: "f%@_s%.2f_l%.2f_p%.2f_m%.1f_i%@", // 以固定格式拼接可读签名
               fontID, fontSize, lineSpacing, paragraphSpacing, horizontalMargin, // 依次写入字体、字号、行距、段距、边距
               indentFirstLine ? "1" : "0") // 缩进开关编码为 1/0
    } // 结束 signature 计算属性

    /// 标准排版实例（各字段取默认值），供「恢复默认」使用。
    static let standard = ReaderTypography() // 标准排版预设，供「恢复默认」使用
} // 结束 ReaderTypography 结构体

// MARK: - 翻页方式
// 该块定义两种翻页方向；ReaderSheets 切换它，PagePagerView 据此决定 UIScrollView 的滚动轴。

/// 翻页方向。
/// ReaderSettings.turnMode 保存当前值，PagePagerView 依据它选择水平或垂直分页容器。
enum PageTurnMode: String, Codable, CaseIterable, Identifiable { // 声明翻页方式枚举
    case horizontal // 左右翻页（水平分页）
    case vertical // 上下翻页（垂直滚动）

    /// Identifiable 标识，直接复用 rawValue。
    var id: String { rawValue } // 用原始字符串作为标识

    /// 面向界面的名称。
    var displayName: String { // 定义显示名计算属性
        switch self { // 按翻页方向分支
        case .horizontal: return "左右翻页" // 水平方向显示「左右翻页」
        case .vertical: return "上下翻页" // 垂直方向显示「上下翻页」
        } // 结束 switch 分支
    } // 结束 displayName 计算属性

    /// 设置面板中的 SF Symbols 图标名。
    var icon: String { // 定义图标名计算属性
        switch self { // 按翻页方向分支
        case .horizontal: return "arrow.left.and.right" // 水平方向使用左右箭头图标
        case .vertical: return "arrow.up.and.down" // 垂直方向使用上下箭头图标
        } // 结束 switch 分支
    } // 结束 icon 计算属性
} // 结束 PageTurnMode 枚举

// MARK: - 阅读设置
// 该块汇总全部可持久化的阅读偏好，并通过 theme 计算属性把 themeID 解析成实际主题。

/// 阅读设置总集：排版、主题、翻页、亮度与常亮开关。
/// ReaderSettingsStore 持有并持久化它；ReaderView / ReaderSheets / ReaderViewModel 都只读这里的字段。
struct ReaderSettings: Codable, Hashable { // 声明阅读设置结构体
    var typography = ReaderTypography() // 排版参数
    var themeID: String = ReaderTheme.paper.id // 当前主题标识，取值为预设 id 或 ReaderTheme.customID
    var customTheme: ReaderTheme = .custom // 自定义主题的颜色数据，themeID 为 custom 时生效
    var turnMode: PageTurnMode = .horizontal // 翻页方向，默认左右翻页
    var brightness: Double = 1.0 // 阅读页遮罩亮度（0 ~ 1），1 表示不加暗
    var followSystemBrightness: Bool = true // 是否跟随系统亮度（为真时忽略 brightness）
    var keepScreenOn: Bool = true // 阅读时是否保持屏幕常亮

    /// 解析出当前生效的主题对象。
    /// 说明：themeID 为 custom 时返回 customTheme，否则在预设中查找，缺失时退回羊皮纸。
    var theme: ReaderTheme { // 定义主题解析计算属性
        if themeID == ReaderTheme.customID { return customTheme } // 自定义主题直接返回用户配色
        return ReaderTheme.presets.first { $0.id == themeID } ?? .paper // 否则查预设，未命中退回羊皮纸
    } // 结束 theme 计算属性
} // 结束 ReaderSettings 结构体

// MARK: - 一键样式模板
// 该块定义「标准 / 护眼 / 夜间」三套组合模板；ReaderSheets 点击后由 ReaderSettingsStore.apply 一次性套用。

/// 一键样式模板：把主题、排版、亮度打包成预设。
/// ReaderSheets 的快捷样式列表遍历 all，选中后调用 ReaderSettingsStore.apply(_:)。
struct ReaderStylePreset: Identifiable { // 声明样式模板结构体
    let id: String // 模板标识
    let name: String // 模板名称（标准 / 护眼 / 夜间）
    let subtitle: String // 副标题描述，概括该模板的主题与字号
    let themeID: String // 关联的主题标识
    let typography: ReaderTypography // 关联的排版参数
    let brightness: Double // 关联的亮度值
    let followSystemBrightness: Bool // 是否跟随系统亮度

    /// 全部内置模板，供设置面板遍历展示。
    static let all: [ReaderStylePreset] = [ // 声明模板列表常量
        ReaderStylePreset( // 第一个模板：标准
            id: "classic", // 模板标识
            name: "标准", // 模板名称
            subtitle: "羊皮纸 · 黑体 19", // 副标题描述
            themeID: ReaderTheme.paper.id, // 使用羊皮纸主题
            typography: ReaderTypography(fontID: "system", fontSize: 19, lineSpacing: 1.45, // 排版参数：黑体 19 号、行距 1.45
                                         paragraphSpacing: 0.35, horizontalMargin: 22, // 段距 0.35、页边距 22
                                         indentFirstLine: true), // 开启首行缩进
            brightness: 1.0, // 不压暗
            followSystemBrightness: true // 跟随系统亮度
        ), // 结束标准模板构造
        ReaderStylePreset( // 第二个模板：护眼
            id: "care", // 模板标识
            name: "护眼", // 模板名称
            subtitle: "绿意 · 宋体 20", // 副标题描述
            themeID: ReaderTheme.eyeCare.id, // 使用护眼绿主题
            typography: ReaderTypography(fontID: "songti", fontSize: 20, lineSpacing: 1.62, // 排版参数：宋体 20 号、行距 1.62
                                         paragraphSpacing: 0.42, horizontalMargin: 26, // 段距 0.42、页边距 26
                                         indentFirstLine: true), // 开启首行缩进
            brightness: 0.78, // 轻微压暗
            followSystemBrightness: false // 固定使用模板亮度
        ), // 结束护眼模板构造
        ReaderStylePreset( // 第三个模板：夜间
            id: "night", // 模板标识
            name: "夜间", // 模板名称
            subtitle: "暗夜 · 黑体 18", // 副标题描述
            themeID: ReaderTheme.night.id, // 使用暗夜黑主题
            typography: ReaderTypography(fontID: "system", fontSize: 18, lineSpacing: 1.55, // 排版参数：黑体 18 号、行距 1.55
                                         paragraphSpacing: 0.3, horizontalMargin: 20, // 段距 0.3、页边距 20
                                         indentFirstLine: true), // 开启首行缩进
            brightness: 0.32, // 明显压暗以护眼
            followSystemBrightness: false // 固定使用模板亮度
        ) // 结束夜间模板构造
    ] // 结束模板列表
} // 结束 ReaderStylePreset 结构体

// MARK: - 设置存储
// 该块是阅读设置的唯一可变入口：InkReadApp 创建实例注入环境，其余界面通过它的 @Published settings 读写。

/// 阅读设置仓库：从 UserDefaults 加载、变更即保存。
/// InkReadApp 以 @StateObject 持有并注入 environmentObject；ReaderSheets / ReaderViewModel 通过它修改或读取设置。
final class ReaderSettingsStore: ObservableObject { // 声明可观察的设置仓库类
    private static let storageKey = "inkread.reader.settings.v1" // UserDefaults 中保存设置 JSON 的键

    /// 当前设置；任何字段变更都会触发 didSet 自动落盘。
    @Published var settings: ReaderSettings { // 以 @Published 暴露设置，供 SwiftUI 订阅刷新
        didSet { save() } // 属性写入后立即持久化
    } // 结束 settings 属性

    /// 初始化：尝试从 UserDefaults 还原设置，失败则使用默认值。
    /// 副作用：读取 UserDefaults。
    init() { // 定义初始化方法
        if let data = UserDefaults.standard.data(forKey: Self.storageKey), // 先取出已存的 JSON 数据
           let decoded = try? JSONDecoder().decode(ReaderSettings.self, from: data) { // 再尝试反序列化为 ReaderSettings
            settings = decoded // 解码成功则恢复上次设置
        } else { // 无数据或解码失败时走默认
            settings = ReaderSettings() // 使用全默认设置
        } // 结束 if-else 分支
    } // 结束 init()

    /// 一次性套用样式模板。
    /// - Parameter preset: 选中的模板；只覆盖模板包含的字段（主题、排版、亮度），其余保持不变。
    /// 副作用：写入 settings，触发保存并通知界面刷新。
    func apply(_ preset: ReaderStylePreset) { // 定义套用模板方法
        var new = settings // 先复制当前设置，避免多次 didSet
        new.themeID = preset.themeID // 覆盖主题标识
        new.typography = preset.typography // 覆盖排版参数
        new.brightness = preset.brightness // 覆盖亮度
        new.followSystemBrightness = preset.followSystemBrightness // 覆盖亮度跟随开关
        settings = new // 一次性写回，触发保存与刷新
    } // 结束 apply(_:)

    /// 将排版恢复为标准值，主题与翻页设置保持不变。
    /// 副作用：写入 settings，触发保存。
    func resetTypography() { // 定义恢复默认排版方法
        var new = settings // 复制当前设置
        new.typography = .standard // 排版替换为标准参数
        settings = new // 写回并触发保存
    } // 结束 resetTypography()

    /// 将当前设置编码为 JSON 写入 UserDefaults。
    /// 说明：私有实现，仅供 settings 的 didSet 调用；编码失败时静默放弃本次保存。
    private func save() { // 定义持久化方法
        guard let data = try? JSONEncoder().encode(settings) else { return } // 编码失败则直接返回
        UserDefaults.standard.set(data, forKey: Self.storageKey) // 写入 UserDefaults
    } // 结束 save()
} // 结束 ReaderSettingsStore 类
