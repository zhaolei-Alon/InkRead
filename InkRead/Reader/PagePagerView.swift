//
//  PagePagerView.swift
//  墨读 InkRead —— UIKit 翻页画布，用 CoreText 直绘单页文字并处理翻页手势
//
//  职责：
//    · 定义分页数据模型 PagerPage / PagerModel 与翻页方向枚举 PageTurnDirection
//    · 定义 PagePagerDelegate 协议，把翻页、点击中央、到达边界三类结果回传给上层
//    · PageCanvasView 负责用 CoreText 把 NSAttributedString 绘制为静态一页
//    · PagePagerView 管理「当前页 + 进场页」两个 PageCanvasView，实现拖拽跟随、回弹与翻页动画
//  上层调用者：ReaderView.swift 中的 PagerContainer（UIViewRepresentable）
//             —— makeUIView / updateUIView 创建并调用 apply(_:)，Coordinator 实现本文件协议
//  下层依赖： PagerPage / PagerModel 数据来自 ReaderViewModel.pagerModel；
//             PageTurnMode、ReaderTheme 来自 Models/ReaderTheme.swift；CoreText 负责排版与绘制
//  关键流程： PagerModel 变化 → apply(_:) → 设置 inset 与文字 → CoreText 直绘；
//             手势 / 点击 → 动画 → delegate 回调 didTurn / tapCenter / reachedBoundary
//             → Coordinator → ReaderViewModel.handleTurn / showChrome 切换 / handleBoundaryReached
//
import UIKit // 引入 UIKit：UIView、手势识别器、UIEdgeInsets、UIView.animate 等
import CoreText // 引入 CoreText：CTFramesetter / CTFrame 用于排版并绘制富文本

/// 单页数据：一页文字及其内容标识
/// 由 ReaderViewModel 分页产出，通过 PagerModel 传给 PagePagerView 绘制
struct PagerPage { // 单页数据容器：内容标识 + 富文本
    let key: String // 内容标识（通常由章节下标 + 页下标组成），用于判断复用页是否需要重绘
    let text: NSAttributedString // 该页已排好样式的富文本，直接交给 CoreText 绘制
} // 结束 PagerPage 结构体

/// 翻页视图的完整渲染模型：当前页 + 前后预载页 + 主题与排版参数
/// 由 ReaderViewModel 以 @Published 输出，PagerContainer 每次刷新时调用 PagePagerView.apply(_:)
struct PagerModel { // 翻页渲染模型：版本号 + 三页数据 + 排版与主题参数
    var revision: Int // 模型版本号，单调递增；页视图仅在版本变化时才真正应用新数据
    var current: PagerPage? // 当前正在显示的页；nil 表示还在分页准备中
    var previous: PagerPage? // 上一页预载内容；nil 表示已到本章/全书开头
    var next: PagerPage? // 下一页预载内容；nil 表示已到本章/全书结尾
    var turnMode: PageTurnMode // 翻页方向模式：横向 or 纵向，决定手势主轴与位移动画轴
    var insets: UIEdgeInsets // 文字绘制内边距（单位 pt），决定 CoreText 文本框的可用区域
    var theme: ReaderTheme // 当前阅读主题，提供背景色与文字样式（颜色在自定义 String 属性中转换）
    var isBusy: Bool = false // 视图是否处于忙碌状态（例如正在重新分页），为 true 时忽略手势
} // 结束 PagerModel 结构体

/// 翻页方向：下一页 / 上一页
/// 被手势逻辑、动画与 delegate 回调共同使用
enum PageTurnDirection { // 翻页方向枚举
    case next // 向后（下一页）翻动
    case previous // 向前（上一页）翻动
} // 结束 PageTurnDirection 枚举

/// 翻页回调协议：PagePagerView 只负责交互与动画，业务推进交给上层 ViewModel
/// 由 PagerContainer.Coordinator 实现并桥接到 ReaderViewModel
protocol PagePagerDelegate: AnyObject { // 轻量回调协议，由 PagerContainer.Coordinator 实现
    /// 一页翻动动画结束后回调，通知上层推进/回退阅读位置
    /// - Parameters:
    ///   - pager: 发出回调的翻页视图
    ///   - direction: 刚刚完成的方向（.next / .previous）
    func pager(_ pager: PagePagerView, didTurn direction: PageTurnDirection) // 翻页完成：上屏页已切换
    /// 点击屏幕中央回调，上层据此呼出/收起阅读菜单（ReaderChrome）
    /// - Parameter pager: 发出回调的翻页视图
    func pagerDidTapCenter(_ pager: PagePagerView) // 中央点击：切换 ReaderViewModel.showChrome
    /// 无更多内容可翻时回调（例如本章最后一页继续后翻），上层据此跨章跳转或提示
    /// - Parameters:
    ///   - pager: 发出回调的翻页视图
    ///   - direction: 触达边界的方向
    func pagerDidReachBoundary(_ pager: PagePagerView, direction: PageTurnDirection) // 到达边界：交给 ViewModel 处理跨章
} // 结束 PagePagerDelegate 协议

// MARK: - 单页绘制
// 该分组只包含 PageCanvasView：一页一个视图，负责把 NSAttributedString 用 CoreText 画到自身图层上，
// 由下方 PagePagerView 创建、设置内容并做位移动画。

/// 使用 CoreText 直接绘制一页文字；layer 自带缓存，翻页只做 GPU 位移，省电且流畅。
/// 不参与事件响应（isUserInteractionEnabled = false），所有手势由父视图 PagePagerView 统一处理。
final class PageCanvasView: UIView { // 单页画布视图：只用 CoreText 绘制，不处理事件
    /// 当前已绘制内容的内容标识；父子视图通过比较 key 判断是否需要重复绘制
    private(set) var contentKey: String = "" // 只允许本类内部写入，外部只读
    /// 页面四周内边距；变化时自动触发重绘
    /// 注意：CoreText 在翻转坐标系下工作，bottom 值对应绘制路径的 y 起点
    var pageInsets: UIEdgeInsets = .zero { // 默认零内边距
        didSet { setNeedsDisplay() } // inset 变化即标记需要重新绘制，UIView 会异步调用 draw(_:)
    } // 结束 pageInsets 属性声明
    /// 待绘制的富文本；nil 或长度为 0 时 draw(_:) 直接返回，画面保持背景色
    private var content: NSAttributedString? // 实际绘制内容，仅在 draw 中读取

    /// 初始化视图，配置透明背景与按需重绘
    /// - Parameter frame: 初始 frame，通常由父视图在 installIncoming 中指定为 bounds
    override init(frame: CGRect) { // 指定初始化器：只做视图基础配置
        super.init(frame: frame) // 调用 UIView 指定初始化器完成基础配置
        isOpaque = false // 背景透明，避免不透明图层带来额外合成开销
        backgroundColor = .clear // 背景色透明，页面底色由 PagePagerView 提供
        contentMode = .redraw // 尺寸变化时重新走 draw(_:)，保证文字按新宽度重新排版
        layer.shouldRasterize = false // 关闭 layer 位图缓存，交给系统按需缓存，避免翻页时重复栅格化
        isUserInteractionEnabled = false // 不接收触摸事件，手势全部上抛给 PagePagerView
    } // 结束 init(frame:)

    /// 不支持从 Storyboard/XIB 反序列化，因为该视图只由代码创建
    /// - Parameter coder: 反序列化解码器（不会真正使用）
    required init?(coder: NSCoder) { // 禁止从 XIB 创建
        fatalError("init(coder:) has not been implemented") // 一旦被 XIB 调用说明使用方式错误，直接崩溃暴露问题
    } // 结束 init?(coder:)

    /// 设置本页要绘制的内容
    /// - Parameters:
    ///   - text: 该页富文本；传 nil 表示清空当前页
    ///   - key: 内容唯一标识，写入 contentKey 供外部判断复用
    /// 副作用：立即标记重绘，下一次绘制周期会调用 CoreText 绘制
    func setContent(_ text: NSAttributedString?, key: String) { // 设置内容并触发重绘
        content = text // 保存富文本引用，供 draw(_:) 使用
        contentKey = key // 记录内容标识，便于调试与后续比较
        setNeedsDisplay() // 请求系统重绘本视图
    } // 结束 setContent(_:key:)

    /// CoreText 绘制入口：把富文本排版进「扣除 inset 后的矩形」，再整体翻转坐标系绘制
    /// - Parameter rect: 系统给出的无效重绘区域（本实现每次整页重绘，未使用该参数）
    override func draw(_ rect: CGRect) { // 绘制入口：CoreText 排版 + 坐标系翻转
        // 缺少绘图上下文、无内容或内容为空时无需绘制，直接返回
        guard let context = UIGraphicsGetCurrentContext(), let content, content.length > 0 else { return } // 三个前置条件任一不满足即退出
        // 文本可用宽度 = 视图宽 - 左右 inset；用 max(1, …) 兜底避免出现 0 或负宽度
        let textWidth = max(1, bounds.width - pageInsets.left - pageInsets.right) // 保证 CoreText 路径宽度至少 1pt
        // 文本可用高度 = 视图高 - 上下 inset；同样兜底为至少 1pt
        let textHeight = max(1, bounds.height - pageInsets.top - pageInsets.bottom) // 保证路径高度非零
        // 翻转后 CoreText 的 y 轴向上，因此路径底边取 bottom inset
        let textRect = CGRect( // 构造 CoreText 使用的文本框矩形
            x: pageInsets.left, // 左边距即左 inset
            y: pageInsets.bottom, // 翻转坐标系中 y 从底部起算，故取 bottom inset 作为左下角 y
            width: textWidth, // 文本框宽度（已扣左右 inset）
            height: textHeight // 文本框高度（已扣上下 inset）
        ).integral // 取整到像素对齐，避免文字发虚（等价于 ceil 对齐 device pixel）
        // 翻转坐标系下 y 从底部起算，矩形上边距顶部的距离 = bounds.height - (y + height) = top inset，上下留白对称

        context.saveGState() // 保存当前图形状态，后续坐标系变换可整体回滚
        // 翻转坐标系，让 CoreText 以左上角为原点绘制
        context.textMatrix = .identity // 重置文本矩阵为单位矩阵，避免上一次绘制的残留变换
        context.translateBy(x: 0, y: bounds.height) // 先把原点平移到视图左下角
        context.scaleBy(x: 1, y: -1) // 再沿 y 轴翻转，使 y 轴向上，从而与 CoreText 坐标系一致
        // 变换后：CoreText 的 (x, y) 对应 UIKit 的 (x, height - y)，故 textRect.y = bottom inset 恰好使文字底边距底部 bottom

        let path = CGPath(rect: textRect, transform: nil) // 用矩形路径作为排版区域，不加额外变换
        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString) // 由富文本创建排版器，内部完成断行计算
        // 从头开始排版整个内容（location 0、length 0 表示一直到字符串末尾），范围超出部分自动截断
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil) // 生成一页 CTFrame
        CTFrameDraw(frame, context) // 把 CTFrame 真正绘制到当前上下文
        context.restoreGState() // 恢复绘图状态，撤销坐标系翻转，避免影响后续绘制
    } // 结束 draw(_:)
} // 结束 PageCanvasView 类

// MARK: - 翻页容器
// 该分组是核心：PagePagerView 持有「当前页 + 进场页」两层 PageCanvasView，
// 通过 transform 位移实现跟手拖动与翻页动画，并在动画结束回调 delegate。

/// 翻页容器：接收 ReaderViewModel 产出的 PagerModel，负责手势判定、翻页动画与回调
/// 只做展示与交互，不修改阅读进度；进度推进由 delegate 交给上层完成后再回流新的 PagerModel
final class PagePagerView: UIView, UIGestureRecognizerDelegate { // 翻页容器：手势判定 + 位移动画 + 回调
    /// 回调代理，通常为 PagerContainer.Coordinator；弱引用避免循环引用
    weak var delegate: PagePagerDelegate? // 回调代理，弱引用避免循环引用

    /// 最近一次应用的渲染模型；手势判定（是否有上/下页、翻页轴向、是否忙碌）依赖它
    private var model: PagerModel? // 未 apply 之前为 nil，此时所有手势直接忽略
    /// 已应用的模型版本号；与 PagerModel.revision 比较，避免同一份数据重复绘制
    private var appliedRevision = -1 // 初始 -1 保证首个 revision 0 也会被应用

    /// 当前展示的页视图，始终铺满容器
    private var currentView = PageCanvasView() // 首次创建即为空白页，apply 后填充内容
    /// 翻页过程中临时插入的「下一页/上一页」视图；动画结束后会被转正或丢弃
    private var incomingView: PageCanvasView? // nil 表示当前没有进行中的进场页
    /// 进场页对应的方向，用于计算其初始位移方向
    private var incomingDirection: PageTurnDirection = .next // 默认按「下一页」方向处理

    /// 是否正在播放动画；为 true 时忽略新手势，防止动画叠加
    private var isAnimating = false // 动画生命周期标记
    /// 是否处于手指按下拖拽状态；用于区分「手势取消」与「未开始拖拽」
    private var isDragging = false // 拖动生命周期标记
    /// 当前生效的拖拽主轴是否为水平；水平翻页模式取翻译量的 x，垂直翻页模式取 y
    private var activeAxisIsHorizontal = true // 每次手势开始会按 turnMode 重置
    /// 是否已锁定拖拽主轴；超过阈值后锁定一次，避免手势中途抖动导致主轴来回切换
    private var dragAxisLocked = false // 每个手势周期开始时复位

    /// 初始化容器，铺好当前页并挂载拖拽、点击两个手势识别器
    /// - Parameter frame: 初始 frame，后续由 Auto Layout / SwiftUI 调整
    override init(frame: CGRect) { // 初始化：搭建视图层级并挂载手势
        super.init(frame: frame) // 调用 UIView 指定初始化器
        clipsToBounds = true // 裁剪子视图，保证翻页时进场页不会溢出容器边界
        backgroundColor = .clear // 背景透明，真实底色由 theme.background 在 apply 时设置
        currentView.frame = bounds // 当前页初始铺满容器
        currentView.autoresizingMask = [.flexibleWidth, .flexibleHeight] // 容器尺寸变化时当前页跟随缩放
        addSubview(currentView) // 把当前页加入视图层级

        // 拖拽手势：一次只允许一根手指，用于跟手翻页
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))) // 创建平移手势并绑定处理函数
        pan.delegate = self // 指定代理，用于控制手势是否可与其他手势并行
        pan.maximumNumberOfTouches = 1 // 只识别单指拖动，避免双指缩放误触发
        addGestureRecognizer(pan) // 把手势挂到容器上

        // 点击手势：用于左右/上下区域翻页与中央呼出菜单
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))) // 创建点击手势并绑定处理函数
        tap.delegate = self // 同样指定代理
        addGestureRecognizer(tap) // 把手势挂到容器上
    } // 结束 init(frame:)

    /// 不允许从 XIB 创建，视图层级完全由代码构建
    /// - Parameter coder: 反序列化解码器（不会被使用）
    required init?(coder: NSCoder) { // 禁止从 XIB 创建
        fatalError("init(coder:) has not been implemented") // 误用时立即失败，便于定位问题
    } // 结束 init?(coder:)

    /// 布局回调：在非动画、非拖拽状态下把当前页复位为铺满容器
    /// 动画/拖动过程中不做布局干预，避免打断 transform 位移
    override func layoutSubviews() { // 布局回调：静止状态下把当前页复位
        super.layoutSubviews() // 先交给 UIView 完成默认布局
        if !isAnimating && !isDragging { // 仅在静止状态复位，防止动画被布局覆盖
            currentView.transform = .identity // 清除可能残留的位移
            currentView.frame = bounds // 当前页重新铺满容器
        } // 结束静止状态判断
    } // 结束 layoutSubviews()

    // MARK: - 应用数据
    // 由 PagerContainer.updateUIView 调用 apply(_:) 灌入新模型，
    // 该分组只负责「按 revision 去重」并重置所有翻页中间态。

    /// 应用新的渲染模型并立即绘制当前页
    /// - Parameter newModel: ReaderViewModel 输出的最新 PagerModel
    /// 副作用：会重置动画/拖拽状态、丢弃进场页，因此必须保证 revision 变化代表一次全新的分页结果
    func apply(_ newModel: PagerModel) { // 应用新模型（按 revision 去重）
        guard newModel.revision != appliedRevision else { return } // 同一版本的数据直接忽略，避免重复绘制
        appliedRevision = newModel.revision // 记录已应用版本
        model = newModel // 保存模型，供后续手势判定使用

        backgroundColor = newModel.theme.background.uiColor // 用主题背景色填充容器
        currentView.pageInsets = newModel.insets // 同步文字内边距（会触发页面重绘）
        currentView.setContent(newModel.current?.text, key: newModel.current?.key ?? "") // 把当前页文字与标识交给画布

        discardIncoming() // 丢弃可能存在的进场页，避免新旧数据混显
        isAnimating = false // 复位动画状态
        isDragging = false // 复位拖拽状态
        currentView.transform = .identity // 清除当前页位移
        currentView.frame = bounds // 当前页重新铺满容器
    } // 结束 apply(_:)

    // MARK: - 手势
    // 点击负责「三区域」快捷翻页与中央呼出菜单；拖拽负责跟手翻页与回弹。
    // 两者都把业务决策交给 delegate，视图本身不改变阅读进度。

    /// 点击处理：左右两侧 28% 区域、上下两端 22% 区域翻页，其余区域视为中央点击
    /// - Parameter gesture: 触发本方法的点击手势
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) { // 点击手势入口
        guard !isAnimating, let model, !model.isBusy else { return } // 动画中/无模型/忙碌时忽略点击
        let point = gesture.location(in: self) // 取点击点在容器坐标系中的位置
        let width = bounds.width // 容器宽度，用于横向三分区判定
        let height = bounds.height // 容器高度，用于纵向分区判定

        // 左右点击翻页
        if point.x < width * 0.28 { // 左侧 28% 区域：上一页
            requestTurn(.previous) // 请求向前翻一页
            return // 命中后直接结束
        } // 结束左侧判定
        if point.x > width * 0.72 { // 右侧 28% 区域：下一页
            requestTurn(.next) // 请求向后翻一页
            return // 命中后直接结束
        } // 结束右侧判定
        // 上下点击翻页
        if point.y < height * 0.22 { // 顶部 22% 区域：上一页
            requestTurn(.previous) // 请求向前翻一页
            return // 命中后直接结束
        } // 结束顶部判定
        if point.y > height * 0.82 { // 底部 22% 区域：下一页
            requestTurn(.next) // 请求向后翻一页
            return // 命中后直接结束
        } // 结束底部判定
        delegate?.pagerDidTapCenter(self) // 中间区域：交给上层切换菜单显隐
    } // 结束 handleTap(_:)

    /// 拖拽处理：跟手位移当前页/进场页，松手后按距离与速度决定提交翻页还是回弹
    /// - Parameter gesture: 触发本方法的平移手势
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) { // 拖拽手势入口
        guard let model, !isAnimating, !model.isBusy else { return } // 动画中/无模型/忙碌时忽略拖拽
        let translation = gesture.translation(in: self) // 取相对手势起点的累计位移（容器坐标系）

        switch gesture.state { // 按手势生命周期分阶段处理
        case .began: // 手指按下开始拖拽
            isDragging = true // 标记进入拖拽状态，阻止 layoutSubviews 复位
            lastOffset = 0 // 清空上一次记录的位移
            dragAxisLocked = false // 主轴尚未锁定，等待首次超阈值位移再决定
            activeAxisIsHorizontal = model.turnMode == .horizontal // 先按阅读设置给一个默认主轴

        case .changed: // 手指移动过程中
            guard isDragging else { return } // 非拖拽态（如被取消后）不再响应
            if !dragAxisLocked { // 主轴未锁定时尝试判定
                let magnitude = max(abs(translation.x), abs(translation.y)) // 取两轴位移的较大绝对值
                guard magnitude > 8 else { return } // 位移小于 8pt 视为抖动/误触，暂不处理
                // 拖动方向自适应：横向或纵向按住拖动都能翻页
                activeAxisIsHorizontal = abs(translation.x) >= abs(translation.y) // 水平位移更大则认定为横向翻页
                dragAxisLocked = true // 锁定主轴，后续不再改变
            } // 结束主轴判定
            let horizontal = activeAxisIsHorizontal // 取当前生效主轴
            let raw = horizontal ? translation.x : translation.y // 按主轴取对应方向的位移量
            guard abs(raw) >= 1 else { return } // 位移过小时忽略，避免无意义的 transform 计算
            lastOffset = raw // 记录最新位移，供松手时判定
            updateDrag(offset: raw, horizontal: horizontal) // 实时更新当前页与进场页的位移

        case .ended, .cancelled, .failed: // 手势结束或被取消
            guard isDragging else { return } // 没进入拖拽态则无需收尾
            isDragging = false // 退出拖拽状态
            guard dragAxisLocked else { // 从未锁定主轴说明位移很小，视为误触
                discardIncoming() // 清理可能已创建的进场页
                currentView.transform = .identity // 当前页复位
                return // 结束处理
            } // 结束主轴锁定判断
            let horizontal = activeAxisIsHorizontal // 取锁定的主轴
            let raw = horizontal ? translation.x : translation.y // 取最终位移
            if abs(raw) >= 1 { lastOffset = raw } // 最终位移有效时覆盖，保证与画面一致
            let velocity = gesture.velocity(in: self) // 取松手瞬间速度（pt/s）
            let speed = horizontal ? velocity.x : velocity.y // 按主轴取速度分量，符号表示方向
            finishDrag(speed: speed) // 根据距离与速度决定提交或回弹

        default: // 其他状态（possible 等）
            break // 不处理
        } // 结束手势状态分支
    } // 结束 handlePan(_:)

    // MARK: - 拖拽逻辑
    // updateDrag 负责「跟手」阶段的实时位移换算，finishDrag 负责「松手」阶段的提交判定，
    // 二者的位移数学为：next 方向进场页初始位于 +dimension（右侧/下方），previous 位于 -dimension。

    /// 跟手阶段：按位移方向安装进场页并实时设置两层页的 transform
    /// - Parameters:
    ///   - offset: 手指沿主轴的累计位移（pt），负值表示向下一页方向拖动
    ///   - horizontal: 主轴是否为水平
    /// 副作用：可能创建并插入进场页视图
    private func updateDrag(offset: CGFloat, horizontal: Bool) { // 跟手阶段的位移换算
        guard let direction = directionForDrag(offset: offset, horizontal: horizontal) else { return } // 位移为 0 等无效情况直接返回
        if incomingView == nil || incomingDirection != direction { // 首次拖动或方向反转时
            installIncoming(direction: direction) // 安装（或重建）对应方向的进场页
        } // 结束进场页准备
        guard let incoming = incomingView else { // 没有可用的进场页说明已到边界
            // 边界：当前页做阻尼跟随
            currentView.transform = transform(offset: offset * 0.18, horizontal: horizontal) // 边界处只跟手 18%，形成阻尼手感
            return // 结束处理
        } // 结束边界分支
        let dimension = horizontal ? bounds.width : bounds.height // 主轴上的容器尺寸，作为一页的位移基准
        // 进场页基准位移：下一页从 +dimension 处进入，上一页从 -dimension 处进入
        let base = direction == .next ? dimension : -dimension // 页码方向的符号基准
        currentView.transform = transform(offset: offset, horizontal: horizontal) // 当前页完全跟手位移
        place(incoming, shift: base + offset, horizontal: horizontal) // 进场页 = 基准位移 + 手指位移，与当前页保持一屏间距
    } // 结束 updateDrag(offset:horizontal:)

    /// 松手阶段：依据拖动进度与速度决定「完成翻页」还是「回弹」
    /// - Parameter speed: 松手瞬间沿主轴的速度（pt/s），符号与拖动方向一致
    /// 副作用：触发 flip 动画，动画结束会回调 delegate 或丢弃进场页
    private func finishDrag(speed: CGFloat) { // 松手判定：提交翻页或回弹
        guard let direction = directionForDrag(offset: lastOffset, horizontal: activeAxisIsHorizontal), // 依据最终位移重新求方向
              direction == incomingDirection else { // 方向必须与已安装的进场页一致，否则无法完成翻页
            snapBack() // 条件不满足：直接回弹
            return // 结束处理
        } // 结束方向一致性判断
        let dimension = activeAxisIsHorizontal ? bounds.width : bounds.height // 主轴尺寸，用于换算进度比例
        guard incomingView != nil else { // 没有进场页（到达边界）时不能提交翻页
            snapBack() // 走回弹路径
            return // 结束处理
        } // 结束进场页存在性判断
        let progress = abs(lastOffset) / max(dimension, 1) // 拖动进度 = 位移绝对值 / 主轴尺寸，范围约 0~1
        let fastEnough = abs(speed) > 420 && speed * lastOffset > 0 // 速度够快且与拖动同向（乘积为正）才算「甩动」
        let shouldCommit = progress > 0.18 || fastEnough // 超过 18% 行程或快速甩动则提交翻页

        if shouldCommit { // 满足提交条件
            animateTurn(direction: direction, horizontal: activeAxisIsHorizontal, commit: true) // 播放完成翻页动画
        } else { // 不满足提交条件
            animateTurn(direction: direction, horizontal: activeAxisIsHorizontal, commit: false) // 播放回弹动画
        } // 结束提交判定
    } // 结束 finishDrag(speed:)

    /// 最近一次沿主轴的拖动位移（pt）；松手判定与进场页计算共用
    private var lastOffset: CGFloat = 0 // 手势结束时会被清 0

    /// 回弹：当前页回到原位，进场页退回一屏之外，随后销毁进场页
    /// 用于「拖动距离不足」「方向无效」「无进场页」等场景
    private func snapBack() { // 回弹到原位
        isAnimating = true // 标记动画开始，期间忽略新手势
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { // 0.2s 缓出，从当前视觉状态继续
            self.currentView.transform = .identity // 当前页回到原点
            if let incoming = self.incomingView { // 若存在进场页，需要同步退回
                let dimension = self.activeAxisIsHorizontal ? self.bounds.width : self.bounds.height // 主轴尺寸
                let base = self.incomingDirection == .next ? dimension : -dimension // 进场页应有的基准位移
                self.place(incoming, shift: base, horizontal: self.activeAxisIsHorizontal) // 把进场页放回一屏之外
            } // 结束进场页处理
        } completion: { _ in // 动画结束回调
            self.discardIncoming() // 销毁进场页
            self.isAnimating = false // 解除动画标记
        } // 结束 completion 闭包
        lastOffset = 0 // 复位位移记录
    } // 结束 snapBack()

    /// 点击/无拖动场景下直接请求翻页
    /// - Parameter direction: 目标方向
    /// 无对应页时播放边界回弹并通知 delegate 触达边界
    private func requestTurn(_ direction: PageTurnDirection) { // 点击翻页入口
        guard !isAnimating, let model, !model.isBusy else { return } // 动画中/无模型/忙碌时忽略
        guard page(for: direction) != nil else { // 目标方向没有预载页
            bounce(at: direction) // 播放撞边回弹
            delegate?.pagerDidReachBoundary(self, direction: direction) // 通知上层处理跨章/结束
            return // 结束处理
        } // 结束边界判断
        activeAxisIsHorizontal = model.turnMode == .horizontal // 按阅读设置决定翻页轴向
        installIncoming(direction: direction) // 安装目标方向的进场页
        animateTurn(direction: direction, horizontal: activeAxisIsHorizontal, commit: true) // 播放完整翻页动画
    } // 结束 requestTurn(_:)

    /// 翻页动画：commit = true 时把进场页推到原点并转正为当前页；false 时退回并销毁
    /// - Parameters:
    ///   - direction: 翻页方向，决定位移正负
    ///   - horizontal: 主轴是否为水平
    ///   - commit: 是否真正完成翻页
    /// 副作用：commit 时替换 currentView 并回调 delegate.pager(_:didTurn:)
    private func animateTurn(direction: PageTurnDirection, horizontal: Bool, commit: Bool) { // 翻页 / 回弹动画
        guard incomingView != nil, let incoming = incomingView else { return } // 没有进场页则无动画可做
        let dimension = horizontal ? bounds.width : bounds.height // 主轴尺寸（一页的位移基准）
        let base = direction == .next ? dimension : -dimension // 方向对应的基准位移符号
        isAnimating = true // 标记动画开始

        if currentView.transform == .identity && incoming.transform == .identity { // 点击翻页场景：两层都尚未位移
            place(incoming, shift: base, horizontal: horizontal) // 先把进场页摆到屏幕外，形成从侧边滑入的初始态
        } // 结束初始态修正

        UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { // 0.26s 缓出动画
            if commit { // 完成翻页
                self.currentView.transform = self.transform(offset: -base, horizontal: horizontal) // 当前页反向移出一屏（-base 与进场页初始位置相反）
                incoming.transform = .identity // 进场页落到原点成为新页面
            } else { // 回弹
                self.currentView.transform = .identity // 当前页回原点
                self.place(incoming, shift: base, horizontal: horizontal) // 进场页退回一屏之外
            } // 结束 commit 分支
        } completion: { finished in // 动画结束回调
            self.isAnimating = false // 解除动画标记
            self.lastOffset = 0 // 复位位移记录
            guard finished else { // 动画被中断（如页面销毁）
                self.discardIncoming() // 清理进场页，保持视图层级干净
                return // 结束处理
            } // 结束中断判断
            if commit { // 成功翻页
                self.currentView.removeFromSuperview() // 移除旧的当前页
                self.currentView = incoming // 把进场页提升为当前页
                self.currentView.transform = .identity // 清除位移
                self.currentView.frame = self.bounds // 铺满容器
                self.incomingView = nil // 清空进场页引用（此时它已是 currentView）
                self.delegate?.pager(self, didTurn: direction) // 通知上层推进阅读位置（会回流新的 PagerModel）
            } else { // 回弹结束
                self.discardIncoming() // 销毁进场页
            } // 结束 commit 分支
        } // 结束 completion 闭包
    } // 结束 animateTurn(direction:horizontal:commit:)

    /// 边界回弹：先小幅位移再弹回，给用户「没有更多内容」的触感反馈
    /// - Parameter direction: 触达边界的方向，决定位移正负
    private func bounce(at direction: PageTurnDirection) { // 边界抖动反馈
        guard !isAnimating else { return } // 动画进行中不叠加
        let horizontal = model?.turnMode == .horizontal // 按阅读设置选择位移轴
        let distance: CGFloat = direction == .next ? -14 : 14 // 向后翻到达边界则向左上弹 14pt，向前则反向
        isAnimating = true // 标记动画开始
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) { // 第一段：快速推出
            self.currentView.transform = self.transform(offset: distance, horizontal: horizontal) // 位移 14pt 形成撞边效果
        } completion: { _ in // 第一段结束
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut]) { // 第二段：缓入缓出回位
                self.currentView.transform = .identity // 回到原点
            } completion: { _ in // 第二段结束
                self.isAnimating = false // 解除动画标记
            } // 结束内层 completion
        } // 结束外层 completion
    } // 结束 bounce(at:)

    // MARK: - 辅助
    // 纯函数与小工具：页码查询、拖拽方向推导、进场页安装/销毁、位移 transform 构造。
    // 这些方法不产生 delegate 回调，仅维护视图内部状态。

    /// 查询指定方向的预载页
    /// - Parameter direction: .next 取 model.next，.previous 取 model.previous
    /// - Returns: 对应页数据；nil 表示该方向已到边界
    private func page(for direction: PageTurnDirection) -> PagerPage? { // 取指定方向的预载页
        guard let model else { return nil } // 尚未应用模型时没有任何页
        return direction == .next ? model.next : model.previous // 按方向返回预载页
    } // 结束 page(for:)

    /// 根据拖动位移推导翻页方向
    /// - Parameters:
    ///   - offset: 沿主轴的位移，负值代表手指向左/上移动（看向下一页）
    ///   - horizontal: 主轴是否为水平（当前实现未参与判定，保留以表意清晰）
    /// - Returns: 位移为 0 或未应用模型时返回 nil，否则返回对应方向
    private func directionForDrag(offset: CGFloat, horizontal: Bool) -> PageTurnDirection? { // 位移推导翻页方向
        guard model != nil else { return nil } // 无模型时无法判断
        if offset == 0 { return nil } // 零位移无方向
        return offset < 0 ? .next : .previous // 负位移 = 内容向前推进 = 下一页
    } // 结束 directionForDrag(offset:horizontal:)

    /// 安装（或复用）进场页，并填充文字、内边距与背景色
    /// - Parameter direction: 进场页对应方向
    /// 副作用：必要时把视图加入层级
    private func installIncoming(direction: PageTurnDirection) { // 安装（或复用）进场页
        guard let model, let page = page(for: direction) else { return } // 无模型或该方向无页则不安装
        let view = incomingView ?? PageCanvasView(frame: bounds) // 复用已有画布，没有则新建
        view.transform = .identity // 清除可能残留的位移
        view.frame = bounds // 铺满容器
        view.pageInsets = model.insets // 与新模型保持相同文字内边距
        view.backgroundColor = model.theme.background.uiColor // 与主题背景保持一致，避免翻页时露出色差
        view.setContent(page.text, key: page.key) // 填充该页富文本
        if view.superview == nil { addSubview(view) } // 仅首次加入层级，避免重复添加
        incomingView = view // 记录进场页引用
        incomingDirection = direction // 记录进场方向
    } // 结束 installIncoming(direction:)

    /// 销毁进场页并清空引用，用于回弹结束或新数据应用前
    private func discardIncoming() { // 销毁进场页
        incomingView?.removeFromSuperview() // 从层级移除
        incomingView = nil // 释放引用
    } // 结束 discardIncoming()

    /// 构造纯位移 transform（不缩放、不旋转）
    /// - Parameters:
    ///   - offset: 位移量（pt），正负号表示方向
    ///   - horizontal: true 沿 x 轴，false 沿 y 轴
    /// - Returns: 对应的 CGAffineTransform
    private func transform(offset: CGFloat, horizontal: Bool) -> CGAffineTransform { // 构造纯位移 transform
        horizontal // 水平翻页
            ? CGAffineTransform(translationX: offset, y: 0) // 沿 x 轴平移 offset
            : CGAffineTransform(translationX: 0, y: offset) // 垂直翻页时沿 y 轴平移 offset
    } // 结束 transform(offset:horizontal:)

    /// 把视图以「主轴位移」方式放到指定偏移位置
    /// - Parameters:
    ///   - view: 待摆放的页视图
    ///   - shift: 位移量（pt）
    ///   - horizontal: 是否为水平位移
    private func place(_ view: UIView, shift: CGFloat, horizontal: Bool) { // 把视图摆到指定位移
        view.transform = transform(offset: shift, horizontal: horizontal) // 通过 transform 位移，避免触发 layout
    } // 结束 place(_:shift:horizontal:)

    // MARK: - UIGestureRecognizerDelegate
    // 只实现「是否允许手势同时识别」：本容器内 pan 与 tap 互斥，避免拖拽结束瞬间误触发点击翻页。

    /// 禁止本视图的两个手势同时识别，保证一次交互只产生一种结果
    /// - Parameters:
    ///   - gestureRecognizer: 当前待判定的手势
    ///   - otherGestureRecognizer: 另一个可能并行的手势
    /// - Returns: 恒为 false，即不并行
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, // 手势代理：判定能否与其他手势并行识别
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { // 第二参数为另一手势；返回 false 表示互斥
        false // 手势互斥：拖动时不会同时识别为点击
    } // 结束 gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)
} // 结束 PagePagerView 类
