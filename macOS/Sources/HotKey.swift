import Carbon

final class HotKey {
    private static let signature: OSType = 0x434E5354
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registeredShortcut: OpenShortcut?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    func register(_ shortcut: OpenShortcut) throws {
        try shortcut.validateCombination()
        if hotKey != nil && registeredShortcut == shortcut { return }
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let handler = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, handler.hotKey != nil, id.signature == HotKey.signature,
                      id.id == handler.registeredShortcut?.eventID else {
                    return OSStatus(eventNotHandledErr)
                }
                handler.onPress()
                return noErr
            }, 1, &spec, context, &eventHandler)
            guard installed == noErr else { throw AppError(L("安装快捷键事件失败（%d）。", installed), code: .shortcut) }
        }
        // 新组合注册成功后才释放旧组合，修改失败时原快捷键仍然可用。
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.code), UInt32(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: shortcut.eventID), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &replacement)
        guard status == noErr, let replacement else {
            throw AppError(L("%@ 注册失败，可能已被占用（%d）。请在设置中选择其他组合。", shortcut.title, status), code: .shortcut)
        }
        if let hotKey {
            let result = UnregisterEventHotKey(hotKey)
            if result != noErr {
                let cleanup = UnregisterEventHotKey(replacement)
                throw AppError(L("释放原快捷键失败（%d），撤销新快捷键注册的状态码为 %d。", result, cleanup), code: .shortcut)
            }
        }
        hotKey = replacement
        registeredShortcut = shortcut
    }

    func suspend() throws {
        guard let hotKey else { return }
        let status = UnregisterEventHotKey(hotKey)
        guard status == noErr else { throw AppError(L("暂停面板快捷键失败（%d）。", status)) }
        self.hotKey = nil
    }

    func resume() throws {
        guard hotKey == nil, let registeredShortcut else { return }
        try register(registeredShortcut)
    }

    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        registeredShortcut = nil
    }

    deinit { invalidate() }
}
