import Foundation
import Security

public enum KeychainStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

public protocol KeychainClient {
    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SecurityKeychainClient: KeychainClient {
    public init() {}

    public func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }

    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func add(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(query as CFDictionary, result)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainStore {
    public static let defaultService = "Inklet.OpenAI"
    public static let defaultAccount = "apiKey"

    private let service: String
    private let account: String
    private let client: KeychainClient

    public init(
        service: String = KeychainStore.defaultService,
        account: String = KeychainStore.defaultAccount,
        client: KeychainClient = SecurityKeychainClient()
    ) {
        self.service = service
        self.account = account
        self.client = client
    }

    public func saveAPIKey(_ apiKey: String) throws {
        let query = baseQuery()
        let attributes = [kSecValueData as String: Data(apiKey.utf8)]

        let updateStatus = client.update(query, attributes: attributes)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = Data(apiKey.utf8)

        let status = client.add(addQuery, result: nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func insertAPIKeyIfAbsent(_ apiKey: String) throws -> Bool {
        var query = baseQuery()
        query[kSecValueData as String] = Data(apiKey.utf8)

        let status = client.add(query, result: nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func loadAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = client.copyMatching(query, result: &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        guard let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        return apiKey
    }

    public func deleteAPIKey() throws {
        let status = client.delete(baseQuery())
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
