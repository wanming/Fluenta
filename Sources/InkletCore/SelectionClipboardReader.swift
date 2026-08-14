import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum SelectionCopyMenuActionResult: Equatable, Sendable {
    case performed
    case noMenuItem
    case disabled
    case failed(String)
}

@MainActor
public final class SelectionClipboardReader {
    public static let generatedCopyEventUserData: Int64 = 0x494E4B4C45544350

    public typealias TrustChecker = @MainActor () -> Bool
    public typealias CopyMenuActionPerformer = @MainActor (pid_t) -> SelectionCopyMenuActionResult
    public typealias CopyShortcutSender = @MainActor (CGEventSource?) throws -> Void
    public typealias DelayProvider = @MainActor (UInt64) async -> Void
    public typealias ShortcutReadWrapper = @MainActor (@escaping @MainActor () async -> String?) async -> String?
    public typealias ActiveProcessIdentifierProvider = @MainActor () -> pid_t?

    private let pasteboard: NSPasteboard
    private let clipboardService: ClipboardService
    private let eventSource: CGEventSource?
    private let activeProcessIdentifierProvider: ActiveProcessIdentifierProvider
    private let pollIntervalNanoseconds: UInt64
    private let pollTimeoutNanoseconds: UInt64
    private let isTrusted: TrustChecker
    private let copyMenuActionPerformer: CopyMenuActionPerformer
    private let copyShortcutSender: CopyShortcutSender
    private let delayProvider: DelayProvider
    private let shortcutReadWrapper: ShortcutReadWrapper

    public init(
        pasteboard: NSPasteboard = .general,
        eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState),
        activeProcessIdentifierProvider: @escaping ActiveProcessIdentifierProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        pollTimeoutNanoseconds: UInt64 = 400_000_000,
        isTrusted: @escaping TrustChecker = { AXIsProcessTrusted() },
        copyMenuActionPerformer: @escaping CopyMenuActionPerformer = {
            SelectionClipboardReader.systemPerformCopyMenuAction(sourceProcessIdentifier: $0)
        },
        copyShortcutSender: @escaping CopyShortcutSender = {
            try SelectionClipboardReader.systemSendCopyShortcut(eventSource: $0)
        },
        delayProvider: @escaping DelayProvider = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        shortcutReadWrapper: @escaping ShortcutReadWrapper = { operation in
            await SelectionClipboardReader.systemWithMutedAlertVolume(operation)
        }
    ) {
        self.pasteboard = pasteboard
        self.clipboardService = ClipboardService(pasteboard: pasteboard)
        self.eventSource = eventSource
        self.activeProcessIdentifierProvider = activeProcessIdentifierProvider
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.pollTimeoutNanoseconds = pollTimeoutNanoseconds
        self.isTrusted = isTrusted
        self.copyMenuActionPerformer = copyMenuActionPerformer
        self.copyShortcutSender = copyShortcutSender
        self.delayProvider = delayProvider
        self.shortcutReadWrapper = shortcutReadWrapper
    }

    public func readSelectedText(
        sourceProcessIdentifier: pid_t?,
        forceSelectionMode: SelectionForceSelectionMode = .menuCopyOnly,
        allowsSimulatedCopyFallback: Bool = false
    ) async -> SelectedTextReadResult {
        guard let sourceProcessIdentifier else {
            return .unsupported
        }

        guard forceSelectionMode != .disabled else {
            return .unsupported
        }

        return await readSelectedTextByMenuAction(
            sourceProcessIdentifier: sourceProcessIdentifier,
            fallbackToShortcut: allowsSimulatedCopyFallback
        )
    }

    private func readSelectedTextByMenuAction(
        sourceProcessIdentifier: pid_t,
        fallbackToShortcut: Bool
    ) async -> SelectedTextReadResult {
        var menuActionResult = SelectionCopyMenuActionResult.noMenuItem
        let menuActionText = await readPasteboardText {
            menuActionResult = self.copyMenuActionPerformer(sourceProcessIdentifier)
            return menuActionResult == .performed
        }
        switch menuActionResult {
        case .performed:
            if let text = menuActionText {
                return .success(text)
            }
            return .emptySelection
        case .noMenuItem:
            return fallbackToShortcut
                ? await readSelectedTextByShortcut(sourceProcessIdentifier: sourceProcessIdentifier)
                : .unsupported
        case .disabled:
            return .emptySelection
        case .failed(let message):
            return .failed(message)
        }
    }

    public static func systemPerformCopyMenuAction(sourceProcessIdentifier: pid_t) -> SelectionCopyMenuActionResult {
        guard AXIsProcessTrusted() else {
            return .failed("Accessibility permission is required for menu copy.")
        }

        let applicationElement = AXUIElementCreateApplication(sourceProcessIdentifier)
        guard let menuBar = copyAttribute(
            kAXMenuBarAttribute as String,
            from: applicationElement
        ) as AXUIElement? else {
            return .noMenuItem
        }

        guard let copyItem = findCopyMenuItem(in: menuBar) else {
            return .noMenuItem
        }

        guard enabledAttribute(from: copyItem) != false else {
            return .disabled
        }

        let status = AXUIElementPerformAction(copyItem, kAXPressAction as CFString)
        guard status == .success else {
            return .failed("Copy menu action failed with status \(status.rawValue).")
        }

        return .performed
    }

    public static func systemSendCopyShortcut(eventSource: CGEventSource?) throws {
        guard let eventSource else {
            throw SelectionClipboardReaderError.cannotCreateCopyEvent
        }

        let events = try makeCopyShortcutEvents(eventSource: eventSource)
        events.keyDown.post(tap: .cghidEventTap)
        events.keyUp.post(tap: .cghidEventTap)
    }

    static func makeCopyShortcutEvents(
        eventSource: CGEventSource
    ) throws -> (keyDown: CGEvent, keyUp: CGEvent) {
        guard let keyDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 0x08,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 0x08,
            keyDown: false
        ) else {
            throw SelectionClipboardReaderError.cannotCreateCopyEvent
        }

        for event in [keyDown, keyUp] {
            event.flags = .maskCommand
            event.setIntegerValueField(
                .eventSourceUserData,
                value: generatedCopyEventUserData
            )
        }
        return (keyDown, keyUp)
    }

    private func readSelectedTextByShortcut(
        sourceProcessIdentifier: pid_t
    ) async -> SelectedTextReadResult {
        guard isTrusted() else {
            return .permissionDenied
        }

        var sourceWasActive = true
        let text = await shortcutReadWrapper {
            await self.readPasteboardText {
                guard self.activeProcessIdentifierProvider() == sourceProcessIdentifier else {
                    sourceWasActive = false
                    return false
                }
                try self.copyShortcutSender(self.eventSource)
                return true
            }
        }

        guard sourceWasActive else {
            return .unsupported
        }
        guard let text else {
            return .emptySelection
        }
        return .success(text)
    }

    private func readPasteboardText(after action: @MainActor () throws -> Bool) async -> String? {
        let snapshot = clipboardService.save()
        let initialChangeCount = pasteboard.changeCount

        do {
            guard try action() else {
                _ = clipboardService.restore(snapshot)
                return nil
            }
        } catch {
            _ = clipboardService.restore(snapshot)
            return nil
        }

        var elapsedNanoseconds: UInt64 = 0
        while elapsedNanoseconds < pollTimeoutNanoseconds {
            if Task.isCancelled {
                break
            }

            if pasteboard.changeCount != initialChangeCount,
               let text = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                _ = clipboardService.restore(snapshot)
                return text
            }

            let nextDelay = min(pollIntervalNanoseconds, pollTimeoutNanoseconds - elapsedNanoseconds)
            await delayProvider(nextDelay)
            elapsedNanoseconds += nextDelay
        }

        _ = clipboardService.restore(snapshot)
        return nil
    }

    public static func systemWithMutedAlertVolume(
        _ operation: @escaping @MainActor () async -> String?
    ) async -> String? {
        let originalVolume = currentAlertVolume()
        if originalVolume != nil {
            setAlertVolume(0)
        }

        let result = await operation()

        if let originalVolume, originalVolume > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                setAlertVolume(originalVolume)
            }
        }

        return result
    }

    private static func currentAlertVolume() -> Int? {
        let script = NSAppleScript(source: "return alert volume of (get volume settings)")
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo).stringValue
        return result.flatMap(Int.init)
    }

    private static func setAlertVolume(_ volume: Int) {
        let clampedVolume = max(0, min(100, volume))
        let script = NSAppleScript(source: "set volume alert volume \(clampedVolume)")
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
    }

    private static func findCopyMenuItem(in menuBar: AXUIElement) -> AXUIElement? {
        let menuChildren = childElements(from: menuBar)
        let orderedIndexes = adjacentIndexes(count: menuChildren.count, preferredIndex: 3)

        for index in orderedIndexes {
            if let copyItem = firstCopyMenuItem(in: menuChildren[index]) {
                return copyItem
            }
        }

        return firstCopyMenuItem(in: menuBar)
    }

    private static func firstCopyMenuItem(in root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visitedCount = 0

        while !queue.isEmpty, visitedCount < 256 {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1

            if isCopyMenuItem(element) {
                return element
            }

            guard depth < 8 else {
                continue
            }

            for child in childElements(from: element).prefix(32) {
                queue.append((child, depth + 1))
            }
        }

        return nil
    }

    private static func isCopyMenuItem(_ element: AXUIElement) -> Bool {
        if stringAttribute("AXIdentifier", from: element) == "copy:" {
            return true
        }

        guard let command = stringAttribute("AXMenuItemCmdChar", from: element),
              command.caseInsensitiveCompare("C") == .orderedSame,
              let title = stringAttribute(kAXTitleAttribute as String, from: element)
        else {
            return false
        }

        return copyMenuTitles.contains(title)
    }

    private static func adjacentIndexes(count: Int, preferredIndex: Int) -> [Int] {
        guard count > 0 else {
            return []
        }

        var indexes: [Int] = []
        let startIndex = min(max(preferredIndex, 0), count - 1)
        indexes.append(startIndex)

        for offset in 1...max(startIndex, count - startIndex - 1) {
            let leftIndex = startIndex - offset
            if leftIndex >= 0 {
                indexes.append(leftIndex)
            }

            let rightIndex = startIndex + offset
            if rightIndex < count {
                indexes.append(rightIndex)
            }
        }

        return indexes
    }

    private static func childElements(from element: AXUIElement) -> [AXUIElement] {
        guard let children = copyAttribute(kAXChildrenAttribute as String, from: element) as [AXUIElement]? else {
            return []
        }
        return children
    }

    private static func enabledAttribute(from element: AXUIElement) -> Bool? {
        copyAttribute(kAXEnabledAttribute as String, from: element) as Bool?
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as String?
    }

    private static func copyAttribute<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var object: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &object)
        guard status == .success else {
            return nil
        }
        return object as? T
    }

    // Localized Copy titles mirror SelectedTextKit's MIT-licensed SystemMenuItem list.
    // See THIRD_PARTY_NOTICES.md.
    private static let copyMenuTitles: Set<String> = [
        "Copy",
        "拷贝", "复制",
        "拷貝", "複製",
        "コピー",
        "복사",
        "Copier",
        "Copiar",
        "Copia",
        "Kopieren",
        "Копировать",
        "Kopiëren",
        "Kopiér",
        "Kopiera",
        "Kopioi",
        "Αντιγραφή",
        "Kopyala",
        "Salin",
        "Sao chép",
        "คัดลอก",
        "Копіювати",
        "Kopiuj",
        "Másolás",
        "Kopírovat",
        "Kopírovať",
        "Kopiraj",
        "Копирај",
        "Копиране",
        "Kopēt",
        "Kopijuoti",
        "Copiază",
        "העתק",
        "نسخ",
        "کپی"
    ]
}

private enum SelectionClipboardReaderError: Error {
    case cannotCreateCopyEvent
}
