import Foundation

package enum AppLanguage: String, CaseIterable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    package var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

package enum L10n {
    private static let lock = NSLock()
    private static var bundle: Bundle?
    private static var currentLocale = Locale(identifier: "zh-Hans")

    package static var locale: Locale { lock.withLock { currentLocale } }

    package static func select(_ language: AppLanguage, resources: URL? = Bundle.main.resourceURL) {
        let identifier: String
        if language == .system {
            // 全局偏好独立于本应用的 AppleLanguages，切回跟随系统时立即读取。
            let preferred = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            identifier = Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: preferred ?? Locale.preferredLanguages).first ?? "zh-Hans"
        } else { identifier = language.rawValue }
        let directory = resources?.appendingPathComponent(identifier + ".lproj", isDirectory: true)
        let selected = directory.flatMap(Bundle.init(url:))
        lock.withLock {
            bundle = selected
            currentLocale = Locale(identifier: selected == nil ? "zh-Hans" : identifier)
        }
    }

    static func string(_ key: String, arguments: [CVarArg]) -> String {
        let (selected, locale) = lock.withLock { (bundle, currentLocale) }
        let format = selected?.localizedString(forKey: key, value: key, table: nil) ?? key
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}

package func L(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.string(key, arguments: arguments)
}
