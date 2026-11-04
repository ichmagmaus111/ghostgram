import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PromptUI
import GGCore
import GGSettingsUI

// More › Fake gifts › Stars: «Локальные звёзды» — the Stars balance this device shows instead of the
// real one (`GGStarsHooks.displayedBalance` in TelegramCore; TON is not touched). Only the number on
// screen changes: what Stars pay for is still checked by the server against the real balance.
// Restored 2026-11-01 at the owner's word: the old client had it in «Кастомизация › Сообщения»
// (`GG.fontCustomization.localStarsBalance`), the remake had lost it.

enum GGLocalStars {
    /// nil = the real balance.
    static let balance = GGSetting<Int64?>("fakeGifts.localStars", default: nil)

    static let section = GGMenuSectionID("more.fakeGifts.stars")

    private static var settingDisposable: Disposable?

    static func declare() {
        let _ = GGLocalStars.balance
    }

    /// Main thread, before `GGHookRegistry.freeze()`.
    static func register() {
        GGStarsHooks.displayedBalance.register({ _ in
            return GGLocalStars.balance.value.map { StarsAmount(value: $0, nanos: 0) }
        })
        // A balance already on screen follows the change at once.
        GGLocalStars.settingDisposable = (GGLocalStars.balance.signal
        |> distinctUntilChanged).start(next: { _ in
            GGStarsHooks.invalidate()
        })

        GGMigrations.registerGlobal(id: "fakeGifts.localStars.v1") { legacy in
            let key = "GG.fontCustomization.localStarsBalance"
            if let number = legacy.object(key) as? NSNumber {
                GGLocalStars.balance.set(max(0, number.int64Value))
            }
            legacy.removeLegacyKey(key)
        }

        GGLocalStars.registerMenu()
    }

    private static func registerMenu() {
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGLocalStars.section,
            screen: .tab(.moreFakeGifts),
            order: 300,
            header: { GGStrings.FakeGifts.Stars.header },
            footer: { _ in GGStrings.FakeGifts.Stars.footer }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "fakeGifts.localStars",
            section: GGLocalStars.section,
            order: 100,
            title: { GGStrings.FakeGifts.Stars.title },
            subtitle: { GGStrings.FakeGifts.Stars.info },
            icon: .bundle("Chat/Context Menu/Stars"),
            kind: .action({ context in
                GGLocalStars.edit(menuContext: context)
            }),
            searchKeywords: { [GGStrings.FakeGifts.Stars.keywords] },
            label: { context in
                guard let value = GGLocalStars.balance.value else {
                    return nil
                }
                return GGLocalStars.formatted(value, groupingSeparator: context.presentationData.dateTimeFormat.groupingSeparator)
            }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "fakeGifts.localStars.reset",
            section: GGLocalStars.section,
            order: 200,
            title: { GGStrings.FakeGifts.Stars.reset },
            kind: .action({ _ in
                GGLocalStars.balance.set(nil)
            }),
            isVisible: { _ in GGLocalStars.balance.value != nil },
            isDestructive: true
        ))
    }

    private static func edit(menuContext: GGMenuContext) {
        let current = GGLocalStars.balance.value.map { "\($0)" }
        menuContext.present(promptController(context: menuContext.context, text: GGStrings.FakeGifts.Stars.title, subtitle: GGStrings.FakeGifts.Stars.promptText, value: current, placeholder: GGStrings.FakeGifts.Stars.placeholder, characterLimit: 32, apply: { value in
            guard let value else {
                return
            }
            GGLocalStars.balance.set(GGLocalStars.parse(value))
        }))
    }

    /// The digits of `text` as a balance, at most `Int64.max`; nil when there are none (the real
    /// balance again).
    static func parse(_ text: String) -> Int64? {
        var result: Int64?
        for scalar in text.unicodeScalars {
            guard scalar.value >= 48 && scalar.value <= 57 else {
                continue
            }
            let digit = Int64(scalar.value - 48)
            let value = result ?? 0
            if value > (Int64.max - digit) / 10 {
                return Int64.max
            }
            result = value * 10 + digit
        }
        return result
    }

    static func formatted(_ value: Int64, groupingSeparator: String) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 {
                result += groupingSeparator
            }
            result.append(character)
        }
        return result
    }
}
