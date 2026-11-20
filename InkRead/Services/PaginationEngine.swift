//
//  PaginationEngine.swift
//  墨读 InkRead —— 基于 CoreText 的整章分页引擎
//
//  职责：
//    · 依排版参数生成富文本属性（字体、颜色、段落样式）
//    · 用 CTFramesetter 对整章文本一次性分页，产出每页在章节内的 UTF-16 范围（PageSlice）
//    · 提供分页缓存结构与缓存签名，并把 PageSlice 还原为一页可绘制的富文本
//    · 对续页取消首行缩进，避免每页首行都出现两字缩进
//  上层调用者：ReaderViewModel（signature / attributedString / paginate / pageContent，写入 CachedLayout 后交给 PagerModel 与 PagePagerView 绘制）
//  下层依赖：CoreText（CTFramesetterCreateWithAttributedString、CTFramesetterCreateFrame、CTFrameGetVisibleStringRange、CGPath）、UIKit（NSAttributedString / NSParagraphStyle）、ReaderTypography 与 ReaderTheme
//  关键流程：章节文本 → attributedString() → paginate() 得到 PageSlice 数组 → 缓存签名与切片 → 绘制时 pageContent() 截取单页富文本 → CTFrameDraw 输出
//

import UIKit // 引入 UIKit：NSAttributedString、NSParagraphStyle、CGSize、CGPath 等
import CoreText // 引入 CoreText：框架排版与分页 API

/// 一页在章节内的范围：以 UTF-16 为单位，与 NSString / NSAttributedString 偏移一致
struct PageSlice: Codable, Hashable { // 可编解码以便写入 layout.json 复用
    /// 页起始 UTF-16 偏移（相对章节正文起点）
    var start: Int // 用于 attributedSubstring 截取
    /// 本页 UTF-16 长度
    var length: Int // 与 start 组合成 NSRange
} // 结束 PageSlice 结构

/// 单章分页缓存：章节索引 + 该章所有页范围
struct CachedChapterLayout: Codable { // 持久化到 layout.json 的章节级条目
    /// 章节索引（对应 Chapter.index）
    var index: Int // 用于按章检索缓存
    /// 该章的分页结果
    var slices: [PageSlice] // 依次排列，下标即章节内页码
} // 结束 CachedChapterLayout 结构

/// 整本布局缓存：排版签名 + 各章分页结果
struct CachedLayout: Codable { // 由 LibraryStore.saveLayout 落盘、loadLayout 读回
    /// 排版签名（字体/字号/行距/边距/版心尺寸），签名不同则缓存失效
    var signature: String // 与 PaginationEngine.signature 生成值比对
    /// 各章缓存条目
    var chapters: [CachedChapterLayout] // 按分页进度逐步追加

    /// 取指定章节的分页结果
    /// - Parameter chapter: 章节索引
    /// - Returns: 该章 PageSlice 数组；尚未分页时返回 nil
    func slices(for chapter: Int) -> [PageSlice]? { // 由 ReaderViewModel 在打开章节时查询
        chapters.first { $0.index == chapter }?.slices // 线性查找首个匹配章节
    } // 结束 slices(for:)
} // 结束 CachedLayout 结构

/// 单章排版产物：章节索引、整章富文本与分页结果
struct ChapterLayout { // 内存中使用的一次性结构，不参与持久化
    /// 章节索引
    var chapterIndex: Int // 与 Chapter.index 对应
    /// 整章富文本（含字体、颜色、段落样式）
    var attributed: NSAttributedString // paginate 的输入，也是 pageContent 的截取源
    /// 整章分页结果
    var slices: [PageSlice] // 与 attributed 一一对应
} // 结束 ChapterLayout 结构

/// CoreText 分页引擎：一次排版产生整章分页结果，页面绘制只做一次 CTFrameDraw。
enum PaginationEngine { // 纯函数集合，无实例状态，全部为 static 方法

    /// 生成排版缓存签名
    /// - Parameters:
    ///   - typography: 当前排版参数（字体、字号、行距、段距、页边距、首行缩进）
    ///   - textSize: 版心尺寸（扣除页边距后的可排版区域）
    /// - Returns: 形如「排版签名|宽x高」的字符串，任一参数变化即失效缓存
    static func signature(typography: ReaderTypography, textSize: CGSize) -> String { // 由 ReaderViewModel 分页前计算并比对旧缓存
        String(format: "%@|%.1fx%.1f", typography.signature, textSize.width, textSize.height) // 拼接排版签名与版心尺寸，尺寸保留一位小数
    } // 结束 signature(typography:textSize:)

    /// 构造段落样式
    /// - Parameters:
    ///   - typography: 排版参数，字号是各类间距的换算基准
    ///   - firstLineIndent: 是否允许首行缩进（续页传 false 以取消缩进）
    /// - Returns: 固定两端对齐、按词换行、不自动断词的段落样式
    static func paragraphStyle(typography: ReaderTypography, firstLineIndent: Bool) -> NSParagraphStyle { // 由 attributes() 与 pageContent() 调用
        let style = NSMutableParagraphStyle() // 可变段落样式，便于逐项设置
        style.lineSpacing = max(0, CGFloat(typography.fontSize) * (typography.lineSpacing - 1)) // 行距倍数换算为额外行间距，保证不为负
        style.paragraphSpacing = max(0, CGFloat(typography.fontSize) * typography.paragraphSpacing) // 段间距按字号倍数换算，保证不为负
        style.alignment = .justified // 两端对齐，中文正文更整齐
        style.lineBreakMode = .byWordWrapping // 按词（西文按单词、中文按字）换行
        style.hyphenationFactor = 0 // 关闭自动连字符，避免中文排版出现断词
        style.firstLineHeadIndent = (firstLineIndent && typography.indentFirstLine) // 仅当允许缩进且用户开启缩进时
            ? CGFloat(typography.fontSize) * 2 : 0 // 首行缩进两个字符宽，否则为 0
        style.headIndent = 0 // 其余行不缩进
        style.tailIndent = 0 // 行尾不额外缩进，保持版心宽度
        return style // 返回配置完成的段落样式
    } // 结束 paragraphStyle(typography:firstLineIndent:)

    /// 构造整章正文的富文本属性
    /// - Parameters:
    ///   - typography: 排版参数，决定字体与段落样式
    ///   - theme: 阅读主题，决定文字颜色
    /// - Returns: 字体 / 前景色 / 段落样式三项属性字典
    static func attributes(typography: ReaderTypography, theme: ReaderTheme) -> [NSAttributedString.Key: Any] { // 由 attributedString() 调用
        let style = paragraphStyle(typography: typography, firstLineIndent: true) // 整章排版允许首行缩进
        return [ // 属性字典字面量
            .font: typography.uiFont(), // 按排版参数解析出的 UIFont
            .foregroundColor: theme.text.uiColor, // 主题文字颜色（已转为 UIColor）
            .paragraphStyle: style // 段落样式（行距、段距、缩进、对齐）
        ] // 结束 属性字典
    } // 结束 attributes(typography:theme:)

    /// 把纯文本包装为带排版的富文本
    /// - Parameters:
    ///   - text: 章节纯文本
    ///   - typography: 排版参数
    ///   - theme: 阅读主题
    /// - Returns: 可直接交给 CTFramesetter 的富文本
    static func attributedString(text: String, typography: ReaderTypography, theme: ReaderTheme) -> NSAttributedString { // 由 ReaderViewModel 构造整章排版输入
        NSAttributedString(string: text, attributes: attributes(typography: typography, theme: theme)) // 以纯文本 + 属性字典创建富文本
    } // 结束 attributedString(text:typography:theme:)

    /// 对整章文本进行分页，返回每页在章节内的 UTF-16 范围
    /// - Parameters:
    ///   - attributed: 整章富文本
    ///   - size: 单页版心尺寸
    /// - Returns: 按阅读顺序排列的 PageSlice 数组；空文本返回空数组
    /// - 说明：用 CTFramesetter 逐页取可见区间推进偏移，页面过小等极端情况下强制前进来避免死循环
    static func paginate(attributed: NSAttributedString, size: CGSize) -> [PageSlice] { // 由 ReaderViewModel 对新章节排版
        let width = max(1, size.width) // 版心宽度下限 1，避免非法尺寸导致 CoreText 异常
        let height = max(1, size.height) // 版心高度下限 1，同上
        let total = attributed.length // 整章 UTF-16 总长度
        guard total > 0 else { return [] } // 空文本无需分页，直接返回空数组

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString) // 创建整章排版器，复用可提升性能
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil) // 单页版心矩形路径

        var slices: [PageSlice] = [] // 累积分页结果
        var offset = 0 // 当前页起始 UTF-16 偏移
        var safety = 0 // 循环保护计数，防止异常文本导致死循环
        let maxPages = max(total / 8 + 64, 256) // 预估页数上限：总长/8 再加冗余，至少允许 256 页

        while offset < total && safety < maxPages { // 未排完且未触及保护上限时继续
            safety += 1 // 保护计数自增
            let frame = CTFramesetterCreateFrame( // 为剩余文本创建单页排版框架
                framesetter, // 复用整章排版器
                CFRange(location: offset, length: 0), // 从当前偏移开始，length 0 表示直到文本末尾
                path, // 单页版心路径
                nil // 不需要额外帧属性
            ) // 结束 CTFramesetterCreateFrame 调用
            var visible = CTFrameGetVisibleStringRange(frame) // 取出该页实际排下的字符区间
            var length = visible.length // 本页长度（UTF-16 单元数）

            if length <= 0 { // 极端情况（页面过小或异常字符）导致无法排入任何一个字符
                // 极端情况（页面过小或异常字符）保证前进
                length = min(max(total - offset, 1), 4000) // 强制至少前进 1 个单元，单页最多 4000 以防跳过过多内容
                visible.length = length // 同步修正可见区间长度，便于调试观察
            } // 结束 极端情况兜底块

            slices.append(PageSlice(start: offset, length: length)) // 记录本页范围
            offset += length // 推进到下一页起点
        } // 结束 逐页排版循环

        return slices // 返回整章分页结果
    } // 结束 paginate(attributed:size:)

    /// 取出一页内容；续页去掉首行缩进，避免每页首行出现缩进
    /// - Parameters:
    ///   - chapterAttributed: 整章富文本（分页依据）
    ///   - chapterText: 整章纯文本（用于判断页首是否恰为段落开头）
    ///   - slice: 目标页的 UTF-16 范围
    ///   - typography: 排版参数（用于生成无首行缩进的段落样式）
    /// - Returns: 可直接绘制的一页富文本；范围非法时返回空富文本
    static func pageContent(chapterAttributed: NSAttributedString, // 由 ReaderViewModel 翻页时调用
                            chapterText: NSString, // 整章纯文本，与富文本偏移一致
                            slice: PageSlice, // 目标页范围
                            typography: ReaderTypography) -> NSAttributedString { // 返回值：单页富文本
        let maxLength = max(0, chapterAttributed.length - slice.start) // 从页首到章末的剩余长度
        let length = min(slice.length, maxLength) // 截取长度不得超过剩余文本
        guard slice.start >= 0, length > 0 else { return NSAttributedString() } // 起点越界或长度为 0 时返回空富文本

        let range = NSRange(location: slice.start, length: length) // 组装截取范围
        let content = NSMutableAttributedString(attributedString: chapterAttributed.attributedSubstring(from: range)) // 截出本页富文本，保留原属性

        var atParagraphStart = slice.start == 0 // 章节第一页自然处于段落开头
        if !atParagraphStart, slice.start <= chapterText.length { // 非首页时检查页前一个字符
            let previous = chapterText.substring(with: NSRange(location: slice.start - 1, length: 1)) // 取页首前一个字符
            atParagraphStart = previous == "\n" // 前一字符是换行说明本页恰起于新段落
        } // 结束 段落起始判定块

        if !atParagraphStart, content.length > 0 { // 续页且非段落开头时
            let style = paragraphStyle(typography: typography, firstLineIndent: false) // 生成不带首行缩进的段落样式
            content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: 1)) // 只覆盖首字符，使本页首行不缩进
        } // 结束 续页缩进修正块
        return content // 返回本页富文本
    } // 结束 pageContent(chapterAttributed:chapterText:slice:typography:)
} // 结束 PaginationEngine 枚举
