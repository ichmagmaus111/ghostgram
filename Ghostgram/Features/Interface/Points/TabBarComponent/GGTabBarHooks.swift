// Compiled into TabBarComponent (filegroup //Ghostgram/Features/Interface:TabBarComponentPointSources),
// used by TabBarComponent and TabBarUI. Owner: W2-5 (tab bar organizer, labels, wide bar, height).
// One style snapshot per layout of the bar; no reads per item.

import Foundation
import UIKit
import GGCore

/// How the main tab bar looks. `.upstream` = Telegram's bar.
public struct GGTabBarStyle: Equatable {
    public var hidesTitles: Bool
    /// No 500 pt cap and narrow side insets.
    public var isWide: Bool
    /// The narrow bar of Swiftgram / the old Ghostgram («Широкая панель» off): as wide as its tabs
    /// need — fewer tabs, a narrower bar — instead of Telegram's stretching over the whole width
    /// (`ggTabBarAvailableWidth`). Off for Telegram's own bars (`.upstream`).
    public var fitsItems: Bool
    /// The bar is taken off the screen (the app's own hide requests still work on top).
    public var hidesBar: Bool
    /// Extra height of the items, pt.
    public var heightOffset: CGFloat
    /// Lift of the bar above the bottom edge, pt.
    public var bottomOffset: CGFloat
    /// Changes whenever own labels change, so cached layouts of the bar refresh.
    public var titlesRevision: Int

    public init(hidesTitles: Bool, isWide: Bool, fitsItems: Bool, hidesBar: Bool, heightOffset: CGFloat, bottomOffset: CGFloat, titlesRevision: Int) {
        self.hidesTitles = hidesTitles
        self.isWide = isWide
        self.fitsItems = fitsItems
        self.hidesBar = hidesBar
        self.heightOffset = heightOffset
        self.bottomOffset = bottomOffset
        self.titlesRevision = titlesRevision
    }

    public static let upstream = GGTabBarStyle(hidesTitles: false, isWide: false, fitsItems: false, hidesBar: false, heightOffset: 0.0, bottomOffset: 0.0, titlesRevision: 0)

    /// Height of a tab before `heightOffset`: Telegram's 56 pt, or 40 pt without labels — the compact
    /// bar of Swiftgram / the old Ghostgram (`showTabNames` off), 48 pt with its glass inset.
    public var baseItemHeight: CGFloat {
        return self.hidesTitles ? 40.0 : 56.0
    }
}

/// The width the bar lays its tabs out in. A narrow bar (`fitsItems`) is Swiftgram's: four tabs
/// keep the width, three get 80 % of it, two 67 %, one 57 %; without the search button it is also
/// that button's width narrower (nothing in this Telegram shows it, so always). The open search
/// field always gets the whole width.
public func ggTabBarAvailableWidth(_ width: CGFloat, style: GGTabBarStyle, itemCount: Int, hasSearch: Bool, isSearchActive: Bool, searchButtonWidth: CGFloat) -> CGFloat {
    if !style.fitsItems || isSearchActive {
        return width
    }
    let reducer: CGFloat
    switch itemCount {
    case 1:
        reducer = 1.75
    case 2:
        reducer = 1.5
    case 3:
        reducer = 1.25
    default:
        reducer = 1.0
    }
    var result = floor(width / reducer)
    if !hasSearch {
        result -= searchButtonWidth
    }
    return max(0.0, result)
}

public enum GGTabBarHooks {
    /// Provider of the style (first registered wins). Main thread, once per layout of the bar.
    public static let style = GGHookPoint<() -> GGTabBarStyle>("tabBar.style")

    /// Policy: an own label for a tab's item (nil = the controller's title). Main thread.
    public static let itemTitle = GGHookPoint<(UITabBarItem) -> String?>("tabBar.itemTitle")
}

/// The current style of the bar.
public func ggTabBarStyle() -> GGTabBarStyle {
    if GGTabBarHooks.style.isEmpty {
        return .upstream
    }
    return GGTabBarHooks.style.handlers[0]()
}

/// The label of a tab's item: an own label or Telegram's.
public func ggTabBarItemTitle(_ item: UITabBarItem) -> String? {
    if GGTabBarHooks.itemTitle.isEmpty {
        return item.title
    }
    for handler in GGTabBarHooks.itemTitle.handlers {
        if let value = handler(item) {
            return value
        }
    }
    return item.title
}
