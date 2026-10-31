import Foundation
import Darwin

// The Xray core is a separate dynamic framework (`Frameworks/GGXrayCore.framework`, built by
// `Core/build-core.sh`) that nothing links against. It is opened with `dlopen` the first time the VPN
// is switched on, so the Go runtime inside it does not exist in the process until then. A Go runtime
// can not be unloaded: once opened, the library stays until the app is restarted (the core itself is
// stopped and its listener released when the VPN is switched off).
//
// Every call here blocks (dlopen, core start/stop): call only from GGVlessController's queue.

enum GGXrayCoreError: Error, Equatable {
    /// This build has no core framework (see Ghostgram/Features/Vless/README.md).
    case notBundled
    case loadFailed(String)
    case missingSymbol(String)
}

final class GGXrayCore {
    private typealias StringFunction = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias FreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias ConfigFunction = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias IntFunction = @convention(c) () -> Int32
    private typealias CounterFunction = @convention(c) () -> Int64

    /// Result codes of the bridge (Core/go/bridge.go).
    enum Result: Int32 {
        case ok = 0
        case alreadyRunning = 1
        case invalidArgument = 2
        case configInvalid = 3
        case startFailed = 4
        case notRunning = 5
        case panic = 6
    }

    static let frameworkName = "GGXrayCore"

    private let handle: UnsafeMutableRawPointer
    private let versionFunction: StringFunction
    private let freeFunction: FreeFunction
    private let lastErrorFunction: StringFunction
    private let startFunction: ConfigFunction
    private let stopFunction: IntFunction
    private let testFunction: ConfigFunction
    private let isRunningFunction: IntFunction
    private let uplinkFunction: CounterFunction
    private let downlinkFunction: CounterFunction

    /// Where the framework is, nil when this build has none. Checking it does not load anything; the
    /// bundle does not change while the app runs, so the file system is asked once.
    static let binaryPath: String? = {
        guard let frameworks = Bundle.main.privateFrameworksPath else {
            return nil
        }
        let path = (frameworks as NSString).appendingPathComponent("\(GGXrayCore.frameworkName).framework/\(GGXrayCore.frameworkName)")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }()

    static var isBundled: Bool {
        return GGXrayCore.binaryPath != nil
    }

    static func load() throws -> GGXrayCore {
        guard let path = GGXrayCore.binaryPath else {
            throw GGXrayCoreError.notBundled
        }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? ""
            throw GGXrayCoreError.loadFailed(reason)
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw GGXrayCoreError.missingSymbol(name)
            }
            return unsafeBitCast(pointer, to: type)
        }
        return GGXrayCore(
            handle: handle,
            versionFunction: try symbol("ggxc_version", StringFunction.self),
            freeFunction: try symbol("ggxc_free", FreeFunction.self),
            lastErrorFunction: try symbol("ggxc_last_error", StringFunction.self),
            startFunction: try symbol("ggxc_start", ConfigFunction.self),
            stopFunction: try symbol("ggxc_stop", IntFunction.self),
            testFunction: try symbol("ggxc_test", ConfigFunction.self),
            isRunningFunction: try symbol("ggxc_is_running", IntFunction.self),
            uplinkFunction: try symbol("ggxc_uplink", CounterFunction.self),
            downlinkFunction: try symbol("ggxc_downlink", CounterFunction.self)
        )
    }

    private init(handle: UnsafeMutableRawPointer, versionFunction: @escaping StringFunction, freeFunction: @escaping FreeFunction, lastErrorFunction: @escaping StringFunction, startFunction: @escaping ConfigFunction, stopFunction: @escaping IntFunction, testFunction: @escaping ConfigFunction, isRunningFunction: @escaping IntFunction, uplinkFunction: @escaping CounterFunction, downlinkFunction: @escaping CounterFunction) {
        self.handle = handle
        self.versionFunction = versionFunction
        self.freeFunction = freeFunction
        self.lastErrorFunction = lastErrorFunction
        self.startFunction = startFunction
        self.stopFunction = stopFunction
        self.testFunction = testFunction
        self.isRunningFunction = isRunningFunction
        self.uplinkFunction = uplinkFunction
        self.downlinkFunction = downlinkFunction
    }

    var version: String {
        return self.takeString(self.versionFunction())
    }

    var lastError: String {
        return self.takeString(self.lastErrorFunction())
    }

    var isRunning: Bool {
        return self.isRunningFunction() != 0
    }

    var traffic: (uplink: Int64, downlink: Int64) {
        return (self.uplinkFunction(), self.downlinkFunction())
    }

    func test(config: String) -> Result {
        return config.withCString { pointer in
            return Result(rawValue: self.testFunction(pointer)) ?? .panic
        }
    }

    func start(config: String) -> Result {
        return config.withCString { pointer in
            return Result(rawValue: self.startFunction(pointer)) ?? .panic
        }
    }

    @discardableResult
    func stop() -> Result {
        return Result(rawValue: self.stopFunction()) ?? .panic
    }

    private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else {
            return ""
        }
        let value = String(cString: pointer)
        self.freeFunction(pointer)
        return value
    }
}
