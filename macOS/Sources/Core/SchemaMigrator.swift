import Foundation
import SQLite3

enum SchemaVersion {
    static let current: Int32 = 4
    static func supports(_ value: Int32) -> Bool { (2...current).contains(value) }
}

enum SchemaMigrator {
    private struct Migration {
        let from: Int32
        let to: Int32
        let columns: [String]
    }
    private static let migrations = [
        Migration(from: 2, to: 3, columns: ["source_app", "tags"]),
        Migration(from: 3, to: 4, columns: ["ocr_text"])
    ]
    private static let baseColumns = ["id", "kind", "width", "height", "history_rank", "history_at", "favorite_rank",
                                      "favorite_at", "text", "thumb", "html", "rtf", "png"]

    static func apply(to db: HistoryDatabase) throws {
        try db.transaction {
            var version = try db.userVersion()
            if version == 0 {
                try db.exec("""
                    CREATE TABLE records(
                        id TEXT PRIMARY KEY, kind INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
                        history_rank INTEGER, history_at REAL, favorite_rank INTEGER, favorite_at REAL,
                        source_app BLOB, tags BLOB, ocr_text BLOB, text BLOB, thumb BLOB, html BLOB, rtf BLOB, png BLOB);
                    CREATE INDEX history_order ON records(history_rank) WHERE history_rank IS NOT NULL;
                    CREATE INDEX favorite_order ON records(favorite_rank) WHERE favorite_rank IS NOT NULL;
                    CREATE INDEX unlisted_records ON records(id) WHERE history_rank IS NULL AND favorite_rank IS NULL;
                    """)
            } else {
                let archive = try columns(of: "damaged_records", in: db)
                let records = try columns(of: "records", in: db)
                guard archive.isEmpty || archive == records else {
                    throw AppError(L("归档表与历史表的列不一致。"), code: .damagedDatabase)
                }
                let expected = baseColumns + migrations.filter { $0.to <= version }.flatMap(\.columns)
                guard Set(expected).isSubset(of: records) else {
                    throw AppError(L("历史表与数据库版本的列不一致。"), code: .damagedDatabase)
                }
                if version == SchemaVersion.current { return }
                let tables = archive.isEmpty ? ["records"] : ["records", "damaged_records"]
                for migration in migrations where migration.from == version {
                    for table in tables {
                        // SQLite 将新列追加在末尾。两表必须保持同序，归档时才能逐列原样复制。
                        for column in migration.columns { try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) BLOB") }
                    }
                    version = migration.to
                }
                guard version == SchemaVersion.current else {
                    throw AppError(L("数据库格式版本无法识别。"), code: .database)
                }
            }
            try db.exec("PRAGMA user_version=\(SchemaVersion.current)")
        }
    }

    private static func columns(of table: String, in db: HistoryDatabase) throws -> [String] {
        var names: [String] = []
        try db.rows("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.text(table)]) {
            names.append(String(cString: sqlite3_column_text($0, 0)))
        }
        return names
    }
}
