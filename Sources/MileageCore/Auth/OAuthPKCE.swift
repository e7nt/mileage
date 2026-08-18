import CryptoKit
import Foundation

/// Proof Key for Code Exchange. Both providers use S256.
public struct PKCE: Sendable, Equatable {
    public let verifier: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncodedString()
    }

    /// Injectable for tests against the RFC 7636 vector.
    public init(verifier: String) {
        self.verifier = verifier
    }

    public var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

public extension Data {
    /// base64url without padding, as required by PKCE.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthError: Error, LocalizedError, Equatable {
    case cancelled
    case stateMismatch
    case portUnavailable(UInt16)
    case timedOut
    case server(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign-in cancelled"
        case .stateMismatch:
            "Sign-in could not be verified — start again"
        case let .portUnavailable(port):
            "Port \(port) is busy. Quit any running `codex login` and try again."
        case .timedOut:
            "Sign-in timed out"
        case let .server(message):
            message
        case .malformedResponse:
            "The provider returned an unexpected response"
        }
    }
}

/// Shared token-endpoint plumbing. Claude wants JSON, OpenAI wants form encoding, so the body
/// is built by the caller.
enum TokenEndpoint {
    struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let id_token: String?
    }

    static func post(
        url: URL,
        body: Data,
        contentType: String,
        http: HTTPFetching
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await http.send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw OAuthError.server(errorMessage(from: data, status: response.statusCode))
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OAuthError.malformedResponse
        }
        return decoded
    }

    /// OAuth errors arrive in several shapes; surface something a human can act on.
    private static func errorMessage(from data: Data, status: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Sign-in failed (HTTP \(status))"
        }
        if let description = json["error_description"] as? String { return description }
        if let error = json["error"] as? String { return error }
        if let nested = json["error"] as? [String: Any], let message = nested["message"] as? String {
            return message
        }
        return "Sign-in failed (HTTP \(status))"
    }

    static func formEncoded(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}
