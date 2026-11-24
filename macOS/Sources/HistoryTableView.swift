import AppKit

final class HistoryTableView: NSTableView {
    var rowIDAtRow: ((Int) -> PanelRowID?)?
    var allowsHoverSelection: () -> Bool = { true }
    private var pressedRow: (index: Int, entryID: PanelRowID?)?
    var draggedSinceMouseDown = false
    var clickMatchesEntry: Bool {
        guard !draggedSinceMouseDown else { return false }
        guard let pressedRow else { return true }
        return pressedRow.index == clickedRow && pressedRow.entryID != nil && pressedRow.entryID == rowIDAtRow?(clickedRow)
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    private var lastScrollEvent: NSEvent?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            guard let self, let event = self.lastScrollEvent,
                  ProcessInfo.processInfo.systemUptime - event.timestamp < 1,
                  NSApp.currentEvent?.type != .keyDown else { return }
            // 滚动动画继续改变可见范围时重新计算，键盘导航不被旧鼠标事件覆盖。
            self.selectRowUnderPointer(event)
        }
    }
    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect 会随滚动和布局更新；重新注册会让静止的鼠标再次触发进入事件。
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { selectRowUnderPointer(event) }
    override func mouseMoved(with event: NSEvent) {
        lastScrollEvent = nil
        selectRowUnderPointer(event)
    }
    override func mouseExited(with event: NSEvent) { lastScrollEvent = nil }
    override func scrollWheel(with event: NSEvent) {
        lastScrollEvent = event
        super.scrollWheel(with: event)
        // 滚动后以当前指针下的记录为准，不触发复制或抢走搜索框焦点。
        selectRowUnderPointer(event)
    }
    private func selectRowUnderPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, allowsHoverSelection(), visibleRect.contains(point) else { return }
        let row = row(at: point)
        guard row >= 0, row < numberOfRows, row != selectedRow else { return }
        select(row: row)
    }
    override func mouseDown(with event: NSEvent) {
        draggedSinceMouseDown = false
        let index = row(at: convert(event.locationInWindow, from: nil))
        pressedRow = (index, rowIDAtRow?(index))
        defer { pressedRow = nil }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard let menu, isEnabled, row >= 0 else { return nil }
        select(row: row)
        // 不调用 super.menu(for:)，避免 NSTableView 在右键行外围叠加系统蓝色边框；右键菜单项均作用于当前选中行。
        return menu
    }
    func scrollAnchor() -> (id: PanelRowID, offset: CGFloat)? {
        guard visibleRect.minY > 0 else { return nil }
        let row = row(at: NSPoint(x: visibleRect.midX, y: visibleRect.minY))
        guard let id = rowIDAtRow?(row) else { return nil }
        return (id, visibleRect.minY - rect(ofRow: row).minY)
    }
}

final class HistoryRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("history-row")
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}
