import AppKit

enum PanelAppearance: String, CaseIterable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .dark: return L("深色")
        case .light: return L("浅色")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

@MainActor
final class AppSettings {
    enum Key: String {
        case appearance = "panelAppearance"
        case keyboard = "keyboardSettings"
        case language, directPaste, plainTextByDefault, paused, ignoredBundleIDs, historyLimit, backgroundIntensity, imageOCR
    }

    static let historyLimits = Limits.historyChoices
    static let backgroundIntensities = 5...30
    static let defaultBackgroundIntensity = 8
    static let defaultIgnoredBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords"
    ]
    static let defaultIgnoredBundleOrder = [
        "com.apple.keychainaccess",
        "com.apple.Passwords"
    ]
    private let defaults: UserDefaults
    var onChange: ((Key) -> Void)?
    var beforeKeyboardChange: ((KeyboardSettings) throws -> Void)?
    var applyHistoryLimit: ((Int, @escaping (Result<Void, Error>) -> Void) -> Void)?
    private var changingHistoryLimit = false
    private(set) var keyboard = KeyboardSettings()
    private(set) var keyboardLoadError: Error?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do { keyboard = try Self.readKeyboard(from: defaults) }
        catch { keyboardLoadError = error }
    }

    static func readKeyboard(from defaults: UserDefaults) throws -> KeyboardSettings {
        let key = Key.keyboard.rawValue
        guard defaults.object(forKey: key) != nil else { return KeyboardSettings() }
        guard let data = defaults.data(forKey: key) else { throw AppError(L("按键设置格式无效。")) }
        let value = try PropertyListDecoder().decode(KeyboardSettings.self, from: data)
        try value.validate()
        return value
    }

    func setKeyboard(_ value: KeyboardSettings) throws {
        try value.validate()
        let data = try PropertyListEncoder().encode(value)
        try beforeKeyboardChange?(value)
        guard keyboardLoadError != nil || keyboard != value else { return }
        keyboard = value
        keyboardLoadError = nil
        save(data, for: .keyboard)
    }

    private func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        onChange?(key)
    }

    private func update<T: Equatable>(_ key: Key, from current: T, to value: T, encode: (T) -> Any = { $0 }) {
        guard current != value else { return }
        save(encode(value), for: key)
    }

    var appearance: PanelAppearance {
        get { defaults.string(forKey: Key.appearance.rawValue).flatMap(PanelAppearance.init(rawValue:)) ?? .system }
        set { update(.appearance, from: appearance, to: newValue) { $0.rawValue } }
    }

    static func language(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: Key.language.rawValue).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var language: AppLanguage {
        get { Self.language(in: defaults) }
        set {
            guard language != newValue else { return }
            if newValue == .system { defaults.removeObject(forKey: "AppleLanguages") }
            else { defaults.set([newValue.rawValue], forKey: "AppleLanguages") }
            save(newValue.rawValue, for: .language)
        }
    }

    var directPaste: Bool {
        get { defaults.object(forKey: Key.directPaste.rawValue) as? Bool ?? true }
        set { update(.directPaste, from: directPaste, to: newValue) }
    }

    var plainTextByDefault: Bool {
        get { defaults.bool(forKey: Key.plainTextByDefault.rawValue) }
        set { update(.plainTextByDefault, from: plainTextByDefault, to: newValue) }
    }

    var backgroundIntensity: Int {
        get {
            let value = defaults.integer(forKey: Key.backgroundIntensity.rawValue)
            return Self.backgroundIntensities.contains(value) ? value : Self.defaultBackgroundIntensity
        }
        set {
            guard Self.backgroundIntensities.contains(newValue) else { return }
            update(.backgroundIntensity, from: backgroundIntensity, to: newValue)
        }
    }

    var paused: Bool {
        get { defaults.bool(forKey: Key.paused.rawValue) }
        set { update(.paused, from: paused, to: newValue) }
    }

    var imageOCR: Bool {
        get { defaults.object(forKey: Key.imageOCR.rawValue) as? Bool ?? true }
        set { update(.imageOCR, from: imageOCR, to: newValue) }
    }

    var ignoredBundleIDs: Set<String> {
        get {
            guard let saved = defaults.stringArray(forKey: Key.ignoredBundleIDs.rawValue) else {
                return Self.defaultIgnoredBundleIDs
            }
            return Set(saved)
        }
        set { update(.ignoredBundleIDs, from: ignoredBundleIDs, to: newValue) { $0.sorted() } }
    }

    var historyLimit: Int {
        let value = defaults.integer(forKey: Key.historyLimit.rawValue)
        return Self.historyLimits.contains(value) ? value : Limits.defaultHistory
    }

    func setHistoryLimit(_ value: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Self.historyLimits.contains(value) else {
            completion(.failure(AppError(L("请选择有效的历史保留条数。"))))
            return
        }
        guard !changingHistoryLimit else {
            completion(.failure(AppError(L("正在调整历史保留条数，请稍后再试。"))))
            return
        }
        guard value != historyLimit else { completion(.success(())); return }
        guard let applyHistoryLimit else {
            save(value, for: .historyLimit)
            completion(.success(()))
            return
        }
        // 数据库完成裁剪后再保存偏好，写入失败时两个位置继续使用原来的值。
        changingHistoryLimit = true
        applyHistoryLimit(value) { result in
            self.changingHistoryLimit = false
            if case .success = result { self.save(value, for: .historyLimit) }
            completion(result)
        }
    }
}
