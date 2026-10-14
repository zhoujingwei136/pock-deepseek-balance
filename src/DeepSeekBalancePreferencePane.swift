import AppKit
import PockKit

/// 一行「余额区间 → 表情」的编辑器
final class DSBRuleRow: NSStackView {

    let minField   = NSTextField(string: "")
    let emojiField = NSTextField(string: "")
    private weak var pane: DeepSeekBalancePreferencePane?

    init(rule: DSBPrefs.EmojiRule, pane: DeepSeekBalancePreferencePane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 22))

        orientation = .horizontal
        spacing = 6
        alignment = .centerY

        let prefix = NSTextField(labelWithString: "余额 ≥")
        prefix.font = .systemFont(ofSize: 11)
        prefix.textColor = .secondaryLabelColor

        minField.stringValue = rule.min == rule.min.rounded()
            ? String(Int(rule.min)) : String(rule.min)
        minField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        minField.alignment = .right
        minField.placeholderString = "0"
        minField.widthAnchor.constraint(equalToConstant: 66).isActive = true

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 11)
        arrow.textColor = .secondaryLabelColor

        emojiField.stringValue = rule.emoji
        emojiField.font = .systemFont(ofSize: 15)
        emojiField.alignment = .center
        emojiField.placeholderString = "🙂"
        emojiField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let remove = NSButton(title: "移除", target: self, action: #selector(removeSelf))
        remove.bezelStyle = .inline
        remove.controlSize = .small
        remove.setContentHuggingPriority(.required, for: .horizontal)

        setViews([prefix, minField, arrow, emojiField, remove], in: .leading)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func removeSelf() {
        pane?.removeRuleRow(self)
    }

    /// 读回这一行的内容，填得不完整就返回 nil
    var rule: DSBPrefs.EmojiRule? {
        let minText = minField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = emojiField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let min = Double(minText), !emoji.isEmpty else { return nil }
        return DSBPrefs.EmojiRule(min: min, emoji: String(emoji.prefix(1)))
    }
}

/// 在 Pock 的「管理部件」页面里显示的偏好设置面板。
///
/// Pock 是这样实例化它的：
///     clss.init(nibName: clss.nibName, bundle: Bundle(for: clss))
/// 正常情况下需要一个 nib，但没有 Xcode 就编不出 nib。
/// 好在 nib 只在 `NSViewController` 默认的 `loadView()` 里才会被加载，
/// 我们重写 `loadView()` 用代码搭界面，那个 nibName 就永远不会被用到。
@objc(DeepSeekBalancePreferencePane)
class DeepSeekBalancePreferencePane: NSViewController, PKWidgetPreference {

    static var nibName: NSNib.Name { "Unused" }   // 随便给，不会被加载

    // MARK: 控件

    private let keyField    = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let rulesStack  = NSStackView()

    private var ruleRows: [DSBRuleRow] = []

    private lazy var saveButton: NSButton = {
        let b = NSButton(title: "保存并查询", target: self, action: #selector(save))
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        return b
    }()

    private lazy var openButton: NSButton = {
        let b = NSButton(title: "获取 API Key", target: self, action: #selector(openPlatform))
        b.bezelStyle = .rounded
        return b
    }()

    private lazy var showEmojiCheck: NSButton = {
        let b = NSButton(checkboxWithTitle: "在余额前显示表情",
                         target: self, action: #selector(toggleShowEmoji))
        b.state = DSBPrefs.showEmoji ? .on : .off
        return b
    }()

    private lazy var edgeCheck: NSButton = {
        let b = NSButton(checkboxWithTitle: "显示状态光效（查询中 / 成功 / 失败时的边缘光）",
                         target: self, action: #selector(toggleEdge))
        b.state = DSBPrefs.edgeEffect ? .on : .off
        return b
    }()

    private lazy var autoCheck: NSButton = {
        let b = NSButton(checkboxWithTitle: "每 5 分钟自动刷新一次",
                         target: self, action: #selector(toggleAuto))
        b.state = DSBPrefs.autoRefresh ? .on : .off
        return b
    }()

    private lazy var addRuleButton: NSButton = {
        let b = NSButton(title: "＋ 添加一档", target: self, action: #selector(addRule))
        b.bezelStyle = .inline
        b.controlSize = .small
        return b
    }()

    private lazy var resetRuleButton: NSButton = {
        let b = NSButton(title: "恢复默认区间", target: self, action: #selector(resetRules))
        b.bezelStyle = .inline
        b.controlSize = .small
        return b
    }()

    // MARK: 界面

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 460))

        let title = NSTextField(labelWithString: "DeepSeek 余额")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "填入 API Key 后即可显示账户余额，点击触控栏上的数字手动刷新。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        // —— API Key ——
        keyField.placeholderString = "sk-..."
        keyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyField.lineBreakMode = .byTruncatingMiddle
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keyRow = NSStackView(views: [keyField, saveButton, openButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.alignment = .centerY

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        // —— 分区标题 ——
        let sectionTitle = NSTextField(labelWithString: "余额表情")
        sectionTitle.font = .systemFont(ofSize: 12, weight: .semibold)

        let sectionHint = NSTextField(labelWithString: "余额达到哪一档，就显示哪个表情；未达最低档时用最低档的表情。")
        sectionHint.font = .systemFont(ofSize: 10)
        sectionHint.textColor = .tertiaryLabelColor

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 6

        let ruleButtons = NSStackView(views: [addRuleButton, resetRuleButton])
        ruleButtons.orientation = .horizontal
        ruleButtons.spacing = 10
        ruleButtons.alignment = .centerY

        let separator = NSBox()
        separator.boxType = .separator

        let footnote = NSTextField(labelWithString: "Key 只保存在本机（UserDefaults），仅用于请求 api.deepseek.com。")
        footnote.font = .systemFont(ofSize: 10)
        footnote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            title, subtitle, keyRow, statusLabel,
            separator, sectionTitle, sectionHint, showEmojiCheck,
            rulesStack, ruleButtons, edgeCheck, autoCheck, footnote
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(14, after: statusLabel)
        stack.setCustomSpacing(4,  after: sectionTitle)
        stack.setCustomSpacing(12, after: ruleButtons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        // 容器高度不够时允许裁掉底部，而不是让自动布局报冲突
        let bottom = root.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 18)
        bottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            bottom,
            keyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        keyField.stringValue = DSBPrefs.apiKey
        DSBPrefs.emojiRules.forEach { appendRuleRow($0) }
        if DSBPrefs.apiKey.isEmpty {
            setStatus("还没有设置 API Key。", color: .secondaryLabelColor)
        } else {
            setStatus("已保存 Key，点击「保存并查询」可验证。", color: .secondaryLabelColor)
        }
    }

    // MARK: 区间行的增删

    private func appendRuleRow(_ rule: DSBPrefs.EmojiRule) {
        let row = DSBRuleRow(rule: rule, pane: self)
        ruleRows.append(row)
        rulesStack.addArrangedSubview(row)
    }

    func removeRuleRow(_ row: DSBRuleRow) {
        guard ruleRows.count > 1 else { return }   // 至少留一档
        ruleRows.removeAll { $0 === row }
        rulesStack.removeArrangedSubview(row)
        row.removeFromSuperview()
    }

    @objc private func addRule() {
        let last = ruleRows.compactMap { $0.rule }.map { $0.min }.max() ?? 0
        appendRuleRow(DSBPrefs.EmojiRule(min: last + 50, emoji: "😎"))
    }

    @objc private func resetRules() {
        ruleRows.forEach {
            rulesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        ruleRows.removeAll()
        DSBPrefs.defaultRules.forEach { appendRuleRow($0) }
    }

    // MARK: 动作

    @objc private func save() {
        let key = keyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        keyField.stringValue = key
        DSBPrefs.apiKey = key

        // 保存表情区间
        let rules = ruleRows.compactMap { $0.rule }.sorted { $0.min < $1.min }
        if !rules.isEmpty {
            DSBPrefs.emojiRules = rules
        } else {
            setStatus("表情区间至少要有完整的一档（余额和表情都不能为空）。", color: .systemRed)
            return
        }

        guard !key.isEmpty else {
            setStatus("请先填入 API Key。", color: .systemRed)
            NotificationCenter.default.post(name: DSBPrefs.didChange, object: nil)
            return
        }

        setStatus("正在查询…", color: .secondaryLabelColor)
        saveButton.isEnabled = false

        DSBClient.fetch(apiKey: key) { [weak self] result in
            guard let self = self else { return }
            self.saveButton.isEnabled = true
            switch result {
            case .success(let balance):
                let emoji = DSBPrefs.emoji(for: balance.value) ?? ""
                self.setStatus("✅ 保存成功，当前余额 \(balance.display) \(emoji)（\(balance.currency)）",
                               color: .systemGreen)
            case .failure(let error):
                self.setStatus("⚠️ 设置已保存，但查询失败：\(error.localizedDescription)",
                               color: .systemOrange)
            }
            // 通知触控栏上的组件立即刷新
            NotificationCenter.default.post(name: DSBPrefs.didChange, object: nil)
        }
    }

    @objc private func openPlatform() {
        if let url = URL(string: "https://platform.deepseek.com/api_keys") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleShowEmoji() {
        DSBPrefs.showEmoji = (showEmojiCheck.state == .on)
        NotificationCenter.default.post(name: DSBPrefs.didChange, object: nil)
    }

    @objc private func toggleEdge() {
        DSBPrefs.edgeEffect = (edgeCheck.state == .on)
        NotificationCenter.default.post(name: DSBPrefs.didChange, object: nil)
    }

    @objc private func toggleAuto() {
        DSBPrefs.autoRefresh = (autoCheck.state == .on)
        NotificationCenter.default.post(name: DSBPrefs.didChange, object: nil)
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }
}
