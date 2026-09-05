import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct GoogleOAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String?
}

enum GoogleOAuthError: LocalizedError {
    case invalidAuthorizationURL
    case invalidCallback
    case denied(String)
    case missingAuthorizationCode
    case tokenExchangeFailed(String)
    case missingAccessToken
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            return "Google authorization URL could not be created."
        case .invalidCallback:
            return "Google returned an invalid authorization callback."
        case .denied(let message):
            return "Google authorization was denied: \(message)"
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .tokenExchangeFailed(let message):
            return "Google token exchange failed: \(message)"
        case .missingAccessToken:
            return "Google did not return an access token."
        case .couldNotStart:
            return "Google sign-in could not be started."
        }
    }
}

@MainActor
final class GoogleOAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleOAuthService()

    static let clientID = "1098275217535-219lt8dtcmeumkkg3hmutnio2agmiihc.apps.googleusercontent.com"
    static let callbackScheme = "com.googleusercontent.apps.1098275217535-219lt8dtcmeumkkg3hmutnio2agmiihc"

    private var authenticationSession: ASWebAuthenticationSession?

    func authorize(scopes: [String]) async throws -> GoogleOAuthTokens {
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)
        let redirectURI = "\(Self.callbackScheme):/oauthredirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let authorizationURL = components?.url else {
            throw GoogleOAuthError.invalidAuthorizationURL
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] url, error in
                self?.authenticationSession = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: GoogleOAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: GoogleOAuthError.couldNotStart)
                return
            }
        }

        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleOAuthError.invalidCallback
        }
        let values: [String: String] = Dictionary(uniqueKeysWithValues: callbackComponents.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
        guard values["state"] == state else {
            throw GoogleOAuthError.invalidCallback
        }
        if let error = values["error"] {
            throw GoogleOAuthError.denied(error)
        }
        guard let code = values["code"] else {
            throw GoogleOAuthError.missingAuthorizationCode
        }

        return try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
    }

    func refreshAccessToken(refreshToken: String) async throws -> String {
        let response = try await requestTokens(parameters: [
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw GoogleOAuthError.missingAccessToken
        }
        return accessToken
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> GoogleOAuthTokens {
        let response = try await requestTokens(parameters: [
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ])
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw GoogleOAuthError.missingAccessToken
        }
        return GoogleOAuthTokens(accessToken: accessToken, refreshToken: response.refreshToken)
    }

    private func requestTokens(parameters: [String: String]) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown response"
            throw GoogleOAuthError.tokenExchangeFailed(String(message.prefix(240)))
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}