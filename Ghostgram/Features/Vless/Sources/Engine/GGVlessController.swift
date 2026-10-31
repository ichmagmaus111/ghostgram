import Foundation
import Network
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import GGCore
import GGFeaturesShared

// The VPN's state machine. Settings decide what should run (switch, chosen server); this object
// makes the core and Telegram's proxy follow them:
//
// - Everything blocking (dlopen, core start/stop) runs on `queue`, never on the main thread. At a
//   cold start Telegram's proxy already points at the loopback listener saved last time, so MTProto
//   simply cannot connect until the core is up: the route is "not ready" instead of the main thread
//   waiting, and nothing leaves around the tunnel.
// - Telegram's proxy is switched to the loopback entry only after the core is running, and given back
//   (the user's previous proxy state) when the VPN is switched off. Picking another proxy in
//   Telegram's own settings switches the VPN off.
// - Repairs are reactive: when the app returns (throttled by GGForegroundTaskScheduler) and when the
//   network path changes, the tunnel is checked end to end and the core is restarted at most twice in
//   ten minutes. No timers, nothing in the background.

public enum GGVlessStatus: Equatable {
    case off
    /// This build has no core framework.
    case notBundled
    /// Switched on, but no server is chosen.
    case noServer
    case starting
    case running(serverName: String)
    /// Running, but the end-to-end check did not reach Telegram.
    case unreachable(serverName: String)
    case failed(GGVlessFailure)
}

public struct GGVlessTraffic: Equatable {
    public let uplink: Int64
    public let downlink: Int64
}

public enum GGVlessFailure: Equatable {
    case loadFailed
    case configInvalid
    case startFailed
}

public final class GGVlessController {
    public static let shared = GGVlessController()

    let queue = Queue(name: "org.ghostgram.vless", qos: .utility)

    // Queue state.
    private var core: GGXrayCore?
    private var running: (server: GGVlessServer, endpoint: GGVlessTunnelEndpoint)?
    private var restartTimes: [Double] = []
    private var pathMonitor: NWPathMonitor?
    private var pathCheck: Disposable?
    private var pathMonitorSeenFirst = false
    /// The framework is there but could not be opened; shown instead of «off» until a restart.
    private var loadFailed = false

    // Main thread state.
    private var accountManager: AccountManager<TelegramAccountManagerTypes>?
    private var pendingProxyUpdate: Bool?
    private var proxyDisposable: Disposable?
    private var lastObservedLoopbackActive = false
    private var settingsDisposable: Disposable?
    private let connectionDisposable = MetaDisposable()
    /// Queue state: the repair started by Telegram's connection state.
    private let connectionCheckDisposable = MetaDisposable()

    private let statusPromise = ValuePromise<GGVlessStatus>(.off, ignoreRepeated: true)
    private let pingsPromise = ValuePromise<[String: Int]>([:], ignoreRepeated: true)
    private var pings: [String: Int] = [:]
    private let pingDisposable = MetaDisposable()

    private init() {
    }

    public var status: Signal<GGVlessStatus, NoError> {
        return self.statusPromise.get()
    }

    /// Connect times by server id (milliseconds; -1 = no answer).
    public var pingResults: Signal<[String: Int], NoError> {
        return self.pingsPromise.get()
    }

    // MARK: - Setup

    /// Main thread, from `GGVlessModule.register()`.
    func setup() {
        if self.settingsDisposable != nil {
            return
        }
        self.settingsDisposable = (combineLatest(GGVlessSettings.enabled.signal, GGVlessSettings.selectedServer.signal)
        |> deliverOn(self.queue)).start(next: { [weak self] enabled, serverId in
            self?.reconcile(enabled: enabled, serverId: serverId)
        })

        GGForegroundTaskScheduler.shared.register(id: "vless.health", minimumInterval: 5.0 * 60.0, delay: 4.0, task: { [weak self] done in
            guard let self else {
                done()
                return EmptyDisposable
            }
            return self.checkTunnel(allowRestart: true).start(completed: {
                done()
            })
        })
        GGForegroundTaskScheduler.shared.register(id: "vless.subscriptions", minimumInterval: 60.0 * 60.0, delay: 6.0, task: { [weak self] done in
            // Nothing goes to a subscription's panel on its own while the VPN is off or the build has
            // no core to use what it returns: only the user's «Обновить» does then.
            guard let self, GGVlessSettings.enabled.value, GGXrayCore.isBundled else {
                done()
                return EmptyDisposable
            }
            return self.refreshDueSubscriptions().start(completed: {
                done()
            })
        })
    }

    /// Main thread, on every load of the root controllers. Gives the controller Telegram's account
    /// manager (proxy settings live there) and the current account's connection state.
    public func attach(context: AccountContext) {
        self.watchConnection(context.account.network.connectionStatus)
        if self.accountManager != nil {
            return
        }
        let accountManager = context.sharedContext.accountManager
        self.accountManager = accountManager
        self.proxyDisposable = (accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> map { sharedData -> ProxySettings in
            return sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? ProxySettings.defaultSettings
        }
        |> deliverOnMainQueue).start(next: { [weak self] settings in
            self?.proxySettingsChanged(settings)
        })
        if let pending = self.pendingProxyUpdate {
            self.pendingProxyUpdate = nil
            self.applyProxy(enable: pending)
        } else if !GGVlessSettings.enabled.value {
            // A loopback entry left without a running VPN (the old client, a crash) would keep
            // Telegram offline: give the proxy back.
            self.applyProxy(enable: false)
        }
    }

    // MARK: - Core

    private func reconcile(enabled: Bool, serverId: String) {
        assert(self.queue.isCurrent())
        GGVlessStore.shared.loadIfNeeded()
        if !enabled {
            self.stopCore()
            self.updatePathMonitor(active: false)
            if !GGXrayCore.isBundled {
                self.statusPromise.set(.notBundled)
            } else if self.loadFailed {
                self.statusPromise.set(.failed(.loadFailed))
            } else {
                self.statusPromise.set(.off)
            }
            Queue.mainQueue().async {
                self.applyProxy(enable: false)
            }
            return
        }
        if !GGXrayCore.isBundled {
            // Nothing can ever answer on the loopback listener in this build: a loopback entry left
            // from an earlier build would keep Telegram offline for good, so give the proxy back.
            // The switch goes off too — «on» with Telegram going direct would mislead.
            self.statusPromise.set(.notBundled)
            Queue.mainQueue().async {
                self.applyProxy(enable: false)
                GGVlessSettings.enabled.set(false)
            }
            return
        }
        var server: GGVlessServer?
        if let match = GGVlessStore.shared.server(id: serverId) {
            server = match.1
        } else if let running = self.running, running.server.id == serverId {
            // The subscription dropped the server while it runs: keep it until the user picks another.
            server = running.server
        }
        guard let server else {
            self.statusPromise.set(.noServer)
            return
        }
        if let running = self.running, running.server == server, self.core?.isRunning == true {
            return
        }
        self.start(server: server)
    }

    private func start(server: GGVlessServer) {
        assert(self.queue.isCurrent())
        self.statusPromise.set(.starting)
        if self.core == nil {
            do {
                self.core = try GGXrayCore.load()
                GGLog.info("vless", "core loaded")
            } catch {
                // Not transient (a broken or foreign framework): same as an unbundled core.
                GGLog.warning("vless", "core could not be loaded")
                self.loadFailed = true
                self.statusPromise.set(.failed(.loadFailed))
                Queue.mainQueue().async {
                    self.applyProxy(enable: false)
                }
                return
            }
        }
        guard let core = self.core else {
            return
        }
        var credentials = GGXrayInboundCredentials(username: GGVlessSettings.inboundUser.value, password: GGVlessSettings.inboundPassword.value)
        if credentials.username.isEmpty || credentials.password.isEmpty {
            credentials = GGXrayInboundCredentials.random()
            GGVlessSettings.inboundUser.set(credentials.username)
            GGVlessSettings.inboundPassword.set(credentials.password)
        }
        var port = GGNetworkSpoofSharedSettings.vlessLocalPort.value
        if !(1024 ... 65535).contains(port) {
            port = GGVlessController.randomPort()
        }
        core.stop()
        self.running = nil
        for attempt in 0 ..< 4 {
            guard let config = GGXrayConfig.make(server: server, port: port, credentials: credentials) else {
                self.statusPromise.set(.failed(.configInvalid))
                return
            }
            if core.test(config: config) != .ok {
                self.statusPromise.set(.failed(.configInvalid))
                return
            }
            let result = core.start(config: config)
            if result == .ok {
                self.running = (server, GGVlessTunnelEndpoint(port: port, credentials: credentials))
                if GGNetworkSpoofSharedSettings.vlessLocalPort.value != port {
                    GGNetworkSpoofSharedSettings.vlessLocalPort.set(port)
                }
                self.statusPromise.set(.running(serverName: server.name))
                self.updatePathMonitor(active: true)
                Queue.mainQueue().async {
                    self.applyProxy(enable: true)
                }
                return
            }
            if result != .startFailed || attempt == 3 {
                break
            }
            // Most often the loopback port is taken: try another one.
            port = GGVlessController.randomPort()
        }
        self.statusPromise.set(.failed(.startFailed))
    }

    private func stopCore() {
        assert(self.queue.isCurrent())
        if let core = self.core, core.isRunning {
            core.stop()
        }
        self.running = nil
    }

    private static func randomPort() -> Int {
        return Int.random(in: 20000 ... 60999)
    }

    /// The running tunnel, for requests that should go through it.
    func currentTunnel() -> Signal<GGVlessTunnelEndpoint?, NoError> {
        return Signal { subscriber in
            subscriber.putNext(self.running?.endpoint)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(self.queue)
    }

    /// Bytes through the tunnel since the core started. Read every 2 s only while the tunnel runs and
    /// someone listens (the servers screen); an unchanged value is not emitted again, so the screen is
    /// not rebuilt for nothing.
    public func traffic() -> Signal<GGVlessTraffic?, NoError> {
        let once = Signal<GGVlessTraffic?, NoError> { subscriber in
            if let core = self.core, self.running != nil {
                let counters = core.traffic
                subscriber.putNext(GGVlessTraffic(uplink: counters.uplink, downlink: counters.downlink))
            } else {
                subscriber.putNext(nil)
            }
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(self.queue)
        let poll = (once |> then(.complete() |> delay(2.0, queue: self.queue))) |> restart
        return self.status
        |> map { status -> Bool in
            switch status {
            case .running, .unreachable:
                return true
            default:
                return false
            }
        }
        |> distinctUntilChanged
        |> mapToSignal { active -> Signal<GGVlessTraffic?, NoError> in
            return active ? poll : .single(nil)
        }
        |> distinctUntilChanged
    }

    // MARK: - Repairs

    /// Telegram stuck in «Connecting…» for 15 s while the tunnel runs is the third trigger of a check
    /// (after a network change and a return to the app). Event driven: the delay exists only while
    /// Telegram is connecting; the restart budget is shared with the other triggers.
    private func watchConnection(_ connectionStatus: Signal<ConnectionStatus, NoError>) {
        let stuck = connectionStatus
        |> map { status -> Bool in
            if case .connecting = status {
                return true
            }
            return false
        }
        |> distinctUntilChanged
        |> mapToSignal { connecting -> Signal<Void, NoError> in
            if !connecting {
                return .complete()
            }
            return .single(Void()) |> delay(15.0, queue: self.queue)
        }
        self.connectionDisposable.set((stuck |> deliverOn(self.queue)).start(next: { [weak self] _ in
            guard let self, self.running != nil else {
                return
            }
            self.connectionCheckDisposable.set(self.checkTunnel(allowRestart: true).start())
        }))
    }

    private func updatePathMonitor(active: Bool) {
        assert(self.queue.isCurrent())
        if active {
            if self.pathMonitor != nil {
                return
            }
            let monitor = NWPathMonitor()
            self.pathMonitorSeenFirst = false
            monitor.pathUpdateHandler = { [weak self] _ in
                guard let self else {
                    return
                }
                self.queue.async {
                    if !self.pathMonitorSeenFirst {
                        self.pathMonitorSeenFirst = true
                        return
                    }
                    // A burst of path changes becomes one check, after the network settles.
                    self.pathCheck?.dispose()
                    self.pathCheck = (Signal<Void, NoError>.single(Void()) |> delay(3.0, queue: self.queue)
                    |> mapToSignal { _ -> Signal<Never, NoError> in
                        return self.checkTunnel(allowRestart: true)
                    }).start()
                }
            }
            monitor.start(queue: self.queue.queue)
            self.pathMonitor = monitor
        } else {
            self.pathCheck?.dispose()
            self.pathCheck = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
        }
    }

    /// Checks the tunnel end to end; restarts the core once when it is dead (within the budget).
    func checkTunnel(allowRestart: Bool) -> Signal<Never, NoError> {
        return Signal<GGVlessTunnelEndpoint?, NoError> { subscriber in
            subscriber.putNext(self.running?.endpoint)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(self.queue)
        |> mapToSignal { endpoint -> Signal<Never, NoError> in
            guard let endpoint else {
                return .complete()
            }
            return GGVlessTunnelProbe.check(endpoint)
            |> deliverOn(self.queue)
            |> mapToSignal { reachable -> Signal<Never, NoError> in
                guard let running = self.running else {
                    return .complete()
                }
                if reachable {
                    self.statusPromise.set(.running(serverName: running.server.name))
                    return .complete()
                }
                if allowRestart && self.consumeRestartBudget() {
                    GGLog.info("vless", "tunnel check failed, restarting the core")
                    self.start(server: running.server)
                    return self.checkTunnel(allowRestart: false)
                }
                self.statusPromise.set(.unreachable(serverName: running.server.name))
                return .complete()
            }
        }
    }

    private func consumeRestartBudget() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        self.restartTimes = self.restartTimes.filter { now - $0 < 10.0 * 60.0 }
        if self.restartTimes.count >= 2 {
            return false
        }
        self.restartTimes.append(now)
        return true
    }

    // MARK: - Telegram's proxy

    /// The VPN's loopback entry: ours by its user name, or the old client's entry by its port.
    private func isOurs(_ server: ProxyServerSettings?, user: String) -> Bool {
        guard let server, server.host == GGNetworkSpoofShared.loopbackHost else {
            return false
        }
        let legacyPort = GGVlessLegacy.loopbackPort.value
        if legacyPort > 0 && Int(server.port) == legacyPort {
            return true
        }
        if case let .socks5(username, _) = server.connection, !user.isEmpty {
            return username == user
        }
        return false
    }

    /// Main thread.
    private func applyProxy(enable: Bool) {
        guard let accountManager = self.accountManager else {
            self.pendingProxyUpdate = enable
            return
        }
        let user = GGVlessSettings.inboundUser.value
        let password = GGVlessSettings.inboundPassword.value
        let port = GGNetworkSpoofSharedSettings.vlessLocalPort.value
        if enable && (user.isEmpty || !(1 ... 65535).contains(port)) {
            return
        }
        let _ = (accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                return
            }
            let current = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? ProxySettings.defaultSettings
            let currentIsOurs = self.isOurs(current.activeServer, user: user)
            if enable {
                if !currentIsOurs && GGVlessSettings.previousProxy.value == nil {
                    GGVlessSettings.previousProxy.set(GGVlessSavedProxy(enabled: current.enabled, activeServer: current.activeServer))
                }
                let loopback = ProxyServerSettings(host: GGNetworkSpoofShared.loopbackHost, port: Int32(port), connection: .socks5(username: user, password: password))
                if current.enabled && current.activeServer == loopback {
                    return
                }
                let _ = updateProxySettingsInteractively(accountManager: accountManager, { settings in
                    var settings = settings
                    settings.activeServer = loopback
                    settings.enabled = true
                    return settings
                }).start(completed: {
                    if GGVlessLegacy.loopbackPort.value != 0 && GGVlessLegacy.loopbackPort.value != port {
                        GGVlessLegacy.loopbackPort.set(0)
                    }
                })
            } else {
                let previous = GGVlessSettings.previousProxy.value
                if previous != nil {
                    GGVlessSettings.previousProxy.set(nil)
                }
                if !currentIsOurs {
                    // The usual cold start without the VPN: nothing to write.
                    return
                }
                let _ = updateProxySettingsInteractively(accountManager: accountManager, { settings in
                    var settings = settings
                    if let previous {
                        settings.enabled = previous.enabled
                        settings.activeServer = previous.activeServer
                    } else {
                        settings.enabled = false
                        settings.activeServer = nil
                    }
                    return settings
                }).start(completed: {
                    if GGVlessLegacy.loopbackPort.value != 0 {
                        GGVlessLegacy.loopbackPort.set(0)
                    }
                })
            }
        })
    }

    /// Main thread. The user picked another proxy or switched the proxy off in Telegram's settings
    /// while the VPN had it: the VPN follows and switches off.
    private func proxySettingsChanged(_ settings: ProxySettings) {
        let user = GGVlessSettings.inboundUser.value
        let ours = settings.enabled && self.isOurs(settings.activeServer, user: user)
        if self.lastObservedLoopbackActive && !ours && GGVlessSettings.enabled.value {
            if GGVlessSettings.previousProxy.value != nil {
                GGVlessSettings.previousProxy.set(nil)
            }
            GGVlessSettings.enabled.set(false)
        }
        self.lastObservedLoopbackActive = ours
    }

    // MARK: - Subscriptions

    /// Adds a subscription from a URL or from pasted `vless://` links / a config.
    func addSubscription(input: String, name: String) -> Signal<GGVlessSubscription, GGVlessFetchError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return self.currentTunnel()
            |> castError(GGVlessFetchError.self)
            |> mapToSignal { tunnel -> Signal<GGVlessFetchResult, GGVlessFetchError> in
                return GGVlessSubscriptionFetcher.fetch(urlString: trimmed, routes: GGVlessSubscriptionFetcher.routes(tunnel: tunnel, userInitiated: true))
            }
            |> map { result -> GGVlessSubscription in
                var subscription = GGVlessSubscription(id: UUID().uuidString, name: customName.isEmpty ? (result.headers.title ?? URL(string: trimmed)?.host ?? trimmed) : customName, url: trimmed, servers: result.servers)
                subscription.usage = result.headers.usage
                subscription.providerUpdateHours = result.headers.updateHours
                subscription.updatedAt = Date().timeIntervalSince1970
                GGVlessStore.shared.update { subscriptions in
                    subscriptions.append(subscription)
                }
                return subscription
            }
        }
        let parsed = GGVlessSubscriptionParser.parse(text: trimmed)
        if parsed.servers.isEmpty {
            return .fail(.empty)
        }
        var subscription = GGVlessSubscription(id: UUID().uuidString, name: customName, url: nil, servers: parsed.servers)
        subscription.updateInterval = .manual
        subscription.updatedAt = Date().timeIntervalSince1970
        GGVlessStore.shared.update { subscriptions in
            subscriptions.append(subscription)
        }
        return .single(subscription)
    }

    /// Refreshes one subscription. The result is dropped when the subscription was deleted or its URL
    /// changed while the request was running. `userInitiated`: the user asked for it (see
    /// `GGVlessSubscriptionFetcher.routes` for what that allows).
    func refresh(subscriptionId: String, userInitiated: Bool = true) -> Signal<Never, GGVlessFetchError> {
        guard let subscription = GGVlessStore.shared.subscriptions.first(where: { $0.id == subscriptionId }), let url = subscription.url else {
            return .complete()
        }
        return self.currentTunnel()
        |> castError(GGVlessFetchError.self)
        |> mapToSignal { tunnel -> Signal<GGVlessFetchResult, GGVlessFetchError> in
            let routes = GGVlessSubscriptionFetcher.routes(tunnel: tunnel, userInitiated: userInitiated)
            if routes.isEmpty {
                // An automatic refresh while Telegram uses an MTProxy / WEB proxy: not now, no error.
                return .complete()
            }
            return GGVlessSubscriptionFetcher.fetch(urlString: url, routes: routes)
        }
        |> `catch` { error -> Signal<GGVlessFetchResult, GGVlessFetchError> in
            GGVlessStore.shared.update { subscriptions in
                if let index = subscriptions.firstIndex(where: { $0.id == subscriptionId && $0.url == url }) {
                    subscriptions[index].lastError = GGVlessController.errorCode(error)
                }
            }
            return .fail(error)
        }
        |> mapToSignal { result -> Signal<Never, GGVlessFetchError> in
            GGVlessStore.shared.update { subscriptions in
                guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionId && $0.url == url }) else {
                    return
                }
                subscriptions[index].servers = result.servers
                subscriptions[index].usage = result.headers.usage ?? subscriptions[index].usage
                subscriptions[index].providerUpdateHours = result.headers.updateHours ?? subscriptions[index].providerUpdateHours
                subscriptions[index].updatedAt = Date().timeIntervalSince1970
                subscriptions[index].lastError = nil
            }
            return .complete()
        }
    }

    /// Foreground task: refreshes the subscriptions whose interval has passed, one after another.
    private func refreshDueSubscriptions() -> Signal<Never, NoError> {
        return Signal<[String], NoError> { subscriber in
            GGVlessStore.shared.loadIfNeeded()
            let now = Date().timeIntervalSince1970
            var due: [String] = []
            for subscription in GGVlessStore.shared.subscriptions where subscription.url != nil {
                guard let interval = subscription.updateInterval.seconds(providerHours: subscription.providerUpdateHours) else {
                    continue
                }
                if now - subscription.updatedAt >= interval {
                    due.append(subscription.id)
                }
            }
            subscriber.putNext(due)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(self.queue)
        |> mapToSignal { ids -> Signal<Never, NoError> in
            var signal: Signal<Never, NoError> = .complete()
            for id in ids {
                signal = signal |> then(self.refresh(subscriptionId: id, userInitiated: false) |> `catch` { _ -> Signal<Never, NoError> in
                    return .complete()
                })
            }
            return signal
        }
    }

    public func removeSubscription(id: String) {
        GGVlessStore.shared.update { subscriptions in
            subscriptions.removeAll(where: { $0.id == id })
        }
    }

    public func updateSubscription(id: String, _ f: @escaping (inout GGVlessSubscription) -> Void) {
        GGVlessStore.shared.update { subscriptions in
            if let index = subscriptions.firstIndex(where: { $0.id == id }) {
                f(&subscriptions[index])
            }
        }
    }

    static func errorCode(_ error: GGVlessFetchError) -> String {
        switch error {
        case .invalidURL:
            return "invalidURL"
        case .network:
            return "network"
        case let .http(code):
            return "http:\(code)"
        case .tooLarge:
            return "tooLarge"
        case .empty:
            return "empty"
        }
    }

    // MARK: - Ping

    /// Measures every server, 12 at a time; the list is updated at most twice a second.
    public func pingAll() {
        let servers = GGVlessStore.shared.subscriptions.flatMap { $0.servers }
        if servers.isEmpty {
            return
        }
        self.pings = [:]
        self.pingsPromise.set([:])
        let queue = Queue(name: "org.ghostgram.vless.pings")
        let disposable = DisposableSet()
        self.pingDisposable.set(disposable)
        var index = 0
        var inFlight = 0
        var pending: [String: Int] = [:]
        var flushScheduled = false
        func flush() {
            flushScheduled = false
            let batch = pending
            pending = [:]
            Queue.mainQueue().async {
                for (id, value) in batch {
                    self.pings[id] = value
                }
                self.pingsPromise.set(self.pings)
            }
        }
        func next() {
            while inFlight < 12 && index < servers.count {
                let server = servers[index]
                index += 1
                inFlight += 1
                disposable.add((GGVlessPing.measure(host: server.address, port: server.port)
                |> deliverOn(queue)).start(next: { value in
                    inFlight -= 1
                    pending[server.id] = value ?? -1
                    if !flushScheduled {
                        flushScheduled = true
                        queue.after(0.5, {
                            flush()
                        })
                    }
                    next()
                }))
            }
        }
        queue.async {
            next()
        }
    }
}
