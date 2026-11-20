//
//  EPUBImporter.swift
//  墨读 InkRead —— EPUB 2 / 3 解析器：从 container.xml 找到 OPF，按 spine 顺序抽取章节纯文本
//
//  职责：
//    · 用 ZipReader 读取 META-INF/container.xml，定位 OPF 文件路径（找不到则在条目里搜 .opf）
//    · 用 OPFDocument（XMLParser 委托）解析书名、作者、manifest 条目与 spine 顺序
//    · 读 EPUB3 的 nav.xhtml 或 EPUB2 的 toc.ncx 建立「章节文件路径 → 目录标题」映射
//    · 逐条渲染 spine 中的 xhtml，经 TextProcessing 降级为纯文本，产出 [RawChapter]
//    · spine 为空时退化为按文件名顺序遍历 xhtml/html/htm
//  上层调用者：BookImporter.load(url:) 的 "epub" 分支与 ZIP 文件头嗅探分支
//  下层依赖：ZipReader（data(for:) / fileNames()）、TextProcessing（decode / plainText(fromHTML:) / title(fromHTML:) / firstMatch / replacing / decodeEntities）、ImportError
//  关键流程：EPUB 字节 → ZipReader → container.xml → OPF → spine 列表 → 各章 xhtml → 纯文本 → RawChapter → BookImporter.assemble 计算 UTF-16 偏移
//

import Foundation // 引入 Foundation：URL、Data、String、NSRegularExpression、XMLParser

/// EPUB 2 / 3 解析：container.xml -> OPF -> spine，提取章节纯文本。
enum EPUBImporter { // 纯静态命名空间，不持有状态

    /// 解析 EPUB 文件，返回书名、作者与原始章节
    /// - Parameter url: EPUB 文件 URL（BookImporter 已完成安全作用域访问与体积检查）
    /// - Returns: 元组（书名, 作者, 章节数组）；书名/作者可能为 nil，由 BookImporter 兜底
    /// - Throws: ImportError.damagedEPUB（container/OPF 缺失、无任何有效章节）、ZipError（ZipReader 抛出）
    static func load(url: URL) throws -> (title: String?, author: String?, chapters: [RawChapter]) { // EPUB 解析主入口
        let data = try Data(contentsOf: url) // 读入整个 EPUB 字节
        let zip = try ZipReader(data: data) // 构造 ZIP 读取器并解析中央目录

        guard let containerData = zip.data(for: "META-INF/container.xml"), // 读取容器描述文件
              let containerXML = String(data: containerData, encoding: .utf8) else { // 按 UTF-8 解码（EPUB 规范要求）
            throw ImportError.damagedEPUB // 缺失或解码失败说明 EPUB 结构异常
        } // 结束 container.xml 读取 guard
        let opfPath = rootPath(from: containerXML) ?? zip.fileNames().first(where: { $0.lowercased().hasSuffix(".opf") }) // 取 rootfile 路径，解析失败则直接搜 .opf 条目
        guard let opfPath, let opfData = zip.data(for: opfPath) else { // 确保 OPF 条目可读
            throw ImportError.damagedEPUB // 没有 OPF 就无法继续
        } // 结束 OPF 读取 guard

        let opf = OPFDocument.parse(opfData) // 用 XMLParser 解析 OPF，得到元数据与 spine

        var tocTitles: [String: String] = [:] // 章节文件路径（小写）→ 目录标题
        if let navItem = opf.items.first(where: { $0.properties.contains("nav") }) { // 优先 EPUB3 的 nav 文档
            let navPath = resolve(base: opfPath, href: navItem.href) // 相对 OPF 解析出 nav 的真实路径
            if let navData = zip.data(for: navPath), let navText = String(data: navData, encoding: .utf8) { // 读取并解码 nav.xhtml
                tocTitles = parseNavTitles(navText, basePath: navPath) // 从 <a href> 提取标题映射
            } // 结束 nav 读取
        } else if let ncxItem = opf.items.first(where: { $0.mediaType.contains("dtbncx") }) { // 退而使用 EPUB2 的 NCX 目录
            let ncxPath = resolve(base: opfPath, href: ncxItem.href) // 解析 NCX 路径
            if let ncxData = zip.data(for: ncxPath), let ncxText = String(data: ncxData, encoding: .utf8) { // 读取并解码 NCX
                tocTitles = parseNCX(ncxText, basePath: ncxPath) // 从 navPoint/content 提取标题映射
            } // 结束 NCX 读取
        } // 结束目录解析分支

        var chapters: [RawChapter] = [] // 累积章节
        for idref in opf.spine { // 严格按 spine 阅读顺序遍历
            guard let item = opf.items.first(where: { $0.id == idref }) else { continue } // spine 引用不到 manifest 条目则跳过
            let path = resolve(base: opfPath, href: item.href) // 解析出章节文件真实路径
            guard let docData = zip.data(for: path) else { continue } // 条目缺失则跳过
            let html = (try? TextProcessing.decode(docData)) ?? "" // 识别编码，失败给空串
            guard !html.isEmpty else { continue } // 空内容跳过
            var body = TextProcessing.plainText(fromHTML: html) // HTML 降级为纯文本
            guard body.count >= 20 else { continue } // 过短的多为封面/版权页，跳过

            let title = tocTitles[path.lowercased()] // 优先用目录中的标题
                ?? TextProcessing.title(fromHTML: html) // 其次用文档内 h1~h3 或 <title>
                ?? "第 \(chapters.count + 1) 章" // 最后按序号命名

            if body.hasPrefix(title) { // 正文开头重复标题时去掉，避免阅读页重复显示
                body = String(body.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines) // 截掉标题前缀并去空白
            } // 结束标题去重
            guard !body.isEmpty else { continue } // 去重后为空则跳过
            chapters.append(RawChapter(title: title, body: body)) // 收录本章
        } // 结束 spine 遍历

        // 部分 EPUB 的 spine 为空：退化为按文件名顺序读取 xhtml
        if chapters.isEmpty { // 只有 spine 方案完全失败时才兜底
            let docs = zip.fileNames() // 取出全部条目名
                .filter { $0.lowercased().hasSuffix(".xhtml") || $0.lowercased().hasSuffix(".html") || $0.lowercased().hasSuffix(".htm") } // 只保留 HTML 类文件
                .filter { name in // 再排除导航/封面等非正文文件
                    let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() // 取文件名词干（不含扩展名）
                    return stem != "nav" && stem != "toc" && stem != "contents" && stem != "cover" // 过滤 nav/toc/contents/cover
                } // 结束文件名过滤
                .sorted() // 按路径字典序近似阅读顺序
            for path in docs { // 逐个渲染
                guard let docData = zip.data(for: path) else { continue } // 条目无法读取则跳过
                let html = (try? TextProcessing.decode(docData)) ?? "" // 解码 HTML
                var body = TextProcessing.plainText(fromHTML: html) // 降级为纯文本
                guard body.count >= 20 else { continue } // 过短内容跳过
                let title = tocTitles[path.lowercased()] ?? TextProcessing.title(fromHTML: html) ?? "第 \(chapters.count + 1) 章" // 标题优先级同上
                if body.hasPrefix(title) { // 正文开头与标题重复
                    body = String(body.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines) // 去掉重复标题
                } // 结束标题去重
                guard !body.isEmpty else { continue } // 空正文跳过
                chapters.append(RawChapter(title: title, body: body)) // 收录本章
            } // 结束兜底遍历
        } // 结束 spine 为空兜底块

        guard !chapters.isEmpty else { throw ImportError.damagedEPUB } // 两种方案都没拿到正文则判定文件损坏
        return (opf.title, opf.author, chapters) // 返回元数据与章节
    } // 结束 load(url:)

    // MARK: - container
    // 本块从 META-INF/container.xml 中取出 rootfile 的 full-path，即 OPF 位置

    /// 从 container.xml 中解析 rootfile 的 full-path
    /// - Parameter xml: container.xml 文本
    /// - Returns: OPF 相对路径（已做百分号解码）；解析不到返回 nil
    private static func rootPath(from xml: String) -> String? { // 兼容双引号与单引号两种属性写法
        if let path = TextProcessing.firstMatch(in: xml, pattern: "<rootfile[^>]*full-path\\s*=\\s*\"([^\"]+)\""), // 匹配双引号形式
           !path.isEmpty { // 结果非空才采用
            return path.removingPercentEncoding ?? path // 解码 %20 之类的转义
        } // 结束双引号分支
        return TextProcessing.firstMatch(in: xml, pattern: "<rootfile[^>]*full-path\\s*=\\s*'([^']+)'") // 单引号形式作为兜底
    } // 结束 rootPath

    // MARK: - 路径
    // 本块把 manifest / 目录中的相对 href 归一化成 ZIP 内的绝对条目名

    /// 将 href 相对 OPF 所在目录解析为 ZIP 内路径
    /// - Parameters:
    ///   - base: 基准文件路径（通常是 OPF 或 nav 的条目名）
    ///   - href: 相对链接，可能含 #锚点、?查询串与百分号转义
    /// - Returns: 规范化后的条目路径（无前导 "/"，已处理 "." 与 ".."）
    static func resolve(base: String, href: String) -> String { // EPUBImporter 内部与目录解析共用
        var clean = href // 工作副本
        if let hash = clean.firstIndex(of: "#") { clean = String(clean[..<hash]) } // 去掉 #锚点
        if let query = clean.firstIndex(of: "?") { clean = String(clean[..<query]) } // 去掉 ?查询串
        clean = clean.removingPercentEncoding ?? clean // 百分号解码
        if clean.hasPrefix("/") { clean = String(clean.dropFirst()) } // ZIP 内路径不应以 "/" 开头

        var parts = base.split(separator: "/").map(String.init) // 基准路径按 "/" 拆分
        if !parts.isEmpty { parts.removeLast() } // 去掉文件名，保留目录

        for component in clean.split(separator: "/") { // 逐段处理 href
            switch component { // 处理特殊段
            case ".", "": continue // "." 与空段直接忽略
            case "..": if !parts.isEmpty { parts.removeLast() } // 回退一级目录
            default: parts.append(String(component)) // 普通段追加
            } // 结束路径段 switch
        } // 结束 href 段遍历
        return parts.joined(separator: "/") // 用 "/" 重新拼接为条目名
    } // 结束 resolve

    // MARK: - 目录标题
    // 本块分别解析 EPUB3 nav 与 EPUB2 NCX，产出「文件路径 → 标题」映射

    /// 解析 EPUB3 nav.xhtml 中的 <a href> 链接，建立路径到标题的映射
    /// - Parameters:
    ///   - html: nav 文档内容
    ///   - basePath: nav 在 ZIP 中的路径，用于解析相对 href
    /// - Returns: 小写路径 → 标题；无匹配返回空字典
    private static func parseNavTitles(_ html: String, basePath: String) -> [String: String] { // 由 load 调用
        var map: [String: String] = [:] // 结果映射
        guard let regex = try? NSRegularExpression(pattern: "(?is)<a[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", options: []) else { // 匹配所有带 href 的 <a> 标签
            return map // 正则失败返回空映射
        } // 结束正则编译 guard
        let ns = html as NSString // 转 NSString 以取子串
        for match in regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { // 遍历每个链接
            let href = ns.substring(with: match.range(at: 1)) // 第 1 组：链接地址
            var title = ns.substring(with: match.range(at: 2)) // 第 2 组：链接内 HTML
            title = TextProcessing.replacing(title, pattern: "(?s)<[^>]+>", template: "") // 去掉内部标签
            title = TextProcessing.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines) // 还原实体并去空白
            let key = resolve(base: basePath, href: href).lowercased() // 解析成条目路径并小写化作为键
            if !title.isEmpty, map[key] == nil { map[key] = title } // 首次出现才记录，保留上级目录标题
        } // 结束链接遍历
        return map // 返回映射
    } // 结束 parseNavTitles

    /// 解析 EPUB2 toc.ncx 的 navPoint，建立路径到标题的映射
    /// - Parameters:
    ///   - xml: NCX 文档内容
    ///   - basePath: NCX 在 ZIP 中的路径
    /// - Returns: 小写路径 → 标题；无匹配返回空字典
    private static func parseNCX(_ xml: String, basePath: String) -> [String: String] { // 由 load 调用
        var map: [String: String] = [:] // 结果映射
        guard let regex = try? NSRegularExpression( // 编译匹配 navPoint 的正则
            pattern: "(?is)<navPoint\\b[^>]*>\\s*<navLabel[^>]*>\\s*<text[^>]*>(.*?)</text>.*?<content[^>]*src\\s*=\\s*[\"']([^\"']+)[\"']", // 一次同时捕获 navLabel 文本与 content src
            options: [] // 无额外选项
        ) else { return map } // 正则失败返回空映射
        let ns = xml as NSString // 转 NSString 以取子串
        for match in regex.matches(in: xml, options: [], range: NSRange(location: 0, length: ns.length)) { // 遍历每个 navPoint
            var title = ns.substring(with: match.range(at: 1)) // 第 1 组：目录标题（可能含标签）
            title = TextProcessing.decodeEntities(TextProcessing.replacing(title, pattern: "(?s)<[^>]+>", template: "")) // 去标签并还原实体
                .trimmingCharacters(in: .whitespacesAndNewlines) // 去掉首尾空白
            let src = ns.substring(with: match.range(at: 2)) // 第 2 组：content 的 src 地址
            let key = resolve(base: basePath, href: src).lowercased() // 解析成条目路径并小写化
            if !title.isEmpty, map[key] == nil { map[key] = title } // 首次出现才记录
        } // 结束 navPoint 遍历
        return map // 返回映射
    } // 结束 parseNCX
} // 结束 EPUBImporter

// MARK: - OPF
// 本块用 XMLParser 事件式解析 OPF：收集 dc:title、dc:creator、manifest 的 item 与 spine 的 itemref

/// OPF 文档解析器：以 XMLParserDelegate 收集书名、作者、manifest 条目与 spine 顺序
final class OPFDocument: NSObject, XMLParserDelegate { // 继承 NSObject 以适配 XMLParserDelegate（NSObjectProtocol）
    /// manifest 中的单个条目
    struct Item { // 对应 <item> 元素
        var id: String // 条目 id，spine 的 idref 指向它
        var href: String // 相对 OPF 的文件路径
        var mediaType: String // MIME 类型，用于识别 ncx
        var properties: String // EPUB3 属性串，含 "nav" 表示导航文档
    } // 结束 Item 定义

    private(set) var title: String? // dc:title 文本（取第一个非空）
    private(set) var author: String? // dc:creator 文本（取第一个非空）
    private(set) var items: [Item] = [] // manifest 条目列表
    private(set) var spine: [String] = [] // spine 中的 idref 顺序，即阅读顺序

    private var currentElement = "" // 当前正在读取的元素名（已去掉命名空间前缀）
    private var buffer = "" // 当前元素的字符缓冲
    private var sawTitle = false // 是否已采集到标题，避免重复覆盖
    private var sawCreator = false // 是否已采集到作者

    /// 解析 OPF 字节，返回填充好的文档对象（解析失败时字段为空但不抛错）
    /// - Parameter data: OPF 文件内容
    /// - Returns: 已收集元数据的 OPFDocument 实例
    static func parse(_ data: Data) -> OPFDocument { // EPUBImporter.load 中调用
        let doc = OPFDocument() // 创建接收解析事件的委托对象
        let parser = XMLParser(data: data) // 创建 XML 解析器
        parser.delegate = doc // 把事件回调指向自身
        parser.parse() // 同步解析；失败时静默返回已收集到的部分
        return doc // 返回结果对象
    } // 结束 parse

    /// XMLParserDelegate：元素开始回调，记录元素名并按 <item>/<itemref> 收集数据
    /// - Parameters:
    ///   - parser: 触发事件的解析器
    ///   - elementName: 元素名（可能带命名空间前缀）
    ///   - namespaceURI: 命名空间 URI（未使用）
    ///   - qName: 限定名（未使用）
    ///   - attributeDict: 元素属性字典
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, // 开始元素回调
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) { // 属性字典带默认值以满足协议
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName // 去掉命名空间前缀，如 dc:title → title
        currentElement = name // 记录当前元素，供字符回调判断
        buffer = "" // 清空字符缓冲

        if name == "item" { // manifest 条目
            items.append(Item( // 立即收集属性
                id: attributeDict["id"] ?? "", // 条目 id
                href: attributeDict["href"] ?? "", // 相对路径
                mediaType: attributeDict["media-type"] ?? "", // MIME 类型
                properties: attributeDict["properties"] ?? "" // EPUB3 属性
            )) // 结束 Item 初始化
        } else if name == "itemref" { // spine 中的阅读顺序项
            if let idref = attributeDict["idref"] { spine.append(idref) } // 记录指向的 manifest id
        } // 结束元素分派
    } // 结束 didStartElement

    /// XMLParserDelegate：字符数据回调，把文本累积到缓冲区
    /// - Parameters:
    ///   - parser: 触发事件的解析器
    ///   - string: 本次读到的字符片段
    func parser(_ parser: XMLParser, foundCharacters string: String) { // 文本可能分多段回调，必须累积
        buffer += string // 追加到当前元素缓冲
    } // 结束 foundCharacters

    /// XMLParserDelegate：元素结束回调，把缓冲文本写入 title / author
    /// - Parameters:
    ///   - parser: 触发事件的解析器
    ///   - elementName: 元素名（可能带命名空间前缀）
    ///   - namespaceURI: 命名空间 URI（未使用）
    ///   - qName: 限定名（未使用）
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, // 结束元素回调
                qualifiedName qName: String?) { // 无属性参数
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName // 去掉命名空间前缀
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines) // 取出并清洗缓冲文本
        if name == "title", !sawTitle, !value.isEmpty { // 第一个非空 title 即书名
            title = value // 记录书名
            sawTitle = true // 标记已采集，忽略后续
        } else if name == "creator", !sawCreator, !value.isEmpty { // 第一个非空 creator 即作者
            author = value // 记录作者
            sawCreator = true // 标记已采集
        } // 结束元数据采集分支
        buffer = "" // 清空缓冲，避免影响后续元素
        currentElement = "" // 复位当前元素
    } // 结束 didEndElement
} // 结束 OPFDocument
