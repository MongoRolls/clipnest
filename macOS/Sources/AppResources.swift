import Foundation
#if SWIFT_PACKAGE
@_exported import ClipNestCore
#endif

enum AppResources {
    static var languageURL: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL
        #else
        return Bundle.main.resourceURL
        #endif
    }
}
