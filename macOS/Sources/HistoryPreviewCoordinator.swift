import AppKit

@MainActor
final class HistoryPreviewCoordinator: NSObject, NSPopoverDelegate {
    private let service: HistoryService
    private let popover = NSPopover()
    private(set) var entryID: String?
    private var imageRequest = RequestGuard()
    private var textRequest = RequestGuard()
    var hasPreview: Bool { imageRequest.isPending || popover.isShown }
    var onError: ((String, Error) -> Void)?
    var onCopiedText: (() -> Void)?

    init(service: HistoryService) {
        self.service = service
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(entry: Entry, in table: NSTableView, toggle: Bool = false, canDisplay: @escaping () -> Bool) {
        if hasPreview && entryID == entry.id {
            if toggle { close() }
            return
        }
        imageRequest.invalidate()
        textRequest.invalidate()
        entryID = entry.id
        guard case .image = entry.content else {
            display(entry, image: nil, in: table)
            return
        }
        let request = imageRequest.begin()
        service.previewImage(for: entry.id) { [weak self, weak table] result in
            guard let self, let table, self.imageRequest.isCurrent(request), self.entryID == entry.id else { return }
            self.imageRequest.invalidate()
            guard canDisplay() else { return }
            switch result {
            case .success(let image): self.display(entry, image: image, in: table)
            case .failure(let error): self.onError?(L("预览图片"), error)
            }
        }
    }

    func close() {
        imageRequest.invalidate()
        textRequest.invalidate()
        entryID = nil
        if popover.isShown { popover.performClose(nil) }
    }

    func closeIfLoading() {
        if imageRequest.isPending { close() }
    }

    func updateAvailability() {
        (popover.contentViewController as? ContentPreviewController)?.actionsEnabled = service.isIdle
    }

    func closeIfMismatch(selectedID: String?) {
        if hasPreview && entryID != selectedID { close() }
    }

    func popoverDidClose(_ notification: Notification) {
        // 系统也可以自行收起弹窗，关闭后释放已解码的详情图。
        if !popover.isShown {
            imageRequest.invalidate()
            textRequest.invalidate()
            entryID = nil
            popover.contentViewController = nil
        }
    }

    private func display(_ entry: Entry, image: CGImage?, in table: NSTableView) {
        popover.appearance = table.window?.appearance
        let controller = ContentPreviewController(entry: entry, image: image)
        if image != nil {
            let id = entry.id
            controller.onRecognize = { [weak self, weak controller] in
                guard let self, let controller, self.service.isIdle, self.entryID == id,
                      self.popover.isShown, self.popover.contentViewController === controller else { return }
                let request = self.textRequest.begin()
                controller.setRecognizing(true)
                self.service.recognizeImageText(for: id) { [weak self, weak controller] result in
                    guard let self, let controller, self.textRequest.isCurrent(request), self.popover.isShown else { return }
                    self.textRequest.invalidate()
                    switch result {
                    case .success(let text):
                        controller.showRecognizedText(text)
                        self.popover.contentSize = controller.preferredContentSize
                    case .failure(let error):
                        controller.setRecognizing(false)
                        if !(error is CancellationError) { self.onError?(L("提取图中文字"), error) }
                    }
                }
            }
            controller.onCopyText = { [weak self, weak controller] text in
                guard let self, let controller, self.service.isIdle, self.entryID == id,
                      self.popover.isShown, self.popover.contentViewController === controller else { return }
                self.service.copyText(text, onFailure: { [weak self] in self?.onError?(L("复制文字"), $0) },
                                      completion: { [weak self] in self?.onCopiedText?() })
            }
        }
        table.scrollRowToVisible(table.selectedRow)
        let rect = table.rect(ofRow: table.selectedRow)
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        updateAvailability()
        if popover.isShown {
            popover.positioningRect = rect
        } else {
            popover.show(relativeTo: rect, of: table, preferredEdge: .maxX)
        }
    }
}
