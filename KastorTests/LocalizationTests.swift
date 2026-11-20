import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testSentorTwelveLanguagesAndRightToLeftConfiguration() {
        let expectedCodes = ["en", "tr", "es", "fr", "de", "it", "pt", "ja", "zh", "ko", "ru", "ar"]
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), expectedCodes)
        XCTAssertEqual(AppLanguage.allCases.count, 12)

        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(lang.isRightToLeft, lang == .ar)
        }
    }

    func testAllLocalizationKeysExistAcrossAllTwelveLanguages() {
        for key in L10nKey.allCases {
            for lang in AppLanguage.allCases {
                let text = L10n.string(key, lang)
                XCTAssertFalse(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Missing translation for \(key.rawValue) in \(lang.rawValue)"
                )
            }
        }

        for lang in AppLanguage.allCases {
            XCTAssertFalse(L10n.itemCount(0, lang).isEmpty)
            XCTAssertFalse(L10n.itemCount(1, lang).isEmpty)
            XCTAssertFalse(L10n.itemCount(5, lang).isEmpty)
            XCTAssertFalse(L10n.deleteConfirmMessage(3, lang).isEmpty)
            XCTAssertFalse(L10n.deleteDoneFeedback(0, lang).isEmpty)
            XCTAssertFalse(L10n.deleteDoneFeedback(2, lang).isEmpty)
        }
    }

    func testPreferencesDefaultsAndPersistence() throws {
        let suiteName = "com.kastor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = KastorPreferences(defaults: defaults)
        XCTAssertEqual(prefs.language, .en)
        XCTAssertEqual(prefs.securityMode, .sensitive)
        XCTAssertFalse(prefs.autoDelete24Hours)
        XCTAssertEqual(prefs.historySize, 100)

        prefs.language = .tr
        prefs.securityMode = .normal
        prefs.autoDelete24Hours = true
        prefs.historySize = 200

        let reloaded = KastorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.language, .tr)
        XCTAssertEqual(reloaded.securityMode, .normal)
        XCTAssertTrue(reloaded.autoDelete24Hours)
        XCTAssertEqual(reloaded.historySize, 200)
    }
}
