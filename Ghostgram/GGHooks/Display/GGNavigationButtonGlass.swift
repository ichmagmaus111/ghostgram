// Compiled into Display (filegroup //Ghostgram/GGHooks:DisplayHookSources).
// The glass behind a navigation bar's buttons is a capsule (NavigationBarImpl). A custom button
// node that is not round — the chat's avatar with square avatars — answers its own corner radius,
// so the glass stays concentric with it. Display has no Ghostgram settings: the node decides.

import Foundation
import UIKit

public protocol GGNavigationButtonGlassShape: AnyObject {
    /// Corner radius of the glass of the given height around this node alone, or nil for
    /// Telegram's capsule.
    func ggGlassCornerRadius(height: CGFloat) -> CGFloat?
}
