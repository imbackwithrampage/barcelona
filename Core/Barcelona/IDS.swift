////  IDS.swift
//  Barcelona
//
//  Created by Eric Rabil on 9/3/21.
//  Copyright © 2021 Eric Rabil. All rights reserved.
//

import Foundation
import IDS
import IDSFoundation
import Logging
import CommonUtilities

private let log = Logger(label: "IDS")

public enum IDSState: Int, Codable {
    /// the state has either not been resolved or failed to resolve
    case unknown = 0
    /// this destination can be reached on this service
    case available = 1
    /// this destination can not and will not be reached on this service
    case unavailable = 2

    public var isAvailable: Bool {
        self == .available
    }

    public init(rawValue: Int) {
        switch rawValue {
        case 1: self = .available
        case 2: self = .unavailable
        default: self = .unknown
        }
    }

    public init(rawValue: Int64) {
        self = .init(rawValue: Int(rawValue))
    }
}

extension IDSState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown: return "unknown"
        case .available: return "available"
        case .unavailable: return "unavailable"
        }
    }
}

class BLIDSIDQueryCache {
    static let shared = BLIDSIDQueryCache()

    let defaults = UserDefaults(suiteName: "com.ericrabil.barcelona.id-query")!
    private var results: [String: (Date, IDSState)] = [:]
    private let resultsLock = NSRecursiveLock()

    static let queryValidityDuration: TimeInterval = 1 * 60 * 60 * 1.5

    func result(for destination: String) -> IDSState? {
        if let (date, result) = resultsLock.withLock({ results[destination] }) {
            if abs(date.timeIntervalSinceNow) < Self.queryValidityDuration {
                return result
            }
        }
        if let dict = defaults.dictionary(forKey: destination),
            let date = dict["date"] as? Date,
            abs(date.timeIntervalSinceNow) < Self.queryValidityDuration,
            let result = dict["result"] as? IDSState.RawValue
        {
            let state = IDSState(rawValue: result)
            resultsLock.withLock {
                results[destination] = (date, state)
            }
            return state
        }
        return nil
    }

    func cache(_ result: IDSState, for destination: String, time: Date = Date()) {
        defaults.set(
            [
                "result": result.rawValue,
                "date": time,
            ],
            forKey: destination
        )
        resultsLock.withLock {
            results[destination] = (time, result)
        }
    }
}

/// Asynchronously resolves the latest IDS status for a set of handles on a given service, defaulting to iMessage.
func BLResolveIDStatusForIDs(
    _ ids: [String],
    onService service: IMServiceStyle,
    _ callback: @escaping ([String: IDSState]) -> Void
) throws {
    var allUnavailable: [String: IDSState] {
        ids.map {
            ($0, IDSState.unavailable)
        }
        .dictionary(keyedBy: \.0, valuedBy: \.1)
    }

    switch service {
    case .SMS:
        guard Registry.sharedInstance.smsServiceEnabled else {
            log.info("Bailing SMS IDS query, sms service is not enabled.")
            return callback(allUnavailable)
        }

        return callback(
            ids.map {
                ($0, ($0.isPhoneNumber /*|| $0.isEmail*/) ? IDSState.available : IDSState.unavailable)
            }
            .dictionary(keyedBy: \.0, valuedBy: \.1)
        )
    case .Phone:
        guard Registry.sharedInstance.callServiceEnabled else {
            log.info("Bailing phone IDS query, calling is not enabled.")
            return callback(allUnavailable)
        }

        return callback(
            ids.map {
                ($0, $0.isPhoneNumber ? IDSState.available : IDSState.unavailable)
            }
            .dictionary(keyedBy: \.0, valuedBy: \.1)
        )
    // only imessage and facetime will return results from IDS
    case .iMessage:
        break
    case .FaceTime:
        break
    }

    let destinations = ids.compactMap(\.destination)

    if destinations.count != ids.count {
        log.warning("Some IDs are malformed and will not be queried, partial results will be returned")
    }

    guard !destinations.isEmpty else {
        return callback([:])
    }

    log.info(
        "Requesting ID status from cache for destinations \(destinations.joined(separator: ",")) on service \(service.idsIdentifier)"
    )

    // Get all the destinations that we have cached values for
    let cached: [String: IDSState] = Dictionary(uniqueKeysWithValues: destinations.compactMap { dest in
        BLIDSIDQueryCache.shared.result(for: dest).map { (dest, $0) }
    })

    log.info("Got cached results for \(cached)")

    // If we already got all of the results from the cache, then just return them
    guard cached.count < destinations.count else {
        return callback(cached.mapKeys(\.idsURIStripped))
    }

    log.info(
        "Requesting ID status from server for destinations \(destinations.joined(separator: ",")) on service \(service.idsIdentifier)"
    )

    let completion: ([String: IDSState]) -> () = { mappedStates in
        // And then save them to the cache
        lazy var now = Date()
        for state in mappedStates {
            BLIDSIDQueryCache.shared.cache(state.value, for: state.key, time: now)
        }

        // And return them in the callback
        log.debug("forceRefreshIDStatus completed with result: \(mappedStates)")
        callback(mappedStates.mapKeys(\.idsURIStripped))
    }

    let sharedController: IDSIDQueryController = IDSIDQueryController.sharedInstance()!

    if #available(macOS 13.0, *) {
        sharedController.idInfo(
            forDestinations: destinations,
            service: service.idsIdentifier,
            // I don't quite know what `infoTypes` is asking for, but ChatKit passes in 0x2
            infoTypes: 0x2,
            options: .refreshIDInfo(),
            listenerID: IDSListenerID,
            queue: HandleQueue
        ) {
            callback($0.mapValues { IDSState(rawValue: $0.status()) })
        }
    } else {
        sharedController.forceRefreshIDStatus(
            forDestinations: destinations,
            service: service.idsIdentifier,
            listenerID: IDSListenerID,
            queue: HandleQueue
        ) { states in
            completion(states.mapValues { IDSState.init(rawValue: $0.intValue) })
        }
    }
}

/// Helper variables when processing string IDs into IDS destinations
extension String {
    fileprivate var destination: String? {
        switch style {
        case .email: return IDSCopyIDForEmailAddress(self as CFString)
        case .businessID: return IDSCopyIDForBusinessID(self as CFString)
        case .phoneNumber: return IDSCopyIDForPhoneNumber(self as CFString)
        case .unknown:
            log.warning("\(self) will not be queried because it is an unrecognized address")
            return nil
        }
    }
}

/// Helper functions for processing IDS results
extension Dictionary {
    fileprivate func mapKeys<NewKey: Hashable>(_ transform: (Key) throws -> NewKey) rethrows -> [NewKey: Value] {
        var newDictionary: [NewKey: Value] = [:]

        try forEach { key, value in
            newDictionary[try transform(key)] = value
        }

        return newDictionary
    }
}

extension String {
    /// Strips the URI prefix that IDS appends to destinations
    fileprivate var idsURIStripped: String {
        IDSURI(prefixedURI: self)?.unprefixedURI ?? self
    }
}
