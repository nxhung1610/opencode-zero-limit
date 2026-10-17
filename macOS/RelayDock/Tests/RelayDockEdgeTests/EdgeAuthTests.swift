import Foundation
import Testing
@testable import RelayDockEdge

struct EdgeAuthTests {
    private let token = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

    @Test func acceptsBearerTokens() {
        #expect(EdgeAuth.isAuthorized(headers: ["authorization": "Bearer \(token)"], token: token))
        #expect(EdgeAuth.isAuthorized(headers: ["authorization": "bearer \(token)"], token: token))
        #expect(!EdgeAuth.isAuthorized(headers: ["authorization": "Bearer wrong"], token: token))
    }

    @Test func acceptsTheTokenOnEitherSideOfBasicCredentials() throws {
        // Tokens are URL userinfo (`http://<token>:@host:port`); different
        // clients split userinfo differently when encoding Basic auth.
        let asUser = Data("\(token):".utf8).base64EncodedString()
        let asPassword = Data("x:\(token)".utf8).base64EncodedString()
        #expect(EdgeAuth.isAuthorized(headers: ["proxy-authorization": "Basic \(asUser)"], token: token))
        #expect(EdgeAuth.isAuthorized(headers: ["proxy-authorization": "Basic \(asPassword)"], token: token))
        let wrong = Data("user:pass".utf8).base64EncodedString()
        #expect(!EdgeAuth.isAuthorized(headers: ["proxy-authorization": "Basic \(wrong)"], token: token))
    }

    @Test func rejectsMissingAndMalformedHeaders() {
        #expect(!EdgeAuth.isAuthorized(headers: [:], token: token))
        #expect(!EdgeAuth.isAuthorized(headers: ["authorization": token], token: token))
        #expect(!EdgeAuth.isAuthorized(headers: ["proxy-authorization": "Basic !!!not-base64!!!"], token: token))
        #expect(!EdgeAuth.isAuthorized(headers: ["authorization": "Bearer \(token)"], token: ""))
    }

    @Test func constantTimeEqualsHandlesLengthAndByteDifferences() {
        #expect(EdgeAuth.constantTimeEquals("abc", "abc"))
        #expect(!EdgeAuth.constantTimeEquals("abc", "abcd"))
        #expect(!EdgeAuth.constantTimeEquals("abc", "abd"))
        #expect(EdgeAuth.constantTimeEquals("", ""))
    }
}
