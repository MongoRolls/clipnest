import Foundation
import CoreGraphics
import SQLite3

struct RecordMapper {
    let cipher: RecordCipher

    enum LightColumn: Int32 {
        case id = 0, kind, width, height, text, thumb
        case historyRank, historyAt, favoriteRank, favoriteAt
        case rowID, sourceApp, ocrText
    }
    static let lightColumns = """
        id,kind,width,height,text,thumb,history_rank,history_at,favorite_rank,favorite_at,rowid,source_app,ocr_text
        """

    enum PayloadColumn: Int32 {
        case id = 0, kind, width, height, text, html, rtf, png
    }
    static let payloadColumns = "id,kind,width,height,text,html,rtf,png"
    static let ocrTargetColumns = "id,kind,width,height,length(png)"

    func historyOrder(_ row: OpaquePointer) throws -> (rank: Int64, date: Date)? {
        try order(row, at: LightColumn.historyRank.rawValue)
    }

    func favoriteOrder(_ row: OpaquePointer) throws -> (rank: Int64, date: Date)? {
        try order(row, at: LightColumn.favoriteRank.rawValue)
    }

    func rowID(_ row: OpaquePointer) -> Int64 {
        sqlite3_column_int64(row, LightColumn.rowID.rawValue)
    }

    func membership(_ row: OpaquePointer) -> (hasHistory: Bool, hasFavorite: Bool) {
        (sqlite3_column_type(row, 0) != SQLITE_NULL, sqlite3_column_type(row, 1) != SQLITE_NULL)
    }

    func ocrTarget(_ row: OpaquePointer) throws -> (header: RecordHeader, pngLength: Int) {
        (try RecordHeader(row), Int(sqlite3_column_int64(row, 4)) - RecordCipher.overhead)
    }

    func order(_ row: OpaquePointer, at index: Int32) throws -> (rank: Int64, date: Date)? {
        let rankType = sqlite3_column_type(row, index), dateType = sqlite3_column_type(row, index + 1)
        if rankType == SQLITE_NULL && dateType == SQLITE_NULL { return nil }
        let rank = sqlite3_column_int64(row, index), time = sqlite3_column_double(row, index + 1)
        guard rankType == SQLITE_INTEGER, rank > 0, (dateType == SQLITE_FLOAT || dateType == SQLITE_INTEGER),
              time.isFinite else { throw AppError(L("记录顺位或日期无效。")) }
        return (rank, Date(timeIntervalSince1970: time))
    }

    func textContent(_ bytes: Data?, header: RecordHeader) throws -> Content {
        guard let bytes, let string = String(data: bytes, encoding: .utf8), !string.isEmpty else {
            throw AppError(L("正文为空或编码无效。"))
        }
        if header.kind == 0 { return .text(string) }
        let paths = string.components(separatedBy: "\0")
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw AppError(L("文件路径无效。")) }
        return .files(paths)
    }

    func lightEntry(_ row: OpaquePointer, date: Date) throws -> Entry {
        let header = try RecordHeader(row)
        let text = try cipher.open(row, at: LightColumn.text.rawValue, header: header, column: "text")
        let thumb = try cipher.open(row, at: LightColumn.thumb.rawValue, header: header, column: "thumb")
        var source: String?
        if let data = try cipher.open(row, at: LightColumn.sourceApp.rawValue, header: header, column: "source_app") {
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw AppError(L("来源应用标识无效。"), code: .database)
            }
            source = value
        }
        let content: Content
        var image: CGImage?
        if header.kind == 1 {
            guard text == nil, let thumb else { throw AppError(L("图片的缩略图或正文列无效。")) }
            image = try ClipImage.thumbnail(thumb, maxPixelSize: Tuning.thumbnailMaxPixelSize)
            content = .image(width: header.width, height: header.height)
        } else {
            guard thumb == nil else { throw AppError(L("文本或文件记录包含意外的缩略图。")) }
            content = try textContent(text, header: header)
        }
        var ocrText: String?
        if let data = try cipher.open(row, at: LightColumn.ocrText.rawValue, header: header, column: "ocr_text", maxBytes: Limits.ocrBytes) {
            guard header.kind == 1, let string = String(data: data, encoding: .utf8) else {
                throw AppError(L("图片文字的类型或编码无效。"), code: .database)
            }
            ocrText = string
        }
        return Entry(id: header.id, date: date, content: content, thumbnail: image, sourceAppBundleID: source,
                     ocrText: ocrText)
    }

    func payload(_ row: OpaquePointer) throws -> Payload {
        let header = try RecordHeader(row)
        let text = try cipher.open(row, at: PayloadColumn.text.rawValue, header: header, column: "text")
        let html = try cipher.open(row, at: PayloadColumn.html.rawValue, header: header, column: "html")
        let rtf = try cipher.open(row, at: PayloadColumn.rtf.rawValue, header: header, column: "rtf")
        let png = try cipher.open(row, at: PayloadColumn.png.rawValue, header: header, column: "png")
        if header.kind == 1, let png, text == nil, html == nil, rtf == nil {
            return .image(png: png, width: header.width, height: header.height)
        }
        if header.kind != 1, png == nil {
            switch try textContent(text, header: header) {
            case let .text(string): return .text(string, html: html, rtf: rtf)
            case let .files(paths) where html == nil && rtf == nil: return .files(paths)
            default: throw AppError(L("记录的正文列无效。"))
            }
        }
        throw AppError(L("记录的正文列无效。"))
    }
}
