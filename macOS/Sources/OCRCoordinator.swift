import Foundation

@MainActor
final class OCRCoordinator {
    typealias Recognize = (Data, (Int, Int), Int, CancellationToken) throws -> String
    private let worker: StoreWorker
    private let queue: DispatchQueue
    private let recognize: Recognize
    private let report: ErrorReporter
    private var scheduler = OCRScheduler()
    private var token: CancellationToken?
    private typealias Callback = (Result<String, Error>) -> Void
    private var waiting: [String: [Callback]] = [:]
    private var listed = Set<String>()
    var onSnapshot: ((StoreWorker.Snapshot) -> Void)?

    init(worker: StoreWorker, report: @escaping ErrorReporter,
         queue: DispatchQueue = DispatchQueue(label: "com.clipnest.ocr", qos: .utility),
         recognize: @escaping Recognize = ImageOCR.recognize) {
        self.worker = worker
        self.queue = queue
        self.recognize = recognize
        self.report = report
    }
    func update(entries: [Entry], favorites: [Entry]) {
        let all = entries + favorites
        listed = Set(all.map(\.id))
        let ids = all.compactMap { entry -> String? in
            guard case .image = entry.content, entry.ocrText == nil else { return nil }
            return entry.id
        }
        send(.candidates(ids))
    }
    func request(_ id: String, completion: @escaping (Result<String, Error>) -> Void) {
        waiting[id, default: []].append(completion)
        send(.manual(id))
    }
    func setAutomatic(_ enabled: Bool) { send(.automatic(enabled)) }
    func setSleeping(_ value: Bool) { send(value ? .sleep : .wake) }
    func stop() { send(.stop) }

    private func send(_ event: OCRScheduler.Event, result: Result<String, Error>? = nil, indexError: Error? = nil) {
        for action in scheduler.receive(event) {
            switch action {
            case .start(let job): start(job)
            case .cancelActive: token?.cancel()
            case .cancelWaiting:
                let cancelled = waiting
                waiting.removeAll()
                for callbacks in cancelled.values { for callback in callbacks { callback(.failure(CancellationError())) } }
            case .deliver(let id):
                guard let result else { preconditionFailure("完成识别时缺少结果") }
                let callbacks = waiting.removeValue(forKey: id) ?? []
                if let indexError, listed.contains(id) { report(L("保存图中文字索引"), indexError) }
                else if case .failure(let error) = result, callbacks.isEmpty, listed.contains(id) { report(L("识别图片文字"), error) }
                for callback in callbacks { callback(result) }
            }
        }
    }
    private func finish(_ job: OCRScheduler.Job, result: Result<String, Error>, indexError: Error? = nil) {
        token = nil
        let failed: Bool
        if case .failure = result { failed = true } else { failed = indexError != nil }
        send(.finished(job, failed: failed && listed.contains(job.id)), result: result, indexError: indexError)
    }

    private func start(_ job: OCRScheduler.Job) {
        let token = CancellationToken()
        self.token = token
        worker.readOCR(job.id, cancellation: token) { [self] input in
            switch input {
            case .failure(let error): finish(job, result: .failure(error))
            case .success(.cached(let text)): finish(job, result: .success(text))
            case let .success(.image(png, width, height)):
                queue.async(qos: job.manual ? .userInitiated : .utility, flags: .enforceQoS) { [recognize, worker] in
                    do {
                        let size = job.manual ? Tuning.manualOCRMaxPixelSize : Tuning.backgroundOCRMaxPixelSize
                        let text = try autoreleasepool { try recognize(png, (width, height), size, token) }
                        worker.saveOCR(text, id: job.id, cancellation: token) { result in
                            switch result {
                            case let .success((saved, snapshot)):
                                if let snapshot { self.onSnapshot?(snapshot) }
                                self.finish(job, result: .success(saved))
                            case .failure(let error as AppError) where error.code == .ocrIndexCapacity:
                                self.finish(job, result: .success(text), indexError: error)
                            case .failure(let error): self.finish(job, result: .failure(error))
                            }
                        }
                    } catch { DispatchQueue.main.async { self.finish(job, result: .failure(error)) } }
                }
            }
        }
    }
}
