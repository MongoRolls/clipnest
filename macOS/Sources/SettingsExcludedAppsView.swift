import AppKit
import UniformTypeIdentifiers

/// 行尾圆形移除按钮，悬停时提高对比度。
private final class RemoveCircleButton: NSButton {
    private var hovered = false { didSet { updateTint() } }
    private var tracker: NSTrackingArea?

    init(accessibilityLabel: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 16, weight: .regular)
        self.target = target
        self.action = action
        setAccessibilityLabel(accessibilityLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建移除按钮。") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracker = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        contentTintColor = hovered ? .secondaryLabelColor : .tertiaryLabelColor
    }
}

/// 卡片化的“已排除的 App”列表：展示应用图标、本地化名称、单行移除及添加入口。
@MainActor
final class SettingsExcludedAppsView: NSView {
    private let card = SettingsCardView()
    private let settings: AppSettings
    private let report: (String, Error) -> Void
    private var identifiers: [String] = []
    private var renderedLocale: Locale?
    private lazy var addButton: NSButton = {
        let button = NSButton(title: L("添加 App…"), target: self, action: #selector(addApps))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(L("添加忽略的应用"))
        return button
    }()
    private lazy var restoreDefaultsButton: NSButton = {
        let button = NSButton(title: L("恢复默认"), target: self, action: #selector(restoreDefaults))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setAccessibilityLabel(L("恢复默认排除"))
        return button
    }()

    init(settings: AppSettings, report: @escaping (String, Error) -> Void) {
        self.settings = settings
        self.report = report
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        card.pinEdges(to: self)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建已排除应用列表。") }

    func refresh() {
        let ordered = orderedIdentifiers(from: settings.ignoredBundleIDs)
        let locale = L10n.locale
        if identifiers != ordered || renderedLocale != locale {
            identifiers = ordered
            renderedLocale = locale
            rebuild()
        }
        restoreDefaultsButton.isHidden = AppSettings.defaultIgnoredBundleIDs.isSubset(of: settings.ignoredBundleIDs)
    }

    private func orderedIdentifiers(from set: Set<String>) -> [String] {
        let defaults = AppSettings.defaultIgnoredBundleOrder.filter { set.contains($0) }
        let others = set.subtracting(defaults).sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
        return defaults + others
    }

    private func displayName(for bundleID: String) -> String {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return AppMetadataCache.shared.displayName(for: bundleID)
        }
        switch bundleID {
        case "com.apple.keychainaccess": return L("钥匙串访问")
        case "com.apple.Passwords": return L("密码")
        default: return bundleID
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private func rebuild() {
        card.clearRows()
        if identifiers.isEmpty {
            let empty = NSTextField(labelWithString: L("暂未排除任何 App"))
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(empty)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 44),
                empty.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                empty.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            card.addRow(row)
        } else {
            for (index, id) in identifiers.enumerated() {
                card.addRow(makeAppRow(bundleID: id, index: index))
            }
        }
        card.addRow(makeActionRow())
    }

    private func makeAppRow(bundleID: String, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let name = displayName(for: bundleID)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = icon(for: bundleID)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)

        let nameField = NSTextField(labelWithString: name)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 13)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let removeButton = RemoveCircleButton(
            accessibilityLabel: L("移除 %@", name),
            target: self,
            action: #selector(removeApp(_:))
        )
        removeButton.tag = index

        row.addSubview(iconView)
        row.addSubview(nameField)
        row.addSubview(removeButton)
        row.toolTip = bundleID

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -10),
            nameField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeActionRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        restoreDefaultsButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(addButton)
        row.addSubview(restoreDefaultsButton)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            addButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            addButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            restoreDefaultsButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            restoreDefaultsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func addApps() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.prompt = L("添加")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            var ids = self.settings.ignoredBundleIDs
            for url in panel.urls {
                guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
                    self.report(L("添加忽略的应用"), AppError(L("无法读取应用标识")))
                    continue
                }
                ids.insert(id)
            }
            self.settings.ignoredBundleIDs = ids
            self.refresh()
        }
    }

    @objc private func removeApp(_ sender: NSButton) {
        guard identifiers.indices.contains(sender.tag) else { return }
        var ids = settings.ignoredBundleIDs
        ids.remove(identifiers[sender.tag])
        settings.ignoredBundleIDs = ids
        refresh()
    }

    @objc private func restoreDefaults() {
        var ids = settings.ignoredBundleIDs
        ids.formUnion(AppSettings.defaultIgnoredBundleIDs)
        settings.ignoredBundleIDs = ids
        refresh()
    }
}
