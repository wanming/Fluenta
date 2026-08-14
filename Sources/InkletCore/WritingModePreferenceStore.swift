import Foundation

public struct WritingModePreferenceStore: @unchecked Sendable {
    public static let defaultKey = InkletPreferenceKeys.lastWritingPromptModeID

    private let userDefaults: UserDefaults
    private let key: String

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = WritingModePreferenceStore.defaultKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func loadLastModeID() -> String? {
        userDefaults.string(forKey: key)
    }

    public func saveLastModeID(_ modeID: String) {
        userDefaults.set(modeID, forKey: key)
    }
}
