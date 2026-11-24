import Foundation
import CoreGraphics

package enum Limits {
    package static let defaultHistory = 50
    package static let historyChoices = [defaultHistory, 100, 200, 500]
    package static let recordSizeMiB = 64
    package static let bytes = recordSizeMiB * 1024 * 1024
    static let ocrBytes = 1024 * 1024
    package static let pixels = 32_000_000
}

package struct AppError: LocalizedError, CustomNSError {
    package enum Code: Int {
        case general = 1
        case validation = 100
        case database = 200
        case damagedDatabase = 201
        case crypto = 300
        case keychain = 310
        case clipboard = 400
        case shortcut = 500
        case directPaste = 600
        case ocr = 900
        case ocrIndexCapacity = 901
    }

    package static var errorDomain: String { "com.clipnest.error" }
    package let code: Code
    let message: String
    package init(_ message: String, code: Code = .general) {
        self.code = code
        self.message = message
    }
    package var errorCode: Int { code.rawValue }
    package var errorDescription: String? { message }
}

package enum Payload: Equatable {
    case text(String, html: Data? = nil, rtf: Data? = nil)
    case image(png: Data, width: Int, height: Int)
    case files([String])

    package var content: Content {
        switch self {
        case let .text(text, _, _): return .text(text)
        case let .image(_, width, height): return .image(width: width, height: height)
        case let .files(paths): return .files(paths)
        }
    }

    package func validate() throws {
        let bytes: Int
        switch self {
        case let .text(text, html, rtf):
            guard !text.isEmpty else { throw AppError(L("剪贴板文本为空。"), code: .validation) }
            bytes = text.utf8.count + (html?.count ?? 0) + (rtf?.count ?? 0)
        case let .image(png, width, height):
            guard !png.isEmpty, width > 0, height > 0, width <= Limits.pixels / height else {
                throw AppError(L("图片数据为空、尺寸无效或超过 3200 万像素。"), code: .validation)
            }
            bytes = png.count
        case let .files(paths):
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
                throw AppError(L("剪贴板文件列表为空或含无效的路径。"), code: .validation)
            }
            bytes = paths.reduce(paths.count - 1) { $0 + $1.utf8.count }
        }
        guard bytes <= Limits.bytes else { throw AppError(L("该记录超过 %ld MiB。", Limits.recordSizeMiB), code: .validation) }
    }
}

package enum Content: Equatable {
    case text(String)
    case image(width: Int, height: Int)
    case files([String])

    var searchText: String {
        switch self {
        case let .text(text): return text
        case let .image(width, height): return "图片 image png \(width)×\(height)"
        case let .files(paths): return paths.joined(separator: "\n")
        }
    }
    func searchFields(ocrText: String?) -> [String] {
        if case let .files(paths) = self { return paths }
        if case .image = self, let ocrText, !ocrText.isEmpty { return [searchText, ocrText] }
        return [searchText]
    }
    package var label: String { EntryPresentation.label(for: self) }
    package var detail: String { EntryPresentation.detail(for: self) }
    package var preview: String { EntryPresentation.render(self).text }
}

package struct Entry {
    package let id: String
    package var date: Date
    package let content: Content
    package let thumbnail: CGImage?
    package var sourceAppBundleID: String?
    package private(set) var ocrText: String?
    private var presentation: EntryPresentation

    package var preview: String { presentation.preview.text }
    package var colorPreview: ClipboardColor? { presentation.color }
    var previewSpans: [Int: [EntryPresentation.PreviewSpan]] { presentation.preview.spans }
    var fuzzyTokens: [FuzzyMatcher.Token] { presentation.fuzzyTokens }
    var cachedSearchIndex: [String]? { presentation.cachedFields }

    init(id: String, date: Date, content: Content, thumbnail: CGImage? = nil, sourceAppBundleID: String? = nil,
         ocrText: String? = nil) {
        self.id = id
        self.date = date
        self.content = content
        self.thumbnail = thumbnail
        self.sourceAppBundleID = sourceAppBundleID
        self.ocrText = ocrText
        presentation = EntryPresentation(content: content, ocrText: ocrText)
    }

    func withOCR(_ text: String) -> Entry {
        var updated = self
        updated.ocrText = text
        updated.presentation.updateOCR(text, content: content)
        return updated
    }

    package func relocalized() -> Entry {
        var updated = self
        updated.presentation.relocalize(content: content, ocrText: ocrText)
        return updated
    }
}
