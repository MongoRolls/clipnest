import Foundation
import XCTest
@testable import ClipNestCore

final class SearchRankingTests: XCTestCase {
    func testRankingSnapshot() {
        let titles = ["HistoryStore.swift", "StorageMetadataTests", "Store", "HistoryStore"]
        let entries = titles.map { Entry(id: $0, date: .distantPast, content: .text($0)) }
        guard case .entries(let sorted, let highlights) = HistorySearch.evaluate(entries, query: "type:text store") else {
            return XCTFail("预期返回普通搜索结果")
        }
        XCTAssertEqual(sorted.map(\.id), ["Store", "HistoryStore.swift", "HistoryStore", "StorageMetadataTests"])
        XCTAssertEqual(highlights["Store"], [NSRange(location: 0, length: 5)])
        XCTAssertEqual(highlights["HistoryStore.swift"], [NSRange(location: 7, length: 5)])
    }

    func testLargeFieldMatchesWholeFieldUnicodeScores() throws {
        let source = try CoreTestFiles.source("HistoryStore")
        let corpus = String(repeating: source, count: 1 + 1024 * 1024 / source.utf8.count)
        let line = "import Foundation "
        let first = String(String(repeating: line, count: 65536 / line.utf8.count + 1).prefix(65536))
        let terms = ["ΟΣ", "ΟΣΑ", "Café", "HEAD", "TAIL", "missing-suffix"].map { $0.lowercased() }
        let samples = [
            first + "ΟΣ TAIL\nHEAD Cafe\u{301} ΟΣΑ\n" + corpus,
            "HEAD " + corpus.replacingOccurrences(of: "\n", with: " ") + " ΟΣ Cafe\u{301} ΟΣΑ TAIL"
        ]
        for text in samples {
            let entry = Entry(id: HistoryStore.fingerprint(.text(text)), date: .distantPast, content: .text(text))
            XCTAssertNil(entry.cachedSearchIndex)
            try assertWholeFieldScores(entry, terms: terms)
            try assertWholeFieldScores(entry, terms: terms.reversed())
        }
    }

    func testPathScoresRestartAtEachField() throws {
        let first = CoreTestFiles.project.appendingPathComponent("macOS/Sources/Core/RecordCipher.swift").path
        let second = CoreTestFiles.project.appendingPathComponent("macOS/Sources/Core/KeyProvider.swift").path
        let paths = Array(repeating: first, count: 1 + 1024 * 1024 / first.utf8.count) + [second]
        let entry = Entry(id: HistoryStore.fingerprint(.files(paths)), date: .distantPast, content: .files(paths))
        XCTAssertNil(entry.cachedSearchIndex)
        try assertWholeFieldScores(entry, terms: ["recordcipher", "keyprovider"])
    }

    private func assertWholeFieldScores(_ entry: Entry, terms: [String]) throws {
        let originalFields = entry.content.searchFields(ocrText: entry.ocrText).map { $0.lowercased() }
        let expected: [Int?] = terms.map { term in
            for field in originalFields {
                guard let start = field.range(of: term)?.lowerBound else { continue }
                let previous = start == field.startIndex ? nil : field[field.index(before: start)]
                let boundary = previous.map { !$0.isLetter && !$0.isNumber } ?? true
                return max(0, 64 - start.utf16Offset(in: field) / 16) + (boundary ? 30 : 0)
            }
            return nil
        }
        XCTAssertEqual(SearchRanker.exactScores(for: terms, in: entry, cancelled: { false }), expected)
    }
}
