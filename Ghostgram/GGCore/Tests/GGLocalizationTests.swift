import Foundation
import XCTest

private struct GGTestStringsDataSource: GGStringsDataSource {
    let tables: [String: String]

    var languages: [String] {
        return ["en", "ru", "uk", "ar"].filter { self.tables[$0] != nil }
    }

    func chunks(for language: String) -> [String]? {
        guard let table = self.tables[language] else {
            return nil
        }
        return [table]
    }
}

final class GGLocalizationTests: XCTestCase {
    private var directory: GGTestDirectory!

    override func setUp() {
        super.setUp()
        self.directory = GGTestDirectory()
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment())
        GGLocalization.languageOverride.set("")
    }

    override func tearDown() {
        GGLocalization.languageOverride.set("")
        GGLocalization.shared.setTelegramLanguageCode("en")
        GGSettingsStore.shared.flushSynchronously()
        GGSettingsStore.shared.resetForTesting(environment: nil)
        self.directory.remove()
        super.tearDown()
    }

    private func makeLocalization() -> GGLocalization {
        let en = """
        {"t.title":"Title","t.only":"English only","t.deleted":"Deleted {date}","t.braces":"{{literal}} {name}",
         "t.files#one":"{count} file","t.files#other":"{count} files","t.named#one":"{count} file in {folder}","t.named#other":"{count} files in {folder}",
         "core.languageNativeName":"English"}
        """
        let ru = """
        {"t.title":"Заголовок","t.deleted":"Удалено {date}",
         "t.files#one":"{count} файл","t.files#few":"{count} файла","t.files#many":"{count} файлов","t.files#other":"{count} файла",
         "t.named#other":"{count} файлов в {folder}",
         "core.languageNativeName":"Русский"}
        """
        let uk = "{\"core.languageNativeName\":\"Українська\"}"
        return GGLocalization(dataSource: GGTestStringsDataSource(tables: ["en": en, "ru": ru, "uk": uk]))
    }

    func testSubstitutionIsNamedAndNeverRescanned() {
        XCTAssertEqual(GGLocalization.substitute("Deleted {date}", [("date", "today")]), "Deleted today")
        XCTAssertEqual(GGLocalization.substitute("{{x}} {a}", [("a", "{b}"), ("b", "no")]), "{x} {b}")
        XCTAssertEqual(GGLocalization.substitute("{missing} {a}", [("a", "1")]), "{missing} 1")
        XCTAssertEqual(GGLocalization.substitute("50% done %@", []), "50% done %@")
        XCTAssertEqual(GGLocalization.substitute("unclosed {a", [("a", "1")]), "unclosed {a")
    }

    func testPluralRules() {
        let ru: [(Int, GGPluralCategory)] = [(0, .many), (1, .one), (2, .few), (4, .few), (5, .many), (11, .many), (12, .many), (14, .many), (21, .one), (22, .few), (111, .many), (112, .many), (-1, .one)]
        for (count, category) in ru {
            XCTAssertEqual(GGPluralRules.category(for: count, language: "ru"), category, "ru \(count)")
            XCTAssertEqual(GGPluralRules.category(for: count, language: "uk"), category, "uk \(count)")
        }
        let ar: [(Int, GGPluralCategory)] = [(0, .zero), (1, .one), (2, .two), (3, .few), (10, .few), (11, .many), (99, .many), (100, .other), (102, .other), (103, .few)]
        for (count, category) in ar {
            XCTAssertEqual(GGPluralRules.category(for: count, language: "ar"), category, "ar \(count)")
        }
        XCTAssertEqual(GGPluralRules.category(for: 1, language: "en"), .one)
        XCTAssertEqual(GGPluralRules.category(for: 0, language: "en"), .other)
        XCTAssertEqual(GGPluralRules.category(for: Int.min, language: "ru"), .many)
    }

    func testLanguageResolution() {
        let localization = self.makeLocalization()
        XCTAssertEqual(localization.languageCode, "en")
        localization.setTelegramLanguageCode("ru-RU")
        XCTAssertEqual(localization.languageCode, "ru")
        localization.setTelegramLanguageCode("ru-raw")
        XCTAssertEqual(localization.languageCode, "ru")
        localization.setTelegramLanguageCode("de")
        XCTAssertEqual(localization.languageCode, "en")

        localization.setTelegramLanguageCode("ru")
        GGLocalization.languageOverride.set("uk")
        XCTAssertEqual(localization.languageCode, "uk")
        GGLocalization.languageOverride.set("xx")
        XCTAssertEqual(localization.languageCode, "ru")
        GGLocalization.languageOverride.set("")
        XCTAssertEqual(localization.languageCode, "ru")
    }

    func testLanguageSignal() {
        let localization = self.makeLocalization()
        let recorder = GGSignalRecorder(localization.languageCodeSignal)
        localization.setTelegramLanguageCode("ru")
        localization.setTelegramLanguageCode("ru-RU")
        localization.setTelegramLanguageCode("en")
        XCTAssertEqual(recorder.values, ["en", "ru", "en"])
        recorder.dispose()
    }

    func testLookupFallsBackToEnglishNeverToRussian() {
        let localization = self.makeLocalization()
        localization.setTelegramLanguageCode("ru")
        XCTAssertEqual(localization.string("t.title"), "Заголовок")
        XCTAssertEqual(localization.string("t.only"), "English only")
        XCTAssertEqual(localization.string("t.nowhere"), "t.nowhere")
        XCTAssertEqual(localization.format("t.deleted", [("date", "вчера")]), "Удалено вчера")
        XCTAssertEqual(localization.format("t.braces", [("name", "x")]), "{literal} x")

        localization.setTelegramLanguageCode("uk")
        XCTAssertEqual(localization.string("t.title"), "Title")
    }

    func testPluralLookup() {
        let localization = self.makeLocalization()
        XCTAssertEqual(localization.plural("t.files", count: 1, []), "1 file")
        XCTAssertEqual(localization.plural("t.files", count: 3, []), "3 files")
        localization.setTelegramLanguageCode("ru")
        XCTAssertEqual(localization.plural("t.files", count: 1, []), "1 файл")
        XCTAssertEqual(localization.plural("t.files", count: 3, []), "3 файла")
        XCTAssertEqual(localization.plural("t.files", count: 25, []), "25 файлов")
        // A missing form falls back to "other" of the same language.
        XCTAssertEqual(localization.plural("t.named", count: 1, [("folder", "Документы")]), "1 файлов в Документы")
        localization.setTelegramLanguageCode("uk")
        XCTAssertEqual(localization.plural("t.named", count: 2, [("folder", "Docs")]), "2 files in Docs")
        XCTAssertEqual(localization.plural("t.none", count: 2, []), "t.none")
    }

    func testAvailableLanguagesAreNamedInThemselves() {
        let localization = self.makeLocalization()
        XCTAssertEqual(localization.availableLanguages, [
            GGLanguageInfo(code: "en", nativeName: "English"),
            GGLanguageInfo(code: "ru", nativeName: "Русский"),
            GGLanguageInfo(code: "uk", nativeName: "Українська")
        ])
    }

    /// The committed generated tables parse and every language has the core keys.
    func testGeneratedTables() {
        for language in GGStringsData.languages {
            let chunks = GGStringsData.chunks(for: language) ?? []
            XCTAssertFalse(chunks.isEmpty, language)
            for chunk in chunks {
                let object = try? JSONSerialization.jsonObject(with: Data(chunk.utf8), options: [])
                XCTAssertNotNil(object as? [String: String], language)
            }
        }
        let localization = GGLocalization(dataSource: GGGeneratedStringsDataSource())
        XCTAssertEqual(localization.availableLanguages.map { $0.code }, ["en", "ru", "uk", "ar"])
        localization.setTelegramLanguageCode("ru")
        XCTAssertEqual(localization.string("core.requiresRestart"), "Нужен перезапуск")
        XCTAssertEqual(localization.format("core.import.unsupportedVersion", [("version", "2")]).contains("(формат 2)"), true)
    }

    func testGeneratedAccessorsFollowTheSharedLanguage() {
        GGLocalization.shared.setTelegramLanguageCode("en")
        XCTAssertEqual(GGStrings.Core.requiresRestart, "Restart required")
        GGLocalization.shared.setTelegramLanguageCode("ru")
        XCTAssertEqual(GGStrings.Core.requiresRestart, "Нужен перезапуск")
        XCTAssertEqual(GGSettingsImportError.unsupportedVersion(3).localizedText, GGStrings.Core.Import.unsupportedVersion(version: "3"))
        GGLocalization.shared.setTelegramLanguageCode("en")
    }

    /// The summary on the right of «Скрыть в сообщениях» / «Скрыть в шапке чата» (W5-CMP2): both
    /// numbers land in every language.
    func testHiddenCountSummary() {
        let expected: [(String, String)] = [
            ("ru", "скрыто: 2 из 4"),
            ("en", "hidden: 2 of 4"),
            ("uk", "приховано: 2 з 4"),
            ("ar", "مخفي: 2 من 4")
        ]
        for (language, text) in expected {
            GGLocalization.shared.setTelegramLanguageCode(language)
            XCTAssertEqual(GGStrings.Appearance.Messages.hiddenCount(selected: "2", total: "4"), text, language)
        }
        GGLocalization.shared.setTelegramLanguageCode("en")
    }
}
