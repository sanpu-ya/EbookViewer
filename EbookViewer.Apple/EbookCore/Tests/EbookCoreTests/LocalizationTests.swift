import XCTest
@testable import EbookCore

final class LocalizationTests: XCTestCase {
    func testErrorMessagesAreLocalizedInEnglishByDefault() {
        XCTAssertEqual(BookError.drmProtected.localizedDescription, "This book is protected by DRM and cannot be opened.")
        XCTAssertEqual(BookError.unsupportedFormat("a.txt").localizedDescription, "Unsupported file format: a.txt")
        XCTAssertEqual(BookError.fileNotFound("/x").localizedDescription, "File not found: /x")
        XCTAssertTrue(BookError.drmProtected.isUnsupported)
        XCTAssertFalse(BookError.invalidData("x").isUnsupported)
    }

    func testJapaneseStringsFileIsBundled() throws {
        // Linux の Foundation は localization 引数付きの検索に対応していないので、パスを直接組み立てる
        let url = Localized.bundle.bundleURL.appendingPathComponent("ja.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("対応していないファイル形式です: %@"))
    }
}
