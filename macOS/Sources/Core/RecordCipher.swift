import Foundation
import CryptoKit
import SQLite3

// 明文类型和尺寸参与每列的认证，防止记录被当作另一种类型解释。
struct RecordHeader {
    let id: String
    let kind: Int64
    let width: Int
    let height: Int

    init(id: String, content: Content) {
        self.id = id
        switch content {
        case .text: (kind, width, height) = (0, 0, 0)
        case .image(let w, let h): (kind, width, height) = (1, w, h)
        case .files: (kind, width, height) = (2, 0, 0)
        }
    }
    init(_ row: OpaquePointer) throws {
        guard sqlite3_column_type(row, 0) == SQLITE_TEXT, sqlite3_column_bytes(row, 0) == 64,
              let bytes = sqlite3_column_text(row, 0),
              UnsafeBufferPointer(start: bytes, count: 64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...3).allSatisfy({ sqlite3_column_type(row, $0) == SQLITE_INTEGER }) else {
            throw AppError(L("记录标识或类型无效。"))
        }
        id = String(cString: bytes)
        kind = sqlite3_column_int64(row, 1)
        width = Int(sqlite3_column_int64(row, 2))
        height = Int(sqlite3_column_int64(row, 3))
        if kind == 1 {
            guard width > 0, height > 0, width <= Limits.pixels / height else { throw AppError(L("记录图片尺寸无效。")) }
        } else {
            guard (kind == 0 || kind == 2), height == 0, width == 0 else { throw AppError(L("记录类型或尺寸无效。")) }
        }
    }
    func authentication(_ column: String) -> Data {
        Data("\(id):\(column):\(kind):\(width):\(height)".utf8)
    }
}

struct RecordCipher {
    let key: SymmetricKey
    static let overhead = 12 + 16 // AES-GCM 的 nonce 和认证标签。

    static func fingerprint(_ payload: Payload) -> String {
        var hash = SHA256()
        func number(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { hash.update(bufferPointer: $0) }
        }
        func bytes(_ data: Data?) {
            guard let data else { number(.max); return }
            number(UInt64(data.count))
            hash.update(data: data)
        }
        func string(_ value: String) {
            number(UInt64(value.utf8.count))
            if value.utf8.withContiguousStorageIfAvailable({ hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }) == nil {
                hash.update(data: Data(value.utf8))
            }
        }
        switch payload {
        case let .text(text, html, rtf):
            number(0); string(text); bytes(html); bytes(rtf)
        case let .image(png, width, height):
            number(1); number(UInt64(bitPattern: Int64(width))); number(UInt64(bitPattern: Int64(height))); bytes(png)
        case let .files(paths):
            number(2); number(UInt64(paths.count))
            for path in paths { string(path) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func seal(_ data: Data?, _ header: RecordHeader, _ column: String) throws -> HistoryDatabase.Value {
        guard let data else { return .null }
        let box = try AES.GCM.seal(data, using: key, authenticating: header.authentication(column))
        guard let combined = box.combined else { throw AppError(L("无法生成加密记录。"), code: .crypto) }
        return .blob(combined as NSData)
    }
    func open(_ stmt: OpaquePointer, at index: Int32, header: RecordHeader, column: String,
              maxBytes: Int = Limits.bytes) throws -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, index))
        guard sqlite3_column_type(stmt, index) == SQLITE_BLOB, (Self.overhead...maxBytes + Self.overhead).contains(length),
              let bytes = sqlite3_column_blob(stmt, index) else { throw AppError(L("记录的 %@ 列长度或格式无效。", column), code: .crypto) }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: length, deallocator: .none)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: header.authentication(column))
        } catch { throw AppError(L("记录的 %@ 列解密失败：%@", column, error.localizedDescription), code: .crypto) }
    }
}
