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
        var speed: Double = 0      // bytes/sec (0 = unknown)
        var etaDate: Date? = nil   // projected completion time, for a live countdown
        var incoming: Bool = false // true = saving back to iPhone, false = sending to Mac
    }

    var serverName: String        // the computer being sent to
}
