//
//  ShareSheet.swift
//  DropSwift
//
//  Thin UIKit wrapper so we can present the system share sheet to save
//  a downloaded file into Files, Photos, etc.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
