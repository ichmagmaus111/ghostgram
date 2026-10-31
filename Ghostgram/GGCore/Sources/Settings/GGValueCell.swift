import Foundation
import SwiftSignalKit

/// The in-memory value of one setting. A read is an uncontended lock and a copy: no disk, no
/// JSON, no key hashing. Subscribers get the current value first, then every change; a version
/// gate keeps the initial value from arriving after a newer one that raced it.
final class GGValueCell<Value: Equatable> {
    private let lock = GGUnfairLock()
    private var value: Value
    private var version: UInt64 = 0
    private let subscribers = Bag<(Value, UInt64) -> Void>()
    #if DEBUG
    private var wasRead = false
    #endif

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        self.lock.lock()
        let value = self.value
        self.lock.unlock()
        return value
    }

    #if DEBUG
    /// `current` for feature code: also remembers that the setting has a reader (dead-toggle audit).
    var currentMarkingRead: Value {
        self.lock.lock()
        let value = self.value
        self.wasRead = true
        self.lock.unlock()
        return value
    }

    var debugWasRead: Bool {
        self.lock.lock()
        let wasRead = self.wasRead
        self.lock.unlock()
        return wasRead
    }
    #endif

    /// Returns false when the value did not change (nothing is delivered then).
    @discardableResult
    func update(_ newValue: Value) -> Bool {
        return self.modify { _ in
            return newValue
        }
    }

    @discardableResult
    func modify(_ f: (Value) -> Value) -> Bool {
        self.lock.lock()
        let newValue = f(self.value)
        if newValue == self.value {
            self.lock.unlock()
            return false
        }
        self.value = newValue
        self.version += 1
        let version = self.version
        let subscribers = self.subscribers.copyItems()
        self.lock.unlock()

        for subscriber in subscribers {
            subscriber(newValue, version)
        }
        return true
    }

    func signal() -> Signal<Value, NoError> {
        return Signal<Value, NoError> { [weak self] subscriber in
            guard let strongSelf = self else {
                return EmptyDisposable
            }
            let gate = GGVersionGate()
            strongSelf.lock.lock()
            let index = strongSelf.subscribers.add({ value, version in
                if gate.pass(version) {
                    subscriber.putNext(value)
                }
            })
            let currentValue = strongSelf.value
            let currentVersion = strongSelf.version
            strongSelf.lock.unlock()

            if gate.pass(currentVersion) {
                subscriber.putNext(currentValue)
            }

            return ActionDisposable { [weak strongSelf] in
                guard let strongSelf = strongSelf else {
                    return
                }
                strongSelf.lock.lock()
                strongSelf.subscribers.remove(index)
                strongSelf.lock.unlock()
            }
        }
        |> distinctUntilChanged
    }
}

/// Per-account values of one account-scoped setting. Accounts without a stored value read the
/// default; the dictionary lookup hashes an Int64, never the setting key.
final class GGAccountValueCell<Value: Equatable> {
    private let lock = GGUnfairLock()
    private let defaultValue: Value
    private var values: [GGAccountID: Value] = [:]
    private var version: UInt64 = 0
    private let subscribers = Bag<(GGAccountID, Value, UInt64) -> Void>()
    #if DEBUG
    private var wasRead = false
    #endif

    init(defaultValue: Value) {
        self.defaultValue = defaultValue
    }

    func current(for account: GGAccountID) -> Value {
        self.lock.lock()
        let value = self.values[account]
        self.lock.unlock()
        if let value = value {
            return value
        }
        return self.defaultValue
    }

    #if DEBUG
    func currentMarkingRead(for account: GGAccountID) -> Value {
        self.lock.lock()
        let value = self.values[account]
        self.wasRead = true
        self.lock.unlock()
        if let value = value {
            return value
        }
        return self.defaultValue
    }

    var debugWasRead: Bool {
        self.lock.lock()
        let wasRead = self.wasRead
        self.lock.unlock()
        return wasRead
    }
    #endif

    /// `nil` removes the stored value (the account reads the default).
    @discardableResult
    func update(_ newValue: Value?, for account: GGAccountID) -> Bool {
        self.lock.lock()
        let previous = self.values[account] ?? self.defaultValue
        let effective = newValue ?? self.defaultValue
        if let newValue = newValue, newValue != self.defaultValue {
            self.values[account] = newValue
        } else {
            self.values.removeValue(forKey: account)
        }
        if previous == effective {
            self.lock.unlock()
            return false
        }
        self.version += 1
        let version = self.version
        let subscribers = self.subscribers.copyItems()
        self.lock.unlock()

        for subscriber in subscribers {
            subscriber(account, effective, version)
        }
        return true
    }

    func signal(for account: GGAccountID) -> Signal<Value, NoError> {
        return Signal<Value, NoError> { [weak self] subscriber in
            guard let strongSelf = self else {
                return EmptyDisposable
            }
            let gate = GGVersionGate()
            strongSelf.lock.lock()
            let index = strongSelf.subscribers.add({ changedAccount, value, version in
                if changedAccount == account && gate.pass(version) {
                    subscriber.putNext(value)
                }
            })
            let currentValue = strongSelf.values[account] ?? strongSelf.defaultValue
            let currentVersion = strongSelf.version
            strongSelf.lock.unlock()

            if gate.pass(currentVersion) {
                subscriber.putNext(currentValue)
            }

            return ActionDisposable { [weak strongSelf] in
                guard let strongSelf = strongSelf else {
                    return
                }
                strongSelf.lock.lock()
                strongSelf.subscribers.remove(index)
                strongSelf.lock.unlock()
            }
        }
        |> distinctUntilChanged
    }
}
