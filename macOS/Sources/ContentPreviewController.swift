import AppKit

final class ContentPreviewController: NSViewController {
    private let textButton = NSButton()
    private var contentBottom: NSLayoutConstraint!
    private var recognizing = false
    private var displayedText: String?
    var onRecognize: (() -> Void)?
    var onCopyText: ((String) -> Void)?
    var actionsEnabled = true {
        didSet { textButton.isEnabled = actionsEnabled && !recognizing && displayedText != "" }
    }

    init(entry: Entry, image: CGImage?) {
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 360, height: image == nil ? 300 : 340)
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view = root
        let kind: String
        if case let .image(width, height) = entry.content { kind = L("图片 · %ld × %ld 像素", width, height) }
        else { kind = entry.content.label }
        let heading = NSTextField(labelWithString: "\(kind) · \(DateFormatter.historyDate(entry.date))")
        heading.font = .systemFont(ofSize: 11)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading])
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        let content: NSView
        if let image {
            textButton.bezelStyle = .rounded
            textButton.controlSize = .small
            textButton.target = self
            textButton.action = #selector(textAction)
            textButton.title = entry.ocrText == nil ? L("提取文字") : L("查看文字")
            if entry.ocrText == "" {
                displayedText = ""
                textButton.title = L("未识别到文字")
                textButton.isEnabled = false
            }
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(textButton)
            let imageView = NSImageView()
            imageView.image = NSImage(cgImage: image, size: .zero)
            imageView.imageScaling = .scaleProportionallyDown
            content = imageView
        } else {
            content = NSScrollView.readOnlyText(entry.content.detail, width: 328).scroll
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        contentBottom = content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            contentBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档创建预览。") }

    @objc private func textAction() {
        if let displayedText {
            if !displayedText.isEmpty { onCopyText?(displayedText) }
        } else {
            onRecognize?()
        }
    }

    func setRecognizing(_ value: Bool) {
        recognizing = value
        textButton.title = value ? L("正在识别…") : L("提取文字")
        textButton.isEnabled = actionsEnabled && !value
    }

    func showRecognizedText(_ value: String) {
        recognizing = false
        displayedText = value
        textButton.title = value.isEmpty ? L("未识别到文字") : L("复制文字")
        textButton.isEnabled = actionsEnabled && !value.isEmpty
        guard !value.isEmpty else { return }
        let scroll = NSScrollView.readOnlyText(value, width: 328).scroll
        scroll.setAccessibilityLabel(L("图中文字"))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let height: CGFloat = 128
        contentBottom.constant -= height + 8
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: height),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        preferredContentSize.height += height + 8
    }
}
