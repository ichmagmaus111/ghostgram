import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import GGCore

/// Forwards sent from Ghostgram's own chat pickers («В Избранное», «Переслать без автора» on the
/// selection panel and in the message menu) without opening the target: the comment typed in the
/// picker first, then the forwards — copies where GGForwardCopy needs one — to every chosen chat.
public enum GGForwardSend {
    public struct Target {
        public let peerId: PeerId
        /// The forum topic chosen in the picker; nil = the chat itself.
        public let threadId: Int64?

        public init(peerId: PeerId, threadId: Int64?) {
            self.peerId = peerId
            self.threadId = threadId
        }
    }

    /// `silent` — without sound; `scheduleTime` — scheduled (`scheduleWhenOnlineTimestamp` = when
    /// online). `completion` gets the copy step's result on the main queue; when it has no messages
    /// nothing was sent, the comment included.
    public static func send(account: Account, messages: [Message], comment: [EnqueueMessage] = [], to targets: [Target], hideNames: Bool, hideCaptions: Bool, silent: Bool = false, scheduleTime: Int32? = nil, repeatPeriod: Int32? = nil, completion: @escaping (GGForwardCopy.Result) -> Void) {
        let forwardAttributes: [MessageAttribute] = (hideNames || hideCaptions) ? [ForwardOptionsMessageAttribute(hideNames: hideNames, hideCaptions: hideCaptions)] : []
        let forwards = messages.map { message -> EnqueueMessage in
            return .forward(source: message.id, threadId: nil, grouping: .auto, attributes: forwardAttributes, correlationId: nil)
        }
        let prepared: Signal<GGForwardCopy.Result, NoError>
        if GGForwardCopy.needsCopy(messages) {
            prepared = GGForwardCopy.convert(forwards, sources: messages, account: account, hideNames: hideNames, hideCaptions: hideCaptions)
        } else {
            prepared = .single(GGForwardCopy.Result(messages: forwards, skippedCount: 0, failedCount: 0))
        }
        let _ = (prepared
        |> deliverOnMainQueue).start(next: { result in
            if !result.messages.isEmpty {
                let batch = (comment + result.messages).map { message -> EnqueueMessage in
                    return message.withUpdatedAttributes { attributes in
                        var attributes = attributes
                        if silent || scheduleTime != nil {
                            attributes.removeAll(where: { $0 is NotificationInfoMessageAttribute })
                        }
                        if silent {
                            attributes.append(NotificationInfoMessageAttribute(flags: .muted))
                        }
                        if let scheduleTime {
                            attributes.removeAll(where: { $0 is OutgoingScheduleInfoMessageAttribute })
                            attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: repeatPeriod))
                        }
                        return attributes
                    }
                }
                for target in targets {
                    var peerBatch = batch
                    if let threadId = target.threadId {
                        peerBatch = peerBatch.map { $0.withUpdatedThreadId(threadId) }
                    }
                    let _ = enqueueMessages(account: account, peerId: target.peerId, messages: peerBatch).start()
                }
            }
            completion(result)
        })
    }
}
