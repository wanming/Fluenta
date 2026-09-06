import AppKit
import SwiftUI

/// Optional, synthetic offscreen fixtures. No app launch, user data or permissions.
@MainActor
enum LocalizationSnapshot {
    static func record(
        _ view: some View,
        name: String,
        size: NSSize? = nil
    ) throws {
        guard ProcessInfo.processInfo.environment["INKLET_LOCALIZATION_SNAPSHOT_DIR"] != nil else {
            return
        }
        let host = NSHostingView(rootView: view)
        let contentSize = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: contentSize)
        try record(host, name: name)
    }

    static func record(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["INKLET_LOCALIZATION_SNAPSHOT_DIR"] else {
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.bounds.size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name).appendingPathExtension("png"))
        let dimensions = try JSONSerialization.data(withJSONObject: [
            "width": host.bounds.width, "height": host.bounds.height
        ])
        try dimensions.write(to: folder.appendingPathComponent(name).appendingPathExtension("json"))
    }
}
