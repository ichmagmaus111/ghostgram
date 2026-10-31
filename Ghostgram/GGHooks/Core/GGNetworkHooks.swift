// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// Network points: initConnection parameters (device spoofing), upload / download part
// tuning, whether the configured proxy is used right now (VPN).

import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
import GGCore

/// The `initConnection` fields a feature may change. nil = keep upstream's value.
public struct GGInitConnectionParameters: Equatable {
    public var deviceModel: String?
    public var appVersion: String?
    public var langPack: String?
    public var langPackCode: String?
    /// Not applied yet: `MTApiEnvironment` has no override for these (MtProtoKit change,
    /// see HOOKS.md → requests). Kept so features declare the whole set once.
    public var systemVersion: String?
    public var systemLangCode: String?

    public init(deviceModel: String? = nil, appVersion: String? = nil, langPack: String? = nil, langPackCode: String? = nil, systemVersion: String? = nil, systemLangCode: String? = nil) {
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.langPack = langPack
        self.langPackCode = langPackCode
        self.systemVersion = systemVersion
        self.systemLangCode = systemLangCode
    }
}

public struct GGInitConnectionContext {
    /// nil while signing in (no account record yet is never the case for `initializedNetwork`,
    /// but the account may be unauthorized).
    public let accountId: AccountRecordId
    public let isSupplementary: Bool
    public let isTestingEnvironment: Bool
    /// The values upstream is about to send.
    public let current: GGInitConnectionParameters
}

public struct GGUploadParameters: Equatable {
    public var useLargerParts: Bool
    public var increaseParallelParts: Bool
    public let hintFileSize: Int64?
    public let isEncrypted: Bool
}

public struct GGDownloadParameters: Equatable {
    public var partSize: Int64
    public var pendingParts: Int
    public let fileSize: Int64?
}

public enum GGNetworkHooks {
    /// Transformer of the initConnection fields when an account's network starts (app,
    /// notification service, share). Applied once per network; a change applies on the next start.
    public static let initConnection = GGHookPoint<(inout GGInitConnectionParameters, GGInitConnectionContext) -> Void>("network.initConnection")

    /// Transformer of upload part parameters (`multipartUpload`).
    public static let uploadParameters = GGHookPoint<(inout GGUploadParameters) -> Void>("network.uploadParameters")

    /// Transformer of download part size / parallelism for large files (FetchV2, MultipartFetch).
    /// The server requires part sizes divisible by 4 KB that divide 1 MB.
    public static let downloadParameters = GGHookPoint<(inout GGDownloadParameters) -> Void>("network.downloadParameters")

    /// Policy: `false` = the configured proxy is not used right now (e.g. "do not use the proxy
    /// while a VPN is up"). Asked by `ProxySettings.effectiveActiveServer`, so every consumer
    /// (MTProto, calls, GGNetwork, the UI) sees the same answer. Must be a cheap snapshot read.
    public static let useProxy = GGHookPoint<(ProxyServerSettings) -> Bool?>("network.useProxy")

    /// Features call this when an answer of `useProxy` may have changed (VPN went up / down):
    /// accounts re-read the proxy settings.
    public static func proxyPolicyDidChange() {
        let _ = ggProxyPolicyRevision.modify { $0 &+ 1 }
        ggProxyPolicyRevisionPromise.set(ggProxyPolicyRevision.with { $0 })
    }
}

private let ggProxyPolicyRevision = Atomic<Int>(value: 0)
private let ggProxyPolicyRevisionPromise = ValuePromise<Int>(0, ignoreRepeated: true)

// MARK: - Call-site helpers (TelegramCore internal)

func ggApplyInitConnectionParameters(_ environment: MTApiEnvironment, accountId: AccountRecordId, supplementary: Bool, testingEnvironment: Bool) -> MTApiEnvironment {
    if GGNetworkHooks.initConnection.isEmpty {
        return environment
    }
    let current = GGInitConnectionParameters(deviceModel: environment.deviceModel, appVersion: environment.appVersion, langPack: environment.langPack, langPackCode: environment.langPackCode, systemVersion: environment.systemVersion, systemLangCode: environment.systemLangCode)
    var updated = current
    let context = GGInitConnectionContext(accountId: accountId, isSupplementary: supplementary, isTestingEnvironment: testingEnvironment, current: current)
    for handler in GGNetworkHooks.initConnection.handlers {
        handler(&updated, context)
    }
    if updated == current {
        return environment
    }
    var result = environment
    if updated.deviceModel != current.deviceModel {
        // The device model is fixed at init: rebuild the environment, copying every field the
        // way MTApiEnvironment's own `withUpdated…` methods do.
        let rebuilt = MTApiEnvironment(deviceModelName: updated.deviceModel)
        rebuilt.apiId = environment.apiId
        rebuilt.appVersion = environment.appVersion
        rebuilt.layer = environment.layer
        rebuilt.langPack = environment.langPack
        rebuilt.disableUpdates = environment.disableUpdates
        rebuilt.tcpPayloadPrefix = environment.tcpPayloadPrefix
        rebuilt.datacenterAddressOverrides = environment.datacenterAddressOverrides
        rebuilt.accessHostOverride = environment.accessHostOverride
        result = rebuilt
            .withUpdatedLangPackCode(environment.langPackCode)
            .withUpdatedSocksProxySettings(environment.socksProxySettings)
            .withUpdatedNetworkSettings(environment.networkSettings)
            .withUpdatedSystemCode(environment.systemCode)
    }
    if let appVersion = updated.appVersion, appVersion != current.appVersion {
        result.appVersion = appVersion
    }
    if let langPack = updated.langPack, langPack != current.langPack {
        result.langPack = langPack
    }
    // Copying through withUpdatedLangPackCode recomputes apiInitializationHash after the setters.
    return result.withUpdatedLangPackCode(updated.langPackCode ?? result.langPackCode)
}

func ggUploadParameters(useLargerParts: Bool, increaseParallelParts: Bool, hintFileSize: Int64?, encrypt: Bool) -> (Bool, Bool) {
    if GGNetworkHooks.uploadParameters.isEmpty {
        return (useLargerParts, increaseParallelParts)
    }
    var value = GGUploadParameters(useLargerParts: useLargerParts, increaseParallelParts: increaseParallelParts, hintFileSize: hintFileSize, isEncrypted: encrypt)
    for handler in GGNetworkHooks.uploadParameters.handlers {
        handler(&value)
    }
    return (value.useLargerParts, value.increaseParallelParts)
}

func ggDownloadPartSize(_ partSize: Int64, fileSize: Int64?) -> Int64 {
    if GGNetworkHooks.downloadParameters.isEmpty {
        return partSize
    }
    var value = GGDownloadParameters(partSize: partSize, pendingParts: 0, fileSize: fileSize)
    for handler in GGNetworkHooks.downloadParameters.handlers {
        handler(&value)
    }
    return value.partSize
}

func ggDownloadPendingParts(_ pendingParts: Int, fileSize: Int64?) -> Int {
    if GGNetworkHooks.downloadParameters.isEmpty {
        return pendingParts
    }
    var value = GGDownloadParameters(partSize: 0, pendingParts: pendingParts, fileSize: fileSize)
    for handler in GGNetworkHooks.downloadParameters.handlers {
        handler(&value)
    }
    return max(1, value.pendingParts)
}

func ggShouldUseProxy(_ server: ProxyServerSettings) -> Bool {
    if GGNetworkHooks.useProxy.isEmpty {
        return true
    }
    for handler in GGNetworkHooks.useProxy.handlers {
        if let value = handler(server) {
            return value
        }
    }
    return true
}

/// Re-emits `signal`'s latest value whenever `GGNetworkHooks.proxyPolicyDidChange()` is called.
func ggWithProxyPolicyUpdates<T>(_ signal: Signal<T, NoError>) -> Signal<T, NoError> {
    if GGNetworkHooks.useProxy.isEmpty {
        return signal
    }
    return combineLatest(signal, ggProxyPolicyRevisionPromise.get())
    |> map { value, _ -> T in
        return value
    }
}
