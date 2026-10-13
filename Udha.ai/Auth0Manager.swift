//
//  Auth0Manager.swift
//  Udha
//
//  Created by Claude
//

import Foundation
import Combine
import AuthenticationServices

class Auth0Manager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var userEmail: String?
    @Published var userId: String?
    @Published var error: String?

    // Auth0 Configuration — set in Udha.xcconfig / Local.xcconfig.
    private let domain = AppConfig.auth0Domain
    private let clientId = AppConfig.auth0ClientID
    private let audience = AppConfig.auth0Audience
    private let callbackScheme = Bundle.main.bundleIdentifier ?? "udha"
    private var redirectUri: String { "\(callbackScheme)://callback" }

    init() {
        checkExistingAuth()
    }

    // Check for existing valid credentials on app launch
    func checkExistingAuth() {
        guard let credentials = SecureStorage.getAuth0Credentials() else {
            isAuthenticated = false
            return
        }

        // Check if token is expired
        if Date() >= credentials.expiresAt {
            // Token expired, try to refresh
            if let refreshToken = credentials.refreshToken {
                Task {
                    await refreshAccessToken(refreshToken)
                }
            } else {
                isAuthenticated = false
            }
        } else {
            // Token is valid
            isAuthenticated = true
            userEmail = credentials.email
            userId = credentials.userId

            // If email is missing, fetch from userinfo endpoint
            if userEmail == nil {
                Task {
                    await fetchUserInfo(accessToken: credentials.accessToken)
                }
            }
        }
    }

    // Fetch user info from Auth0 userinfo endpoint
    private func fetchUserInfo(accessToken: String) async {
        let userinfoUrl = URL(string: "https://\(domain)/userinfo")!

        var request = URLRequest(url: userinfoUrl)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            let email = json["email"] as? String
            let sub = json["sub"] as? String

            // Update stored credentials with user info
            if email != nil || sub != nil {
                if let credentials = SecureStorage.getAuth0Credentials() {
                    let updatedCredentials = Auth0Credentials(
                        accessToken: credentials.accessToken,
                        refreshToken: credentials.refreshToken,
                        expiresAt: credentials.expiresAt,
                        userId: sub ?? credentials.userId,
                        email: email ?? credentials.email
                    )
                    SecureStorage.saveAuth0Credentials(updatedCredentials)

                    await MainActor.run {
                        self.userEmail = email
                        self.userId = sub ?? self.userId
                    }
                }
            }
        } catch {
            print("Failed to fetch user info: \(error)")
        }
    }

    // Get valid access token (refreshing if needed)
    func getValidToken() async -> String? {
        guard let credentials = SecureStorage.getAuth0Credentials() else {
            return nil
        }

        // Check if token is expired or expiring soon (within 5 minutes)
        let bufferTime: TimeInterval = 5 * 60
        if Date().addingTimeInterval(bufferTime) >= credentials.expiresAt {
            // Token expired or expiring soon, refresh it
            if let refreshToken = credentials.refreshToken {
                return await refreshAccessToken(refreshToken)
            }
            return nil
        }

        return credentials.accessToken
    }

    // Refresh access token
    @discardableResult
    private func refreshAccessToken(_ refreshToken: String) async -> String? {
        let tokenUrl = URL(string: "https://\(domain)/oauth/token")!

        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                // ONLY force sign-out on `invalid_grant` (refresh token
                // genuinely invalid). Transient failures (5xx, network blip,
                // rate limit) must leave the user signed in and let the next
                // call retry. Otherwise a single bad refresh logs them out.
                let body = String(data: data, encoding: .utf8) ?? ""
                let isInvalidGrant = body.contains("invalid_grant")
                if isInvalidGrant {
                    await MainActor.run {
                        self.isAuthenticated = false
                    }
                }
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Int else {
                return nil
            }

            let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

            // Decode JWT to get user info
            let userInfo = decodeJWT(accessToken)

            let credentials = Auth0Credentials(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                expiresAt: expiresAt,
                userId: userInfo.userId ?? self.userId,
                email: userInfo.email ?? self.userEmail
            )

            SecureStorage.saveAuth0Credentials(credentials)

            await MainActor.run {
                self.isAuthenticated = true
                self.userId = credentials.userId
                self.userEmail = credentials.email
            }

            return accessToken
        } catch {
            print("Token refresh failed: \(error)")
            await MainActor.run {
                self.isAuthenticated = false
            }
            return nil
        }
    }

    // Login with Auth0 Universal Login
    @MainActor
    func login() async {
        await authenticate(screenHint: nil)
    }

    // Signup with Auth0 Universal Login
    @MainActor
    func signup() async {
        await authenticate(screenHint: "signup")
    }

    // Shared authentication flow
    @MainActor
    private func authenticate(screenHint: String?) async {
        guard AppConfig.isRelayConfigured else {
            error = "No relay configured. Set UDHA_RELAY_HOST, UDHA_AUTH0_DOMAIN and UDHA_AUTH0_CLIENT_ID in Local.xcconfig and rebuild."
            return
        }
        isLoading = true
        error = nil

        // Generate PKCE code verifier and challenge
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = generateState()

        // Build authorization URL
        var components = URLComponents(string: "https://\(domain)/authorize")!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "audience", value: audience),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]

        // Add screen_hint for signup
        if let screenHint = screenHint {
            queryItems.append(URLQueryItem(name: "screen_hint", value: screenHint))
        }

        components.queryItems = queryItems

        guard let authURL = components.url else {
            isLoading = false
            error = "Failed to build auth URL"
            return
        }

        // Use ASWebAuthenticationSession for the OAuth flow
        do {
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL = callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: AuthError.unknownError)
                    }
                }

                session.presentationContextProvider = WebAuthContextProvider.shared
                session.prefersEphemeralWebBrowserSession = true

                if !session.start() {
                    continuation.resume(throwing: AuthError.sessionStartFailed)
                }
            }

            // Parse the callback URL
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
                  returnedState == state else {
                isLoading = false
                error = "Invalid callback"
                return
            }

            // Exchange code for tokens
            let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)

            // Decode ID token to get user info (email is in ID token, not access token)
            let userInfo: (userId: String?, email: String?)
            if let idToken = tokens.idToken {
                userInfo = decodeJWT(idToken)
            } else {
                // Fallback to access token if no ID token
                userInfo = decodeJWT(tokens.accessToken)
            }

            let credentials = Auth0Credentials(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresAt,
                userId: userInfo.userId,
                email: userInfo.email
            )

            SecureStorage.saveAuth0Credentials(credentials)

            isAuthenticated = true
            userId = credentials.userId
            userEmail = credentials.email
            isLoading = false

        } catch let authError as ASWebAuthenticationSessionError {
            isLoading = false
            if authError.code == .canceledLogin {
                error = "Login cancelled"
            } else {
                error = authError.localizedDescription
            }
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    // Exchange authorization code for tokens
    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> TokenResponse {
        let tokenUrl = URL(string: "https://\(domain)/oauth/token")!

        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectUri,
            "code_verifier": codeVerifier
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.tokenExchangeFailed(errorMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw AuthError.invalidTokenResponse
        }

        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        return TokenResponse(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken, expiresAt: expiresAt)
    }

    // Logout
    @MainActor
    func logout() {
        SecureStorage.clearAuth0Credentials()
        isAuthenticated = false
        userEmail = nil
        userId = nil
        error = nil
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateState() -> String {
        var buffer = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // Decode JWT to extract user info
    private func decodeJWT(_ jwt: String) -> (userId: String?, email: String?) {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count >= 2 else { return (nil, nil) }

        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad with = to make it valid base64
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        let userId = json["sub"] as? String
        let email = json["email"] as? String ?? json["\(audience)/email"] as? String

        return (userId, email)
    }
}

// MARK: - Supporting Types

struct TokenResponse {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
}

enum AuthError: LocalizedError {
    case unknownError
    case sessionStartFailed
    case tokenExchangeFailed(String)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .unknownError:
            return "An unknown error occurred"
        case .sessionStartFailed:
            return "Failed to start authentication session"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .invalidTokenResponse:
            return "Invalid token response"
        }
    }
}

// Presentation context provider for ASWebAuthenticationSession
class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// Import CommonCrypto for SHA256
import CommonCrypto
