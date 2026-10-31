import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// How many other signed-in accounts there are, cached for the «Чаты» header button (it answers from
/// memory on every header rebuild). «Сворачивать аккаунты в Настройках» was removed (owner,
/// 2026-10-27); its stored keys are dropped by `security.accounts.collapse.removed.v1`.
final class GGAccountsList {
    static let shared = GGAccountsList()

    /// Main thread.
    private(set) var otherAccountCount = 0
    private var disposable: Disposable?

    /// From every account's root controllers (main thread): the count follows the account list.
    func start(context: AccountContext) {
        self.disposable?.dispose()
        let currentId = context.account.id
        self.disposable = (context.sharedContext.activeAccountsWithInfo
        |> map { _, accounts -> Int in
            return accounts.filter { $0.account.id != currentId }.count
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] count in
            guard let self else {
                return
            }
            self.otherAccountCount = count
        })
    }
}
