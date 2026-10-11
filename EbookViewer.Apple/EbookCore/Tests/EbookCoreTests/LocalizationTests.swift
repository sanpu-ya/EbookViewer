import XCTest
@testable import EbookCore

/// パッケージに同梱した Localizable.strings (en / ja) の読み取り。
///
/// どの言語が引かれるかは実行環境の設定しだいなので、「英語になること」ではなく
/// 「実行環境の言語の表のとおりに引けること」と「どの言語の表にも訳が載っていること」を見る。
final class LocalizationTests: XCTestCase {
    private static let drmKey = "This book is protected by DRM and cannot be opened."
    private static let unsupportedKey = "Unsupported file format: %@"
    private static let notFoundKey = "File not found: %@"

    func testErrorMessagesComeFromTheStringsFile() throws {
        let table = try entries(preferredLocalization())
        XCTAssertEqual(BookError.drmProtected.localizedDescription, try XCTUnwrap(table[Self.drmKey]))
        XCTAssertEqual(
            BookError.unsupportedFormat("a.txt").localizedDescription,
            String(format: try XCTUnwrap(table[Self.unsupportedKey]), "a.txt"))
        XCTAssertEqual(
            BookError.fileNotFound("/x").localizedDescription,
            String(format: try XCTUnwrap(table[Self.notFoundKey]), "/x"))
    }

    func testEnglishAndJapaneseTablesMatch() throws {
        let en = try entries("en")
        let ja = try entries("ja")
        XCTAssertFalse(en.isEmpty)
        XCTAssertEqual(Set(en.keys), Set(ja.keys), "en と ja で鍵がそろっていない")
        // 鍵は英語の文そのものなので、en は鍵と同じ。ja は訳されていること
        for (key, value) in en { XCTAssertEqual(value, key) }
        for (key, value) in ja { XCTAssertNotEqual(value, key, "\(key) が訳されていない") }
        XCTAssertEqual(ja[Self.unsupportedKey], "対応していないファイル形式です: %@")
    }

    func testErrorKindIsUnsupported() {
        XCTAssertTrue(BookError.drmProtected.isUnsupported)
        XCTAssertFalse(BookError.invalidData("x").isUnsupported)
    }

    // MARK: - 表の読み取り

    /// 実行環境で実際に引かれる言語。
    private func preferredLocalization() -> String {
        let available = Set(Localized.bundle.localizations)
        for localization in Localized.bundle.preferredLocalizations where available.contains(localization) {
            return localization
        }
        return "en"
    }

    /// 指定した言語の Localizable.strings を "鍵 → 文言" にして返す。
    ///
    /// 置き場所は macOS ではバンドルの Contents/Resources、Linux ではバンドル直下になる。
    /// Linux の Foundation は localization 引数付きの検索に対応していないので、パスを組み立てる。
    private func entries(_ localization: String) throws -> [String: String] {
        let base = Localized.bundle.resourceURL ?? Localized.bundle.bundleURL
        let url = base.appendingPathComponent("\(localization).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\";") else { continue }
            let body = trimmed.dropFirst().dropLast(2)
            let parts = body.components(separatedBy: "\" = \"")
            guard parts.count == 2 else { continue }
            table[parts[0]] = parts[1]
        }
        XCTAssertFalse(table.isEmpty, "\(localization) の Localizable.strings が読めない")
        return table
    }
}
