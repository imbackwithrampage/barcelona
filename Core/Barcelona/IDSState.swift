//
//  IDSState.swift
//  Barcelona
//
//  Created by Joonas Myhrberg on 27.3.2023.
//

import Foundation

enum IDSState: Int, Codable, CustomStringConvertible {
    /// the state has either not been resolved or failed to resolve
    case unknown = 0
    /// this destination can be reached on this service
    case available = 1
    /// this destination can not and will not be reached on this service
    case unavailable = 2

    var isAvailable: Bool {
        self == .available
    }

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .available
        case 2: self = .unavailable
        default: self = .unknown
        }
    }

    var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .available:
            return "available"
        case .unavailable:
            return "unavailable"
        }
    }
}
