//
//  NetworkMonitor.swift
//  墨读 InkRead —— 基于 NWPathMonitor 的网络类型观察器
//
//  职责：
//    · 单例监听系统网络路径变化，产出 wifi / cellular / wired / offline / unknown 状态
//    · 提供状态栏所需的 SF Symbol 名称与中文文案
//  上层调用者：ReaderView（阅读页自定义状态栏，@ObservedObject 订阅 NetworkMonitor.shared；页面出现时 start()）
//  下层依赖：Network 框架的 NWPathMonitor / NWPath、DispatchQueue、SwiftUI 可观察机制
//  关键流程：start() 启动监控 → pathUpdateHandler 在后台队列判定接口类型 → 主队列更新 @Published status → ReaderView 状态栏刷新图标与文案
//

import Foundation // 引入 Foundation：DispatchQueue 与 ObservableObject 依赖
import Network // 引入 Network 框架：NWPathMonitor 与 NWInterface 类型

/// 网络状态观察器：全局单例，仅为阅读页状态栏提供网络类型展示
final class NetworkMonitor: ObservableObject { // 可观察对象：status 变化时状态栏自动刷新
    /// 全局共享实例，避免重复创建系统级监控
    static let shared = NetworkMonitor() // 通过 shared 访问，ReaderView 以 @ObservedObject 订阅

    /// 对 NWPath 的网络类型归类，屏蔽系统接口细节
    enum Status { // 仅表达状态栏需要展示的五种情况
        case wifi // 已连接 Wi-Fi
        case cellular // 已连接蜂窝网络
        case wired // 已连接有线以太网（模拟器/外接网卡）
        case offline // 无可用网络路径
        case unknown // 已连通但接口类型无法识别
    } // 结束 Status 枚举

    /// 当前网络状态；初始为 unknown，start 后由系统回调更新
    @Published private(set) var status: Status = .unknown // 只读发布属性，避免外部直接改写

    /// 系统网络路径监控器；start() 时创建，stop() 时取消
    private var monitor = NWPathMonitor() // 持有监控实例以维持回调生命周期
    /// 网络回调专用串行队列，避免占用主线程
    private let queue = DispatchQueue(label: "inkread.network.monitor") // 固定 label 便于 Instruments 排查
    /// 是否已启动，防止重复 start 造成多个监控
    private var started = false // 幂等标记，与 start/stop 成对维护

    /// 启动网络监控（幂等）
    /// - 副作用：创建并启动 NWPathMonitor，路径变化时在主队列更新 status
    func start() { // 由 ReaderView 在页面出现时调用
        guard !started else { return } // 已启动则不重复创建监控
        started = true // 置位启动标记
        monitor = NWPathMonitor() // 重新创建监控实例，确保句柄干净
        monitor.pathUpdateHandler = { [weak self] path in // 路径变化回调，弱引用避免单例被额外持有
            let newStatus: Status // 本次回调计算出的新状态
            if path.status != .satisfied { // 路径不可用时优先判定为离线
                newStatus = .offline // 无网络
            } else if path.usesInterfaceType(.wifi) { // 满足条件且走 Wi-Fi 接口
                newStatus = .wifi // Wi-Fi 状态
            } else if path.usesInterfaceType(.cellular) { // 走蜂窝接口
                newStatus = .cellular // 蜂窝状态
            } else if path.usesInterfaceType(.wiredEthernet) { // 走有线以太网接口
                newStatus = .wired // 有线状态
            } else { // 已连通但接口类型未知（如 VPN、其他虚拟接口）
                newStatus = .unknown // 兜底为未知
            } // 结束 网络类型判定链
            DispatchQueue.main.async { // 回到主线程更新 UI 相关属性
                self?.status = newStatus // 发布新状态，触发状态栏刷新
            } // 结束 主线程更新闭包
        } // 结束 pathUpdateHandler 赋值
        monitor.start(queue: queue) // 在专用队列上开始投递路径回调
    } // 结束 start()

    /// 停止网络监控（幂等）
    /// - 副作用：取消 NWPathMonitor，并把 status 复位为 unknown
    func stop() { // 阅读页退出时调用，节省系统资源
        guard started else { return } // 未启动则无需处理
        started = false // 复位启动标记
        monitor.cancel() // 取消系统监控
        DispatchQueue.main.async { [weak self] in // 主线程复位状态
            self?.status = .unknown // 状态回到未知，避免展示过期网络类型
        } // 结束 主线程复位闭包
    } // 结束 stop()

    /// 状态栏图标名（SF Symbols）
    var symbolName: String { // 由 ReaderView 状态栏绑定到 Image(systemName:)
        switch status { // 按当前状态映射图标
        case .wifi: return "wifi" // Wi-Fi 图标
        case .cellular: return "cellularbars" // 蜂窝信号图标
        case .wired: return "cable.connector" // 有线连接图标
        case .offline: return "wifi.slash" // 断开图标
        case .unknown: return "network" // 通用网络图标
        } // 结束 图标映射 switch
    } // 结束 symbolName

    /// 状态栏文案（简体中文）
    var label: String { // 由 ReaderView 状态栏绑定到 Text
        switch status { // 按当前状态映射文案
        case .wifi: return "WiFi" // Wi-Fi 文案
        case .cellular: return "蜂窝" // 蜂窝文案
        case .wired: return "有线" // 有线文案
        case .offline: return "离线" // 离线文案
        case .unknown: return "网络" // 未知文案
        } // 结束 文案映射 switch
    } // 结束 label
} // 结束 NetworkMonitor 类
