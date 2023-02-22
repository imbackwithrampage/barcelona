//
//  BLChat.swift
//  BarcelonaMautrixIPC
//
//  Created by Eric Rabil on 5/24/21.
//  Copyright © 2021 Eric Rabil. All rights reserved.
//

import Barcelona
import Foundation
import IMCore

extension IMChat {
    public var blChat: BLChat {
        BLChat(
            chat_guid: blChatGUID,
            title: displayName,
            members: participants.map(\.id)
        )
    }
}

public struct BLChat: Codable, ChatResolvable {
    public var chat_guid: String
    public var title: String?
    public var members: [String]
}
