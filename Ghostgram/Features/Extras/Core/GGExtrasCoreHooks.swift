// Compiled into TelegramCore (filegroup //Ghostgram/Features/Extras:TelegramCoreSources).
// Points of the Swiftgram-parity features (W5-SG) that TelegramCore itself calls. Handlers are
// registered by `GGExtrasShared.register()` (GGFeaturesShared), which reads the settings.
// An empty point = upstream.

import Foundation
import Postbox
import SwiftSignalKit
import GGCore

public enum GGExtrasCoreHooks {
    /// Policy (any `true`): an in-chat text search the server answered with nothing looks for the
    /// query inside the words of the messages already on this device.
    public static let searchesPartialWords = GGHookPoint<() -> Bool>("extras.searchesPartialWords")

    /// Transformer of the text a restricted chat or message shows: `(text, reason, platform)`.
    public static let restrictionText = GGHookPoint<(String, String, String) -> String>("extras.restrictionText")
}

/// GHOST hook target: `PeerUtils.restrictionText` and `RestrictedContentMessageAttribute.platformText`.
public func ggExtrasRestrictionText(_ text: String, reason: String, platform: String) -> String {
    if GGExtrasCoreHooks.restrictionText.isEmpty {
        return text
    }
    var result = text
    for handler in GGExtrasCoreHooks.restrictionText.handlers {
        result = handler(result, reason, platform)
    }
    return result
}

/// How many of the latest messages of a chat the on-device fallback looks through.
private let ggExtrasSearchScanLimit = 1500
/// How many results it returns at most.
private let ggExtrasSearchResultLimit = 100

private func ggExtrasSearchesPartialWords() -> Bool {
    if GGExtrasCoreHooks.searchesPartialWords.isEmpty {
        return false
    }
    for handler in GGExtrasCoreHooks.searchesPartialWords.handlers where handler() {
        return true
    }
    return false
}

/// GHOST hook target: `TelegramEngine.Messages.searchMessages`. The upstream signal unchanged while
/// nobody asks for the fallback, and for every page after the first.
func ggExtrasWrapSearch(_ signal: Signal<(SearchMessagesResult, SearchMessagesState), NoError>, account: Account, location: SearchMessagesLocation, query: String, state: SearchMessagesState?) -> Signal<(SearchMessagesResult, SearchMessagesState), NoError> {
    if GGExtrasCoreHooks.searchesPartialWords.isEmpty || state != nil {
        return signal
    }
    return signal
    |> mapToSignal { result -> Signal<(SearchMessagesResult, SearchMessagesState), NoError> in
        return ggExtrasSearchFallback(account: account, location: location, query: query, state: state, result: result)
    }
}

/// When the first page of an in-chat
/// text search is empty, the latest messages on this device are searched for the query as a part of
/// a word (case and diacritics ignored). The server's state is kept: the result is complete.
func ggExtrasSearchFallback(account: Account, location: SearchMessagesLocation, query: String, state: SearchMessagesState?, result: (SearchMessagesResult, SearchMessagesState)) -> Signal<(SearchMessagesResult, SearchMessagesState), NoError> {
    if state != nil || !result.0.messages.isEmpty || !ggExtrasSearchesPartialWords() {
        return .single(result)
    }
    guard case let .peer(peerId, fromId, tags, reactions, threadId, minDate, maxDate) = location else {
        return .single(result)
    }
    if fromId != nil || tags != nil || reactions != nil {
        return .single(result)
    }
    if (minDate ?? 0) != 0 || (maxDate ?? 0) != 0 {
        return .single(result)
    }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedQuery.isEmpty {
        return .single(result)
    }
    return account.postbox.transaction { transaction -> (SearchMessagesResult, SearchMessagesState) in
        let view = transaction.getMessagesHistoryViewState(input: .single(peerId: peerId, threadId: threadId), ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set(), count: ggExtrasSearchScanLimit, clipHoles: false, anchor: .upperBound, namespaces: .just(Set([Namespaces.Message.Cloud])))
        var messages: [Message] = []
        for entry in view.entries.reversed() {
            let message = entry.message
            if message.text.isEmpty {
                continue
            }
            if message.text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                continue
            }
            messages.append(message)
            if messages.count >= ggExtrasSearchResultLimit {
                break
            }
        }
        if messages.isEmpty {
            return result
        }
        var readStates: [PeerId: CombinedPeerReadState] = [:]
        if let readState = transaction.getCombinedPeerReadState(peerId) {
            readStates[peerId] = readState
        }
        return (SearchMessagesResult(messages: messages, readStates: readStates, threadInfo: [:], totalCount: Int32(messages.count), completed: true), result.1)
    }
}
