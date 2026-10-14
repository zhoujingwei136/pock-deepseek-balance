import AppKit
import PockKit

// MARK: - 配置存取

enum DSBPrefs {

    static let suiteName = "com.zhoujingwei.pock.DeepSeekBalance"
    static let apiKeyKey = "apiKey"
    static let autoKey   = "autoRefresh"
    static let emojiKey  = "emojiRules"
    static let showKey   = "showEmoji"
    static let edgeKey   = "edgeEffect"
    static let didChange = Notification.Name("DeepSeekBalancePreferencesDidChange")

    static var store: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    /// API Key（读取时自动去掉首尾空白和误粘的引号）
    static var apiKey: String {
        get {
            let raw = store.string(forKey: apiKeyKey) ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
                       .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        set { store.set(newValue, forKey: apiKeyKey) }
    }

    /// 是否每 5 分钟自动刷新一次（默认开）
    static var autoRefresh: Bool {
        get { store.object(forKey: autoKey) == nil ? true : store.bool(forKey: autoKey) }
        set { store.set(newValue, forKey: autoKey) }
    }

    /// 是否在余额前面显示表情（默认开）
    static var showEmoji: Bool {
        get { store.object(forKey: showKey) == nil ? true : store.bool(forKey: showKey) }
        set { store.set(newValue, forKey: showKey) }
    }

    /// 是否显示状态光效（那圈贴边光），默认开
    static var edgeEffect: Bool {
        get { store.object(forKey: edgeKey) == nil ? true : store.bool(forKey: edgeKey) }
        set { store.set(newValue, forKey: edgeKey) }
    }

    // MARK: 余额区间 → 表情

    struct EmojiRule {
        var min: Double      // 余额达到这个值
        var emoji: String    // 就显示这个表情
    }

    static let defaultRules: [EmojiRule] = [
        EmojiRule(min: 0,   emoji: "😱"),
        EmojiRule(min: 5,   emoji: "😐"),
        EmojiRule(min: 20,  emoji: "🙂"),
        EmojiRule(min: 60,  emoji: "😎"),
        EmojiRule(min: 200, emoji: "🤩")
    ]

    /// 用户配置的区间，按 min 升序
    static var emojiRules: [EmojiRule] {
        get {
            guard let raw = store.array(forKey: emojiKey) as? [[String: Any]] else { return defaultRules }
            let rules = raw.compactMap { dict -> EmojiRule? in
                guard let min = dict["min"] as? Double,
                      let emoji = dict["emoji"] as? String, !emoji.isEmpty else { return nil }
                return EmojiRule(min: min, emoji: emoji)
            }
            return rules.isEmpty ? defaultRules : rules.sorted { $0.min < $1.min }
        }
        set {
            store.set(newValue.map { ["min": $0.min, "emoji": $0.emoji] }, forKey: emojiKey)
        }
    }

    /// 余额落在哪一档，返回对应表情；关掉显示时返回 nil
    static func emoji(for balance: Double) -> String? {
        guard showEmoji else { return nil }
        var result: String?
        for rule in emojiRules where balance >= rule.min {
            result = rule.emoji
        }
        return result ?? emojiRules.first?.emoji
    }
}

// MARK: - 查询

struct DSBBalance {
    let amount: String     // 例如 "110.00"
    let currency: String   // "CNY" / "USD"

    var symbol: String { currency.uppercased() == "USD" ? "$" : "¥" }
    var display: String { "\(symbol)\(amount)" }

    /// 转成数值，用于比对区间
    var value: Double {
        Double(amount.filter { $0.isNumber || $0 == "." }) ?? 0
    }
}

enum DSBError: LocalizedError {
    case noKey
    case unauthorized
    case server(Int)
    case badResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noKey:            return "还没有设置 API Key"
        case .unauthorized:     return "API Key 无效或无权限（HTTP 401）"
        case .server(let code): return "服务器返回 HTTP \(code)"
        case .badResponse:      return "无法解析服务器返回的数据"
        case .network(let msg): return msg
        }
    }
}

enum DSBClient {

    static func fetch(apiKey: String, completion: @escaping (Result<DSBBalance, DSBError>) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(.noKey)); return
        }
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            completion(.failure(.badResponse)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let finish: (Result<DSBBalance, DSBError>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }

            if let error = error {
                finish(.failure(.network(error.localizedDescription))); return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(.badResponse)); return
            }
            switch http.statusCode {
            case 401, 403: finish(.failure(.unauthorized)); return
            case 200: break
            default: finish(.failure(.server(http.statusCode))); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = json["balance_infos"] as? [[String: Any]],
                  let first = infos.first,
                  let total = first["total_balance"] as? String else {
                finish(.failure(.badResponse)); return
            }
            let currency = (first["currency"] as? String) ?? "CNY"
            finish(.success(DSBBalance(amount: total, currency: currency)))
        }.resume()
    }
}

// MARK: - 边缘光

/// 贴着卡片边缘的一圈描边，颜色沿横向渐隐（两端透明、中间实色），
/// 用透明度来做「呼吸」和「闪烁」。
final class DSBEdgeView: NSView {

    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1.5
    var cornerRadius: CGFloat = 6.5

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 往里收一点，给外发光留出可见的空间
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        guard rect.width > 2, rect.height > 2 else { return }

        let path = CGPath(roundedRect: rect,
                          cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                          transform: nil)

        // 1) 外发光：让边缘像「光」而不是一条线
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4, color: color.withAlphaComponent(0.9).cgColor)
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
        ctx.restoreGState()

        // 2) 描边本体：整圈同色，四条边都看得见
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// 一段被渲染成图、并且量出了「墨迹」范围的文字。
/// 绘制时把墨迹中心对到目标位置，就能做到真正的视觉居中。
private struct DSBTextSprite {
    let image: NSImage
    let size: NSSize      // 图片尺寸（点）
    let ink: NSRect       // 墨迹在图片坐标里的位置
    var inkSize: NSSize { ink.size }
}

// MARK: - 触控栏上的显示

/// 扁平样式：平时只有「表情 + 余额数字」，没有底色也没有描边。
/// 状态靠一圈边缘光表达：
///   - 查询中 → 黄色边缘持续呼吸
///   - 成功   → 绿色边缘闪烁两次后消失，回到干净状态
///   - 失败   → 红色边缘闪烁两次后留下一道很淡的红边，提示上次刷新没成功
///
/// 表情和数字都是**自己渲染成图**再按墨迹定位的，没有用 `NSTextField`。
/// 原因是实测踩到几个坑：
///   - `NSTextFieldCell` 内边距左右不对称（左缩进 4~6pt、右边几乎为 0），
///     拿 intrinsicContentSize 当 frame 宽度会把最后一个字符切掉；
///   - 它只保证文本框居中，不保证字形墨迹居中；
///   - 亚像素偏移在 2x 栅格上会被吃掉，按 8x 校准的偏移到实机上就不准了；
///   - emoji 和数字字形高度差很多，靠字体度量对齐总会差半个点。
/// 统一成「墨迹居中」之后，两者都是构造出来的对齐，不依赖任何魔数。
final class DSBBalanceView: NSView {

    enum Style {
        case unknown, loading, ok, failed
    }

    let edgeView = DSBEdgeView(frame: .zero)          // 内部可见，预览程序要用

    private var emojiSprite: DSBTextSprite?
    private var amountSprite: DSBTextSprite?

    private let amountGap: CGFloat = 6
    private let emojiFont = NSFont.systemFont(ofSize: 15)
    private let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    private let amountColor = NSColor.white.withAlphaComponent(0.96)

    var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // MARK: 构建

    private func build() {
        edgeView.frame = bounds
        edgeView.autoresizingMask = [.width, .height]   // 跟随卡片尺寸
        edgeView.isHidden = true
        addSubview(edgeView)          // 先加，保证在文字下面
        wantsLayer = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        click.allowedTouchTypes = .direct      // 触控栏是「直接触摸」，不加这行点不动
        addGestureRecognizer(click)
    }

    /// 边缘光是子视图，必须跟着卡片尺寸走。
    /// （之前把布局全部改成自绘时删掉了这个，导致边缘光尺寸为 0、整圈消失。）
    override func layout() {
        super.layout()
        edgeView.frame = bounds
    }

    // MARK: 状态

    func update(style: Style, text: String, emoji: String?,
                animated: Bool = true, edgeEnabled: Bool = true) {
        let newEmoji = emoji ?? ""
        let scale = window?.backingScaleFactor ?? 2
        if newEmoji != lastEmoji {
            lastEmoji = newEmoji
            emojiSprite = Self.makeSprite(newEmoji, font: emojiFont, color: .white, scale: scale)
        }
        if text != lastAmount {
            lastAmount = text
            amountSprite = Self.makeSprite(text, font: amountFont, color: amountColor, scale: scale)
        }
        applyEdge(style, animated: animated, enabled: edgeEnabled)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var lastEmoji = "\u{0}"
    private var lastAmount = "\u{0}"

    private func applyEdge(_ style: Style, animated: Bool, enabled: Bool) {
        edgeView.layer?.removeAllAnimations()

        // 关掉光效时，彻底不显示这一圈（连失败时的淡红边也不留）
        guard enabled else {
            edgeView.isHidden = true
            return
        }

        let color: NSColor
        let restingOpacity: Float
        switch style {
        case .unknown:
            edgeView.isHidden = true
            return
        case .loading:
            color = .systemYellow
            restingOpacity = 0
        case .ok:
            color = .systemGreen
            restingOpacity = 0
        case .failed:
            color = .systemRed
            restingOpacity = 0.22          // 失败留一道淡红边，别让旧数字骗人
        }

        edgeView.isHidden = false
        edgeView.color = color
        edgeView.layer?.opacity = restingOpacity

        guard animated else { return }

        switch style {
        case .loading:
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.15
            breathe.toValue   = 0.95
            breathe.duration  = 0.7
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            edgeView.layer?.add(breathe, forKey: "breathe")

        case .ok:
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values   = [0, 1, 0, 1, 0]                    // 闪两次后消失
            flash.keyTimes = [0, 0.2, 0.45, 0.65, 1]
            flash.duration = 1.3
            edgeView.layer?.add(flash, forKey: "flash")

        case .failed:
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values   = [0, 1, 0, 1, 0.22] as [NSNumber]   // 闪两次，停在淡红
            flash.keyTimes = [0, 0.2, 0.45, 0.65, 1]
            flash.duration = 1.3
            edgeView.layer?.add(flash, forKey: "flash")

        case .unknown:
            break
        }
    }

    // MARK: 文字 → 图

    /// 把一段文字渲染成位图，并扫描出不透明像素的范围（墨迹）。
    private static func makeSprite(_ string: String, font: NSFont, color: NSColor,
                                   scale: CGFloat) -> DSBTextSprite? {
        guard !string.isEmpty else { return nil }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = string as NSString
        let textSize = ns.size(withAttributes: attrs)
        let pad: CGFloat = 3
        let wPt = ceil(textSize.width + pad * 2)
        let hPt = ceil(textSize.height + pad * 2)
        guard wPt > 0, hPt > 0 else { return nil }

        let wPx = Int(wPt * scale), hPx = Int(hPt * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: wPx, pixelsHigh: hPx,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // 必须先设 rep.size 再建绘图上下文：否则上下文按像素尺寸建立，
        // 画出来的东西只有一半大（隐蔽的坑，实测踩过）。
        rep.size = NSSize(width: wPt, height: hPt)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ns.draw(at: NSPoint(x: pad, y: pad), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let bpr = rep.bytesPerRow
        var minCol = wPx, maxCol = -1, minRow = hPx, maxRow = -1
        for row in 0..<hPx {
            let base = row * bpr
            for col in 0..<wPx where data[base + col * 4 + 3] > 40 {
                if col < minCol { minCol = col }
                if col > maxCol { maxCol = col }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard maxCol >= 0 else { return nil }

        let ink = NSRect(x: CGFloat(minCol) / scale,
                         y: CGFloat(hPx - 1 - maxRow) / scale,
                         width: CGFloat(maxCol - minCol + 1) / scale,
                         height: CGFloat(maxRow - minRow + 1) / scale)
        let image = NSImage(size: NSSize(width: wPt, height: hPt))
        image.addRepresentation(rep)
        return DSBTextSprite(image: image, size: NSSize(width: wPt, height: hPt), ink: ink)
    }

    // MARK: 尺寸

    private var emojiInkWidth: CGFloat { emojiSprite.map { ceil($0.inkSize.width) } ?? 0 }
    private var amountInkWidth: CGFloat { amountSprite.map { ceil($0.inkSize.width) } ?? 0 }

    override var intrinsicContentSize: NSSize {
        let gap = (emojiInkWidth > 0 && amountInkWidth > 0) ? amountGap : 0
        return NSSize(width: max(118, emojiInkWidth + gap + amountInkWidth + 26), height: 30)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.height / 2
        let gap = (emojiInkWidth > 0 && amountInkWidth > 0) ? amountGap : 0
        let contentWidth = emojiInkWidth + gap + amountInkWidth
        var x = max(6, (bounds.width - contentWidth) / 2)

        // 两段文字都把自己的「墨迹中心」对到 midY，所以必然水平对齐
        if let sprite = emojiSprite {
            sprite.image.draw(in: NSRect(x: x - sprite.ink.minX,
                                         y: midY - sprite.ink.midY,
                                         width: sprite.size.width,
                                         height: sprite.size.height))
            x += emojiInkWidth + gap
        }
        if let sprite = amountSprite {
            sprite.image.draw(in: NSRect(x: x - sprite.ink.minX,
                                         y: midY - sprite.ink.midY,
                                         width: sprite.size.width,
                                         height: sprite.size.height))
        }
    }

    // MARK: 点击

    @objc private func handleTap() {
        onTap?()
    }
}

// MARK: - 插件本体

@objc(DeepSeekBalance)
public class DeepSeekBalance: NSObject, PKWidget {

    public var identifier = NSTouchBarItem.Identifier("com.zhoujingwei.pock.DeepSeekBalance")
    public var customizationLabel: String = "DeepSeek 余额"
    public var view: NSView!

    private let card = DSBBalanceView()
    private var timer: Timer?
    private var lastBalance: DSBBalance?
    private var inFlight = false
    private var observer: NSObjectProtocol?

    public required override init() {
        super.init()
        self.view = card
        card.onTap = { [weak self] in self?.refresh(force: true) }
        card.update(style: .unknown, text: "未设置", emoji: nil,
                    animated: false, edgeEnabled: DSBPrefs.edgeEffect)

        // 偏好设置里改了 Key / 区间后，立刻同步
        observer = NotificationCenter.default.addObserver(
            forName: DSBPrefs.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastBalance = nil
            self?.refresh(force: true)
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: 生命周期

    public func viewWillAppear() {
        refresh(force: false)
        startTimer()
    }

    public func viewDidDisappear() {
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        guard DSBPrefs.autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: 查询

    private var lastEmoji: String? {
        lastBalance.flatMap { DSBPrefs.emoji(for: $0.value) }
    }

    private func refresh(force: Bool) {
        if inFlight { return }

        let key = DSBPrefs.apiKey
        guard !key.isEmpty else {
            lastBalance = nil
            card.update(style: .unknown, text: "未设置", emoji: nil,
                        edgeEnabled: DSBPrefs.edgeEffect)
            return
        }

        inFlight = true
        card.update(style: .loading,
                    text: lastBalance?.display ?? "查询中…",
                    emoji: lastEmoji,
                    edgeEnabled: DSBPrefs.edgeEffect)

        DSBClient.fetch(apiKey: key) { [weak self] result in
            guard let self = self else { return }
            self.inFlight = false
            switch result {
            case .success(let balance):
                self.lastBalance = balance
                self.card.update(style: .ok,
                                 text: balance.display,
                                 emoji: DSBPrefs.emoji(for: balance.value),
                                 edgeEnabled: DSBPrefs.edgeEffect)
            case .failure(let error):
                // 保留上一次的金额，只用红边提示这次没查成
                self.card.update(style: .failed,
                                 text: self.lastBalance?.display ?? Self.shortMessage(for: error),
                                 emoji: self.lastEmoji,
                                 edgeEnabled: DSBPrefs.edgeEffect)
            }
        }
    }

    private static func shortMessage(for error: DSBError) -> String {
        switch error {
        case .noKey:        return "未设置"
        case .unauthorized: return "Key 无效"
        default:            return "查询失败"
        }
    }
}
