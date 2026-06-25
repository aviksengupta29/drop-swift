//
//  TransferActivityAttributes.swift
//  DropSwift
//
//  Shared between the app (which starts/updates the Live Activity) and the
//  widget extension (which renders the Dynamic Island + Lock Screen UI).
//
//  NOTE: add this file to BOTH the app target AND the widget extension target
//  (File Inspector → Target Membership).
//

import ActivityKit
import Foundation

struct TransferActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var completed: Int
        var total: Int
        var fraction: Double      // 0...1 overall progress
        var currentName: String
        var done: Bool
    }

    var serverName: String        // the computer being sent to
}
