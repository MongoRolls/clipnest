import AppKit

final class HistorySurface: NSView {
    override var allowsVibrancy: Bool { false }
    private var backgroundImage: NSImage?
    private var fraction: CGFloat = 0

    func setBackground(_ image: NSImage?, intensity: Int) {
        let value = CGFloat(intensity) / 100
        guard backgroundImage !== image || fraction != value else { return }
        backgroundImage = image
        fraction = value
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = backgroundImage, !bounds.isEmpty, image.size.width > 0, image.size.height > 0 else { return }
        // 先铺不透明底色，透明图片和不同桌面背景上的文字对比度保持一致。
        let backdrop = usesDarkAppearance
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        backdrop.setFill()
        bounds.fill()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = bounds.width / scale
        let height = bounds.height / scale
        let crop = NSRect(x: (image.size.width - width) / 2, y: (image.size.height - height) / 2,
                          width: width, height: height)
        image.draw(in: bounds, from: crop, operation: .sourceOver, fraction: fraction,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class HistoryWindow: NSPanel {
    var keyAction: ((NSEvent) -> Bool)?
    func applyAppearance(_ value: PanelAppearance) { appearance = value.nsAppearance }

    func installSurface() -> HistorySurface {
        let surface = HistorySurface()
        surface.layerContentsRedrawPolicy = .duringViewResize
        if #available(macOS 26.0, *) {
            let container = NSView()
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = HistoryLayout.cornerRadius
            // 参考 Maccy：玻璃作为背景，正文单独承载，保持文字颜色稳定。
            for view in [glass, surface] {
                container.addSubview(view)
                view.pinEdges(to: container)
            }
            container.wantsLayer = true
            container.layer?.cornerRadius = HistoryLayout.cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
            contentView = container
            return surface
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        contentView = material
        applyRoundedCorners()
        material.addSubview(surface)
        surface.pinEdges(to: material)
        return surface
    }
    func applyRoundedCorners() {
        guard let material = contentView as? NSVisualEffectView else { return }
        let radius = HistoryLayout.cornerRadius
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        // 材质由窗口合成器绘制，必须使用原生遮罩同步裁切材质与阴影。
        material.maskImage = mask
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.cornerCurve = .circular
        material.layer?.masksToBounds = true
        invalidateShadow()
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        // 组合输入的确认、取消与候选选择交给当前文本编辑器处理。
        if event.type == .keyDown, let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            super.sendEvent(event)
            return
        }
        if event.type == .keyDown, keyAction?(event) == true { return }
        super.sendEvent(event)
    }
}
