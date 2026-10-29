import Foundation
import Security

public struct StoredSession: Codable, Sendable {
    let token: String
    let expiresAt: Date
    let email: String
    let userID: Int?
    let endpoints: PanelEndpoints
}

public struct RememberedLogin: Codable, Sendable {
    public let email: String
    public let password: String
    public let site: URL
    public init(email: String, password: String, site: URL) {
        self.email = email; self.password = password; self.site = site
    }
}

@MainActor
public protocol CredentialVault: AnyObject {
    var logoutPending: Bool { get set }
    var endpoints: PanelEndpoints? { get set }
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
    func loadRemembered() throws -> RememberedLogin?
    func saveRemembered(_ login: RememberedLogin) throws
    func clearRemembered() throws
}

@MainActor
public final class KeychainVault: CredentialVault {
    private let service: String
    private let defaults: UserDefaults

    public init(service: String, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    public var deviceID: String {
        let key = "\(service).device-id"
        if let value = defaults.string(forKey: key), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    public var logoutPending: Bool {
        get { defaults.bool(forKey: "\(service).logout-pending") }
        set { defaults.set(newValue, forKey: "\(service).logout-pending") }
    }

    public var endpoints: PanelEndpoints? {
        get {
            guard let data = defaults.data(forKey: "\(service).origins"),
                  let saved = try? JSONDecoder().decode(PanelEndpoints.self, from: data) else { return nil }
            return try? PanelEndpoints(site: saved.site.absoluteString, config: saved.config.absoluteString)
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "\(service).origins") }
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]
    }

    public func load() throws -> StoredSession? { try load("session", as: StoredSession.self) }
    public func save(_ session: StoredSession) throws { try save(session, account: "session") }
    public func clear() throws { try clear("session") }
    public func loadRemembered() throws -> RememberedLogin? { try load("remembered-login", as: RememberedLogin.self) }
    public func saveRemembered(_ login: RememberedLogin) throws { try save(login, account: "remembered-login") }
    public func clearRemembered() throws { try clear("remembered-login") }

    private func load<Value: Decodable>(_ account: String, as type: Value.Type) throws -> Value? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClientError.keychain(status) }
        guard let data = result as? Data else { throw ClientError.invalidResponse }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    private func save<Value: Encodable>(_ value: Value, account: String) throws {
        let query = query(account)
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw ClientError.keychain(status) }
        } else if status != errSecSuccess {
            throw ClientError.keychain(status)
        }
    }

    private func clear(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientError.keychain(status) }
    }
}
