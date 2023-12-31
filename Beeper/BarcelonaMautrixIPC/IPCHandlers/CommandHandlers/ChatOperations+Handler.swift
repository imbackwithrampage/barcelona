//
//  ChatOperations+Handler.swift
//  BarcelonaMautrixIPC
//
//  Created by Eric Rabil on 8/23/21.
//  Copyright © 2021 Eric Rabil. All rights reserved.
//

import Barcelona
import BarcelonaDB
import Foundation
import IMCore
import Logging
import Sentry

extension Array where Element == String {
    /// Given self is an array of chat GUIDs, masks the GUIDs to iMessage service and returns the deduplicated result
    func dedupeChatGUIDs() -> [String] {
        Array(Set(self))
    }
}

extension GetChatsCommand: Runnable {
    func run(payload: IPCPayload, ipcChannel: MautrixIPCChannel) async {
        payload.fail(strategy: .internal_error("get_chats is not supported"), ipcChannel: ipcChannel)
        /*SentrySDK.configureScope { scope in
            scope.setContext(
                value: [
                    "id": String(describing: payload.id),
                    "command": payload.command.name.rawValue,
                ],
                key: "payload"
            )
        }
        let span = SentrySDK.startTransaction(name: "GetChatsCommand", operation: "run", bindToScope: true)
        let breadcrumb = Breadcrumb(level: .debug, category: "command")
        breadcrumb.message = "GetChatsCommand/\(payload.id ?? 0)"
        breadcrumb.type = "user"
        SentrySDK.addBreadcrumb(breadcrumb)
        if min_timestamp <= 0 {
            payload.reply(
                withResponse: .chats_resolved(IMChatRegistry.shared.allChats.map(\.blChatGUID)),
                ipcChannel: ipcChannel
            )
            span.finish()
            return
        }

        do {
            let timestamps = try await DBReader.shared.latestMessageTimestamps()

            let guids =
                timestamps.mapValues { timestamp, guid in
                    (IMDPersistenceTimestampToUnixSeconds(timestamp: timestamp), guid)
                }
                .filter { chatID, pair in
                    pair.0 > min_timestamp
                }
                .map(\.value.1)

            payload.reply(withResponse: .chats_resolved(guids.dedupeChatGUIDs()), ipcChannel: ipcChannel)
            span.finish()
        } catch {
            payload.fail(strategy: .internal_error(error.localizedDescription), ipcChannel: ipcChannel)
            SentrySDK.capture(error: error)
            span.finish(status: .internalError)
        }*/
    }
}

extension GetGroupChatInfoCommand: Runnable {
    var log: Logging.Logger {
        Logger(label: "TapbackCommand")
    }
    func run(payload: IPCPayload, ipcChannel: MautrixIPCChannel) async {
        let span = SentrySDK.startIPCTransaction(forPayload: payload, uppercasedName: "GetGroupChatInfoCommand")

        log.info("Getting chat with id \(chat_guid)", source: "MautrixIPC")

        guard let chat = await blChat else {
            payload.fail(strategy: .chat_not_found, ipcChannel: ipcChannel)
            span.finish(status: .notFound)
            return
        }
        SentrySDK.configureScope { scope in
            scope.setContext(
                value: [
                    "guid": chat_guid,
                    "service": chat.service,
                ],
                key: "blchat"
            )
        }

        payload.respond(.chat_resolved(chat), ipcChannel: ipcChannel)
        span.finish()
    }
}

extension SendReadReceiptCommand: Runnable, AuthenticatedAsserting {
    var log: Logging.Logger {
        Logger(label: "TapbackCommand")
    }
    func run(payload: IPCPayload, ipcChannel: MautrixIPCChannel) async {
        let span = SentrySDK.startIPCTransaction(forPayload: payload, uppercasedName: "SendReadReceiptCommand")

        let chatGUID = await cbChat?.blChatGUID
        log.info("Sending read receipt to \(String(describing: chatGUID))", source: "MautrixIPC")

        guard let chat = await cbChat else {
            payload.fail(strategy: .chat_not_found, ipcChannel: ipcChannel)
            span.finish(status: .notFound)
            return
        }
        SentrySDK.configureScope { scope in
            scope.setContext(
                value: [
                    "id": chat.id,
                    "service": String(describing: chat.service),
                ],
                key: "chat"
            )
        }

        chat.markMessageAsRead(withID: read_up_to)
        span.finish()
    }
}

extension SendTypingCommand: Runnable, AuthenticatedAsserting {
    func run(payload: IPCPayload, ipcChannel: MautrixIPCChannel) async {
        let span = SentrySDK.startIPCTransaction(forPayload: payload, uppercasedName: "SendTypingCommand")

        guard let chat = await cbChat else {
            payload.fail(strategy: .chat_not_found, ipcChannel: ipcChannel)
            span.finish(status: .notFound)
            return
        }
        SentrySDK.configureScope { scope in
            scope.setContext(
                value: [
                    "id": chat.id,
                    "service": String(describing: chat.service),
                ],
                key: "chat"
            )
        }

        chat.setTyping(typing)
        span.finish()
    }
}

extension GetGroupChatAvatarCommand: Runnable {
    func run(payload: IPCPayload, ipcChannel: MautrixIPCChannel) async {
        let span = SentrySDK.startIPCTransaction(forPayload: payload, uppercasedName: "GetGroupChatAvatarCommand")

        guard let chat = await chat, let groupPhotoID = chat.groupPhotoID else {
            payload.respond(.chat_avatar(nil), ipcChannel: ipcChannel)
            span.finish()
            return
        }
        SentrySDK.configureScope { scope in
            scope.setContext(
                value: [
                    "id": chat.id
                ],
                key: "imchat"
            )
        }

        payload.respond(.chat_avatar(BLAttachment(guid: groupPhotoID)), ipcChannel: ipcChannel)
        span.finish()
    }
}
