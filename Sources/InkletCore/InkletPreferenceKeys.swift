public enum InkletPreferenceKeys {
    public static let appConfig = "appConfig"
    public static let modelCatalogSnapshot = "modelCatalogSnapshot"
    public static let interfaceLanguage = "InkletInterfaceLanguage"
    public static let didCompleteOnboarding = "didCompleteOnboarding"
    public static let translationPanelSize = "SelectionActionWindowController.translationPanelSize"
    public static let lastWritingPromptModeID = "lastWritingPromptModeID"
    public static let lastAutomaticUpdateCheckDate = "lastAutomaticUpdateCheckDate"
    public static let providerAPIKeyPrefix = "providerAPIKey."

    public static let recognizedLegacyKeys = [
        appConfig,
        modelCatalogSnapshot,
        interfaceLanguage,
        didCompleteOnboarding,
        translationPanelSize,
        lastWritingPromptModeID
    ]

    public static func providerID(fromLegacyKey key: String) -> String? {
        guard key.hasPrefix(providerAPIKeyPrefix) else { return nil }
        let providerID = String(key.dropFirst(providerAPIKeyPrefix.count))
        return providerID.isEmpty ? nil : providerID
    }
}
