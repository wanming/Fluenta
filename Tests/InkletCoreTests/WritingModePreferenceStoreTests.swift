import XCTest
@testable import InkletCore

final class WritingModePreferenceStoreTests: XCTestCase {
    func testLastModeIDRoundTripsWithoutWritingAppConfig() throws {
        let suiteName = "WritingModePreferenceStoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let appConfigData = Data("sentinel-app-config".utf8)
        userDefaults.set(appConfigData, forKey: UserDefaultsConfigStore.defaultKey)
        let store = WritingModePreferenceStore(userDefaults: userDefaults)

        XCTAssertNil(store.loadLastModeID())

        store.saveLastModeID(PromptMode.friendlyReplyID)

        XCTAssertEqual(store.loadLastModeID(), PromptMode.friendlyReplyID)
        XCTAssertEqual(
            userDefaults.string(forKey: WritingModePreferenceStore.defaultKey),
            PromptMode.friendlyReplyID
        )
        XCTAssertEqual(userDefaults.data(forKey: UserDefaultsConfigStore.defaultKey), appConfigData)
    }

    func testCustomKeyRoundTripsWithoutWritingDefaultPreferenceKey() throws {
        let suiteName = "WritingModePreferenceStoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let customKey = "customWritingModeID.\(UUID().uuidString)"
        let store = WritingModePreferenceStore(userDefaults: userDefaults, key: customKey)

        store.saveLastModeID(PromptMode.friendlyReplyID)

        XCTAssertEqual(store.loadLastModeID(), PromptMode.friendlyReplyID)
        XCTAssertEqual(userDefaults.string(forKey: customKey), PromptMode.friendlyReplyID)
        XCTAssertNil(userDefaults.object(forKey: WritingModePreferenceStore.defaultKey))
    }
}
