import AppKit
import UniformTypeIdentifiers

@MainActor
final class PanelBackgroundControls: NSObject {
    private let settings: AppSettings
    private let store: PanelBackgroundStore
    private let report: (String, Error) -> Void
    private let percent = NSTextField(labelWithString: "")
    private lazy var choose: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(chooseImage))
        button.bezelStyle = .rounded
        return button
    }()
    private lazy var remove: NSButton = {
        let button = NSButton(title: L("移除"), target: self, action: #selector(removeImage))
        button.bezelStyle = .rounded
        return button
    }()
    private lazy var slider: NSSlider = {
        let control = NSSlider(
            value: Double(settings.backgroundIntensity),
            minValue: Double(AppSettings.backgroundIntensities.lowerBound),
            maxValue: Double(AppSettings.backgroundIntensities.upperBound),
            target: self,
            action: #selector(changeIntensity)
        )
        control.isContinuous = true
        control.widthAnchor.constraint(equalToConstant: 136).isActive = true
        control.setAccessibilityLabel(L("图片不透明度"))
        return control
    }()

    private(set) lazy var imageRow = SettingsRowView(
        title: L("面板背景"),
        subtitle: L("使用系统材质"),
        trailing: [choose, remove]
    )
    private(set) lazy var opacityRow: SettingsRowView = {
        percent.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 36).isActive = true
        return SettingsRowView(title: L("图片不透明度"), trailing: [slider, percent])
    }()
    var onLayoutChange: (() -> Void)?

    init(settings: AppSettings, store: PanelBackgroundStore, report: @escaping (String, Error) -> Void) {
        self.settings = settings
        self.store = store
        self.report = report
        super.init()
        refresh()
    }

    func refresh() {
        if let error = store.loadError {
            imageRow.setSubtitle(error.localizedDescription, color: .systemRed)
            imageRow.toolTip = error.localizedDescription
        } else if let name = store.name {
            imageRow.setSubtitle(name, color: .secondaryLabelColor)
            imageRow.toolTip = name
        } else {
            imageRow.setSubtitle(L("使用系统材质"), color: .secondaryLabelColor)
            imageRow.toolTip = nil
        }
        choose.title = store.name == nil ? L("选择图片…") : L("更换图片…")
        choose.isEnabled = !store.importing
        remove.isHidden = store.name == nil && store.loadError == nil
        remove.isEnabled = !store.importing
        let shouldHideOpacity = store.image == nil
        if opacityRow.isHidden != shouldHideOpacity {
            opacityRow.isHidden = shouldHideOpacity
            onLayoutChange?()
        }
        slider.integerValue = settings.backgroundIntensity
        updatePercent()
    }

    @objc private func chooseImage() {
        guard let window = imageRow.window else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.png, .jpeg, .heic]
        picker.beginSheetModal(for: window) { response in
            guard response == .OK, let url = picker.url else { return }
            Task {
                do { try await self.store.replace(with: url) }
                catch { self.showError(L("导入面板背景"), error) }
            }
        }
    }

    @objc private func removeImage() {
        do { try store.remove() }
        catch { showError(L("移除面板背景"), error) }
    }

    private func showError(_ action: String, _ error: Error) {
        report(action, error)
        let alert = NSAlert()
        alert.messageText = action
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = imageRow.window, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    @objc private func changeIntensity() {
        settings.backgroundIntensity = Int(slider.doubleValue.rounded())
        updatePercent()
    }

    private func updatePercent() {
        percent.stringValue = "\(settings.backgroundIntensity)%"
        slider.setAccessibilityValueDescription(percent.stringValue)
    }
}
