import AppKit

package final class AppMetadataCache {
    package static let shared = AppMetadataCache()
    private let lock = NSLock()
    private let applicationURL: (String) -> URL?
    private struct Metadata {
        let display: String
        let localizedNames: [String: String]
        let names: [String]
    }
    private var cache: [String: Metadata] = [:]

    package init(applicationURL: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        self.applicationURL = applicationURL
    }

    package func displayName(for bundleID: String) -> String {
        let metadata = metadata(for: bundleID)
        let language = L10n.locale.language.languageCode?.identifier == "en" ? "en" : "zh-Hans"
        return metadata.localizedNames[language] ?? metadata.display
    }

    package func matches(_ term: String, bundleID: String) -> Bool {
        metadata(for: bundleID).names.contains { FuzzyMatcher.score(term, in: $0) != nil }
    }

    private func metadata(for bundleID: String) -> Metadata {
        if let cached = lock.withLock({ cache[bundleID] }) { return cached }
        var names = Set([bundleID])
        var display = bundleID
        var localizedNames: [String: String] = [:]
        if let url = applicationURL(bundleID), let bundle = Bundle(url: url) {
            let filename = url.deletingPathExtension().lastPathComponent
            names.insert(filename)
            let keys = ["CFBundleDisplayName", "CFBundleName"]
            display = keys.compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }.first ?? filename
            names.insert(display)
            for key in keys {
                if let name = bundle.infoDictionary?[key] as? String { names.insert(name) }
                for language in ["en", "zh-Hans"] {
                    let name: String
                    if #available(macOS 15.4, *) {
                        name = bundle.localizedString(forKey: key, value: key, table: "InfoPlist",
                                                      localizations: [Locale.Language(identifier: language)])
                    } else if let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [language]).first,
                              let path = bundle.path(forResource: localization, ofType: "lproj"),
                              let localized = Bundle(path: path) {
                        name = localized.localizedString(forKey: key, value: key, table: "InfoPlist")
                    } else { continue }
                    if name != key, !name.isEmpty {
                        names.insert(name)
                        if localizedNames[language] == nil { localizedNames[language] = name }
                    }
                }
            }
        }
        let metadata = Metadata(display: display, localizedNames: localizedNames, names: Array(names))
        lock.withLock { cache[bundleID] = metadata }
        return metadata
    }
}
