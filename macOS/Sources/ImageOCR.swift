import Foundation
import Vision

enum ImageOCR {
    static func recognize(pngData: Data, expectedSize: (Int, Int), maxPixelSize: Int,
                          cancellation: CancellationToken = CancellationToken()) throws -> String {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let image = try ClipImage.thumbnail(pngData, maxPixelSize: min(maxPixelSize, max(expectedSize.0, expectedSize.1)),
                                            expectedSize: expectedSize)
        let request = VNRecognizeTextRequest()
        cancellation.setHandler { request.cancel() }
        defer { cancellation.setHandler(nil) }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Vision 根据识别精度和系统版本决定可用语言，按当前请求查询。
        // https://developer.apple.com/documentation/vision/vnrecognizetextrequest
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["zh-Hans", "zh-Hant", "en-US"] + Locale.preferredLanguages
        var languages: [String] = []
        for language in preferred {
            let identifier = Locale.Language(identifier: language)
            let match = supported.first { $0 == language } ?? supported.first {
                let candidate = Locale.Language(identifier: $0)
                return candidate.languageCode == identifier.languageCode && candidate.script == identifier.script
            }
            if let match, !languages.contains(match) { languages.append(match) }
        }
        if !languages.isEmpty { request.recognitionLanguages = languages }
        guard !cancellation.isCancelled else { throw CancellationError() }
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let observations = request.results else {
            throw AppError(L("图片文字识别未返回结果。"), code: .ocr)
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
