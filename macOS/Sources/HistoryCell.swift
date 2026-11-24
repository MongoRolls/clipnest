import AppKit

final class ColorSwatchView: NSView {
    static let side: CGFloat = 14
    var color: NSColor? { didSet { needsDisplay = true } }

    // 色块仅用于预览，点击仍由整行处理。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        guard !rect.isEmpty else { return }
        let swatch = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        swatch.addClip()
        if color.alphaComponent < 1 {
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.72, alpha: 1).setFill()
            for row in 0..<4 {
                for column in 0..<4 where (row + column).isMultiple(of: 2) {
                    NSRect(x: CGFloat(column * 4), y: CGFloat(row * 4), width: 4, height: 4).fill()
                }
            }
        }
        color.setFill()
        swatch.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.34).setStroke()
        swatch.lineWidth = pixel
        swatch.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class HistoryCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("history-cell")
    private let label = NSTextField(labelWithString: "")
    private let ocrLabel = NSTextField(wrappingLabelWithString: "")
    private let thumbnail = NSImageView()
    private let swatch = ColorSwatchView()
    private let favoriteIcon = NSImageView()
    private let shortcut = NSTextField(labelWithString: "")
    private var labelLeading: NSLayoutConstraint!
    private var thumbnailWidth: NSLayoutConstraint!
    private var favoriteWidth: NSLayoutConstraint!
    private var shortcutSpacing: NSLayoutConstraint!
    private var labelTrailing: NSLayoutConstraint!
    private var previewText = ""
    private var highlights: [NSRange] = []
    private var ocrSnippet: EntryPresentation.OCRSnippet?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ocrLabel.font = .systemFont(ofSize: 12)
        ocrLabel.maximumNumberOfLines = 2
        ocrLabel.lineBreakMode = .byTruncatingTail
        ocrLabel.cell?.truncatesLastVisibleLine = true
        ocrLabel.isSelectable = false
        ocrLabel.isHidden = true
        ocrLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .systemFont(ofSize: 13, weight: .medium)
        shortcut.alignment = .right
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.imageAlignment = .alignLeft
        favoriteIcon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        favoriteIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        favoriteIcon.toolTip = L("已收藏")
        favoriteIcon.setAccessibilityElement(false)
        favoriteIcon.isHidden = true
        swatch.isHidden = true
        for view in [label, ocrLabel, thumbnail, swatch, favoriteIcon, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HistoryLayout.rowInset)
        thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: 180)
        thumbnailWidth.priority = .defaultHigh
        labelTrailing = label.trailingAnchor.constraint(equalTo: favoriteIcon.leadingAnchor)
        favoriteWidth = favoriteIcon.widthAnchor.constraint(equalToConstant: 0)
        shortcutSpacing = favoriteIcon.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor)
        NSLayoutConstraint.activate([
            labelLeading,
            labelTrailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: HistoryLayout.imageHeight),
            thumbnailWidth,
            thumbnail.trailingAnchor.constraint(lessThanOrEqualTo: label.trailingAnchor),
            ocrLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
            ocrLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: -8),
            ocrLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ocrLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            ocrLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HistoryLayout.rowInset),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: ColorSwatchView.side),
            swatch.heightAnchor.constraint(equalTo: swatch.widthAnchor),
            favoriteWidth,
            favoriteIcon.heightAnchor.constraint(equalToConstant: 12),
            favoriteIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutSpacing,
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HistoryLayout.rowInset),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.widthAnchor.constraint(equalToConstant: HistoryLayout.shortcutWidth)
        ])
        textField = label
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档创建历史行。") }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateSelectionColors() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionColors()
    }
    private func updateSelectionColors() {
        let selected = backgroundStyle == .emphasized
        let foreground: NSColor = selected ? .white : .labelColor
        label.textColor = foreground
        shortcut.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        favoriteIcon.contentTintColor = selected ? NSColor.white.withAlphaComponent(0.9) : .systemOrange
        let highlightBackground = selected
            ? NSColor.white.withAlphaComponent(0.26)
            : NSColor.controlAccentColor.withAlphaComponent(usesDarkAppearance ? 0.30 : 0.20)
        if !highlights.isEmpty, !label.isHidden {
            let font = label.font ?? .systemFont(ofSize: 14)
            let attributed = NSMutableAttributedString(string: previewText, attributes: [
                .font: font,
                .foregroundColor: foreground
            ])
            let boldFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            for range in highlights {
                attributed.addAttributes([.backgroundColor: highlightBackground, .font: boldFont], range: range)
            }
            label.attributedStringValue = attributed
        }
        if let snippet = ocrSnippet, !ocrLabel.isHidden {
            let font = ocrLabel.font ?? .systemFont(ofSize: 12)
            let baseColor: NSColor = selected ? NSColor.white.withAlphaComponent(0.88) : .secondaryLabelColor
            let matchColor: NSColor = selected ? .white : .labelColor
            let attributed = NSMutableAttributedString(string: snippet.text, attributes: [
                .font: font,
                .foregroundColor: baseColor
            ])
            let boldFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            let limit = attributed.length
            for range in snippet.highlights where range.location >= 0 && NSMaxRange(range) <= limit {
                attributed.addAttributes([
                    .backgroundColor: highlightBackground,
                    .foregroundColor: matchColor,
                    .font: boldFont
                ], range: range)
            }
            ocrLabel.attributedStringValue = attributed
        }
    }

    func configure(entry: Entry, row: Int, isFavorite: Bool, inFavoritesList: Bool = false,
                   numberShortcut: HistoryShortcut, highlightRanges: [NSRange] = [],
                   ocrSnippet: EntryPresentation.OCRSnippet? = nil) {
        let image = entry.thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        previewText = entry.preview
        highlights = highlightRanges
        self.ocrSnippet = image != nil ? ocrSnippet : nil
        label.isHidden = image != nil
        if highlightRanges.isEmpty || image != nil {
            label.stringValue = entry.preview
        }
        thumbnail.image = image
        thumbnail.isHidden = image == nil
        ocrLabel.isHidden = self.ocrSnippet == nil
        if self.ocrSnippet == nil { ocrLabel.stringValue = "" }
        if let image {
            let maxWidth: CGFloat = self.ocrSnippet == nil ? 200 : 108
            thumbnailWidth.constant = min(maxWidth, max(1, HistoryLayout.imageHeight * image.size.width / max(1, image.size.height)))
        } else {
            thumbnailWidth.constant = 0
        }
        swatch.color = entry.colorPreview.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
        swatch.isHidden = swatch.color == nil
        labelLeading.constant = HistoryLayout.rowInset + (swatch.isHidden ? 0 : ColorSwatchView.side + 6)
        favoriteIcon.isHidden = !(isFavorite && !inFavoritesList)
        favoriteWidth.constant = favoriteIcon.isHidden ? 0 : 12
        labelTrailing.constant = favoriteIcon.isHidden ? 0 : -6
        shortcutSpacing.constant = favoriteIcon.isHidden ? 0 : -3
        shortcut.stringValue = numberShortcut.label(for: row)
        updateSelectionColors()
        let date = DateFormatter.historyDate(entry.date)
        toolTip = isFavorite ? L("%@ · %@ · 已收藏", entry.content.label, date) : "\(entry.content.label) · \(date)"
        let summary = isFavorite ? L("%@：%@，已收藏", entry.content.label, entry.preview) : L("%@：%@", entry.content.label, entry.preview)
        let sourceName = entry.sourceAppBundleID.map(AppMetadataCache.shared.displayName(for:))
        setAccessibilityLabel([summary, sourceName].compactMap { $0 }.joined(separator: " · "))
    }
}
