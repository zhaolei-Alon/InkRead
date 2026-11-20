//
//  TextProcessing.swift
//  墨读 InkRead —— 文本解码、规范化与 HTML/Markdown 降级为纯文本的工具集
//
//  职责：
//    · 定义全工程共用的 ImportError 错误枚举（导入失败的统一出口）
//    · 依 BOM、零字节分布、候选编码质量评分识别原始字节的文本编码
//    · 统一换行符、清理行首行尾空白、压缩空行，产出可直接分页的规范化文本
//    · 把 HTML / Markdown / 实体转成纯文本，并抽取书名与作者
//  上层调用者：BookImporter.load(url:)、BookImporter.makeDraft(...)、EPUBImporter.load(url:)、ChapterSplitter.split(_:markdownHeadings:)
//  下层依赖：Foundation（Data、String.Encoding、NSRegularExpression、NSString、CharacterSet）、CoreFoundation（CFStringEncodings 与编码桥接）
//  关键流程：文件 Data → decode 猜编码 → normalize 规范化 → 纯文本交给 ChapterSplitter 切章 / BookImporter 装配 BookDraft
//

import Foundation // 引入 Foundation：Data、String.Encoding、NSRegularExpression、CharacterSet 等
import CoreFoundation // 引入 CoreFoundation：CFStringEncodings 常量与 CFStringConvertEncodingToNSStringEncoding

/// 导入阶段的统一错误类型，由 TextProcessing / BookImporter / EPUBImporter / ZipReader 路径向外抛出
enum ImportError: LocalizedError { // 错误枚举，遵循 LocalizedError 以便 UI 直接展示文案
    case unsupportedFormat // 格式不在支持列表内（当前分派逻辑中较少触发）
    case emptyFile // 文件为 0 字节，或解码/规范化后无有效文本
    case encodingFailed // 所有候选编码与兜底编码均解码失败
    case damagedEPUB // EPUB 结构缺失：container.xml、OPF 或正文全为空
    case tooLarge // 超过 120MB 上限，避免一次性读入导致内存暴涨

    /// 面向用户的错误文案，LibraryStore / LibraryView 在导入失败弹窗中直接展示
    var errorDescription: String? { // LocalizedError 协议要求实现
        switch self { // 按具体错误分支给出中文说明
        case .unsupportedFormat: return "暂不支持该文件格式" // 扩展名分派未命中时的兜底文案
        case .emptyFile: return "文件内容为空" // decode 或规范化后为空
        case .encodingFailed: return "无法识别文本编码" // 候选编码全部失败
        case .damagedEPUB: return "EPUB 文件已损坏或结构异常" // Zip 可读但 EPUB 结构不完整
        case .tooLarge: return "文件过大（超过 120MB）" // BookImporter 体积检查命中
        } // 结束 switch 分支
    } // 结束 errorDescription 计算属性
} // 结束 ImportError 定义

/// 无状态的文本处理工具集合：编码识别、规范化、HTML/Markdown 降级、标题与作者抽取
enum TextProcessing { // 纯静态命名空间，不持有任何状态

    // MARK: - 编码识别
    // 本块负责把原始 Data 猜成正确编码的 String，是 BookImporter 与 EPUBImporter 的唯一解码入口

    /// 将文件字节解码为字符串：先看 BOM，再嗅探无 BOM 的 UTF-16，最后按候选编码打分择优
    /// - Parameter data: 文件原始字节（非空）
    /// - Returns: 解码后的原始文本（尚未规范化）
    /// - Throws: ImportError.emptyFile（空数据）、ImportError.encodingFailed（全部编码失败）
    static func decode(_ data: Data) throws -> String { // 编码识别主入口
        guard !data.isEmpty else { throw ImportError.emptyFile } // 空数据直接抛错，避免后续无意义推断

        if data.starts(with: [0xEF, 0xBB, 0xBF]) { // 命中 UTF-8 BOM：EF BB BF
            return String(decoding: data.dropFirst(3), as: UTF8.self) // 跳过 3 字节 BOM，按 UTF-8 宽松解码（非法字节替换为 U+FFFD）
        } // 结束 UTF-8 BOM 分支
        if data.starts(with: [0xFF, 0xFE]) { // 命中 UTF-16LE BOM：FF FE
            return String(data: data, encoding: .utf16LittleEndian) ?? "" // 按小端 UTF-16 解码，失败给空串由后续质量评分兜底
        } // 结束 UTF-16LE BOM 分支
        if data.starts(with: [0xFE, 0xFF]) { // 命中 UTF-16BE BOM：FE FF
            return String(data: data, encoding: .utf16BigEndian) ?? "" // 按大端 UTF-16 解码
        } // 结束 UTF-16BE BOM 分支

        // 无 BOM 的 UTF-16（常见于 Windows 记事本另存）
        if data.count > 16 { // 样本过短时零字节统计不可靠，直接跳过嗅探
            let sample = data.prefix(4096) // 只取前 4KB 做统计，兼顾准确度与性能
            var zerosAtOdd = 0 // 奇数位零字节计数：偏多说明是 UTF-16LE（低位在前）
            var zerosAtEven = 0 // 偶数位零字节计数：偏多说明是 UTF-16BE（高位在前）
            for (i, byte) in sample.enumerated() where byte == 0 { // 遍历样本中所有零字节及其下标
                if i % 2 == 0 { zerosAtEven += 1 } else { zerosAtOdd += 1 } // 依下标奇偶累加到对应计数器
            } // 结束零字节统计循环
            if zerosAtOdd > sample.count / 4 { // 奇数位零字节超过 1/4，典型 ASCII 为主的 UTF-16LE
                return String(data: data, encoding: .utf16LittleEndian) ?? "" // 按小端解码返回
            } // 结束 UTF-16LE 嗅探分支
            if zerosAtEven > sample.count / 4 { // 偶数位零字节超过 1/4，典型 UTF-16BE
                return String(data: data, encoding: .utf16BigEndian) ?? "" // 按大端解码返回
            } // 结束 UTF-16BE 嗅探分支
        } // 结束无 BOM UTF-16 嗅探块

        let candidates: [String.Encoding] = [ // 候选编码列表：按中文阅读场景常见程度排序
            .utf8, // 最常见的 UTF-8
            encoding(CFStringEncodings.GB_18030_2000), // 简体中文 GB18030，兼容 GBK / GB2312
            encoding(CFStringEncodings.big5), // 繁体中文 Big5
            .shiftJIS, // 日文 Shift-JIS
            .japaneseEUC, // 日文 EUC-JP
            encoding(CFStringEncodings.EUC_KR), // 韩文 EUC-KR
            .windowsCP1252, // 西欧 Windows 代码页
            .windowsCP1251, // 西里尔 Windows 代码页
            .isoLatin1 // 拉丁兜底：几乎任意字节都能解码
        ] // 结束候选编码数组字面量

        var best: (text: String, score: Double)? // 当前最优解码结果与对应质量分
        for candidate in candidates { // 逐个候选编码尝试解码
            guard let text = String(data: data, encoding: candidate) else { continue } // 该编码解码失败则跳过
            let score = quality(of: text) // 用文字质量评分衡量解码正确性
            if score > (best?.score ?? -Double.infinity) { // 只有严格更优才替换，保证列表顺序优先
                best = (text, score) // 记录更优的解码结果
            } // 结束最优比较分支
        } // 结束候选编码遍历
        if let best, best.score > 0.2 { // 最优结果达到最低可信阈值才采纳
            return best.text // 返回评分最高的解码文本
        } // 结束可信阈值判断
        guard let fallback = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { // 兜底：UTF-8 不行就用 Latin-1 硬解
            throw ImportError.encodingFailed // 连 Latin-1 都失败才抛编码错误
        } // 结束兜底 guard
        return fallback // 返回兜底解码结果
    } // 结束 decode

    /// 把 CoreFoundation 的编码常量桥接成 Foundation 的 String.Encoding
    /// - Parameter value: CFStringEncodings 枚举值（如 GB_18030_2000、EUC_KR）
    /// - Returns: 可用于 String(data:encoding:) 的 String.Encoding
    private static func encoding(_ value: CFStringEncodings) -> String.Encoding { // CF 编码 → Foundation 编码桥接
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue))) // 先转 CFStringEncoding，再转 NSStringEncoding 原始值
    } // 结束 encoding

    /// 文本质量评分：CJK 字符权重更高，替换字符与控制字符扣分
    private static func quality(of text: String) -> Double { // 评估一次解码结果「像不像正常文字」
        let sample = text.prefix(20000) // 只评估前 2 万字符，控制耗时
        guard !sample.isEmpty else { return 0 } // 空样本记 0 分
        var score = 0.0 // 累计得分
        var count = 0.0 // 样本标量数，用于求平均
        for scalar in sample.unicodeScalars { // 按 Unicode 标量遍历，便于做码位判断
            count += 1 // 累计字符数
            if scalar == "\u{FFFD}" { // 替换字符说明解码出错
                score -= 4 // 重罚乱码
                continue // 处理下一个字符
            } // 结束替换字符判断
            if CharacterSet.controlCharacters.contains(scalar) { // 控制字符通常意味着解错了
                if scalar == "\n" || scalar == "\r" || scalar == "\t" { continue } // 换行与制表符属于正常文本，跳过不罚
                score -= 2 // 其余控制字符扣分
                continue // 处理下一个字符
            } // 结束控制字符判断
            if isCJK(scalar) { // 中日韩字符：目标语言，权重最高
                score += 2.2 // 加分
            } else if CharacterSet.letters.contains(scalar) { // 其它语言的字母
                score += 1 // 正常加分
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) { // 空白与换行
                score += 0.4 // 少量加分
            } else if CharacterSet.punctuationCharacters.contains(scalar) { // 标点符号
                score += 0.6 // 中等加分
            } else if scalar.value < 0x20 { // 其余低级控制码位（兜底分支）
                score -= 2 // 扣分
            } // 结束码位分类判断链
        } // 结束标量遍历
        return score / count // 归一化为平均每字符得分
    } // 结束 quality

    /// 判断是否为 CJK（中日韩）码位
    /// - Parameter scalar: 待判断的 Unicode 标量
    /// - Returns: true 表示属于 CJK 常用区段
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool { // 按码位区间判断
        switch scalar.value { // 匹配码位值所在区间
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F, // 汉字基本区、扩展 A、CJK 标点
             0x3040...0x30FF, 0xAC00...0xD7AF, 0xFF00...0xFFEF: // 日文假名、谚文音节、全角字符
            return true // 命中任一区段即视为 CJK
        default: // 其它码位
            return false // 非 CJK
        } // 结束码位区间 switch
    } // 结束 isCJK

    // MARK: - 规范化
    // 本块把任意换行风格与零散空白的文本统一成阅读器可直接排版的形式，所有导入路径都会经过

    /// 规范化原始文本：统一为 \n 换行，去掉 BOM 与 NBSP，裁剪行首行尾空白，压缩连续空行
    /// - Parameter raw: decode 得到的原始文本
    /// - Returns: 适合分页与切章的规范化文本（首尾空白已裁剪）
    static func normalize(_ raw: String) -> String { // 公共清洗步骤，BookImporter 各分派分支都会调用
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n") // 先把 CRLF 统一成 LF
            .replacingOccurrences(of: "\r", with: "\n") // 再把孤立的 CR 统一成 LF
            .replacingOccurrences(of: "\u{FEFF}", with: "") // 去掉残留的零宽 BOM 字符
            .replacingOccurrences(of: "\u{00A0}", with: " ") // 把不间断空格换成普通空格，避免排版异常
        text = replacing(text, pattern: "(?m)^[ \\t\\u3000]+", template: "") // 去掉每行行首的半角/全角空白
        text = replacing(text, pattern: "(?m)[ \\t\\u3000]+$", template: "") // 去掉每行行尾的半角/全角空白
        text = replacing(text, pattern: "\\n{3,}", template: "\n\n") // 连续 3 个以上换行压缩为一个空行
        return text.trimmingCharacters(in: .whitespacesAndNewlines) // 去掉全文首尾空白后返回
    } // 结束 normalize

    /// 用 NSRegularExpression 做一次全文替换；正则非法时原样返回，绝不抛错
    /// - Parameters:
    ///   - text: 待处理文本
    ///   - pattern: 正则表达式（注意字符串内的反斜杠需转义）
    ///   - template: 替换模板，支持 $1 等捕获组引用
    /// - Returns: 替换后的文本；正则编译失败时返回原文
    static func replacing(_ text: String, pattern: String, template: String) -> String { // 供本文件、EPUBImporter、ChapterSplitter 复用
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text } // 编译失败直接返回原文，保证导入流程不中断
        let range = NSRange(location: 0, length: (text as NSString).length) // 以 UTF-16 长度构造全文范围，与 NSString 一致
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template) // 执行全部匹配替换并返回结果
    } // 结束 replacing

    // MARK: - HTML / Markdown 转纯文本
    // 本块把结构化标记降级成读者可见的文字：EPUB 章节、独立 HTML 文件、Markdown 文件都走这里

    /// HTML → 纯文本：剔除脚本/样式/注释，块级标签转换行，删除标签并还原实体，最后规范化
    /// - Parameter html: HTML / XHTML 源码
    /// - Returns: 规范化纯文本（EPUBImporter 取章节正文、BookImporter 处理 .html 时使用）
    static func plainText(fromHTML html: String) -> String { // HTML 降级主流程
        var text = html // 工作副本
        text = replacing(text, pattern: "(?is)<(script|style|head|svg)[^>]*>.*?</\\1>", template: "") // 整段删除 script/style/head/svg 等不可见内容
        text = replacing(text, pattern: "(?is)<!--.*?-->", template: "") // 删除 HTML 注释
        text = replacing(text, pattern: "(?i)<br\\s*/?>", template: "\n") // <br> 及其自闭合写法转成换行
        text = replacing(text, pattern: "(?i)</?(p|div|section|article|h[1-6]|li|tr|blockquote|pre|figure|figcaption)[^>]*>", template: "\n") // 块级标签开闭都转换行，保留段落结构
        text = replacing(text, pattern: "(?s)<[^>]+>", template: "") // 删除剩余所有标签
        text = decodeEntities(text) // 还原 &nbsp; / &amp; / &#x4E2D; 等实体
        return normalize(text) // 统一换行与空白后返回
    } // 结束 plainText(fromHTML:)

    /// Markdown → 纯文本：去掉代码围栏行、图片语法、链接地址、引用符、强调符、分隔线与行内代码反引号
    /// - Parameter markdown: Markdown 源码
    /// - Returns: 规范化纯文本（BookImporter 处理 .md / .markdown 时使用）
    static func plainText(fromMarkdown markdown: String) -> String { // Markdown 降级主流程
        var text = markdown // 工作副本
        text = replacing(text, pattern: "(?m)^```.*$", template: "") // 删除代码围栏行（保留围栏内的代码文本）
        text = replacing(text, pattern: "!\\[[^\\]]*\\]\\([^\\)]*\\)", template: "") // 删除图片语法 ![alt](src)
        text = replacing(text, pattern: "\\[([^\\]]+)\\]\\([^\\)]*\\)", template: "$1") // 链接保留文字、丢弃地址
        text = replacing(text, pattern: "(?m)^\\s*>[ \\t]?", template: "") // 去掉行首引用符号 >
        text = replacing(text, pattern: "(\\*\\*|__)(.*?)\\1", template: "$2") // 去掉粗体标记，保留内部文字
        text = replacing(text, pattern: "(?m)^[ \\t]*[-*_]{3,}[ \\t]*$", template: "") // 删除分隔线
        text = replacing(text, pattern: "`([^`]*)`", template: "$1") // 去掉行内代码的反引号
        return normalize(text) // 规范化后返回
    } // 结束 plainText(fromMarkdown:)

    /// 还原 HTML 实体：先按倒序处理数字实体（&#123; / &#x4E2D;），再替换常用命名实体
    /// - Parameter input: 可能含实体的文本片段
    /// - Returns: 实体已被替换的文本
    static func decodeEntities(_ input: String) -> String { // HTML 实体解码
        var text = input // 工作副本
        let named: [String: String] = [ // 常用命名实体映射表
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", // 空白、& 与尖括号
            "&quot;": "\"", "&apos;": "'", "&#39;": "'", // 各类引号
            "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", // 破折号与省略号
            "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’", // 中英文弯引号
            "&middot;": "·", "&times;": "×" // 间隔号与乘号
        ] // 结束命名实体表字面量
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: []) { // 匹配十进制与十六进制数字实体
            let ns = text as NSString // 转 NSString 以便按下标取子串
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) // 找出所有数字实体
            for match in matches.reversed() { // 倒序替换，避免前面替换导致后面的 range 失效
                guard match.numberOfRanges == 3 else { continue } // 捕获组数量不符则跳过
                let isHex = ns.substring(with: match.range(at: 1)).lowercased() == "x" // 第 1 组捕获到 x 说明是十六进制
                let digits = ns.substring(with: match.range(at: 2)) // 取出数字部分
                guard let value = UInt32(digits, radix: isHex ? 16 : 10), // 按对应进制解析码位
                      let scalar = Unicode.Scalar(value) else { continue } // 码位非法（如落在代理区）则跳过
                text = (text as NSString).replacingCharacters(in: match.range, with: String(Character(scalar))) // 用对应字符替换实体
            } // 结束数字实体替换循环
        } // 结束数字实体处理块
        for (key, value) in named { // 逐个替换常用命名实体
            text = text.replacingOccurrences(of: key, with: value) // 字面量替换
        } // 结束命名实体替换循环
        return text // 返回解码结果
    } // 结束 decodeEntities

    /// 从 HTML 推断书名：优先 h1~h3，其次 <title>，都限制在 40 字以内
    /// - Parameter html: HTML 源码
    /// - Returns: 干净的标题文本；找不到合适标题时返回 nil（调用方用文件名兜底）
    static func title(fromHTML html: String) -> String? { // EPUB 章节名与 HTML 书名的公共来源
        if let heading = firstMatch(in: html, pattern: "(?is)<h[1-3][^>]*>(.*?)</h[1-3]>") { // 先取第一个 h1~h3 的内容
            let clean = plainText(fromHTML: heading).trimmingCharacters(in: .whitespacesAndNewlines) // 用同一套 HTML 降级清洗标题
            if !clean.isEmpty, clean.count <= 40 { return clean } // 非空且不超长才采用
        } // 结束 h 标签分支
        if let title = firstMatch(in: html, pattern: "(?is)<title[^>]*>(.*?)</title>") { // 再退而取 <title> 内容
            let clean = decodeEntities(replacing(title, pattern: "(?s)<[^>]+>", template: "")) // 先删标签再还原实体
                .trimmingCharacters(in: .whitespacesAndNewlines) // 去掉首尾空白
            if !clean.isEmpty, clean.count <= 40 { return clean } // 同样做非空与限长校验
        } // 结束 title 标签分支
        return nil // 均未命中则返回 nil，交由调用方兜底
    } // 结束 title(fromHTML:)

    /// 取正则第一个匹配的第 1 个捕获组内容
    /// - Parameters:
    ///   - text: 待搜索文本
    ///   - pattern: 必须含至少一个捕获组的正则
    /// - Returns: 捕获组内容；正则非法或无匹配时返回 nil
    static func firstMatch(in text: String, pattern: String) -> String? { // EPUBImporter 解析 container.xml / OPF 时复用
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []), // 编译正则
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)), // 取首个匹配
              match.numberOfRanges > 1 else { return nil } // 必须存在捕获组才能取值
        return (text as NSString).substring(with: match.range(at: 1)) // 返回第 1 个捕获组内容
    } // 结束 firstMatch

    // MARK: - 作者识别
    // 本块从正文前部按常见署名格式抽取作者，BookImporter.authorOrUnknown 依赖它

    /// 在正文中识别作者署名（“作者：”“著者：”“Author:”）
    /// - Parameter text: 规范化后的正文
    /// - Returns: 作者名；未识别到时返回 nil
    static func detectAuthor(in text: String) -> String? { // 作者抽取
        let patterns = [ // 三种常见署名写法
            "(?m)^[\\s　]*作\\s*者\\s*[:：]\\s*([^\\n]{1,24})", // 中文“作者：xxx”
            "(?m)^[\\s]*Author\\s*[:：]\\s*([^\\n]{1,40})", // 英文“Author: xxx”
            "(?m)^[\\s]*著\\s*者\\s*[:：]\\s*([^\\n]{1,24})" // 中文“著者：xxx”
        ] // 结束正则数组字面量
        for pattern in patterns { // 依次尝试各写法
            if let value = firstMatch(in: text, pattern: pattern)?.trimmingCharacters(in: .whitespacesAndNewlines), // 取捕获组并去首尾空白
               !value.isEmpty { // 非空才算识别成功
                return value // 返回第一个命中的作者名
            } // 结束命中判断
        } // 结束写法遍历
        return nil // 全部未命中
    } // 结束 detectAuthor

    /// 清洗书名：去短括注、去书名号、去文件扩展名，空则给默认名
    /// - Parameter raw: 原始书名（通常来自文件名）
    /// - Returns: 可直接展示的书名，永不为空
    static func cleanTitle(_ raw: String) -> String { // BookImporter.load 用它生成 fallbackTitle
        var title = raw // 工作副本
        title = replacing(title, pattern: "[\\(（\\[【].{0,20}[\\)）\\]】]", template: "") // 删除短括注，如“（校对版）”“[精校]”
        title = title.replacingOccurrences(of: "《", with: "") // 去掉左书名号
            .replacingOccurrences(of: "》", with: "") // 去掉右书名号
        title = replacing(title, pattern: "(?i)\\.(txt|epub|md|markdown|html?|rtf)$", template: "") // 去掉残留的扩展名
        title = title.trimmingCharacters(in: .whitespacesAndNewlines) // 去掉首尾空白
        return title.isEmpty ? "未命名书籍" : title // 空标题兜底为“未命名书籍”
    } // 结束 cleanTitle
} // 结束 TextProcessing 命名空间
