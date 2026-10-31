import Foundation
import Display
import AccountContext
import GGSettingsUI

// GHOST: Ghostgram's menu in Telegram's own settings search. The places come from GGSettingsUI
// (`ggSettingsSearchItems`), the same index the Ghostgram root screen searches; breadcrumbs start
// at «Ghostgram», and opening a result pushes the screen and highlights the row — through the
// menu's access gates (a locked category asks for the code first, possibly pushing later).
func ggSettingsSearchableItems(context: AccountContext) -> [SettingsSearchableItem] {
    return ggSettingsSearchItems(context: context).map { item in
        let open = item.open
        return SettingsSearchableItem(
            id: item.id,
            title: item.title,
            alternate: item.keywords,
            icon: .ghostgram,
            breadcrumbs: item.breadcrumbs,
            present: { context, _, present in
                open(context, { controller in
                    present(.push, controller)
                })
            }
        )
    }
}
