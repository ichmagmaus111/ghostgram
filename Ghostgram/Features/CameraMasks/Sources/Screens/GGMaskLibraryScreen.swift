import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ItemListUI
import PresentationDataUtils
import GGCore
import GGFeaturesShared

enum GGMaskLibraryTarget {
    /// The user's own choice for round videos and calls.
    case current
    /// The anonymous mode's mask.
    case anonymous
}

/// What the library screen shows: refreshed by the stores' signals, read by the content closure.
private final class GGMaskLibraryState {
    var userEntries: [GGMaskStoreEntry] = []
    var catalogEntries: [GGMaskCatalogEntry] = []
    var cacheSize: Int64?
}

/// «Маски»: pick a mask (built-in, own, from the catalog) and manage the catalog cache. Opening it
/// refreshes the catalog if it is stale (only while masks are in use); nothing else touches the
/// network, and the cache size is computed once in the background, not on every update.
func ggMakeMaskLibraryScreen(context: AccountContext, target: GGMaskLibraryTarget) -> ViewController {
    let state = GGMaskLibraryState()
    let accountId = context.account.id.gg
    let refresh = ValuePromise<Int>(0, ignoreRepeated: false)
    var refreshValue = 0
    let bump = {
        refreshValue += 1
        refresh.set(refreshValue)
    }
    let extra: Signal<Void, NoError> = combineLatest(
        GGMaskStore.shared.entries,
        GGMaskCatalog.shared.entries,
        GGMaskEngine.shared.changes.get(),
        refresh.get()
    )
    |> deliverOnMainQueue
    |> map { userEntries, catalogEntries, _, _ -> Void in
        state.userEntries = userEntries
        state.catalogEntries = catalogEntries
        return Void()
    }

    weak var controllerRef: ViewController?
    let languageCode = { GGLocalization.shared.languageCode }

    let currentSelection: () -> GGMaskSelection = {
        switch target {
        case .current:
            return GGMaskSelection(storage: GGMaskSettings.selection.value)
        case .anonymous:
            return GGMaskSelection(storage: GGAnonymousMode.mask.value)
        }
    }
    let select: (GGMaskSelection) -> Void = { selection in
        switch target {
        case .current:
            GGMaskEngine.shared.select(selection, account: accountId)
        case .anonymous:
            GGAnonymousMode.mask.set(selection.storage)
            GGMaskEngine.shared.retry(selection)
        }
    }

    let controller = ggMakeListScreen(context: context, extra: extra, content: {
        let selected = currentSelection()
        var rows: [GGListRow] = []

        rows.append(GGListRow(id: "builtin.header", section: 0, kind: .header(GGStrings.CameraMasks.Masks.builtInSection)))
        if case .current = target {
            rows.append(GGListRow(id: "none", section: 0, kind: .checkbox(title: GGStrings.CameraMasks.Masks.none, subtitle: nil, checked: selected == .none, enabled: true), action: {
                select(.none)
            }))
        }
        for id in GGBuiltInMasks.ids {
            let selection = GGMaskSelection.builtIn(id)
            rows.append(GGListRow(id: "builtin." + id, section: 0, kind: .checkbox(title: GGBuiltInMasks.glyph(id: id) + "  " + GGBuiltInMasks.title(id: id), subtitle: nil, checked: selected == selection, enabled: true), action: {
                select(selection)
            }))
        }

        rows.append(GGListRow(id: "user.header", section: 1, kind: .header(GGStrings.CameraMasks.Masks.ownSection)))
        for entry in state.userEntries {
            let selection = GGMaskSelection.user(entry.id)
            rows.append(GGListRow(id: "user." + entry.id, section: 1, kind: .checkbox(title: entry.manifest.displayName(languageCode: languageCode()), subtitle: GGStrings.CameraMasks.Studio.layers(count: entry.manifest.effects.count), checked: selected == selection, enabled: true), action: {
                select(selection)
            }))
        }
        rows.append(GGListRow(id: "user.create", section: 1, kind: .action(title: GGStrings.CameraMasks.Studio.create, destructive: false, enabled: true), action: {
            controllerRef?.push(ggMakeMaskStudioHome(context: context))
        }))

        rows.append(GGListRow(id: "catalog.header", section: 2, kind: .header(GGStrings.CameraMasks.Masks.catalogSection)))
        if !GGMaskCatalog.isAvailable {
            rows.append(GGListRow(id: "catalog.unavailable", section: 2, kind: .footer(GGStrings.CameraMasks.Masks.catalogUnavailable)))
        } else if state.catalogEntries.isEmpty {
            rows.append(GGListRow(id: "catalog.empty", section: 2, kind: .footer(GGStrings.CameraMasks.Masks.catalogEmpty)))
        } else {
            for entry in state.catalogEntries {
                let selection = GGMaskSelection.catalog(entry.id)
                rows.append(GGListRow(id: "catalog." + entry.id, section: 2, kind: .checkbox(title: entry.displayName(languageCode: languageCode()), subtitle: nil, checked: selected == selection, enabled: true), action: {
                    select(selection)
                }))
            }
        }

        if case .current = target, GGMaskCatalog.isAvailable {
            let fetchedAt = GGMaskSettings.catalogFetchedAt.value
            let fetchedLabel: String
            if fetchedAt > 0.0 {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                fetchedLabel = formatter.string(from: Date(timeIntervalSince1970: fetchedAt))
            } else {
                fetchedLabel = GGStrings.CameraMasks.Masks.never
            }
            rows.append(GGListRow(id: "cache.header", section: 3, kind: .header(GGStrings.CameraMasks.Masks.cacheSection)))
            rows.append(GGListRow(id: "cache.refresh", section: 3, kind: .disclosure(title: GGStrings.CameraMasks.Masks.refreshCatalog, label: fetchedLabel, icon: nil, enabled: true), action: {
                GGMaskCatalog.shared.refreshIfNeeded(force: true)
            }))
            let sizeLabel = state.cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
            rows.append(GGListRow(id: "cache.size", section: 3, kind: .disclosure(title: GGStrings.CameraMasks.Masks.cacheSize, label: sizeLabel, icon: nil, enabled: true), action: {
                guard let controller = controllerRef else {
                    return
                }
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                controller.present(textAlertController(context: context, title: GGStrings.CameraMasks.Masks.clearCacheTitle, text: GGStrings.CameraMasks.Masks.clearCacheText, actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: GGStrings.CameraMasks.Masks.clearCacheConfirm, action: {
                        GGMaskCatalog.shared.clearCache(completion: {
                            state.cacheSize = 0
                            bump()
                        })
                    })
                ]), in: .window(.root))
            }))
            rows.append(GGListRow(id: "cache.limit", section: 3, kind: .disclosure(title: GGStrings.CameraMasks.Masks.cacheLimit, label: GGStrings.CameraMasks.Masks.megabytes(value: GGMaskSettings.cacheLimit.value), icon: nil, enabled: true), action: {
                let sheet = UIAlertController(title: GGStrings.CameraMasks.Masks.cacheLimit, message: nil, preferredStyle: .actionSheet)
                for value in ["50", "100", "200", "400", "800", "1024"] {
                    let prefix = value == GGMaskSettings.cacheLimit.value ? "✓ " : ""
                    sheet.addAction(UIAlertAction(title: prefix + GGStrings.CameraMasks.Masks.megabytes(value: value), style: .default, handler: { _ in
                        GGMaskSettings.cacheLimit.set(value)
                    }))
                }
                sheet.addAction(UIAlertAction(title: context.sharedContext.currentPresentationData.with({ $0 }).strings.Common_Cancel, style: .cancel))
                ggPresentNative(sheet, from: controllerRef)
            }))
        }
        rows.append(GGListRow(id: "footer", section: 4, kind: .footer(GGStrings.CameraMasks.Masks.footer)))

        let title: String
        switch target {
        case .current:
            title = GGStrings.CameraMasks.Masks.title
        case .anonymous:
            title = GGStrings.CameraMasks.Anonymous.mask
        }
        return GGListScreenContent(title: title, rows: rows)
    })
    controllerRef = controller

    if GGMaskEngine.isActive(for: accountId) || target == .anonymous {
        GGMaskCatalog.shared.refreshIfNeeded()
    }
    if case .current = target {
        GGMaskCatalog.shared.cacheSize(completion: { size in
            state.cacheSize = size
            bump()
        })
    }
    return controller
}

extension GGMaskLibraryTarget: Equatable {}
