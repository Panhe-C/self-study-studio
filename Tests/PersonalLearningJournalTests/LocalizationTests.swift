import XCTest

final class LocalizationTests: XCTestCase {
    func testEnglishAndChineseCoreKeysMatch() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PersonalLearningJournal/Resources")
        let english = try LocalizedStringFile.keys(at: resources.appendingPathComponent("en.lproj/Localizable.strings"))
        let chinese = try LocalizedStringFile.keys(at: resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings"))

        XCTAssertEqual(english, chinese)
        XCTAssertTrue(english.contains("review.decision.continue"))
        XCTAssertTrue(english.contains("trash.delete_permanently"))
        XCTAssertTrue(english.contains("privacy.app_lock"))
    }
}

private enum LocalizedStringFile {
    static func keys(at url: URL) throws -> Set<String> {
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = #"^\s*\"([^\"]+)\"\s*="#
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(source.startIndex..., in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }
}
