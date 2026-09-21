import Foundation
import Combine
import Security

struct DoorConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let schoolNumber: String
    let lockNumber: String
    let serviceUUID: String
    let characteristicUUID: String
    let secret: String

    init(
        name: String,
        schoolNumber: String,
        lockNumber: String,
        serviceUUID: String,
        characteristicUUID: String,
        secret: String
    ) {
        self.id = "\(schoolNumber):\(lockNumber)"
        self.name = name
        self.schoolNumber = schoolNumber
        self.lockNumber = lockNumber
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.secret = secret
    }
}

enum DoorConfigurationStorage {
    private static let service = "app.yunmeiunlock.client.door-configuration"
    private static let configurationsAccount = "configurations"
    private static let activeIDAccount = "active-id"

    static func loadConfigurations() -> [DoorConfiguration] {
        guard let data = read(account: configurationsAccount) else { return [] }
        return (try? JSONDecoder().decode([DoorConfiguration].self, from: data)) ?? []
    }

    static func loadActiveConfiguration() -> DoorConfiguration? {
        let configurations = loadConfigurations()
        guard !configurations.isEmpty else { return nil }

        guard let data = read(account: activeIDAccount),
              let activeID = String(data: data, encoding: .utf8) else {
            return configurations.first
        }
        return configurations.first(where: { $0.id == activeID }) ?? configurations.first
    }

    static func save(configurations: [DoorConfiguration], activeID: String) throws {
        let data = try JSONEncoder().encode(configurations)
        try write(data, account: configurationsAccount)
        try write(Data(activeID.utf8), account: activeIDAccount)
    }

    static func setActiveID(_ activeID: String) throws {
        try write(Data(activeID.utf8), account: activeIDAccount)
    }

    static func clear() throws {
        try delete(account: configurationsAccount)
        try delete(account: activeIDAccount)
    }

    private static func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain 错误（\(status)）"
    }
}

@MainActor
final class DoorConfigurationStore: ObservableObject {
    @Published private(set) var configurations: [DoorConfiguration]
    @Published private(set) var activeConfiguration: DoorConfiguration?

    init() {
        configurations = DoorConfigurationStorage.loadConfigurations()
        activeConfiguration = DoorConfigurationStorage.loadActiveConfiguration()
    }

    func replace(with configurations: [DoorConfiguration], activeID: String) throws {
        try DoorConfigurationStorage.save(configurations: configurations, activeID: activeID)
        self.configurations = configurations
        activeConfiguration = configurations.first(where: { $0.id == activeID })
    }

    func select(_ configuration: DoorConfiguration) throws {
        try DoorConfigurationStorage.setActiveID(configuration.id)
        activeConfiguration = configuration
    }

    func clear() throws {
        try DoorConfigurationStorage.clear()
        configurations = []
        activeConfiguration = nil
    }
}
