import AppKit

@MainActor protocol FrontmostAppProvider {
    var frontmostBundleID: String? { get }
}

enum CaptureWorkspaceEvent { case activated(String?), sleep, wake }

@MainActor protocol WorkspaceEvents {
    func subscribe(_ receive: @escaping @MainActor (CaptureWorkspaceEvent) -> Void) -> () -> Void
}

struct SystemWorkspace: FrontmostAppProvider, WorkspaceEvents {
    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    func subscribe(_ receive: @escaping @MainActor (CaptureWorkspaceEvent) -> Void) -> () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]
        let observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    switch name {
                    case NSWorkspace.didActivateApplicationNotification:
                        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                        receive(.activated(app?.bundleIdentifier ?? self.frontmostBundleID))
                    case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification: receive(.sleep)
                    default: receive(.wake)
                    }
                }
            }
        }
        return { for observer in observers { center.removeObserver(observer) } }
    }
}

@MainActor
final class CaptureMonitor {
    private let clipboard: ClipboardAccess
    private let frontmost: FrontmostAppProvider
    private let workspace: WorkspaceEvents
    private let report: ErrorReporter
    private var unsubscribe: (() -> Void)?
    private var timer: Timer?
    private var denied = false
    private var observedSequence: Int?
    private var polledSequence: Int?
    private var attempts = 0
    private var capturing = false
    private(set) var sleeping = false

    init(clipboard: ClipboardAccess, frontmost: FrontmostAppProvider, workspace: WorkspaceEvents, report: @escaping ErrorReporter) {
        self.clipboard = clipboard
        self.frontmost = frontmost
        self.workspace = workspace
        self.report = report
        clipboard.updateFrontmostApplication(frontmost.frontmostBundleID)
    }
    func observeSource() { clipboard.observeSource(frontmost.frontmostBundleID, sequence: clipboard.pasteboard.changeCount) }
    func setPolicy(paused: Bool, ignored: Set<String>) {
        clipboard.updateCapturePolicy(paused: paused, ignoredBundleIDs: ignored, frontmostBundleID: frontmost.frontmostBundleID)
    }

    func start(available: @escaping () -> Bool, capture: @escaping (Bool) -> Void, sleepChanged: @escaping (Bool) -> Void) {
        guard unsubscribe == nil else { return }
        let poll: () -> Void = { [weak self] in self?.poll(available: available, capture: capture) }
        unsubscribe = workspace.subscribe { [weak self] event in
            guard let self, self.unsubscribe != nil else { return }
            switch event {
            case .activated(let id):
                self.clipboard.updateFrontmostApplication(id)
                if !self.sleeping { poll() }
            case .sleep:
                self.sleeping = true
                self.timer?.invalidate()
                self.timer = nil
                sleepChanged(true)
            case .wake:
                self.sleeping = false
                self.startTimer(poll)
                poll()
                sleepChanged(false)
            }
        }
        startTimer(poll)
        poll()
    }

    private func startTimer(_ poll: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Tuning.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        timer.tolerance = timer.timeInterval * 0.1
        self.timer = timer
    }

    private func poll(available: () -> Bool, capture: (Bool) -> Void) {
        guard unsubscribe != nil else { return }
        let deniedNow = SystemAccess.clipboardStatus(for: clipboard.pasteboard) == .denied
        if deniedNow != denied {
            denied = deniedNow
            if denied { report(L("记录剪贴板"), AppError(L("无法读取剪贴板"))) }
            else { polledSequence = nil }
        }
        guard !denied else { return }
        let sequence = clipboard.pasteboard.changeCount
        if observedSequence != sequence {
            observedSequence = sequence
            clipboard.observeSource(frontmost.frontmostBundleID, sequence: sequence)
        }
        guard available(), !capturing else { return }
        if polledSequence != sequence {
            polledSequence = sequence
            attempts = Tuning.pollAttempts
        }
        guard attempts > 0 else { return }
        let first = attempts == Tuning.pollAttempts
        attempts -= 1
        capturing = true
        capture(first)
    }

    func finished(_ result: Result<Int?, Error>, firstAttempt: Bool) {
        capturing = false
        switch result {
        case .success(let handled):
            polledSequence = handled
            attempts = 0
        case .failure(let error):
            if firstAttempt { report(L("记录剪贴板"), error) }
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        unsubscribe?()
        unsubscribe = nil
    }
}
