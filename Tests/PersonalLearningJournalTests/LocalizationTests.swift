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
        // Task 12: two-tab navigation, courses list, onboarding, adjustments.
        XCTAssertTrue(english.contains("nav.courses"))
        XCTAssertTrue(english.contains("root.menu.sync"))
        XCTAssertTrue(english.contains("root.menu.app_lock"))
        XCTAssertTrue(english.contains("courses.manual_badge"))
        XCTAssertTrue(english.contains("courses.pending_suggestions"))
        XCTAssertTrue(english.contains("onboarding.promise"))
        XCTAssertTrue(english.contains("onboarding.create_course"))
        XCTAssertTrue(english.contains("onboarding.manual"))
        XCTAssertTrue(english.contains("adjustment.pending.section"))
        XCTAssertTrue(english.contains("adjustment.adopt"))
        XCTAssertTrue(english.contains("adjustment.modify"))
        XCTAssertTrue(english.contains("adjustment.ignore"))
        XCTAssertTrue(english.contains("adjustment.review_draft"))
        XCTAssertTrue(english.contains("adjustment.request"))
        XCTAssertTrue(english.contains("adjustment.requesting"))
        XCTAssertTrue(english.contains("adjustment.sheet.adopt.title"))
        XCTAssertTrue(english.contains("adjustment.command.daily_order.date"))
        XCTAssertTrue(english.contains("adjustment.command.temporary_duration.minutes"))
        XCTAssertTrue(english.contains("adjustment.error.command_kind_mismatch"))
        XCTAssertTrue(english.contains("adjustment.error.invalid_structural"))
        XCTAssertTrue(english.contains("vnext.today.practice.manage"))
        XCTAssertTrue(english.contains("vnext.today.practice.start"))
        XCTAssertTrue(english.contains("vnext.today.practice.continue"))
        XCTAssertTrue(english.contains("vnext.today.practice.recovery.active"))
        XCTAssertTrue(english.contains("vnext.today.practice.recovery.pending"))
        XCTAssertTrue(english.contains("vnext.today.practice.recovery.accessibility"))
        XCTAssertTrue(english.contains("vnext.today.practice.shelf.title"))
        XCTAssertTrue(english.contains("vnext.today.practice.shelf.total"))
        XCTAssertTrue(english.contains("vnext.today.practice.project_unavailable"))
        XCTAssertTrue(english.contains("ai.settings.provider"))
        XCTAssertTrue(english.contains("ai.settings.preset_footer"))
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
