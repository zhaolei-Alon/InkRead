//
//  ChapterSplitter.swift
//  墨读 InkRead —— 把整篇文本切成可导航的章节（RawChapter 列表）
//
//  职责：
//    · 用正则识别中文章节名（第X章/回/卷、序章、番外…）、英文章节名（Chapter/Part）与 Markdown 标题
//    · 识别不到标题或有效标题少于 2 个时，按目标长度在段落边界智能分块
//    · 通过扩展为 TextProcessing 补充章节标题清洗方法 cleanChapterTitle
//  上层调用者：BookImporter.load(url:) 各格式分支、BookImporter.makeDraft(title:author:format:text:source:)
//  下层依赖：Foundation（NSString、NSRegularExpression）、TextProcessing.cleanChapterTitle 与 TextProcessing.replacing
//  关键流程：TextProcessing 规范化文本 → 正则匹配标题行 → 按标题位置切出 body → [RawChapter] → BookImporter.assemble 按 UTF-16 计算偏移
//

import Foundation // 引入 Foundation：NSString、NSRegularExpression、CharacterSet

/// 章节切分：支持中文章节名、英文章节名、Markdown 标题；无标题时按长度智能分节。
enum ChapterSplitter { // 纯静态工具，无状态

    private static let plainPattern = "(?m)^[ \\t\\u3000]*(?:第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回卷部篇集](?:[ \\t·:：、.．\\-—]+[^\\n]{0,36})?|(?:序章|序言|楔子|引子|前言|自序|后记|尾声|终章|番外|外传)(?:[ \\t·:：、.．\\-—]+[^\\n]{0,30})?|(?:Chapter|CHAPTER|Part|PART)[ \\t]+[0-9IVXLCivxlc]+(?:[ \\t.:：\\-—]+[^\\n]{0,50})?)[ \\t]*$" // 纯文本标题行正则：中文“第X章/回/卷”系列、序章/楔子/番外等特名、英文 Chapter/Part 编号，整行匹配

    private static let markdownPattern = "(?m)^[ \\t]*#{1,6}[ \\t]+[^\\n]{1,60}$" // Markdown 标题行正则：# 到 ###### 开头且标题不超 60 字

    /// 按章节标题切分全文；无法识别（有效标题 < 2）时退化为按长度分块
    /// - Parameters:
    ///   - text: 已规范化的纯文本（通常来自 TextProcessing.normalize / plainText）
    ///   - markdownHeadings: true 时使用 Markdown 的 # 标题正则，false 时使用中英文标题正则
    /// - Returns: 章节数组；极端情况下返回 chunk 的结果，可能为空数组
    static func split(_ text: String, markdownHeadings: Bool = false) -> [RawChapter] { // 切章主入口，BookImporter 各分支调用
        let ns = text as NSString // 转 NSString，所有位置与长度均按 UTF-16 计
        let pattern = markdownHeadings ? markdownPattern : plainPattern // 依调用场景选择标题正则
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { // 编译正则
            return chunk(text) // 编译失败时退化为按长度分块
        } // 结束正则编译 guard
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) // 找出所有候选标题行
        let valid = matches.filter { match in // 过滤掉明显不像标题的匹配
            let title = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines) // 取出标题行文本并去首尾空白
            return title.count <= 50 // 超过 50 字的多半是正文句子，视为无效标题
        } // 结束无效标题过滤

        // 少于两个标题时按长度分节，避免误判
        guard valid.count >= 2 else { // 只有一个标题无法构成章节结构
            return chunk(text) // 退化为按长度智能分块
        } // 结束标题数量判断

        var chapters: [RawChapter] = [] // 累积切分出的章节
        let prefaceRange = NSRange(location: 0, length: valid[0].range.location) // 第一个标题之前的区域，即卷首内容
        let preface = ns.substring(with: prefaceRange).trimmingCharacters(in: .whitespacesAndNewlines) // 取出卷首文本

        for (i, match) in valid.enumerated() { // 逐个标题生成章节
            let titleRaw = ns.substring(with: match.range) // 原始标题行（含 Markdown 的 # 号）
            var title = TextProcessing.cleanChapterTitle(titleRaw) // 清洗标题：去掉 # 与多余空白
            if title.isEmpty { title = "第 \(i + 1) 章" } // 标题清洗后为空则给序号名

            let bodyEnd = i + 1 < valid.count ? valid[i + 1].range.location : ns.length // 本节正文结束位置：下一标题起点或全文末尾
            let bodyStart = match.range.location + match.range.length // 本节正文起点：标题行结尾
            guard bodyEnd > bodyStart else { continue } // 标题紧邻下一标题（无正文）则跳过
            var body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart)) // 截取本节正文
            body = body.trimmingCharacters(in: .whitespacesAndNewlines) // 去掉正文首尾空白

            if i == 0, !preface.isEmpty { // 卷首内容只并入第一章
                let looksLikeMetadata = preface.count < 200 && ( // 短卷首且含作者/简介字样，判为元信息而非正文
                    preface.contains("作者") || preface.contains("简介") || // 中文元信息关键字
                    preface.lowercased().contains("author") // 英文元信息关键字
                ) // 结束元信息判断
                if preface.count > 200 { // 长卷首视为独立的序章内容
                    chapters.append(RawChapter(title: "序章", body: preface)) // 作为“序章”单独成章
                } else if !looksLikeMetadata { // 短且不像元信息时并入第一章正文
                    body = preface + "\n\n" + body // 用空行把卷首与第一章正文拼接
                } // 结束卷首处理分支
            } // 结束第一章卷首判断
            if !body.isEmpty { // 正文非空才收录
                chapters.append(RawChapter(title: title, body: body)) // 记录章节标题与正文
            } // 结束章节收录判断
        } // 结束标题遍历

        return chapters.isEmpty ? chunk(text) : chapters // 一个有效章节都没产出时退化为按长度分块
    } // 结束 split

    /// 无章节标题时，按 5000 字左右在段落边界智能切分
    /// - Parameters:
    ///   - text: 已规范化的纯文本
    ///   - targetLength: 目标章节长度（UTF-16 长度近似字数），默认 5000
    /// - Returns: 以“第 N 节”命名的章节数组；空文本返回空数组
    static func chunk(_ text: String, targetLength: Int = 5000) -> [RawChapter] { // 无标题文本的兜底分块
        let ns = text as NSString // 转 NSString 以按 UTF-16 取子串与查找
        guard ns.length > 0 else { return [] } // 空文本直接返回空数组
        var chapters: [RawChapter] = [] // 累积分块结果
        var start = 0 // 当前分块的起始位置
        var index = 1 // 分块序号，用于生成“第 N 节”

        while start < ns.length { // 从前往后逐块滑动
            var end = min(start + targetLength, ns.length) // 先取目标长度处作为块尾
            if end < ns.length { // 尚未到文末时才需要对齐段落边界
                let searchRange = NSRange(location: max(start + targetLength - 1200, start), length: min(1200, end - start)) // 在块尾前 1200 字范围内寻找换行
                let breakRange = ns.rangeOfCharacter(from: .newlines, options: .backwards, range: searchRange) // 从后往前找最近的换行符
                if breakRange.location != NSNotFound, breakRange.location > start + 500 { // 找到换行且不会切出过短的块
                    end = breakRange.location // 把块尾对齐到换行处
                } else if end > 0 { // 找不到合适换行时退回按字符边界处理
                    // 避免截断组合字符 / 代理对
                    let composed = ns.rangeOfComposedCharacterSequence(at: end - 1) // 取块尾字符所在的完整组合字符序列
                    end = max(end, composed.location + composed.length) // 保证块尾不落在组合字符中间
                } // 结束块尾调整分支
            } // 结束段落边界对齐块
            var body = ns.substring(with: NSRange(location: start, length: end - start)) // 截取当前块文本
            body = body.trimmingCharacters(in: .whitespacesAndNewlines) // 去掉块首尾空白
            if !body.isEmpty { // 非空块才收录
                chapters.append(RawChapter(title: "第 \(index) 节", body: body)) // 以序号命名该节
                index += 1 // 序号自增
            } // 结束空块判断
            start = end // 推进到下一块起点
        } // 结束分块循环
        return chapters // 返回分块结果
    } // 结束 chunk
} // 结束 ChapterSplitter

/// 为 TextProcessing 补充章节标题清洗能力（切章专用，故放在本文件而非 TextProcessing.swift）
extension TextProcessing { // 扩展命名空间，保持切章逻辑内聚
    /// 清洗章节标题行：去掉 Markdown 的 # 号，压缩连续空白为单个半角空格
    /// - Parameter raw: 原始标题行（可能带 # 前缀与全角空格）
    /// - Returns: 可展示的章节标题；可能为空串，由调用方兜底命名
    static func cleanChapterTitle(_ raw: String) -> String { // ChapterSplitter.split 内部调用
        var title = raw // 工作副本
            .replacingOccurrences(of: "#", with: "") // 去掉 Markdown 标题的 # 前缀
            .trimmingCharacters(in: .whitespacesAndNewlines) // 去掉首尾空白
        title = replacing(title, pattern: "[\\s\\u3000]+", template: " ") // 连续空白（含全角空格）压缩为单个空格
        return title // 返回清洗后的标题
    } // 结束 cleanChapterTitle
} // 结束 TextProcessing 扩展
