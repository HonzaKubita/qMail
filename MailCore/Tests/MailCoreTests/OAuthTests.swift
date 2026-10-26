import Foundation
import Testing
@testable import MailCore

/// Answers requests to the token endpoint with a canned JSON body.
final class TokenEndpointStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var lastRequestBody = ""

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "oauth2.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastRequestBody = String(decoding: data, as: UTF8.self)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct OAuthTests {
    let config = OAuthConfiguration.google(clientID: "123-abc.apps.googleusercontent.com")

    @Test func googleConfiguration() {
        #expect(config.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(config.callbackScheme == "com.googleusercontent.apps.123-abc")
        #expect(config.clientSecret == nil)
        #expect(config.scopes.contains("https://mail.google.com/"))
    }

    @Test func authorizationURLCarriesPKCEAndOfflineAccess() throws {
        let pkce = PKCE()
        let url = OAuthClient.authorizationURL(config, pkce: pkce, state: "s1", loginHint: "me@gmail.com")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(items["redirect_uri"] == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["login_hint"] == "me@gmail.com")
        #expect(items["scope"] == "https://mail.google.com/ openid email profile")
        #expect(pkce.verifier.count >= 43 && !pkce.verifier.contains("="))
    }

    @Test func parsesCallback() throws {
        let ok = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=s1&code=4%2F0Abc")!
        #expect(try OAuthClient.authorizationCode(from: ok, expectedState: "s1") == "4/0Abc")
        #expect(throws: MailError.self) {
            try OAuthClient.authorizationCode(from: ok, expectedState: "other")
        }
        let denied = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?error=access_denied&state=s1")!
        #expect(throws: MailError.oauth("access_denied")) {
            try OAuthClient.authorizationCode(from: denied, expectedState: "s1")
        }
    }

    @Test func exchangesCodeAndReadsIdentity() async throws {
        URLProtocol.registerClass(TokenEndpointStub.self)
        defer { URLProtocol.unregisterClass(TokenEndpointStub.self) }
        let claims = #"{"email":"honza@gmail.com","name":"Honza Kubita","email_verified":true}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        TokenEndpointStub.responseBody = Data(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","id_token":"h.\#(payload).sig"}"#.utf8)

        let pkce = PKCE()
        let tokens = try await OAuthClient.exchange(code: "4/0Abc", pkce: pkce, config: config)
        #expect(tokens.accessToken == "ya29.x")
        #expect(tokens.refreshToken == "1//r")
        #expect(tokens.email == "honza@gmail.com")
        #expect(tokens.name == "Honza Kubita")
        #expect(!tokens.needsRefresh)
        #expect(TokenEndpointStub.lastRequestBody.contains("code_verifier=\(pkce.verifier)"))
        #expect(TokenEndpointStub.lastRequestBody.contains("grant_type=authorization_code"))
        #expect(!TokenEndpointStub.lastRequestBody.contains("client_secret"))
    }

    @Test func refreshKeepsRefreshTokenAndMapsInvalidGrant() async throws {
        URLProtocol.registerClass(TokenEndpointStub.self)
        defer { URLProtocol.unregisterClass(TokenEndpointStub.self) }
        let old = OAuthTokens(accessToken: "old", refreshToken: "1//r", expiresAt: .distantPast, email: "honza@gmail.com", name: "Honza")

        TokenEndpointStub.responseBody = Data(#"{"access_token":"new","expires_in":3599}"#.utf8)
        let refreshed = try await OAuthClient.refresh(old, config: config)
        #expect(refreshed.accessToken == "new")
        #expect(refreshed.refreshToken == "1//r")
        #expect(refreshed.email == "honza@gmail.com")

        TokenEndpointStub.responseBody = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        await #expect(throws: MailError.signInRequired) {
            try await OAuthClient.refresh(old, config: config)
        }
    }

    @Test func rejectsSignInWithoutGmailPermission() async throws {
        URLProtocol.registerClass(TokenEndpointStub.self)
        defer { URLProtocol.unregisterClass(TokenEndpointStub.self) }
        // Google's granular consent: the user left the Gmail box unticked.
        TokenEndpointStub.responseBody = Data(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","scope":"openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"}"#.utf8)
        await #expect(throws: MailError.mailAccessNotGranted) {
            try await OAuthClient.exchange(code: "c", pkce: PKCE(), config: config)
        }

        TokenEndpointStub.responseBody = Data(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","scope":"https://mail.google.com/ openid https://www.googleapis.com/auth/userinfo.email"}"#.utf8)
        let tokens = try await OAuthClient.exchange(code: "c", pkce: PKCE(), config: config)
        #expect(tokens.grantedScopes?.contains("https://mail.google.com/") == true)
    }

    @Test func microsoftScopesMatchWithOrWithoutPrefix() async throws {
        let microsoft = OAuthConfiguration.microsoft(clientID: "id", redirectURI: "msauth.x://auth")
        #expect(microsoft.mailScopes.allSatisfy { $0.hasPrefix("https://outlook.office.com/") })
    }

    @Test func decodesXOAuth2Refusal() {
        let json = #"{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}"#
        let detail = IMAPClient.xoauth2ErrorDetail(Data(json.utf8).base64EncodedString())
        #expect(detail == "server says: status 400, requires scope https://mail.google.com/")
        #expect(IMAPClient.xoauth2ErrorDetail("not base64!") == nil)
    }

    @Test func xoauth2Payload() {
        let auth = MailAuth.oauth2(username: "honza@gmail.com", accessToken: "ya29.x")
        let decoded = String(decoding: Data(base64Encoded: auth.xoauth2Payload!)!, as: UTF8.self)
        #expect(decoded == "user=honza@gmail.com\u{01}auth=Bearer ya29.x\u{01}\u{01}")
    }
}
