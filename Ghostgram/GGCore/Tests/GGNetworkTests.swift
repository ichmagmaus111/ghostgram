import CryptoKit
import Foundation
import SwiftSignalKit
import XCTest

final class GGNetworkTests: XCTestCase {
    private let body = Data("{\"masks\":[1,2,3]}".utf8)

    private func request(keys: [Data] = [], maxBytes: Int = 1024, etag: String? = nil) -> GGNetworkRequest {
        return GGNetworkRequest(url: URL(string: "https://example.org/catalog.json")!, etag: etag, signingKeys: keys, maxBytes: maxBytes)
    }

    func testSignatureCheckAcceptsEveryKeyEncoding() throws {
        let privateKey = P256.Signing.PrivateKey()
        let signature = try privateKey.signature(for: self.body).derRepresentation.base64EncodedString()
        let publicKey = privateKey.publicKey
        for keyData in [publicKey.rawRepresentation, publicKey.x963Representation, publicKey.derRepresentation] {
            XCTAssertTrue(GGNetwork.isValidSignature(body: self.body, signatureBase64: signature, keys: [keyData]))
        }
        let otherKey = P256.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertTrue(GGNetwork.isValidSignature(body: self.body, signatureBase64: signature, keys: [otherKey, publicKey.rawRepresentation]), "key rotation: any key may match")
        XCTAssertFalse(GGNetwork.isValidSignature(body: self.body, signatureBase64: signature, keys: [otherKey]))
        XCTAssertFalse(GGNetwork.isValidSignature(body: Data("tampered".utf8), signatureBase64: signature, keys: [publicKey.rawRepresentation]))
        XCTAssertFalse(GGNetwork.isValidSignature(body: self.body, signatureBase64: nil, keys: [publicKey.rawRepresentation]))
        XCTAssertFalse(GGNetwork.isValidSignature(body: self.body, signatureBase64: "not base64!", keys: [publicKey.rawRepresentation]))
    }

    func testValidation() throws {
        let privateKey = P256.Signing.PrivateKey()
        let signature = try privateKey.signature(for: self.body).derRepresentation.base64EncodedString()
        let key = privateKey.publicKey.rawRepresentation

        let signed = GGNetwork.validate(status: 200, body: self.body, headers: ["x-gg-signature": signature, "Etag": "\"v2\""], request: self.request(keys: [key]))
        XCTAssertEqual(try? signed.get().data, self.body)
        XCTAssertEqual(try? signed.get().etag, "\"v2\"")

        let unsigned = GGNetwork.validate(status: 200, body: self.body, headers: [:], request: self.request(keys: [key]))
        XCTAssertEqual(GGNetworkTests.error(unsigned), .badSignature)

        let notModified = GGNetwork.validate(status: 304, body: Data(), headers: [:], request: self.request(etag: "\"v1\""))
        XCTAssertEqual(try? notModified.get().notModified, true)
        XCTAssertEqual(try? notModified.get().etag, "\"v1\"")

        XCTAssertEqual(GGNetworkTests.error(GGNetwork.validate(status: 404, body: Data(), headers: [:], request: self.request())), .http(404))
        XCTAssertEqual(GGNetworkTests.error(GGNetwork.validate(status: 200, body: self.body, headers: [:], request: self.request(maxBytes: 4))), .tooLarge)
    }

    func testSignatureContextAndHeader() throws {
        let privateKey = P256.Signing.PrivateKey()
        let key = privateKey.publicKey.rawRepresentation
        let context = Data("GCONNECT-TG-BADGES/1\n".utf8)
        var signedMessage = context
        signedMessage.append(self.body)
        let signature = try privateKey.signature(for: signedMessage).derRepresentation.base64EncodedString()
        let bodyOnlySignature = try privateKey.signature(for: self.body).derRepresentation.base64EncodedString()

        // Defaults keep the old contract: `X-GG-Signature` over the body alone.
        let defaults = self.request(keys: [key])
        XCTAssertEqual(defaults.signatureHeader, "X-GG-Signature")
        XCTAssertTrue(defaults.signatureContext.isEmpty)

        var request = self.request(keys: [key])
        request.signatureHeader = "X-GTok-Sig"
        request.signatureContext = context

        let accepted = GGNetwork.validate(status: 200, body: self.body, headers: ["x-gtok-sig": signature], request: request)
        XCTAssertEqual(try? accepted.get().data, self.body, "the response carries the body, not the signed context")

        let sameKeyOtherDomain = GGNetwork.validate(status: 200, body: self.body, headers: ["X-GTok-Sig": bodyOnlySignature], request: request)
        XCTAssertEqual(GGNetworkTests.error(sameKeyOtherDomain), .badSignature, "a body signed without the context is not accepted")

        let defaultHeader = GGNetwork.validate(status: 200, body: self.body, headers: ["X-GG-Signature": signature], request: request)
        XCTAssertEqual(GGNetworkTests.error(defaultHeader), .badSignature, "only the request's own header is read")

        let initialized = GGNetworkRequest(url: URL(string: "https://example.org/badges")!, signingKeys: [key], signatureHeader: "X-GTok-Sig", signatureContext: context)
        let viaInit = GGNetwork.validate(status: 200, body: self.body, headers: ["X-GTok-Sig": signature], request: initialized)
        XCTAssertEqual(try? viaInit.get().data, self.body)
    }

    func testRequestCarriesNothingAboutTheUser() {
        let urlRequest = GGNetwork.makeURLRequest(self.request(etag: "\"v1\""))
        XCTAssertFalse(urlRequest.httpShouldHandleCookies)
        XCTAssertEqual(urlRequest.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "User-Agent"), "Ghostgram")
        XCTAssertEqual(urlRequest.allHTTPHeaderFields?.count, 3)

        let configuration = GGNetwork.makeConfiguration(proxy: nil)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.connectionProxyDictionary)
    }

    func testSocksProxyDictionary() {
        let configuration = GGNetwork.makeConfiguration(proxy: .socks5(host: "127.0.0.1", port: 1080, username: "u", password: "p"))
        let dictionary = configuration.connectionProxyDictionary ?? [:]
        XCTAssertEqual(dictionary["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["SOCKSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary["SOCKSPort"] as? Int, 1080)
        XCTAssertEqual(dictionary[kCFStreamPropertySOCKSUser as String] as? String, "u")
        XCTAssertEqual(dictionary[kCFStreamPropertySOCKSPassword as String] as? String, "p")
    }

    func testOnlyHttpsIsFetched() {
        let network = GGNetwork()
        var received: GGNetworkError?
        let request = GGNetworkRequest(url: URL(string: "http://example.org/a.json")!)
        let disposable = network.fetch(request).start(error: { error in
            received = error
        })
        XCTAssertEqual(received, .network)
        disposable.dispose()
    }

    func testDirectRequestsAreRefusedBehindAnotherProxy() {
        let network = GGNetwork()
        network.proxyProvider = {
            return nil
        }
        network.isDirectConnectionAllowedProvider = {
            return false
        }
        var received: GGNetworkError?
        let disposable = network.fetch(self.request()).start(error: { error in
            received = error
        })
        XCTAssertEqual(received, .network)
        disposable.dispose()
    }

    private static func error(_ result: Result<GGNetworkResponse, GGNetworkError>) -> GGNetworkError? {
        switch result {
        case .success:
            return nil
        case let .failure(error):
            return error
        }
    }
}
