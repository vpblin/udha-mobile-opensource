//
//  SecureStorage.swift
//  Udha
//
//  Created by Claude
//

import Foundation
import Security

// Auth0 credentials model
struct Auth0Credentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let userId: String?
    let email: String?
}

class SecureStorage {
    private static let service = "com.appmaker.claudeterminal"
    private static let tokenKey = "relay_token"
    private static let sessionIdKey = "session_id"

    // Auth0 keys
    private static let auth0AccessTokenKey = "auth0_access_token"
    private static let auth0RefreshTokenKey = "auth0_refresh_token"
    private static let auth0ExpiresAtKey = "auth0_expires_at"
    private static let auth0UserIdKey = "auth0_user_id"
    private static let auth0EmailKey = "auth0_email"

    // Multi-instance keys
    private static let activeInstanceIdKey = "active_instance_id"
    private static let anthropicKeyKey = "anthropic_api_key"
    private static let pairedInstancesKey = "paired_instances"

    // MARK: - Token Storage

    static func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw SecureStorageError.encodingFailed
        }

        // Delete existing token first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new token
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw SecureStorageError.saveFailed(status)
        }
    }

    static func getToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasToken: Bool {
        return getToken() != nil
    }

    // MARK: - Session ID Storage

    static func saveSessionId(_ sessionId: String) throws {
        guard let data = sessionId.data(using: .utf8) else {
            throw SecureStorageError.encodingFailed
        }

        // Delete existing session ID first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionIdKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new session ID
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionIdKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw SecureStorageError.saveFailed(status)
        }
    }

    static func getSessionId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionIdKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let sessionId = String(data: data, encoding: .utf8) else {
            return nil
        }

        return sessionId
    }

    static func deleteSessionId() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionIdKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Auth0 Credentials Storage

    static func saveAuth0Credentials(_ credentials: Auth0Credentials) {
        // Save access token
        saveKeychainItem(key: auth0AccessTokenKey, value: credentials.accessToken)

        // Save refresh token
        if let refreshToken = credentials.refreshToken {
            saveKeychainItem(key: auth0RefreshTokenKey, value: refreshToken)
        }

        // Save expiration as ISO8601 string
        let formatter = ISO8601DateFormatter()
        saveKeychainItem(key: auth0ExpiresAtKey, value: formatter.string(from: credentials.expiresAt))

        // Save user ID
        if let userId = credentials.userId {
            saveKeychainItem(key: auth0UserIdKey, value: userId)
        }

        // Save email
        if let email = credentials.email {
            saveKeychainItem(key: auth0EmailKey, value: email)
        }
    }

    static func getAuth0Credentials() -> Auth0Credentials? {
        guard let accessToken = getKeychainItem(key: auth0AccessTokenKey),
              let expiresAtString = getKeychainItem(key: auth0ExpiresAtKey) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        guard let expiresAt = formatter.date(from: expiresAtString) else {
            return nil
        }

        let refreshToken = getKeychainItem(key: auth0RefreshTokenKey)
        let userId = getKeychainItem(key: auth0UserIdKey)
        let email = getKeychainItem(key: auth0EmailKey)

        return Auth0Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            userId: userId,
            email: email
        )
    }

    static func clearAuth0Credentials() {
        deleteKeychainItem(key: auth0AccessTokenKey)
        deleteKeychainItem(key: auth0RefreshTokenKey)
        deleteKeychainItem(key: auth0ExpiresAtKey)
        deleteKeychainItem(key: auth0UserIdKey)
        deleteKeychainItem(key: auth0EmailKey)
    }

    static var hasAuth0Credentials: Bool {
        return getAuth0Credentials() != nil
    }

    // MARK: - Active Instance ID Storage

    static func saveActiveInstanceId(_ instanceId: String) {
        saveKeychainItem(key: activeInstanceIdKey, value: instanceId)
    }

    static func getActiveInstanceId() -> String? {
        return getKeychainItem(key: activeInstanceIdKey)
    }

    static func deleteActiveInstanceId() {
        deleteKeychainItem(key: activeInstanceIdKey)
    }

    // MARK: - Anthropic API Key

    /// The user's own Anthropic key, used only when the Mac is unreachable —
    /// the Mac summarises with its own key when it is there. Keychain rather
    /// than UserDefaults because it is a credential, and never sent over the
    /// relay.

    static func saveAnthropicKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteKeychainItem(key: anthropicKeyKey)
        } else {
            saveKeychainItem(key: anthropicKeyKey, value: trimmed)
        }
    }

    static func getAnthropicKey() -> String? {
        guard let key = getKeychainItem(key: anthropicKeyKey), !key.isEmpty else { return nil }
        return key
    }

    static func deleteAnthropicKey() {
        deleteKeychainItem(key: anthropicKeyKey)
    }

    // MARK: - Paired Instances Storage

    static func savePairedInstances(_ instances: [BridgeInstance]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(instances)
            if let jsonString = String(data: data, encoding: .utf8) {
                saveKeychainItem(key: pairedInstancesKey, value: jsonString)
            }
        } catch {
            print("Failed to encode paired instances: \(error)")
        }
    }

    static func getPairedInstances() -> [BridgeInstance] {
        guard let jsonString = getKeychainItem(key: pairedInstancesKey),
              let data = jsonString.data(using: .utf8) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([BridgeInstance].self, from: data)
        } catch {
            print("Failed to decode paired instances: \(error)")
            return []
        }
    }

    static func addPairedInstance(_ instance: BridgeInstance) {
        var instances = getPairedInstances()
        // Remove existing with same ID
        instances.removeAll { $0.id == instance.id }
        instances.append(instance)
        savePairedInstances(instances)
    }

    static func removePairedInstance(id: String) {
        var instances = getPairedInstances()
        instances.removeAll { $0.id == id }
        savePairedInstances(instances)
    }

    static func clearPairedInstances() {
        deleteKeychainItem(key: pairedInstancesKey)
    }

    // MARK: - Generic Keychain Helpers

    private static func saveKeychainItem(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private static func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum SecureStorageError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode token"
        case .saveFailed(let status):
            return "Failed to save token (status: \(status))"
        }
    }
}
