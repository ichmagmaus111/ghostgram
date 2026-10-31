import Foundation
import UIKit
import TelegramPresentationData
import TelegramUIPreferences
import ChatListTitleView // GHOST: chat list row style (GGChatListStyleHooks)

public final class ChatListPresentationData {
    public let theme: PresentationTheme
    public let fontSize: PresentationFontSize
    public let strings: PresentationStrings
    public let dateTimeFormat: PresentationDateTimeFormat
    public let nameSortOrder: PresentationPersonNameOrder
    public let nameDisplayOrder: PresentationPersonNameOrder
    public let disableAnimations: Bool
    // GHOST: the look of the rows, taken once per presentation data (GGChatListStyleHooks.rowStyle)
    public let ggRowStyle: GGChatListRowStyle
    
    public init(theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameSortOrder: PresentationPersonNameOrder, nameDisplayOrder: PresentationPersonNameOrder, disableAnimations: Bool) {
        self.theme = theme
        self.fontSize = fontSize
        self.strings = strings
        self.dateTimeFormat = dateTimeFormat
        self.nameSortOrder = nameSortOrder
        self.nameDisplayOrder = nameDisplayOrder
        self.disableAnimations = disableAnimations
        self.ggRowStyle = ggChatListRowStyle() // GHOST: see the property
    }
}
