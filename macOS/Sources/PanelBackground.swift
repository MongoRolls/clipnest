import AppKit
import ImageIO
import UniformTypeIdentifiers

private struct SavedBackground: Codable {
    let name: String
    let png: Data

    static func prepare(from url: URL) throws -> (SavedBackground, CGImage) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let source = try ClipImage.source(data)
        guard let type = CGImageSourceGetType(source),
              [UTType.png, .jpeg, .heic].contains(where: { $0.identifier == type as String }) else {
            throw AppError(L("请选择 PNG、JPEG 或 HEIC 图片。"))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
            throw AppError(L("无法完整解码背景图片。"))
        }
        return (SavedBackground(name: url.lastPathComponent, png: try ClipImage.png(image)), image)
    }
}

@MainActor
final class PanelBackgroundStore {
    private let file: URL
    private(set) var name: String?
    private(set) var image: NSImage?
    private(set) var loadError: Error?
    private(set) var importing = false
    var onChange: (() -> Void)?

    init(directory: URL) {
        file = AppPaths(directory: directory).panelBackground
        do {
            let saved = try PropertyListDecoder().decode(SavedBackground.self, from: Data(contentsOf: file))
            let source = try ClipImage.source(saved.png)
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw AppError(L("无法完整解码背景图片。"))
            }
            setImage(cgImage, name: saved.name)
        } catch CocoaError.fileReadNoSuchFile {
            // 首次启动和移除图片后都使用系统材质。
        } catch { loadError = error }
    }

    private func setImage(_ cgImage: CGImage, name: String) {
        self.name = name
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        loadError = nil
    }

    func replace(with url: URL) async throws {
        guard !importing else { throw AppError(L("正在导入背景图片。")) }
        importing = true
        onChange?()
        defer { importing = false; onChange?() }
        let (name, image) = try await Task.detached(priority: .userInitiated) { [file] in
            let (saved, image) = try SavedBackground.prepare(from: url)
            // 文件名和图片一起原子替换，写入失败时仍可使用原图。
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(saved).write(to: file, options: .atomic)
            return (saved.name, image)
        }.value
        setImage(image, name: name)
    }

    func remove() throws {
        guard !importing else { throw AppError(L("正在导入背景图片。")) }
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile { /* 副本已被用户移除。 */ }
        name = nil
        image = nil
        loadError = nil
        onChange?()
    }
}
