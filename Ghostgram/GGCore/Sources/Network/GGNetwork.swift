import CryptoKit
import Foundation
import SwiftSignalKit

/// The proxy Ghostgram's own requests go through. Only SOCKS5 can carry a `URLSession` request;
/// MTProxy and WEB proxies can not (see `GGNetwork.isDirectConnectionAllowedProvider`).
public enum GGProxy: Equatable {
    case socks5(host: String, port: Int, username: String?, password: String?)
}

public struct GGNetworkRequest {
    public var url: URL
    /// ETag of the copy the caller already has; a 304 answers `notModified`.
    public var etag: String?
    /// Raw P-256 public keys (64-byte x‖y, 65-byte X9.63 or DER). Empty: no signature check.
    public var signingKeys: [Data]
    public var maxBytes: Int
    /// Response header that carries the signature (default `X-GG-Signature`).
    public var signatureHeader: String
    /// Bytes signed in front of the body (a domain-separation context, so a list signed by the
    /// same key for another purpose is not accepted here). Empty: the body alone is signed.
    public var signatureContext: Data

    public init(url: URL, etag: String? = nil, signingKeys: [Data] = [], maxBytes: Int = 8 * 1024 * 1024, signatureHeader: String = GGNetwork.signatureHeader, signatureContext: Data = Data()) {
        self.url = url
        self.etag = etag
        self.signingKeys = signingKeys
        self.maxBytes = maxBytes
        self.signatureHeader = signatureHeader
        self.signatureContext = signatureContext
    }
}

public struct GGNetworkResponse {
    public let data: Data?
    public let etag: String?
    public let notModified: Bool

    public init(data: Data?, etag: String?, notModified: Bool) {
        self.data = data
        self.etag = etag
        self.notModified = notModified
    }
}

public enum GGNetworkError: Error, Equatable {
    case network
    case http(Int)
    case tooLarge
    case badSignature
    case cancelled
}

/// The one HTTP client for Ghostgram's own catalogs (masks, badges, …).
///
/// - Ephemeral `URLSession`: no cookies, no cache, no credential storage; a fixed user agent.
/// - Only `https`, redirects only to `https`.
/// - The user's SOCKS5 proxy from Telegram's settings (set by the TelegramCore bridge). While the
///   user has an MTProxy or WEB proxy on, direct requests are refused: they would leave outside the
///   proxy the user chose.
/// - Body signature: base64 DER ECDSA P-256 / SHA-256 over `signatureContext ‖ body`, in the
///   response header `signatureHeader` (defaults: `X-GG-Signature`, no context — the body alone).
/// - Nothing about the user goes into a request: no ids, no device data, no telemetry. Callers
///   must not put ids into URLs either.
public final class GGNetwork {
    public static let shared = GGNetwork()

    /// The default signature header of `GGNetworkRequest`.
    public static let signatureHeader = "X-GG-Signature"
    static let userAgent = "Ghostgram"
    static let timeout: Double = 30.0

    private let lock = GGUnfairLock()
    private var currentProxyProvider: (() -> GGProxy?)?
    private var currentDirectProvider: (() -> Bool)?
    private var sessionBox: GGNetworkSessionBox?

    init() {
    }

    /// Set by the TelegramCore bridge from the active `ProxySettings` (SOCKS5 only).
    public var proxyProvider: (() -> GGProxy?)? {
        get {
            return self.lock.withLock {
                return self.currentProxyProvider
            }
        }
        set {
            self.lock.withLock {
                self.currentProxyProvider = newValue
            }
        }
    }

    /// Set by the TelegramCore bridge: false while a proxy that can not carry HTTP (MTProxy, WEB)
    /// is on. Unset means direct connections are allowed.
    public var isDirectConnectionAllowedProvider: (() -> Bool)? {
        get {
            return self.lock.withLock {
                return self.currentDirectProvider
            }
        }
        set {
            self.lock.withLock {
                self.currentDirectProvider = newValue
            }
        }
    }

    public func fetch(_ request: GGNetworkRequest) -> Signal<GGNetworkResponse, GGNetworkError> {
        return Signal { [weak self] subscriber in
            guard let strongSelf = self else {
                subscriber.putError(.cancelled)
                return EmptyDisposable
            }
            guard request.url.scheme?.lowercased() == "https" else {
                GGLog.warning("network", "only https requests are allowed")
                subscriber.putError(.network)
                return EmptyDisposable
            }
            let proxy = strongSelf.proxyProvider?()
            if proxy == nil, let isDirectAllowed = strongSelf.isDirectConnectionAllowedProvider, !isDirectAllowed() {
                GGLog.info("network", "request skipped: the active proxy can not carry it")
                subscriber.putError(.network)
                return EmptyDisposable
            }
            let box = strongSelf.session(for: proxy)
            let task = box.session.dataTask(with: GGNetwork.makeURLRequest(request))
            box.delegate.track(task: task, request: request, completion: { result in
                switch result {
                case let .success(response):
                    subscriber.putNext(response)
                    subscriber.putCompletion()
                case let .failure(error):
                    subscriber.putError(error)
                }
            })
            task.resume()
            let delegate = box.delegate
            return ActionDisposable {
                delegate.forget(task: task)
                task.cancel()
            }
        }
    }

    // MARK: - Internal

    static func makeURLRequest(_ request: GGNetworkRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: GGNetwork.timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(GGNetwork.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        if let etag = request.etag, !etag.isEmpty {
            urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return urlRequest
    }

    static func makeConfiguration(proxy: GGProxy?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = GGNetwork.timeout
        configuration.timeoutIntervalForResource = GGNetwork.timeout * 4.0
        configuration.httpAdditionalHeaders = [:]
        if let proxy = proxy {
            configuration.connectionProxyDictionary = GGNetwork.proxyDictionary(proxy)
        }
        return configuration
    }

    /// `URLSession` SOCKS keys. The `kCFNetworkProxiesSOCKS*` constants are macOS only; their
    /// string values are what iOS reads too.
    static func proxyDictionary(_ proxy: GGProxy) -> [AnyHashable: Any] {
        switch proxy {
        case let .socks5(host, port, username, password):
            var dictionary: [AnyHashable: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5 as String
            ]
            if let username = username, !username.isEmpty {
                dictionary[kCFStreamPropertySOCKSUser as String] = username
            }
            if let password = password, !password.isEmpty {
                dictionary[kCFStreamPropertySOCKSPassword as String] = password
            }
            return dictionary
        }
    }

    static func publicKey(from data: Data) -> P256.Signing.PublicKey? {
        if let key = try? P256.Signing.PublicKey(rawRepresentation: data) {
            return key
        }
        if let key = try? P256.Signing.PublicKey(x963Representation: data) {
            return key
        }
        if let key = try? P256.Signing.PublicKey(derRepresentation: data) {
            return key
        }
        return nil
    }

    /// True when `signatureBase64` is a valid signature of `body` by any of `keys`.
    static func isValidSignature(body: Data, signatureBase64: String?, keys: [Data]) -> Bool {
        guard let signatureBase64 = signatureBase64, let signatureData = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            return false
        }
        for keyData in keys {
            if let key = GGNetwork.publicKey(from: keyData), key.isValidSignature(signature, for: body) {
                return true
            }
        }
        return false
    }

    /// Validates a finished response (status, size, signature).
    static func validate(status: Int, body: Data, headers: [AnyHashable: Any], request: GGNetworkRequest) -> Result<GGNetworkResponse, GGNetworkError> {
        let etag = GGNetwork.headerValue("ETag", in: headers)
        if status == 304 {
            return .success(GGNetworkResponse(data: nil, etag: etag ?? request.etag, notModified: true))
        }
        guard (200 ..< 300).contains(status) else {
            return .failure(.http(status))
        }
        if body.count > request.maxBytes {
            return .failure(.tooLarge)
        }
        if !request.signingKeys.isEmpty {
            let signature = GGNetwork.headerValue(request.signatureHeader, in: headers)
            var signed = request.signatureContext
            signed.append(body)
            if !GGNetwork.isValidSignature(body: signed, signatureBase64: signature, keys: request.signingKeys) {
                return .failure(.badSignature)
            }
        }
        return .success(GGNetworkResponse(data: body, etag: etag, notModified: false))
    }

    static func headerValue(_ name: String, in headers: [AnyHashable: Any]) -> String? {
        let lowercasedName = name.lowercased()
        for (key, value) in headers {
            if let key = key as? String, key.lowercased() == lowercasedName {
                return value as? String
            }
        }
        return nil
    }

    private func session(for proxy: GGProxy?) -> GGNetworkSessionBox {
        return self.lock.withLock { () -> GGNetworkSessionBox in
            if let box = self.sessionBox, box.proxy == proxy {
                return box
            }
            self.sessionBox?.session.finishTasksAndInvalidate()
            let box = GGNetworkSessionBox(proxy: proxy)
            self.sessionBox = box
            return box
        }
    }
}

private final class GGNetworkSessionBox {
    let proxy: GGProxy?
    let delegate: GGNetworkSessionDelegate
    let session: URLSession

    init(proxy: GGProxy?) {
        self.proxy = proxy
        self.delegate = GGNetworkSessionDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "org.ghostgram.network"
        self.session = URLSession(configuration: GGNetwork.makeConfiguration(proxy: proxy), delegate: self.delegate, delegateQueue: queue)
    }
}

private final class GGNetworkTaskContext {
    let request: GGNetworkRequest
    let completion: (Result<GGNetworkResponse, GGNetworkError>) -> Void
    var body = Data()

    init(request: GGNetworkRequest, completion: @escaping (Result<GGNetworkResponse, GGNetworkError>) -> Void) {
        self.request = request
        self.completion = completion
    }
}

private final class GGNetworkSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = GGUnfairLock()
    private var contexts: [Int: GGNetworkTaskContext] = [:]

    func track(task: URLSessionTask, request: GGNetworkRequest, completion: @escaping (Result<GGNetworkResponse, GGNetworkError>) -> Void) {
        let context = GGNetworkTaskContext(request: request, completion: completion)
        self.lock.withLock {
            self.contexts[task.taskIdentifier] = context
        }
    }

    /// The subscriber went away: no more events for this task.
    func forget(task: URLSessionTask) {
        self.lock.withLock {
            self.contexts[task.taskIdentifier] = nil
        }
    }

    private func context(for task: URLSessionTask) -> GGNetworkTaskContext? {
        return self.lock.withLock {
            return self.contexts[task.taskIdentifier]
        }
    }

    private func take(_ task: URLSessionTask) -> GGNetworkTaskContext? {
        return self.lock.withLock {
            return self.contexts.removeValue(forKey: task.taskIdentifier)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = self.context(for: dataTask) else {
            return
        }
        var expectedLength: Int64 = -1
        if let response = dataTask.response {
            expectedLength = response.expectedContentLength
        }
        if expectedLength > Int64(context.request.maxBytes) || context.body.count + data.count > context.request.maxBytes {
            if let context = self.take(dataTask) {
                context.completion(.failure(.tooLarge))
            }
            dataTask.cancel()
            return
        }
        context.body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.scheme?.lowercased() == "https" {
            var redirected = request
            redirected.httpShouldHandleCookies = false
            completionHandler(redirected)
        } else {
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = self.take(task) else {
            return
        }
        if let error = error {
            if (error as? URLError)?.code == .cancelled {
                context.completion(.failure(.cancelled))
            } else {
                context.completion(.failure(.network))
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            context.completion(.failure(.network))
            return
        }
        context.completion(GGNetwork.validate(status: response.statusCode, body: context.body, headers: response.allHeaderFields, request: context.request))
    }
}
