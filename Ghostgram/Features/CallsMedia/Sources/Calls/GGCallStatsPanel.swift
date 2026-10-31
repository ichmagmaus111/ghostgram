import Foundation
import UIKit
import Darwin
import SwiftSignalKit
import GGCallsMediaHooks
import GGCore

/// «Статистика звонка»: duration, connection quality, throughput and network type. Draggable; the
/// position is remembered. Ticks once a second only while it is in a window and the app is in the
/// foreground — a call in the background or a minimized call screen costs nothing.
final class GGCallStatsPanel: UIView {
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let qualityLabel = UILabel()
    private let throughputLabel = UILabel()
    private let networkLabel = UILabel()

    private var isAppActive = true
    private var timer: SwiftSignalKit.Timer?
    private var state: GGCallScreenState?
    private var previousCounters: (received: UInt64, sent: UInt64, time: Double)?
    private var throughput: (down: Double, up: Double)?
    private var networkName: String?
    private var didPlace = false
    private var dragStartOrigin: CGPoint = .zero

    init() {
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 160.0, height: 94.0))
        self.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        self.layer.cornerRadius = 10.0
        self.titleLabel.font = UIFont.systemFont(ofSize: 10.0, weight: .semibold)
        self.titleLabel.textColor = UIColor(white: 1.0, alpha: 0.55)
        for label in [self.timeLabel, self.qualityLabel, self.throughputLabel, self.networkLabel] {
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .regular)
            label.textColor = .white
        }
        for (index, label) in [self.titleLabel, self.timeLabel, self.qualityLabel, self.throughputLabel, self.networkLabel].enumerated() {
            label.frame = CGRect(x: 8.0, y: 6.0 + CGFloat(index) * 16.0, width: 144.0, height: 14.0)
            self.addSubview(label)
        }
        self.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:))))
        self.refreshTexts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.timer?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updateTimer()
    }

    func setActive(_ active: Bool) {
        self.isAppActive = active
        self.updateTimer()
    }

    func update(state: GGCallScreenState) {
        self.state = state
        self.refreshTexts()
    }

    func layoutIn(bounds: CGRect, insets: UIEdgeInsets) {
        let size = self.bounds.size
        if !self.didPlace {
            self.didPlace = true
            let stored = GGCallsMediaSettings.statsPanelOrigin.value
            var origin = CGPoint(x: insets.left + 16.0, y: insets.top + 64.0)
            if stored.count == 2 {
                let candidate = CGPoint(x: stored[0], y: stored[1])
                if bounds.insetBy(dx: 0.0, dy: insets.top).contains(CGRect(origin: candidate, size: size)) {
                    origin = candidate
                }
            }
            self.frame = CGRect(origin: origin, size: size)
        } else if let superview = self.superview, !superview.bounds.contains(self.frame) {
            self.frame = CGRect(origin: GGCallStatsPanel.clamp(self.frame.origin, size: size, in: superview.bounds), size: size)
        }
    }

    private func updateTimer() {
        let shouldRun = self.window != nil && self.isAppActive && !self.isHidden
        if shouldRun && self.timer == nil {
            self.previousCounters = nil
            let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
                self?.tick()
            }, queue: Queue.mainQueue())
            self.timer = timer
            timer.start()
            self.tick()
        } else if !shouldRun, let timer = self.timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if let counters = GGCallStatsPanel.interfaceCounters() {
            if let previous = self.previousCounters, now > previous.time {
                let interval = now - previous.time
                let received = counters.received >= previous.received ? Double(counters.received - previous.received) : 0.0
                let sent = counters.sent >= previous.sent ? Double(counters.sent - previous.sent) : 0.0
                self.throughput = (received * 8.0 / interval / 1000.0, sent * 8.0 / interval / 1000.0)
            }
            self.previousCounters = (counters.received, counters.sent, now)
            self.networkName = counters.busiestInterface
        }
        self.refreshTexts()
    }

    private func refreshTexts() {
        self.titleLabel.text = GGStrings.Calls.Stats.title.uppercased()
        if let activeSince = self.state?.activeSince {
            let elapsed = max(0.0, CFAbsoluteTimeGetCurrent() - activeSince)
            self.timeLabel.text = GGStrings.Calls.Stats.time(value: GGCallsMediaUI.durationText(elapsed))
        } else {
            self.timeLabel.text = GGStrings.Calls.Stats.time(value: "--:--")
        }
        if let quality = self.state?.signalQuality {
            self.qualityLabel.text = GGStrings.Calls.Stats.quality(value: "\(quality)/4")
        } else {
            self.qualityLabel.text = GGStrings.Calls.Stats.quality(value: "—")
        }
        if let throughput = self.throughput {
            self.throughputLabel.text = GGStrings.Calls.Stats.throughput(down: "\(Int(throughput.down.rounded()))", up: "\(Int(throughput.up.rounded()))")
        } else {
            self.throughputLabel.text = GGStrings.Calls.Stats.throughput(down: "--", up: "--")
        }
        let network: String
        if let name = self.networkName {
            if name.hasPrefix("en") {
                network = GGStrings.Calls.Stats.wifi
            } else if name.hasPrefix("pdp_ip") {
                network = GGStrings.Calls.Stats.cellular
            } else {
                network = name
            }
        } else {
            network = "—"
        }
        self.networkLabel.text = GGStrings.Calls.Stats.network(value: network)
    }

    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let superview = self.superview else {
            return
        }
        switch recognizer.state {
        case .began:
            self.dragStartOrigin = self.frame.origin
        case .changed:
            let translation = recognizer.translation(in: superview)
            let origin = CGPoint(x: self.dragStartOrigin.x + translation.x, y: self.dragStartOrigin.y + translation.y)
            self.frame = CGRect(origin: GGCallStatsPanel.clamp(origin, size: self.bounds.size, in: superview.bounds), size: self.bounds.size)
        case .ended, .cancelled:
            GGCallsMediaSettings.statsPanelOrigin.set([Double(self.frame.minX), Double(self.frame.minY)])
        default:
            break
        }
    }

    private static func clamp(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        return CGPoint(x: max(bounds.minX, min(bounds.maxX - size.width, origin.x)), y: max(bounds.minY, min(bounds.maxY - size.height, origin.y)))
    }

    /// Byte counters of the device's network interfaces that are up (not per call — the system has
    /// no per-call counter), and the interface that carries the most.
    private static func interfaceCounters() -> (received: UInt64, sent: UInt64, busiestInterface: String?)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return nil
        }
        defer {
            freeifaddrs(addresses)
        }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var busiest: (name: String, bytes: UInt64)?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            pointer = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else {
                continue
            }
            let flags = Int32(entry.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 {
                continue
            }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            let interfaceReceived = UInt64(counters.ifi_ibytes)
            let interfaceSent = UInt64(counters.ifi_obytes)
            received += interfaceReceived
            sent += interfaceSent
            let name = String(cString: entry.ifa_name)
            let total = interfaceReceived + interfaceSent
            if let current = busiest, current.bytes >= total {
                continue
            }
            busiest = (name, total)
        }
        return (received, sent, busiest?.name)
    }
}
