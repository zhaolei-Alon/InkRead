//
//  ZipReader.swift
//  墨读 InkRead —— 极简 ZIP 解包器，为 EPUB 提供条目读取与 zlib raw inflate 能力
//
//  职责：
//    · 扫描 EOCD（中央目录结束记录），解析中央目录得到条目名、压缩方式、压缩/原始大小、本地头偏移
//    · 按条目名读取数据：stored(0) 直接返回，deflate(8) 用 zlib 的 raw inflate（windowBits = -15）解压
//    · 提供 fileNames() 供 EPUBImporter 在 spine 为空时按文件名兜底遍历
//  上层调用者：EPUBImporter.load(url:)（创建实例并调用 data(for:) / fileNames()）
//  下层依赖：Foundation（Data、String(decoding:)）、zlib（z_stream、inflateInit2_、inflate、inflateEnd）
//  关键流程：EPUB 字节 → ZipReader(data:) 解析中央目录 → data(for: "META-INF/container.xml"/OPF/章节 xhtml) → 交给 TextProcessing 解码
//

import Foundation // 引入 Foundation：Data、String(decoding:as:)
import zlib // 引入系统 zlib：raw inflate 解压 deflate 条目

/// ZIP 解析过程中的错误类型
enum ZipError: Error { // 由 ZipReader 内部抛出，EPUBImporter 侧统一转换为 ImportError.damagedEPUB
    case notZip // 找不到 EOCD 或中央目录非法，说明不是 ZIP
    case zip64Unsupported // 命中 ZIP64 标记，本实现不支持
    case corruptEntry // 本地文件头缺失或字段越界
    case inflateFailed // deflate 解压失败或输出缓冲多次扩容仍不足
} // 结束 ZipError 定义

/// 单个 ZIP 条目的元信息（来自中央目录）
struct ZipEntry { // 只保留解包所需的字段
    let name: String // 条目名（已去掉开头的 "./"，使用 "/" 分隔）
    let method: UInt16 // 压缩方式：0 = stored，8 = deflate
    let compressedSize: Int // 压缩后字节数
    let uncompressedSize: Int // 解压后字节数（用于预分配输出缓冲）
    let localHeaderOffset: Int // 本地文件头在文件中的偏移
} // 结束 ZipEntry 定义

/// 极简 ZIP 读取器：只解析中央目录，支持 stored / deflate（EPUB 所需）。
final class ZipReader { // 引用类型：持有一份字节数组与条目索引
    private let bytes: [UInt8] // 整个 ZIP 的字节副本，便于随机下标访问
    private(set) var entries: [String: ZipEntry] = [:] // 条目名 → 条目元信息（对外只读）

    /// 构造并立即解析中央目录
    /// - Parameter data: 完整 ZIP 文件字节（即 EPUB 文件内容）
    /// - Throws: ZipError.notZip / .zip64Unsupported
    init(data: Data) throws { // EPUBImporter 中由 EPUB 文件字节创建
        bytes = [UInt8](data) // 转成字节数组，后续全部按下标读取
        try parseCentralDirectory() // 解析中央目录，失败则构造失败
    } // 结束 init

    /// 读取指定条目的原始（已解压）数据
    /// - Parameter name: 条目路径（可带 "./" 前缀，内部会规范化）
    /// - Returns: 条目数据；条目不存在或解包失败时返回 nil（调用方据此跳过该文件）
    func data(for name: String) -> Data? { // EPUBImporter 读取 container.xml / OPF / 章节文件
        let key = name.hasPrefix("./") ? String(name.dropFirst(2)) : name // 去掉可能存在的 "./" 前缀
        guard let entry = entries[key] else { return nil } // 条目不存在直接返回 nil
        return try? extract(entry) // 解包失败同样返回 nil，交由上层跳过
    } // 结束 data(for:)

    /// 列出所有条目名（顺序不保证）
    /// - Returns: 条目名数组；EPUBImporter 在 spine 为空或找不到 OPF 时用它兜底搜索
    func fileNames() -> [String] { Array(entries.keys) } // 字典键转数组返回

    // MARK: - 解析
    // 本块定位 EOCD 并逐条读取中央目录记录，填充 entries

    /// 从文件尾部向前搜索 EOCD（0x06054b50），再按记录中的偏移解析全部条目
    /// - Throws: ZipError.notZip（文件过小/找不到 EOCD/偏移非法/无条目）、ZipError.zip64Unsupported
    private func parseCentralDirectory() throws { // 由 init 调用
        guard bytes.count > 22 else { throw ZipError.notZip } // 小于 EOCD 最小长度（22 字节）不可能是 ZIP
        var eocd = -1 // EOCD 位置，-1 表示未找到
        let lowerBound = max(0, bytes.count - 66_000) // 搜索下界：ZIP 注释最长 65535，故最多回退 66000 字节
        var i = bytes.count - 22 // 从理论上最靠后的 EOCD 位置开始
        while i >= lowerBound { // 向前逐字节扫描
            if u32(i) == 0x06054b50 { // 命中 EOCD 签名
                eocd = i // 记录位置
                break // 停止扫描
            } // 结束签名判断
            i -= 1 // 继续向前
        } // 结束 EOCD 搜索循环
        guard eocd >= 0 else { throw ZipError.notZip } // 没找到 EOCD 说明不是 ZIP

        let count = Int(u16(eocd + 10)) // 条目总数（偏移 10 处的 2 字节）
        let cdOffset = Int(u32(eocd + 16)) // 中央目录起始偏移（偏移 16 处的 4 字节）
        guard cdOffset > 0, cdOffset < bytes.count else { throw ZipError.notZip } // 偏移必须落在文件内
        if cdOffset == 0xFFFF_FFFF || count == 0xFFFF { // 命中 ZIP64 的哨兵值
            throw ZipError.zip64Unsupported // 明确拒绝，避免解析错乱
        } // 结束 ZIP64 判断

        var offset = cdOffset // 当前解析位置，从中央目录起点开始
        for _ in 0..<count { // 逐个读取中央目录记录
            guard offset + 46 <= bytes.count, u32(offset) == 0x02014b50 else { break } // 固定头长度不足或签名不符则停止
            let method = u16(offset + 10) // 压缩方式（偏移 10）
            let compressedSize = Int(u32(offset + 20)) // 压缩大小（偏移 20）
            let uncompressedSize = Int(u32(offset + 24)) // 原始大小（偏移 24）
            let nameLength = Int(u16(offset + 28)) // 文件名长度（偏移 28）
            let extraLength = Int(u16(offset + 30)) // 扩展字段长度（偏移 30）
            let commentLength = Int(u16(offset + 32)) // 注释长度（偏移 32）
            let localOffset = Int(u32(offset + 42)) // 本地文件头偏移（偏移 42）

            guard offset + 46 + nameLength <= bytes.count else { break } // 文件名越界则停止解析
            let nameBytes = bytes[(offset + 46)..<(offset + 46 + nameLength)] // 取出文件名原始字节
            let name = String(decoding: nameBytes, as: UTF8.self) // 按 UTF-8 解码（EPUB 条目名通常是 ASCII）
            let key = name.hasPrefix("./") ? String(name.dropFirst(2)) : name // 规范化：去掉 "./" 前缀

            entries[key] = ZipEntry( // 写入条目索引
                name: key, // 规范化后的条目名
                method: method, // 压缩方式
                compressedSize: compressedSize, // 压缩大小
                uncompressedSize: uncompressedSize, // 原始大小
                localHeaderOffset: localOffset // 本地头偏移
            ) // 结束 ZipEntry 初始化
            offset += 46 + nameLength + extraLength + commentLength // 跳到下一条中央目录记录
        } // 结束中央目录遍历

        if entries.isEmpty { throw ZipError.notZip } // 一条都没解析出来视为非 ZIP
    } // 结束 parseCentralDirectory

    /// 解包单个条目：定位本地文件头，取出压缩数据，按 method 分派 stored / deflate
    /// - Parameter entry: 中央目录给出的条目元信息
    /// - Returns: 解压后的数据
    /// - Throws: ZipError.corruptEntry（头部异常/不支持的方法）、ZipError.inflateFailed
    private func extract(_ entry: ZipEntry) throws -> Data { // 由 data(for:) 调用
        let header = entry.localHeaderOffset // 本地文件头位置
        guard header + 30 <= bytes.count, u32(header) == 0x04034b50 else { // 本地头签名与长度校验
            throw ZipError.corruptEntry // 头部损坏
        } // 结束本地头校验
        let nameLength = Int(u16(header + 26)) // 本地头中的文件名长度（偏移 26）
        let extraLength = Int(u16(header + 28)) // 本地头中的扩展字段长度（偏移 28）
        let dataStart = header + 30 + nameLength + extraLength // 数据区起点 = 头长 30 + 文件名 + 扩展
        guard dataStart + entry.compressedSize <= bytes.count else { throw ZipError.corruptEntry } // 数据区越界
        let payload = Data(bytes[dataStart..<(dataStart + entry.compressedSize)]) // 截取压缩数据

        switch entry.method { // 按压缩方式分派
        case 0: // stored：未压缩
            return payload // 原样返回
        case 8: // deflate：需要 raw inflate
            return try inflateRaw(payload, expectedSize: entry.uncompressedSize) // 解压后返回
        default: // 其它压缩算法（如 bzip2、LZMA）不支持
            throw ZipError.corruptEntry // 视为损坏条目
        } // 结束压缩方式分派
    } // 结束 extract

    /// 使用 zlib 做 raw deflate 解压（windowBits = -15，不带 zlib 头）
    /// - Parameters:
    ///   - input: 压缩数据
    ///   - expectedSize: 中央目录声明的原始大小，用于预分配输出缓冲
    /// - Returns: 解压后的数据
    /// - Throws: ZipError.inflateFailed（初始化失败、非流结束、或 4 次扩容仍不足）
    private func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data { // 由 extract 调用
        guard !input.isEmpty else { return Data() } // 空压缩数据对应空内容
        var capacity = max(expectedSize, 4096) // 初始输出容量：至少 4KB，避免小文件也分配过小

        for _ in 0..<4 { // 最多尝试 4 次，每次失败就放大容量
            var output = [UInt8](repeating: 0, count: capacity) // 预分配输出缓冲
            var stream = z_stream() // zlib 流状态结构体
            var initResult: Int32 = Z_OK // 初始化结果
            var inflateResult: Int32 = Z_OK // 解压结果

            input.withUnsafeBytes { rawBuffer in // 以指针方式访问输入数据（zlib 需要裸指针）
                guard let inBase = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { return } // 取输入首地址，空则直接返回
                stream.next_in = UnsafeMutablePointer(mutating: inBase) // 设置输入指针（解除不可变限制）
                stream.avail_in = uInt(input.count) // 设置可读输入字节数
                initResult = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) // 初始化 raw inflate（-15 表示无 zlib 头）
                guard initResult == Z_OK else { return } // 初始化失败则跳过后续
                output.withUnsafeMutableBufferPointer { outBuffer in // 以可变指针方式访问输出缓冲
                    stream.next_out = outBuffer.baseAddress // 设置输出指针
                    stream.avail_out = uInt(outBuffer.count) // 设置可写空间
                    inflateResult = inflate(&stream, Z_FINISH) // 一次性解压到缓冲，Z_FINISH 表示期望一次完成
                } // 结束输出缓冲闭包
                inflateEnd(&stream) // 释放 zlib 内部状态
            } // 结束输入缓冲闭包

            if initResult == Z_OK, inflateResult == Z_STREAM_END { // 正常解压完成
                let written = min(Int(stream.total_out), output.count) // 实际写入字节数（做上界保护）
                return Data(output[0..<written]) // 截取有效部分返回
            } // 结束成功分支
            if initResult == Z_OK, inflateResult == Z_BUF_ERROR || stream.avail_out == 0 { // 输出缓冲不足，需要扩容重试
                capacity *= 4 // 容量放大 4 倍
                continue // 进入下一轮尝试
            } // 结束扩容分支
            throw ZipError.inflateFailed // 其它情况视为数据损坏
        } // 结束重试循环
        throw ZipError.inflateFailed // 4 次扩容后仍失败
    } // 结束 inflateRaw

    /// 读取小端 16 位无符号整数
    /// - Parameter offset: 起始字节下标
    /// - Returns: 解析值；越界时返回 0（调用方随后会因签名不符而报错）
    private func u16(_ offset: Int) -> UInt16 { // ZIP 字段均为小端
        guard offset >= 0, offset + 1 < bytes.count else { return 0 } // 越界保护
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) // 低字节 + 高字节左移 8 位
    } // 结束 u16

    /// 读取小端 32 位无符号整数
    /// - Parameter offset: 起始字节下标
    /// - Returns: 解析值；越界时返回 0
    private func u32(_ offset: Int) -> UInt32 { // ZIP 字段均为小端
        guard offset >= 0, offset + 3 < bytes.count else { return 0 } // 越界保护
        return UInt32(bytes[offset]) // 第 1 个字节（最低位）
            | (UInt32(bytes[offset + 1]) << 8) // 第 2 个字节左移 8 位
            | (UInt32(bytes[offset + 2]) << 16) // 第 3 个字节左移 16 位
            | (UInt32(bytes[offset + 3]) << 24) // 第 4 个字节左移 24 位
    } // 结束 u32
} // 结束 ZipReader
