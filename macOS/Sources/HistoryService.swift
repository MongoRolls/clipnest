import AppKit

@MainActor
final class HistoryService {
    enum Change { case state, history, all }
    private struct Observer {
        weak var owner: AnyObject?
        let change: (Change) -> Void
    }
    private var observers: [ObjectIdentifier: Observer] = [:]
    private let worker: StoreWorker
    private let clipboard: ClipboardAccess
    private let monitor: CaptureMonitor
    private let ocr: OCRCoordinator
    private let report: ErrorReporter
    private let recoveryURL: URL?
    private let shutdownTimeout: TimeInterval
    private let pendingCaptures = DispatchGroup()
    private var retryOpenStore: (() throws -> HistoryStore)?
    private var openingStore = false
    private var shutdownDeadline: DispatchWorkItem?
    private var shutdownReplies: [() -> Void] = []
    private var stopped = false

    private(set) var entries: [Entry] = []
    private(set) var favorites: [Entry] = []
    private(set) var favoriteIDs = Set<String>()
    private(set) var ready = false
    private(set) var busy = true
    private(set) var quitting = false
    private(set) var loadFailure: Error?
    var isIdle: Bool { ready && !busy && !quitting }
    var canArchiveAfterFailure: Bool {
        guard !ready, !openingStore, !quitting, recoveryURL != nil, let loadFailure else { return false }
        return DatabaseRecovery.canArchive(after: loadFailure)
    }

    init(clipboard: ClipboardAccess, recoveryURL: URL? = nil, frontmost: FrontmostAppProvider? = nil,
         workspace: WorkspaceEvents? = nil, shutdownTimeout: TimeInterval = Tuning.shutdownTimeout,
         report: @escaping ErrorReporter) {
        self.clipboard = clipboard
        self.report = report
        self.recoveryURL = recoveryURL
        self.shutdownTimeout = shutdownTimeout
        let worker = StoreWorker(clipboard: clipboard)
        self.worker = worker
        monitor = CaptureMonitor(clipboard: clipboard, frontmost: frontmost ?? SystemWorkspace(),
                                 workspace: workspace ?? SystemWorkspace(), report: report)
        ocr = OCRCoordinator(worker: worker, report: report)
        ocr.onSnapshot = { [weak self] snapshot in self?.publish(snapshot) }
    }

    func observeChanges(owner: AnyObject, _ change: @escaping (Change) -> Void) {
        observers[ObjectIdentifier(owner)] = Observer(owner: owner, change: change)
    }
    func removeObserver(_ owner: AnyObject) { observers.removeValue(forKey: ObjectIdentifier(owner)) }
    private func notify(_ change: Change) {
        for key in Array(observers.keys) {
            guard let observer = observers[key], observer.owner != nil else { observers.removeValue(forKey: key); continue }
            observer.change(change)
        }
    }
    private func setBusy(_ value: Bool) {
        busy = value
        notify(.state)
    }
    private func publish(_ snapshot: StoreWorker.Snapshot, completion: () -> Void = {}) {
        entries = snapshot.entries
        if let favorites = snapshot.favorites, let ids = snapshot.favoriteIDs {
            self.favorites = favorites
            favoriteIDs = ids
        }
        completion()
        notify(snapshot.favorites == nil ? .history : .all)
        ocr.update(entries: entries, favorites: favorites)
    }

    func start(openStore: @escaping () throws -> HistoryStore) {
        guard !ready, !openingStore, !quitting else { return }
        retryOpenStore = openStore
        load(openStore, archiveAt: nil)
    }
    func retryLoad() {
        guard !ready, !openingStore, !quitting, let retryOpenStore else { return }
        load(retryOpenStore, archiveAt: nil)
    }
    @discardableResult func archiveAndRestart() -> Bool {
        guard canArchiveAfterFailure, let url = recoveryURL, let retryOpenStore else { return false }
        load(retryOpenStore, archiveAt: url)
        return true
    }
    private func load(_ factory: @escaping () throws -> HistoryStore, archiveAt url: URL?) {
        openingStore = true
        loadFailure = nil
        let locale = L10n.locale
        setBusy(true)
        worker.open(factory, archiveAt: url) { [self] result in
            openingStore = false
            switch result {
            case .success(let snapshot):
                retryOpenStore = nil
                ready = true
                publish(snapshot) {
                    setBusy(false)
                    if let warning = snapshot.warning { report(L("部分记录未加载"), warning) }
                }
                guard !quitting else { return }
                // 首次解密整库时用户也可能切换语言，完成后重新生成该语言的展示文字。
                if locale != L10n.locale { reloadLocalizedSnapshot() }
                monitor.start(available: { [weak self] in self?.isIdle == true },
                              capture: { [weak self] first in self?.capture(firstAttempt: first) },
                              sleepChanged: { [weak self] in self?.ocr.setSleeping($0) })
            case .failure(let error):
                if url == nil, locale != L10n.locale, !quitting { retryLoad(); return }
                loadFailure = error
                setBusy(false)
                report(url == nil ? L("加载历史和收藏，原始数据已保留") : L("归档历史数据库"), error)
            }
        }
    }

    func reloadLocalizedSnapshot() {
        guard !quitting else { return }
        guard ready else { retryLoad(); return }
        worker.relocalize { [self] result in
            switch result {
            case .success(let snapshot): publish(snapshot)
            case .failure(let error): report(L("重新加载历史预览"), error)
            }
        }
    }
    func setHistoryLimit(_ value: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isIdle else { completion(.failure(AppError(L("历史记录尚未就绪，请稍后再试。")))); return }
        setBusy(true)
        worker.setHistoryLimit(value) { [self] result in
            switch result {
            case .success(let snapshot): publish(snapshot) { setBusy(false); completion(.success(())) }
            case .failure(let error): setBusy(false); completion(.failure(error))
            }
        }
    }
    @discardableResult
    func perform(_ label: String, action: @escaping (HistoryStore, ClipboardAccess) throws -> Void,
                 onFailure: ((Error) -> Void)? = nil,
                 completion: (() -> Void)? = nil) -> Bool {
        performResult(label, action: action, onFailure: onFailure, completion: { _ in completion?() })
    }

    @discardableResult
    private func performResult<T>(_ label: String, action: @escaping (HistoryStore, ClipboardAccess) throws -> T,
                                  onFailure: ((Error) -> Void)? = nil,
                                  completion: ((T) -> Void)? = nil) -> Bool {
        guard isIdle else { return false }
        setBusy(true)
        worker.perform(action) { [self] result in
            switch result {
            case let .success((snapshot, outcome)):
                publish(snapshot) {
                    setBusy(false)
                    switch outcome {
                    case .success(let value): completion?(value)
                    case .failure(let error):
                        report(label, error)
                        onFailure?(error)
                    }
                }
            case .failure(let error):
                setBusy(false)
                report(label, error)
                onFailure?(error)
            }
        }
        return true
    }

    // MARK: - 领域操作

    func copyEntry(_ entry: Entry, replacement: Payload?, promote: Bool,
                   onFailure: ((Error) -> Void)? = nil, completion: @escaping (Int) -> Void) {
        performResult(promote ? L("复制记录") : L("提取图中文字"), action: { store, clipboard in
            let payload = try replacement ?? store.payload(for: entry.id)
            return try store.withRetainedRecord(entry.id) {
                let version = try clipboard.write(payload, preservingChangesIn: store)
                if promote {
                    do { try store.recordUse(of: entry) }
                    catch { throw AppError(L("内容已复制，但更新历史失败：%@", error.localizedDescription)) }
                }
                return version
            }
        }, onFailure: onFailure, completion: completion)
    }

    func copyText(_ text: String, onFailure: ((Error) -> Void)? = nil, completion: @escaping () -> Void) {
        perform(L("复制文字"), action: { store, clipboard in
            try clipboard.write(.text(text), preservingChangesIn: store)
        }, onFailure: onFailure, completion: completion)
    }

    func toggleFavorite(_ id: String, onFailure: ((Error) -> Void)? = nil) {
        let removing = favoriteIDs.contains(id)
        perform(removing ? L("取消收藏") : L("收藏记录"), action: { store, _ in
            if removing { try store.removeFavorite(id) } else { try store.addFavorite(id) }
        }, onFailure: onFailure)
    }

    func deleteForUndo(_ id: String, fromFavorites: Bool, onFailure: ((Error) -> Void)? = nil,
                       completion: @escaping (HistoryStore.DeletedEntry) -> Void) {
        performResult(fromFavorites ? L("取消收藏") : L("删除记录"), action: { store, _ in
            try store.deleteForUndo(id, fromFavorites: fromFavorites)
        }, onFailure: onFailure, completion: { deleted in
            if let deleted { completion(deleted) }
        })
    }

    func restoreDeleted(_ deleted: HistoryStore.DeletedEntry, onFailure: ((Error) -> Void)? = nil,
                        completion: @escaping (Bool) -> Void) {
        performResult(L("撤销删除"), action: { store, _ in
            try store.restore(deleted)
        }, onFailure: onFailure, completion: completion)
    }

    func moveFavorite(_ id: String, relativeTo neighbor: String, insertAfter: Bool, onFailure: ((Error) -> Void)? = nil) {
        perform(L("调整收藏顺序"), action: { store, _ in
            try store.moveFavorite(id, relativeTo: neighbor, insertAfter: insertAfter)
        }, onFailure: onFailure)
    }

    func clearHistory(onFailure: ((Error) -> Void)? = nil) {
        let current = clipboardChangeCount
        perform(L("清空历史"), action: { store, clipboard in
            try store.clear()
            clipboard.handledSequence = current
        }, onFailure: onFailure)
    }

    func discardDeleted(_ deleted: HistoryStore.DeletedEntry) {
        guard !stopped else { return }
        worker.discardDeleted(deleted) { [self] result in
            if case .failure(let error) = result { report(L("清理已淘汰记录"), error) }
        }
    }

    var clipboardChangeCount: Int { clipboard.pasteboard.changeCount }
    var usesGeneralPasteboard: Bool { clipboard.pasteboard.name == NSPasteboard.general.name }
    func ownsClipboard(sequence: Int) -> Bool { clipboard.ownsGeneralPasteboard(sequence: sequence) }
    func updateCapturePolicy(paused: Bool, ignoredBundleIDs: Set<String>) { monitor.setPolicy(paused: paused, ignored: ignoredBundleIDs) }
    func observeClipboardSource() { monitor.observeSource() }
    func previewImage(for id: String, completion: @escaping (Result<CGImage, Error>) -> Void) {
        worker.preview(id, reply: completion)
    }
    func setAutoOCREnabled(_ enabled: Bool) { ocr.setAutomatic(enabled) }
    var ocrImageProgress: (indexed: Int, total: Int) {
        var seen = Set<String>()
        var total = 0, indexed = 0
        for entry in entries + favorites where seen.insert(entry.id).inserted {
            guard case .image = entry.content else { continue }
            total += 1
            if entry.ocrText != nil { indexed += 1 }
        }
        return (indexed, total)
    }
    func recognizeImageText(for id: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard !quitting, !monitor.sleeping else { completion(.failure(CancellationError())); return }
        guard let entry = entries.first(where: { $0.id == id }) ?? favorites.first(where: { $0.id == id }),
              case .image = entry.content else { completion(.failure(AppError(L("所选记录没有图片。")))); return }
        if let text = entry.ocrText { completion(.success(text)); return }
        ocr.request(id, completion: completion)
    }
    private func capture(firstAttempt: Bool) {
        pendingCaptures.enter()
        worker.capture { [self] result in
            switch result {
            case .failure(let error):
                monitor.finished(.failure(error), firstAttempt: firstAttempt)
                pendingCaptures.leave()
            case .success(let capture):
                monitor.finished(capture.result.map(\.sequence), firstAttempt: firstAttempt)
                if case let .success((_, snapshot?)) = capture.result { publish(snapshot) }
                // 发布期间排队的用户复制仍可使用旧尾记录，清理必须最后入队。
                guard let id = capture.retainedID else { pendingCaptures.leave(); return }
                worker.release(id) { [self] result in
                    if case .failure(let error) = result { report(L("清理已淘汰记录"), error) }
                    pendingCaptures.leave()
                }
            }
        }
    }

    func invalidatePolling() {
        quitting = true
        monitor.stop()
        ocr.stop()
    }
    func stop(completion: @escaping () -> Void) {
        guard !stopped else { completion(); return }
        shutdownReplies.append(completion)
        guard shutdownDeadline == nil else { return }
        let deadline = DispatchWorkItem { [weak self] in self?.finishStop(timedOut: true) }
        shutdownDeadline = deadline
        invalidatePolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + shutdownTimeout, execute: deadline)
        worker.drain(after: pendingCaptures) { [self] in finishStop(timedOut: false) }
    }
    private func finishStop(timedOut: Bool) {
        guard !stopped else { return }
        stopped = true
        shutdownDeadline?.cancel()
        shutdownDeadline = nil
        if timedOut { report(L("等待历史数据库退出"), AppError(L("等待历史数据库退出超时。"), code: .database)) }
        let replies = shutdownReplies
        shutdownReplies.removeAll()
        for reply in replies { reply() }
    }
}
