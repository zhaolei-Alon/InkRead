//
//  InkReadApp.swift
//  墨读 InkRead —— 应用入口，创建全局状态对象并注入根视图
//
//  职责：
//    · 定义库页使用的配色常量 AppTheme（纸色、墨色、强调色）
//    · 以 @main 声明 App，创建 LibraryStore / ReaderSettingsStore / BookmarkStore 三个全局状态
//    · 通过 WindowGroup 承载 LibraryView，并用 environmentObject 注入上述三个仓库
//  上层调用者：iOS 系统（App 生命周期），无业务层调用者
//  下层依赖：LibraryStore（书库与正文文件）、ReaderSettingsStore（阅读设置持久化）、BookmarkStore（书签持久化）、LibraryView（根界面）
//  关键流程：启动 → 构造三个 @StateObject → LibraryView 读取环境对象 → 用户点开书籍后 LibraryView 再把它们传给 ReaderView
//

import SwiftUI // 引入 SwiftUI，提供 App、Scene、WindowGroup 与 @StateObject

/// 库页（书库界面）配色常量。
/// LibraryView 及书库卡片、按钮等子视图统一引用，保证书库整体视觉一致。
enum AppTheme { // 声明书库配色命名空间枚举
    static let paper = Color(hex: 0xF7F1E4) // 书库背景的纸色（浅米色）
    static let ink = Color(hex: 0x2C2A26) // 主文字与图标的墨色（近黑）
    static let accent = Color(hex: 0xB4553B) // 强调色（朱砂红），用于按钮与高亮
} // 结束 AppTheme 枚举

/// 应用入口。
/// 负责在启动时构建三个 Store，并把它们注入到 LibraryView 的环境中；
/// ReaderView 通过 LibraryView 的导航跳转继续使用这些同一份实例，保证状态一致。
@main // 标记为应用入口，由系统调用
struct InkReadApp: App { // 声明 App 结构体
    @StateObject private var library = LibraryStore() // 全局书库仓库：书籍元数据、正文与章节的落盘读写
    @StateObject private var settings = ReaderSettingsStore() // 全局阅读设置仓库：主题、字体、排版、翻页方式
    @StateObject private var bookmarks = BookmarkStore() // 全局书签仓库：书签的增删与持久化

    /// 应用场景体。
    /// - Returns: 承载 LibraryView 的 WindowGroup；无副作用，仅在启动时构建一次。
    var body: some Scene { // 定义场景构建属性
        WindowGroup { // 声明主窗口组
            LibraryView() // 根视图为书库页
                .environmentObject(library) // 注入书库仓库，供 LibraryView 及其子视图读取
                .environmentObject(settings) // 注入阅读设置仓库，供设置面板与阅读器读取
                .environmentObject(bookmarks) // 注入书签仓库，供阅读器页签与书签列表读取
        } // 结束 WindowGroup 内容
    } // 结束 body 属性
} // 结束 InkReadApp 结构体
