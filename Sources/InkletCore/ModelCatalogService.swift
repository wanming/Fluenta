import Foundation

public struct ModelCatalogSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var providerModels: [String: [String]]

    public init(fetchedAt: Date, providerModels: [String: [String]]) {
        self.fetchedAt = fetchedAt
        self.providerModels = providerModels
    }
}

public final class ModelCatalogService: @unchecked Sendable {
    public static let cacheKey = InkletPreferenceKeys.modelCatalogSnapshot
    public static let catalogURL = URL(string: "https://models.dev/api.json")!
    public static let refreshInterval: TimeInterval = 86_400
    public static let maxModelsPerProvider = 80

    private let userDefaults: UserDefaults
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let bundledFallbackData: () -> Data?
    private let now: () -> Date
    private let fetchData: (URL) async throws -> Data

    public init(
        userDefaults: UserDefaults = .standard,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        bundledFallbackData: (() -> Data?)? = nil,
        now: @escaping () -> Date = Date.init,
        fetchData: @escaping (URL) async throws -> Data = { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
    ) {
        self.userDefaults = userDefaults
        self.decoder = decoder
        self.encoder = encoder
        self.bundledFallbackData = bundledFallbackData ?? Self.loadBundledFallbackData
        self.now = now
        self.fetchData = fetchData
    }

    public func cachedModelIDs(for providerID: String) -> [String]? {
        cachedSnapshot()?.providerModels[providerID]
    }

    public func refreshIfNeeded() async throws {
        if let snapshot = cachedSnapshot(),
           now().timeIntervalSince(snapshot.fetchedAt) < Self.refreshInterval {
            return
        }

        do {
            let data = try await fetchData(Self.catalogURL)
            let snapshot = try Self.snapshot(from: data, fetchedAt: now(), decoder: decoder)
            try save(snapshot)
        } catch {
            if cachedSnapshot() == nil {
                throw error
            }
        }
    }

    private func cachedSnapshot() -> ModelCatalogSnapshot? {
        if let data = userDefaults.data(forKey: Self.cacheKey),
           let snapshot = try? decoder.decode(ModelCatalogSnapshot.self, from: data) {
            return snapshot
        }

        guard let data = bundledFallbackData() else {
            return nil
        }

        return try? decoder.decode(ModelCatalogSnapshot.self, from: data)
    }

    private func save(_ snapshot: ModelCatalogSnapshot) throws {
        let data = try encoder.encode(snapshot)
        userDefaults.set(data, forKey: Self.cacheKey)
    }

    private static func loadBundledFallbackData() -> Data? {
        guard let url = bundledFallbackURL() else {
            return nil
        }

        return try? Data(contentsOf: url)
    }

    static func bundledFallbackURL(mainBundleURL: URL = Bundle.main.bundleURL) -> URL? {
        let appResourceURL = mainBundleURL
            .appendingPathComponent("Contents/Resources/Inklet_InkletCore.bundle", isDirectory: true)
            .appendingPathComponent("model-catalog-snapshot.json")

        if FileManager.default.fileExists(atPath: appResourceURL.path) {
            return appResourceURL
        }

        return Bundle.module.url(forResource: "model-catalog-snapshot", withExtension: "json")
    }

    private static func snapshot(
        from data: Data,
        fetchedAt: Date,
        decoder: JSONDecoder
    ) throws -> ModelCatalogSnapshot {
        let catalog = try decoder.decode([String: ModelsDevProvider].self, from: data)
        var providerModels: [String: [String]] = [:]

        for (appProviderID, modelsDevProviderID) in providerMapping {
            guard let provider = catalog[modelsDevProviderID] else {
                continue
            }

            let modelIDs = provider.models.values
                .filter(\.supportsTextOutput)
                .sorted()
                .prefix(Self.maxModelsPerProvider)
                .map(\.id)

            if !modelIDs.isEmpty {
                providerModels[appProviderID] = Array(modelIDs)
            }
        }

        return ModelCatalogSnapshot(fetchedAt: fetchedAt, providerModels: providerModels)
    }

    private static let providerMapping: [String: String] = [
        "openai": "openai",
        "anthropic": "anthropic",
        "gemini": "google",
        "deepseek": "deepseek",
        "qwen": "alibaba",
        "moonshot": "moonshotai",
        "xai": "xai",
        "groq": "groq",
        "mistral": "mistral",
        "openrouter": "openrouter",
        "perplexity": "perplexity",
        "together": "togetherai",
        "cerebras": "cerebras",
        "zhipu": "zhipuai",
        "minimax": "minimax",
        "siliconflow": "siliconflow"
    ]
}

private struct ModelsDevProvider: Decodable {
    var models: [String: ModelsDevModel]
}

private struct ModelsDevModel: Decodable, Comparable {
    var id: String
    var lastUpdated: String?
    var releaseDate: String?
    var modalities: ModelsDevModalities?

    var supportsTextOutput: Bool {
        guard let modalities else {
            return false
        }

        return modalities.input.contains("text") && modalities.output.contains("text")
    }

    static func < (lhs: ModelsDevModel, rhs: ModelsDevModel) -> Bool {
        let lhsDate = lhs.lastUpdated ?? lhs.releaseDate ?? ""
        let rhsDate = rhs.lastUpdated ?? rhs.releaseDate ?? ""

        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        return lhs.id < rhs.id
    }

    static func == (lhs: ModelsDevModel, rhs: ModelsDevModel) -> Bool {
        lhs.id == rhs.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case lastUpdated = "last_updated"
        case releaseDate = "release_date"
        case modalities
    }
}

private struct ModelsDevModalities: Decodable {
    var input: [String]
    var output: [String]
}
