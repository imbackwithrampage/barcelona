//
//  ERDaemonListener.swift
//  imessage-rest
//
//  Created by Eric Rabil on 8/11/20.
//  Copyright © 2020 Eric Rabil. All rights reserved.
//
//  CBDaemonListener is the new publisher for iMessage events. It is synchronous and does very minimal post-processing.
//
//  It does away with most foundation APIs, opting for a much more lightweight pipeline that acts as a delivery mechanism to higher-level implementations.
//

import BarcelonaDB
import Combine
import CommunicationsFilter
import Foundation
import IMCore
import IMDaemonCore
import IMFoundation
import IMSharedUtilities
import Logging

private let log = Logger(label: "ERDaemonListener")

// set to false and the logging conditions (probably) wont even compile, but they will be disabled
#if DEBUG
@usableFromInline internal let verboseLoggingEnabled = true
#else
@usableFromInline internal let verboseLoggingEnabled = true
#endif

extension String {
    fileprivate var bl_mergedID: String {
        if let lastIndex = lastIndex(of: ";") {
            return String(self[index(after: lastIndex)...])
        }

        return self
    }
}

extension IMItem {
    fileprivate var nonce: Int {
        var hasher = Hasher()
        id.hash(into: &hasher)
        type.hash(into: &hasher)
        isFromMe.hash(into: &hasher)

        switch self {
        case let item as IMMessageItem:
            item.body?.hash(into: &hasher)
            item.messageID.hash(into: &hasher)
            item.associatedMessageGUID()?.hash(into: &hasher)
        default:
            break
        }

        return hasher.finalize()
    }
}

public enum CBMessageStatusType: String, Codable {
    case delivered
    case read
    case played
    case downgraded
    case notDelivered
    case sent
}

private struct CBMessageStatusChangeContext {
    var message: IMMessageItem?
}

// Represents the different updates that are made to a message
public struct CBMessageStatusChange: Codable, Hashable {
    public static func == (lhs: CBMessageStatusChange, rhs: CBMessageStatusChange) -> Bool {
        false
    }

    fileprivate init(
        type: CBMessageStatusType,
        service: IMServiceStyle,
        time: Double,
        sender: String? = nil,
        fromMe: Bool,
        chatID: String,
        messageID: String,
        context: CBMessageStatusChangeContext = .init()
    ) {
        self.type = type
        self.service = service
        self.time = time
        self.sender = sender
        self.fromMe = fromMe
        self.chatID = chatID
        self.messageID = messageID
        self.context = context
    }

    public var type: CBMessageStatusType
    public var service: IMServiceStyle
    public var time: Double
    public var sender: String?
    public var fromMe: Bool
    public var chatID: String
    public var messageID: String

    // backing storage for the message object used to create this
    private var context: CBMessageStatusChangeContext = .init()

    public var chat: IMChat? {
        IMChat.chat(withIdentifier: chatID, onService: service, style: nil)
    }

    public var hasFullMessage: Bool {
        context.message != nil
    }

    public var message: IMMessageItem {
        context.message ?? IMMessageItem()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(service)
        hasher.combine(time)
        hasher.combine(sender)
        hasher.combine(fromMe)
        hasher.combine(chatID)
        hasher.combine(messageID)
    }

    private enum CodingKeys: String, CodingKey {
        case type, service, time, sender, fromMe, chatID, messageID
    }
}

extension Notification.Name: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}

extension CBDaemonListener {
    static var didStartListening = false
    func startListening() {
        guard CBDaemonListener.didStartListening == false else {
            return
        }

        CBDaemonListener.didStartListening = true

        _ = CBIDSListener.shared.reflectedReadReceiptPipeline.pipe { guid, service, time in
            Task {
                let chatIdentifier = try? await DBReader.shared.chatIdentifier(forMessageGUID: guid)

                log.debug(
                    "reflectedReadReceiptPipeline received guid \(guid) in chat \(String(describing: chatIdentifier))"
                )

                guard let chatIdentifier else {
                    return
                }

                self.messageStatusPipeline.send(
                    CBMessageStatusChange(
                        type: .read,
                        service: service,
                        time: time.timeIntervalSince1970,
                        fromMe: true,
                        chatID: chatIdentifier,
                        messageID: guid
                    )
                )
            }
        }

        if CBFeatureFlags.useSMSReadBuffer {
            _ = messageStatusPipeline.pipe { status in
                guard status.type == .read, status.fromMe else {
                    return
                }

                // Since this is only processing things on the SMS Read Buffer, we only want to continue
                // if we have a chat for this chatID on SMS
                guard IMChat.chat(withIdentifier: status.chatID, onService: .SMS, style: nil) != nil else {
                    return
                }

                self.pushToSMSReadBuffer(status.messageID)
            }
        }

        // Apparently in Ventura, macOS started ignoring certain chats to make the iMessage
        // service more lean, so we have to manually tell the system to listen to all of the
        // conversations that exist.
        // We're not 100% certain what will do this (listen to a conversation), so we're trying
        // all of these to see if any of them do the trick and will update later.
        if #available(macOS 13, *) {
            IMDMessageStore.sharedInstance().setSuppressDatabaseUpdates(false)

            for chat in IMChatRegistry.shared.allChats {
                chat.watchAllHandles()
            }
        }

        NotificationCenter.default.addObserver(forName: .IMAccountPrivacySettingsChanged, object: nil, queue: nil) {
            notification in
            guard let account = notification.object as? IMAccount else {
                return
            }

            guard let blockList = account.blockList as? [String] else {
                return log.debug("unexpected type for blockList: \(type(of: account.blockList))")
            }

            self.blocklistPipeline.send(blockList)
        }

        NotificationCenter.default.addObserver(forName: .IMChatJoinStateDidChange, object: nil, queue: nil) {
            notification in
            guard let chat = notification.object as? IMChat else {
                return
            }

            self.chatJoinStatePipeline.send((chat.chatIdentifier, chat.joinState))
        }

        NotificationCenter.default.addObserver(forName: .IMChatPropertiesChanged, object: nil, queue: nil) {
            notification in
            guard let chat = notification.object as? IMChat else {
                return
            }

            self.chatConfigurationPipeline.send(chat.configurationBits)
        }

        NotificationCenter.default.addObserver(forName: .IMPeopleAdded, object: nil, queue: nil) { notification in
            log.debug("IMPeopleAdded: \(notification.object), \(notification.userInfo)")
        }

        NotificationCenter.default.addObserver(forName: .IMChatRegistryDidRegisterChat, object: nil, queue: nil) {
            notification in
            log.debug("IMChatRegistryDidRegisterChat: \(notification.object), \(notification.userInfo)")
        }

        NotificationCenter.default.addObserver(forName: .IMHandleStatusChanged, object: nil, queue: nil) {
            notification in
            log.debug("IMHandleStatusChanged: \(notification.object), \(notification.userInfo)")
        }

        NotificationCenter.default.addObserver(forName: .IMChatParticipantsDidChange, object: nil, queue: nil) {
            notification in
            log.debug("IMChatParticipantsDidChange: \(notification.object), \(notification.userInfo)")
        }

        ifDebugBuild {
            _scratchboxMain()

            if CBFeatureFlags.exitAfterScratchbox {
                exit(0)
            }
        }
    }
}

@resultBuilder
struct PipelineGlobber<T> {
    static func buildBlock(_ components: CBPipeline<T>...) -> CBPipeline<T> {
        let pipeline = CBPipeline<T>()

        for component in components {
            component.pipe(pipeline.send(_:))
        }

        return pipeline
    }
}

func createPipelineGlob<T>(@PipelineGlobber<T> component: () -> CBPipeline<T>) -> CBPipeline<T> {
    return component()
}

public class OrderedDictionary<K: Hashable, V> {
    private(set) var dictionary: [K: V] = [:]
    private var orderedSet: NSMutableOrderedSet = .init()

    public var maximumCapacity: Int? = nil

    public init() {}

    public init(maximumCapacity: Int) {
        self.maximumCapacity = maximumCapacity
    }

    public subscript(_ key: K) -> V? {
        get {
            let index = orderedSet.index(of: key)
            if index != NSNotFound {
                orderedSet.moveObjects(at: IndexSet(integer: index), to: orderedSet.count - 1)
            }
            return dictionary[key]
        }
        set {
            if newValue == nil {
                orderedSet.remove(key)
                dictionary.removeValue(forKey: key)
            } else {
                let index = orderedSet.index(of: key)
                if index == NSNotFound {
                    orderedSet.add(key)
                    if let maximumCapacity = maximumCapacity, orderedSet.count == maximumCapacity,
                        let first = orderedSet.firstObject
                    {
                        orderedSet.remove(first)
                        dictionary.removeValue(forKey: first as! K)
                    }
                } else {
                    orderedSet.moveObjects(at: IndexSet(integer: index), to: orderedSet.count - 1)
                }
                dictionary[key] = newValue
            }
        }
    }

    public var count: Int {
        orderedSet.count
    }

    public func index(of key: K) -> Int {
        orderedSet.index(of: key)
    }

    public var keys: Dictionary<K, V>.Keys {
        dictionary.keys
    }

    public var values: Dictionary<K, V>.Values {
        dictionary.values
    }

    public func removeOldest(_ n: Int) {
        Array(orderedSet.prefix(n))
            .forEach { element in
                self[(element as! K)] = nil
            }
    }

    public func shrink(to size: Int) {
        let overflow = max(count - size, 0)
        guard overflow > 0 else {
            return
        }
        removeOldest(overflow)
    }
}

public class CBDaemonListener: ERBaseDaemonListener {
    public static let shared = CBDaemonListener()

    public enum PipelineEvent: Codable {
        case unreadCount(chat: String, count: Int)
        case typing(chat: String, service: IMServiceStyle, typing: Bool)
        case chatName(chat: String, name: String?)
        case chatParticipants(chat: String, participants: [String])
        case blocklist(entries: [String])
        case messagesDeleted(ids: [String])
        case chatsDeleted(chatIDs: [String])
        case chatJoinState(chat: String, joinState: IMChatJoinState)
        case message(payload: Message)
        case phantom(item: PhantomChatItem)
        case messageStatus(change: CBMessageStatusChange)
        case resetHandle(ids: [String])
        case configuration(updated: ChatConfiguration)

        static func message(_ message: Message) -> PipelineEvent {
            return .message(payload: message)
        }

        static func phantom(_ item: PhantomChatItem) -> PipelineEvent {
            return .phantom(item: item)
        }

        static func messageStatus(_ change: CBMessageStatusChange) -> PipelineEvent {
            return .messageStatus(change: change)
        }

        static func configuration(_ updated: ChatConfiguration) -> PipelineEvent {
            return .configuration(updated: updated)
        }
    }

    public let unreadCountPipeline = CBPipeline<(chat: String, count: Int)>()
    public let typingPipeline = CBPipeline<(chat: String, service: IMServiceStyle, typing: Bool)>()
    public let chatNamePipeline = CBPipeline<(chat: String, name: String?)>()
    public let chatParticipantsPipeline = CBPipeline<(chat: String, participants: [String])>()
    public let blocklistPipeline = CBPipeline<[String]>()
    public let messagesDeletedPipeline = CBPipeline<[String]>()
    public let chatsDeletedPipeline = CBPipeline<[String]>()
    public let chatJoinStatePipeline = CBPipeline<(chat: String, joinState: IMChatJoinState)>()
    public let messagePipeline = CBPipeline<Message>()
    public let phantomPipeline = CBPipeline<PhantomChatItem>()
    public let messageStatusPipeline = CBPipeline<CBMessageStatusChange>()
    public let chatConfigurationPipeline = CBPipeline<ChatConfiguration>()
    public let disconnectPipeline: CBPipeline<Void> = {
        let pipeline = CBPipeline<Void>()

        NotificationCenter.default.addObserver(forName: .IMDaemonDidDisconnect) { _ in pipeline.send(()) }

        return pipeline
    }()

    public private(set) lazy var aggregatePipeline: CBPipeline<PipelineEvent> = createPipelineGlob {
        unreadCountPipeline.pipe(PipelineEvent.unreadCount(chat:count:))
        typingPipeline.pipe(PipelineEvent.typing(chat:service:typing:))
        chatNamePipeline.pipe(PipelineEvent.chatName(chat:name:))
        chatParticipantsPipeline.pipe(PipelineEvent.chatParticipants(chat:participants:))
        blocklistPipeline.pipe(PipelineEvent.blocklist(entries:))
        messagesDeletedPipeline.pipe(PipelineEvent.messagesDeleted(ids:))
        chatsDeletedPipeline.pipe(PipelineEvent.chatsDeleted(chatIDs:))
        chatJoinStatePipeline.pipe(PipelineEvent.chatJoinState(chat:joinState:))
        messagePipeline.pipe(PipelineEvent.message(_:))
        phantomPipeline.pipe(PipelineEvent.phantom(_:))
        messageStatusPipeline.pipe(PipelineEvent.messageStatus(_:))
        chatConfigurationPipeline.pipe(PipelineEvent.configuration(_:))
    }

    private override init() {
        super.init()
    }

    public var automaticallyReconnect = true

    // Caches for determining whether an update notification is needed
    private var unreadCounts: [String: Int] = [:]
    private var displayNames: [String: String] = [:]
    private var participants: [String: [String]] = [:]

    private var currentlyTyping = Set<String>()

    // Dedupes messages sent from self - we should have a cleanup routine for this
    private var nonces = Set<Int>()

    private lazy var listenForDisconnectsOnce: Void = {
        disconnectPipeline.pipe(disconnectedFromDaemon)
    }()

    /// In the event a reflected read receipt is processed immediately before an SMS relay message, it will die. This buffer tracks the n most recent GUIDs, which should support this edge case.
    internal private(set) var smsReadBuffer: [String] = []
    internal var smsReadBufferCapacity: Int = 15 {
        didSet {
            smsReadBuffer = smsReadBuffer.suffix(smsReadBufferCapacity)
        }
    }

    private var chatIdentifierCache = OrderedDictionary<String, String>(maximumCapacity: 100)

    private func disconnectedFromDaemon() {
        log.warning("Disconnected from daemon, reconnecting.")

        IMDaemonController.shared()
            .connectToDaemon(
                withLaunch: true,
                capabilities: FZListenerCapabilities.defaults_,
                blockUntilConnected: true
            )
        IMDaemonController.shared().listener.addHandler(self)
    }

    public override func setupComplete(_ success: Bool, info: [AnyHashable: Any]!) {
        _ = listenForDisconnectsOnce  // workaround for swift murdering dispatch_once because apple

        log.debug("setup: \(success)")

        if let info = info, let dicts = (info["personMergedChats"] ?? info["chats"]) as? [[AnyHashable: Any]] {
            for dict in dicts {
                apply(serializedChat: dict, emitIfNeeded: false)
            }
        }

        if CBFeatureFlags.prewarmItemRules {
            DispatchQueue.global(qos: .background)
                .async {
                    for chat in IMChatRegistry.shared.allChats {
                        _ = chat.chatItemRules
                    }
                }
        }

        guard ProcessInfo.processInfo.environment["BLNoBlocklist"] == nil else {
            return
        }

        ERSharedBlockList()._connect()
    }

    // MARK: - Chat events

    public override func groupPhotoUpdated(
        forChatIdentifier chatIdentifier: String!,
        style: IMChatStyle,
        account: String!,
        userInfo: [AnyHashable: Any]! = [:]
    ) {
        log.debug("chat:\(String(describing: chatIdentifier)) groupPhotoUpdated")
    }

    // Properties were changed
    public override func chat(_ persistentIdentifier: String, updated updateDictionary: [AnyHashable: Any]) {
        log.debug("chat:\(persistentIdentifier) updated:\(updateDictionary.singleLineDebugDescription)")
        apply(serializedChat: updateDictionary, emitIfNeeded: true)
    }

    // Group name changed
    public override func chat(_ persistentIdentifier: String!, displayNameUpdated displayName: String?) {
        log.debug("chat:\(String(describing: persistentIdentifier)) displayNameUpdated:\(displayName ?? "nil")")
        chatNamePipeline.send((persistentIdentifier.bl_mergedID, displayName))
    }

    public override func leftChat(_ persistentIdentifier: String!) {
        log.debug("leftChat:\(String(describing: persistentIdentifier))")
    }

    public override func loadedChats(_ chats: [[AnyHashable: Any]]!) {
        log.debug("loadedChats:\(chats.count)")
    }

    // A new chat has been created
    public override func chatLoaded(withChatIdentifier chatIdentifier: String!, chats chatDictionaries: [Any]!) {
        log.debug("chatLoaded:\(String(describing: chatIdentifier)), dicts:\(chatDictionaries.count)")
        for chat in chatDictionaries {
            guard let dict = chat as? [AnyHashable: Any] else {
                continue
            }

            apply(serializedChat: dict, emitIfNeeded: false)
        }
    }

    // MARK: - Message events

    // Invoked when we send a message, either here or elsewhere
    public override func account(
        _ accountUniqueID: String,
        chat chatIdentifier: String,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any],
        groupID: String,
        chatPersonCentricID personCentricID: String!,
        messageSent msg: IMMessageItem
    ) {
        log.debug("messageSent: \(msg.singleLineDebugDescription)")
        chatIdentifierCache[msg.id] = chatIdentifier
        process(newMessage: msg, chatIdentifier: chatIdentifier)
    }

    // Invoked when we sent a message *locally*
    public override func account(
        _ accountUniqueID: String!,
        chat chatIdentifier: String!,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any]!,
        notifySentMessage msg: IMMessageItem!,
        sendTime: NSNumber!
    ) {
        log.debug("notifySentMessage: \(msg.singleLineDebugDescription)")
        process(sentMessage: msg, sentTime: (msg.clientSendTime ?? msg.time ?? Date()).timeIntervalSince1970)
    }

    public override func account(
        _ accountUniqueID: String,
        chat chatIdentifier: String,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any],
        groupID: String,
        chatPersonCentricID personCentricID: String,
        messageReceived msg: IMItem
    ) {
        log.debug("messageReceived: \(msg.singleLineDebugDescription)")

        process(newMessage: msg, chatIdentifier: chatIdentifier)
    }

    public override func account(
        _ accountUniqueID: String,
        chat chatIdentifier: String,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any],
        groupID: String,
        chatPersonCentricID personCentricID: String,
        messagesReceived messages: [IMItem],
        messagesComingFromStorage fromStorage: Bool
    ) {
        log.debug("messagesReceived: \(messages.singleLineDebugDescription)")

        for message in messages {
            process(newMessage: message, chatIdentifier: chatIdentifier)
        }
    }

    public override func account(
        _ accountUniqueID: String!,
        chat chatIdentifier: String!,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any]!,
        groupID: String!,
        chatPersonCentricID personCentricID: String!,
        messagesReceived messages: [IMItem]!
    ) {
        log.debug("messagesReceived: \(messages.singleLineDebugDescription)")

        for message in messages {
            process(newMessage: message, chatIdentifier: chatIdentifier)
        }
    }

    // Invoked for status updates (read/deliver/play/save/edit etc)
    public override func service(
        _ serviceID: String!,
        chat chatIdentifier: String!,
        style chatStyle: IMChatStyle,
        messagesUpdated messages: [[AnyHashable: Any]]!
    ) {
        log.debug("messagesUpdated[service]: \(messages.debugDescription.singleLineDebugDescription)")

        for message in CBCreateItemsFromSerializedArray(messages) {
            switch message {
            case let message as IMMessageItem:
                self.process(serviceMessage: message, chatIdentifier: chatIdentifier, chatStyle: chatStyle)
            default:
                return
            }
        }
    }

    public override func account(
        _ accountUniqueID: String!,
        chat chatIdentifier: String!,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any]!,
        messageUpdated msg: IMItem!
    ) {
        account(
            accountUniqueID,
            chat: chatIdentifier,
            style: chatStyle,
            chatProperties: properties,
            messagesUpdated: [msg]
        )
    }

    public override func account(
        _ accountUniqueID: String!,
        chat chatIdentifier: String!,
        style chatStyle: IMChatStyle,
        chatProperties properties: [AnyHashable: Any]!,
        messagesUpdated messages: [NSObject]!
    ) {
        log.debug("messagesUpdated[account]: \(messages.debugDescription.singleLineDebugDescription)")

        for message in messages as? [IMItem] ?? CBCreateItemsFromSerializedArray(messages) {
            switch message {
            case let message as IMMessageItem:
                // This listener call is only for failed messages that are not otherwise caught.
                guard message.errorCode != .noError else {
                    log.debug(
                        "messagesUpdated[account]: ignoring message \(message.id) because it has no error. it will flow through another handler."
                    )
                    continue
                }
                guard
                    let chatIdentifier = chatIdentifier
                        ?? DBReader.shared.immediateChatIdentifier(forMessageGUID: message.id)
                else {
                    continue
                }
                self.process(newMessage: message, chatIdentifier: chatIdentifier)
            default:
                continue
            }
        }
    }

    public override func historicalMessageGUIDsDeleted(_ deletedGUIDs: [String], chatGUIDs: [String], queryID: String!)
    {
        if deletedGUIDs.count > 0 {
            messagesDeletedPipeline.send(deletedGUIDs)
        }

        if chatGUIDs.count > 0 {
            chatsDeletedPipeline.send(chatGUIDs)
        }
    }

    // MARK: - File Transfers

    public override func fileTransfer(_ guid: String!, createdWithProperties properties: [AnyHashable: Any]!) {
        _ = CBPurgedAttachmentController.shared.process(transferIDs: [guid])
    }

    public override func fileTransfer(_ guid: String!, updatedWithProperties properties: [AnyHashable: Any]!) {
        _ = CBPurgedAttachmentController.shared.process(transferIDs: [guid])
    }
}

// MARK: - Chat Logic

extension CBDaemonListener {
    fileprivate func previousUnreadCount(forChatIdentifier chatIdentifier: String) -> Int {
        unreadCounts[chatIdentifier] ?? 0
    }

    fileprivate func extractParticipants(_ value: Any?) -> [String] {
        guard let array = value as? [NSDictionary] else {
            return []
        }

        return array.compactMap {
            $0["FZPersonID"] as? String
        }
    }

    fileprivate func apply(serializedChat dict: [AnyHashable: Any], emitIfNeeded: Bool = true) {
        guard let chatIdentifier = dict["chatIdentifier"] as? String else {
            log.debug("couldn't find chatIdentifier in serialized chat!")
            log.debug("\(dict.debugDescription)")
            return
        }

        if let unreadCount = (dict["unreadCount"] as? NSNumber)?.intValue {
            let previousUnreadCount = previousUnreadCount(forChatIdentifier: chatIdentifier)
            unreadCounts[chatIdentifier] = unreadCount

            if emitIfNeeded && previousUnreadCount != unreadCount {
                unreadCountPipeline.send((chatIdentifier, unreadCount))
            }
        }

        let displayName = dict["displayName"] as? String
        let previousDisplayName = displayNames[chatIdentifier]
        displayNames[chatIdentifier] = displayName

        if emitIfNeeded && previousDisplayName != displayName {
            chatNamePipeline.send((chatIdentifier, displayName))
        }

        apply(
            chatIdentifier: chatIdentifier,
            participants: extractParticipants(dict["participants"]),
            emitIfNeeded: emitIfNeeded
        )
    }

    fileprivate func apply(chatIdentifier: String, participants chatParticipants: [String], emitIfNeeded: Bool = true) {
        let previousParticipants = participants[chatIdentifier] ?? []
        participants[chatIdentifier] = chatParticipants

        if emitIfNeeded && previousParticipants != chatParticipants {
            chatParticipantsPipeline.send((chatIdentifier, chatParticipants))
        }
    }
}

// MARK: - Message Handling

extension CBDaemonListener {
    private func preflight(message: IMItem) -> Bool {
        lazy var messageItem: IMMessageItem? = message as? IMMessageItem
        lazy var sendProgress = messageItem?.sendProgress

        if CBFeatureFlags.withholdDupes, nonces.contains(message.nonce) {
            // only let failed messages emit more than once, as failed messages may not first fail with their error code
            guard sendProgress == .failed else {
                log.debug("withholding message \(String(describing: message.guid)): dedupe")
                return false
            }
        }

        guard message.isFromMe, let message = messageItem else {
            // passthrough!
            nonces.insert(message.nonce)
            return true
        }

        if sendProgress == .failed, message.errorCode == .noError, CBFeatureFlags.withholdPartialFailures {
            log.debug(
                "withholding message \(String(describing: message.guid)): missing error code, message is either still in progress or the error code is coming soon"
            )
            return false
        }

        return true
    }

    fileprivate func process(sentMessage message: IMMessageItem, sentTime: Double) {
        guard
            let chatID = chatIdentifierCache[message.id]
                ?? DBReader.shared.immediateChatIdentifier(forMessageGUID: message.id)
        else {
            log.error("Failed to resolve chat identifier for sent message \(message.id)")
            return
        }

        guard let service = IMServiceStyle(rawValue: message.service) else {
            log.error("Cannot process sentMessage \(message): service is not a known value")
            return
        }

        messageStatusPipeline.send(
            CBMessageStatusChange(
                type: .sent,
                service: service,
                time: sentTime,
                sender: nil,
                fromMe: true,
                chatID: chatID,
                messageID: message.id,
                context: .init(message: message)
            )
        )
    }

    fileprivate func recover(failedMessage: IMMessageItem, chatIdentifier: String) -> Bool {
        lazy var chat = IMChatRegistry.shared.existingChat(withChatIdentifier: chatIdentifier)

        switch failedMessage.errorCode {
        case .remoteUserDoesNotExist:
            guard failedMessage.serviceStyle == .iMessage else {
                log.info(
                    "Message \(failedMessage.id) failed with remoteUserDoesNotExist but it is not on iMessage. I can't fix this."
                )
                return false
            }
            guard let chat = chat, chat.participantHandleIDs().allSatisfy({ $0.isPhoneNumber || $0.isEmail }) else {
                log.info(
                    "Message \(failedMessage.id) failed with remoteUserDoesNotExist but I could not guarantee that the chat is downgradeable. I won't fix this."
                )
                return false
            }
            log.info("Downgrading failed message \(failedMessage.id) to SMS")
            if chat.participants.count == 1 {
                let manualDowngradesCount = chat._consecutiveDowngradeAttempts(viaManualDowngrades: true) as? Int ?? 0
                if manualDowngradesCount > 5 {
                    log.info(
                        "Chat \(chatIdentifier) has had five consecutive downgrade attempts, persisting the downgrade."
                    )
                    chat._updateDowngradeState(true, checkAgainInterval: 10)
                } else {
                    log.info("Incrementing downgrade counter for chat \(chatIdentifier)")
                    chat._setAndIncrementDowngradeMarkers(forManual: true)
                }
            }
            chat._target(toService: IMServiceImpl.sms(), newComposition: false)
            var flags = IMMessageFlags(rawValue: failedMessage.flags)
            flags.insert(.downgraded)
            nonces.remove(failedMessage.nonce)
            failedMessage._updateFlags(flags.rawValue)
            failedMessage.service = "SMS"
            failedMessage.account = IMAccountController.shared.activeSMSAccount!.uniqueID
            chat.send(
                IMMessage.init(
                    fromIMMessageItem: failedMessage,
                    sender: failedMessage.sender(),
                    subject: failedMessage.subject
                )
            )
            return true
        default:
            return false
        }
    }

    fileprivate func process(newMessage: IMItem, chatIdentifier: String) {
        if !preflight(message: newMessage) {
            log.warning("withholding message \(String(describing: newMessage.guid)): preflight failure")
            return
        }

        guard let serv = newMessage.service, let service = IMServiceStyle(rawValue: serv) else {
            log.warning(
                "Couldn't form relevant service from \(String(describing: newMessage.service)); ignoring message \(String(describing: newMessage.guid))"
            )
            return
        }

        var currentlyTyping: Bool {
            get { self.currentlyTyping.contains(chatIdentifier) }
            set {
                if newValue {
                    if self.currentlyTyping.insert(chatIdentifier).inserted {
                        typingPipeline.send((chatIdentifier, service, true))
                    }
                } else {
                    if self.currentlyTyping.remove(chatIdentifier) != nil {
                        typingPipeline.send((chatIdentifier, service, false))
                    }
                }
            }
        }

        switch newMessage {
        case let item as IMMessageItem:
            currentlyTyping = item.isIncomingTypingMessage() && !item.isCancelTypingMessage()

            // typing messages are not part of the timeline anymore
            if item.isTypingMessage {
                log.debug("ignoring message \(String(describing: item.guid)): typing doesnt flow through here")
                return
            }

            if CBFeatureFlags.dropSpamMessages, item.isSpam {
                log.debug("ignoring message \(String(describing: item.guid)): flagged as spam")
                return
            }

            if item.errorCode == .remoteUserDoesNotExist {
                return
            }

            log.debug(
                "sending message \(String(describing: item.guid)) \(String(describing: item.service)) \(chatIdentifier) down the pipeline"
            )
            messagePipeline.send(Message(messageItem: item, chatID: chatIdentifier, service: service))
        case let item:
            // wrap non-message items and send them as transcript actions
            switch transcriptRepresentation(item, chatID: chatIdentifier) {
            case let phantom as PhantomChatItem:
                phantomPipeline.send(phantom)
            case let representation:
                var additionalFileTransfers = [String]()

                switch representation {
                case let participantChange as ParticipantChangeItem:
                    guard let targetID = participantChange.targetID, var chatParticipants = participants[chatIdentifier]
                    else {
                        break
                    }

                    // Apply participant change to the cached participants and emit if needed
                    if participantChange.changeType == 0 && !chatParticipants.contains(targetID) {
                        chatParticipants.append(targetID)
                        apply(chatIdentifier: chatIdentifier, participants: chatParticipants, emitIfNeeded: true)
                    } else if participantChange.changeType == 1 && chatParticipants.contains(targetID) {
                        chatParticipants.removeAll(where: { $0 == targetID })
                        apply(chatIdentifier: chatIdentifier, participants: chatParticipants, emitIfNeeded: true)
                    }
                case let groupAction as GroupActionItem:
                    if groupAction.actionType.rawValue == 1,
                        let groupPhoto = IMChat.chat(withIdentifier: chatIdentifier, onService: service, style: nil)?
                            .groupPhotoID
                    {
                        additionalFileTransfers.append(groupPhoto)
                    }
                default:
                    break
                }

                messagePipeline.send(
                    Message(
                        item,
                        transcriptRepresentation: representation,
                        service: service,
                        additionalFileTransferGUIDs: additionalFileTransfers
                    )
                )
            }
        }
    }

    private func transcriptRepresentation(_ item: IMItem, chatID: String) -> ChatItem {
        switch item {
        case let item as IMParticipantChangeItem:
            return ParticipantChangeItem(item, chatID: chatID)
        case let item as IMGroupTitleChangeItem:
            return GroupTitleChangeItem(item, chatID: chatID)
        case let item as IMGroupActionItem:
            return GroupActionItem(item, chatID: chatID)
        default:
            return PhantomChatItem(item, chatID: chatID)
        }
    }
}

// MARK: - Service Messages

extension IMMessageItem {
    private var statusPayload: (type: CBMessageStatusType, time: Date)? {
        if errorCode.rawValue > 0 {
            return (.notDelivered, time)
        }

        if let timePlayed = timePlayed {
            return (.played, timePlayed)
        } else if let timeRead = timeRead {
            return (.read, timeRead)
        } else if let timeDelivered = timeDelivered {
            return (.delivered, timeDelivered)
        } else if wasDowngraded {
            return (.downgraded, time)
        } else {
            return nil
        }
    }

    fileprivate func statusChange(inChat chat: String, style: IMChatStyle) -> CBMessageStatusChange? {
        guard let payload = statusPayload, let service = IMServiceStyle(rawValue: service) else {
            return nil
        }

        var canBeFromOthers: Bool {
            style == .instantMessage
        }

        var fromMe: Bool {
            if style == .group {
                return payload.type != .played
            } else {
                switch payload.type {
                case .read:
                    if isFromMe() {
                        return false  // other user just read our message
                    } else {
                        return true  // we just read the chat
                    }
                case .delivered:
                    return false
                case .played:
                    return false
                case .downgraded:
                    return true
                case .notDelivered:
                    return true
                case .sent:
                    return true
                }
            }
        }

        /// Sender of the receipt, not sender of the message
        var sender: String? {
            if fromMe {
                return nil
            }

            if style == .group {
                return resolveSenderID(inService: serviceStyle)
            } else {
                return chat  // chat identifier for DM is just the recipient
            }
        }

        return CBMessageStatusChange(
            type: payload.type,
            service: service,
            time: payload.time.timeIntervalSince1970 * 1000,
            sender: sender,
            fromMe: fromMe,
            chatID: chat,
            messageID: id,
            context: CBMessageStatusChangeContext(message: self)
        )
    }
}

extension CBDaemonListener {
    fileprivate func process(serviceMessage message: IMMessageItem, chatIdentifier: String, chatStyle: IMChatStyle) {
        guard let messageStatus = message.statusChange(inChat: chatIdentifier, style: chatStyle) else {
            return
        }

        if CBFeatureFlags.dropSpamMessages, message.isSpam {
            return
        }

        messageStatusPipeline.send(messageStatus)
    }
}

extension CBDaemonListener {
    func flushSMSReadBuffer() {
        smsReadBuffer.removeAll()
    }

    func pushToSMSReadBuffer(_ guid: String) {
        guard CBFeatureFlags.useSMSReadBuffer, !smsReadBuffer.contains(guid) else {
            return
        }
        log.debug("Adding \(guid) to sms read buffer", source: "ReadState")
        smsReadBuffer.append(guid)
        if smsReadBuffer.count > smsReadBufferCapacity {
            smsReadBuffer = smsReadBuffer.suffix(smsReadBufferCapacity)
        }
    }
}
