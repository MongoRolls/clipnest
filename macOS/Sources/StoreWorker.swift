import AppKit

/// 可变的 store 只在私有串行队列中访问，异步接口在主线程交付快照或独立的值。
final class StoreWorker: @unchecked Sendable {
    struct Snapshot {
        let entries: [Entry]
        let favorites: [Entry]?
        let favoriteIDs: Set<String>?
        let warning: AppError?

        fileprivate init(_ store: HistoryStore, includeFavorites: Bool = true) {
            entries = store.entries
            favorites = includeFavorites ? store.favorites : nil
            favoriteIDs = favorites.map { Set($0.map(\.id)) }
            warning = store.loadWarning
        }
    }
    struct Capture {
        let retainedID: String?
        let result: Result<(sequence: Int?, snapshot: Snapshot?), Error>
    }
    enum ImageInput {
        case cached(String)
        case image(Data, Int, Int)
    }
    typealias Reply<T> = @MainActor (Result<T, Error>) -> Void
    private let queue = DispatchQueue(label: "com.clipnest.history")
    private var store: HistoryStore?
    private let clipboard: ClipboardAccess
    init(clipboard: ClipboardAccess) { self.clipboard = clipboard }

    private func submit<T>(_ operation: @escaping () throws -> T, reply: @escaping Reply<T>) {
        queue.async {
            let result = autoreleasepool { Result { try operation() } }
            DispatchQueue.main.async { reply(result) }
        }
    }
    private func loaded() throws -> HistoryStore {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let store else { throw AppError(L("历史数据库尚未加载。")) }
        return store
    }

    func open(_ factory: @escaping () throws -> HistoryStore, archiveAt url: URL?, reply: @escaping Reply<Snapshot>) {
        submit({
            let reopen = {
                let next = try factory()
                try next.load()
                return next
            }
            let next: HistoryStore
            if let url { next = try DatabaseRecovery.archiveAndRestart(at: url, reopen: reopen) }
            else { next = try reopen() }
            self.store = next
            return Snapshot(next)
        }, reply: reply)
    }
    func relocalize(_ reply: @escaping Reply<Snapshot>) {
        submit({
            let store = try self.loaded()
            store.relocalize()
            return Snapshot(store)
        }, reply: reply)
    }
    func setHistoryLimit(_ limit: Int, reply: @escaping Reply<Snapshot>) {
        submit({
            let store = try self.loaded()
            try store.setHistoryLimit(limit)
            return Snapshot(store, includeFavorites: false)
        }, reply: reply)
    }
    func perform<T>(_ action: @escaping (HistoryStore, ClipboardAccess) throws -> T,
                    reply: @escaping Reply<(Snapshot, Result<T, Error>)>) {
        submit({
            let store = try self.loaded()
            let outcome = Result { try action(store, self.clipboard) }
            // 复制动作可能已收录新的内容才报错，这时仍需发布真实数据库快照。
            return (Snapshot(store), outcome)
        }, reply: reply)
    }
    func capture(_ reply: @escaping Reply<Capture>) {
        submit({
            let store = try self.loaded()
            let retainedID = store.retainCaptureTail()
            let result = Result { () -> (sequence: Int?, snapshot: Snapshot?) in
                let saved = try self.clipboard.capture(in: store, allowRetrySleep: false)
                let favorite = saved && store.entries.first.map { first in store.favorites.contains { $0.id == first.id } } == true
                return (self.clipboard.handledSequence, saved ? Snapshot(store, includeFavorites: favorite) : nil)
            }
            return Capture(retainedID: retainedID, result: result)
        }, reply: reply)
    }
    func release(_ id: String, reply: @escaping Reply<Void>) {
        submit({ try self.loaded().releaseCaptureTail(id) }, reply: reply)
    }
    func discardDeleted(_ deleted: HistoryStore.DeletedEntry, reply: @escaping Reply<Void>) {
        submit({ try self.loaded().discardDeleted(deleted) }, reply: reply)
    }
    func preview(_ id: String, reply: @escaping Reply<CGImage>) {
        submit({
            guard case let .image(png, width, height) = try self.loaded().payload(for: id) else {
                throw AppError(L("所选记录没有图片。"))
            }
            return try ClipImage.thumbnail(png, maxPixelSize: Tuning.previewMaxPixelSize, expectedSize: (width, height))
        }, reply: reply)
    }
    func readOCR(_ id: String, cancellation: CancellationToken, reply: @escaping Reply<ImageInput>) {
        submit({
            guard !cancellation.isCancelled else { throw CancellationError() }
            let store = try self.loaded()
            guard let entry = store.cachedEntry(id) else { throw AppError(L("记录已不存在。")) }
            if let cached = entry.ocrText { return .cached(cached) }
            guard case let .image(png, width, height) = try store.payload(for: id) else { throw AppError(L("所选记录没有图片。")) }
            return .image(png, width, height)
        }, reply: reply)
    }
    func saveOCR(_ text: String, id: String, cancellation: CancellationToken, reply: @escaping Reply<(String, Snapshot?)>) {
        submit({
            guard !cancellation.isCancelled else { throw CancellationError() }
            let store = try self.loaded()
            let change = try store.saveOCRText(text, for: id)
            guard let saved = store.cachedEntry(id)?.ocrText else { throw AppError(L("记录已不存在。")) }
            return (saved, change.updated ? Snapshot(store, includeFavorites: change.affectsFavorites) : nil)
        }, reply: reply)
    }
    func drain(after captures: DispatchGroup, completion: @escaping @MainActor () -> Void) {
        captures.notify(queue: queue) { DispatchQueue.main.async { completion() } }
    }
}
