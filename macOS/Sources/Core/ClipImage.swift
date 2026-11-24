import Foundation
import ImageIO
import UniformTypeIdentifiers

package enum ClipImage {
    package static func source(_ data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AppError(L("无法读取图片数据。"))
        }
        return source
    }

    package static func size(_ data: Data) throws -> (Int, Int) { try size(source(data)) }

    package static func size(_ source: CGImageSource) throws -> (Int, Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Limits.pixels / height else {
            throw AppError(L("图片无法读取或超过 3200 万像素。"))
        }
        return (width, height)
    }

    package static func thumbnail(_ data: Data, maxPixelSize: Int, expectedSize: (Int, Int)? = nil) throws -> CGImage {
        let source = try source(data)
        let dimensions = try size(source)
        if let expectedSize, dimensions != expectedSize { throw AppError(L("图片尺寸校验失败。")) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError(L("无法解码图片缩略图。"))
        }
        return image
    }

    package static func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError(L("无法创建 PNG 图片。"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError(L("无法编码 PNG 图片。")) }
        return output as Data
    }
}
