import Foundation
import Network
import SwiftSignalKit

// Two measurements, both on demand (no timers): the TCP connect time to a server for the list, and
// an end-to-end check of the running tunnel — a SOCKS5 CONNECT through the core to a Telegram data
// centre followed by an unencrypted `req_pq_multi`, which the data centre answers. Only an answer
// proves that traffic really flows; the core acknowledges CONNECT before it dials.

enum GGVlessPing {
    /// Connect time in milliseconds, nil on failure or after `timeout`.
    static func measure(host: String, port: Int, timeout: Double = 3.0) -> Signal<Int?, NoError> {
        return Signal { subscriber in
            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let queue = DispatchQueue(label: "org.ghostgram.vless.ping")
            let parameters = NWParameters.tcp
            parameters.prohibitedInterfaceTypes = [.loopback]
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
            let started = CFAbsoluteTimeGetCurrent()
            var finished = false
            let finish: (Int?) -> Void = { value in
                if finished {
                    return
                }
                finished = true
                connection.cancel()
                subscriber.putNext(value)
                subscriber.putCompletion()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Int(((CFAbsoluteTimeGetCurrent() - started) * 1000.0).rounded()))
                case .failed, .cancelled:
                    finish(nil)
                case .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
            return ActionDisposable {
                queue.async {
                    if !finished {
                        finished = true
                        connection.cancel()
                    }
                }
            }
        }
    }
}

enum GGVlessTunnelProbe {
    /// A Telegram data centre (DC2, the main seed address).
    static let host = "149.154.167.50"
    static let port: UInt16 = 443

    /// true when the data centre answered through the tunnel within `timeout`.
    static func check(_ tunnel: GGVlessTunnelEndpoint, timeout: Double = 8.0) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            guard let localPort = NWEndpoint.Port(rawValue: UInt16(clamping: tunnel.port)) else {
                subscriber.putNext(false)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let queue = DispatchQueue(label: "org.ghostgram.vless.probe")
            let connection = NWConnection(host: "127.0.0.1", port: localPort, using: .tcp)
            var finished = false
            let finish: (Bool) -> Void = { value in
                if finished {
                    return
                }
                finished = true
                connection.cancel()
                subscriber.putNext(value)
                subscriber.putCompletion()
            }
            func exchange(_ data: Data, expect length: Int, _ next: @escaping (Data) -> Void) {
                connection.send(content: data, completion: .contentProcessed({ error in
                    if error != nil {
                        finish(false)
                        return
                    }
                    connection.receive(minimumIncompleteLength: length, maximumLength: max(length, 64), completion: { content, _, _, error in
                        guard error == nil, let content, content.count >= length else {
                            finish(false)
                            return
                        }
                        next(content)
                    })
                }))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Greeting: SOCKS5, one method — username/password.
                    exchange(Data([0x05, 0x01, 0x02]), expect: 2, { reply in
                        guard reply[reply.startIndex] == 0x05, reply[reply.startIndex + 1] == 0x02 else {
                            finish(false)
                            return
                        }
                        exchange(GGVlessTunnelProbe.authentication(tunnel.credentials), expect: 2, { reply in
                            guard reply[reply.startIndex + 1] == 0x00 else {
                                finish(false)
                                return
                            }
                            exchange(GGVlessTunnelProbe.connectRequest(), expect: 10, { reply in
                                guard reply[reply.startIndex + 1] == 0x00 else {
                                    finish(false)
                                    return
                                }
                                // Any answer of the data centre to req_pq_multi proves the path.
                                exchange(GGVlessTunnelProbe.requestPQ(), expect: 1, { _ in
                                    finish(true)
                                })
                            })
                        })
                    })
                case .failed, .cancelled, .waiting:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
            return ActionDisposable {
                queue.async {
                    if !finished {
                        finished = true
                        connection.cancel()
                    }
                }
            }
        }
    }

    private static func authentication(_ credentials: GGXrayInboundCredentials) -> Data {
        let user = Array(credentials.username.utf8.prefix(255))
        let password = Array(credentials.password.utf8.prefix(255))
        var bytes: [UInt8] = [0x01, UInt8(user.count)]
        bytes.append(contentsOf: user)
        bytes.append(UInt8(password.count))
        bytes.append(contentsOf: password)
        return Data(bytes)
    }

    private static func connectRequest() -> Data {
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x01]
        for part in GGVlessTunnelProbe.host.split(separator: ".") {
            bytes.append(UInt8(part) ?? 0)
        }
        bytes.append(UInt8(GGVlessTunnelProbe.port >> 8))
        bytes.append(UInt8(GGVlessTunnelProbe.port & 0xff))
        return Data(bytes)
    }

    /// MTProto abridged transport: 0xef, then length/4, then an unencrypted message
    /// (auth_key_id 0, message id, length 20, `req_pq_multi#be7e8ef1 nonce:int128`).
    private static func requestPQ() -> Data {
        var bytes: [UInt8] = [0xef, 40 / 4]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        let messageId = UInt64(Date().timeIntervalSince1970 * 4294967296.0) & ~UInt64(3)
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((messageId >> UInt64(shift)) & 0xff))
        }
        bytes.append(contentsOf: [20, 0, 0, 0])
        bytes.append(contentsOf: [0xf1, 0x8e, 0x7e, 0xbe])
        for _ in 0 ..< 16 {
            bytes.append(UInt8.random(in: 0 ... 255))
        }
        return Data(bytes)
    }
}
