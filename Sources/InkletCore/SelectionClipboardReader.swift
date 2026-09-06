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

public struct SelectionClipboardUserCopyHandoff: Sendable {
    public let id: UUID
    public let boundaryChangeCount: Int

    fileprivate let activeReadToken: UUID?
    fileprivate let activeReadTask: Task<SelectedTextReadResult, Never>?
    fileprivate let didRelinquishRestoration: Bool
    fileprivate let didCaptureUnobservedSyntheticAction: Bool
}

public enum SelectionClipboardUserCopyHandoffOutcome: Equatable, Sendable {
    case noActiveRead
    case unobservedSyntheticAction
    case restorationRelinquished
    case completedWithoutPasteboardMutation
}

@MainActor
public final class SelectionClipboardReader {
    public typealias TrustChecker = @MainActor () -> Bool
    public typealias CopyMenuActionPerformer = @MainActor (pid_t) -> SelectionCopyMenuActionResult
    public typealias CopyShortcutSender = @MainActor (CGEventSource?) throws -> Void
    public typealias DelayProvider = @MainActor (UInt64) async -> Void
    public typealias ShortcutReadWrapper = @MainActor (@escaping @MainActor () async -> String?) async -> String?
    public typealias SourceProcessValidator = @MainActor @Sendable (pid_t) -> Bool
    typealias AlertVolumeGetter = @MainActor () -> Int?
    typealias AlertVolumeSetter = @MainActor (Int) -> Void

    public static let syntheticCopyEventUserData: Int64 = 0x494E_4B4C_4554

    struct CopyShortcutEvents {
        let keyDown: CGEvent
        let keyUp: CGEvent
    }

    private struct ActiveRead {
        let token: UUID
        let task: Task<SelectedTextReadResult, Never>
    }

    private struct PasteboardTransaction {
        let token: UUID
        let snapshot: PasteboardSnapshot
        let initialChangeCount: Int
        var didDispatchCopyAction: Bool
        var observedCopyChangeCount: Int?
    }

    private struct PendingAlertVolumeRestore {
        let token: UUID
        let originalVolume: Int
        let task: Task<Void, Never>
    }

    private enum PasteboardReadResult {
        case text(String)
        case empty
        case invalidSource
    }

    private let pasteboard: NSPasteboard
    private let clipboardService: ClipboardService
    private let eventSource: CGEventSource?
    private let pollIntervalNanoseconds: UInt64
    private let pollTimeoutNanoseconds: UInt64
    private let sourceProcessValidator: SourceProcessValidator
    private let isTrusted: TrustChecker
    private let copyMenuActionPerformer: CopyMenuActionPerformer
    private let copyShortcutSender: CopyShortcutSender
    private let delayProvider: DelayProvider
    private let shortcutReadWrapper: ShortcutReadWrapper?
    private let alertVolumeGetter: AlertVolumeGetter
    private let alertVolumeSetter: AlertVolumeSetter
    private let alertVolumeRestoreDelayProvider: DelayProvider
    private var activeRead: ActiveRead?
    private var pasteboardTransaction: PasteboardTransaction?
    private var latestReadRequestToken: UUID?
    private var relinquishedTransactionTokens: Set<UUID> = []
    private var pendingAlertVolumeRestore: PendingAlertVolumeRestore?

    public convenience init(
        pasteboard: NSPasteboard = .general,
        eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState),
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        pollTimeoutNanoseconds: UInt64 = 400_000_000,
        sourceProcessValidator: @escaping SourceProcessValidator = {
            SelectionSourceValidator().isCurrent($0)
        },
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
        shortcutReadWrapper: ShortcutReadWrapper? = nil
    ) {
        self.init(
            pasteboard: pasteboard,
            eventSource: eventSource,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            pollTimeoutNanoseconds: pollTimeoutNanoseconds,
            sourceProcessValidator: sourceProcessValidator,
            isTrusted: isTrusted,
            copyMenuActionPerformer: copyMenuActionPerformer,
            copyShortcutSender: copyShortcutSender,
            delayProvider: delayProvider,
            shortcutReadWrapper: shortcutReadWrapper,
            alertVolumeGetter: { SelectionClipboardReader.currentAlertVolume() },
            alertVolumeSetter: { SelectionClipboardReader.setAlertVolume($0) },
            alertVolumeRestoreDelayProvider: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        )
    }

    init(
        pasteboard: NSPasteboard = .general,
        eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState),
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        pollTimeoutNanoseconds: UInt64 = 400_000_000,
        sourceProcessValidator: @escaping SourceProcessValidator = {
            SelectionSourceValidator().isCurrent($0)
        },
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
        shortcutReadWrapper: ShortcutReadWrapper? = nil,
        alertVolumeGetter: @escaping AlertVolumeGetter,
        alertVolumeSetter: @escaping AlertVolumeSetter,
        alertVolumeRestoreDelayProvider: @escaping DelayProvider
    ) {
        self.pasteboard = pasteboard
        self.clipboardService = ClipboardService(pasteboard: pasteboard)
        self.eventSource = eventSource
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.pollTimeoutNanoseconds = pollTimeoutNanoseconds
        self.sourceProcessValidator = sourceProcessValidator
        self.isTrusted = isTrusted
        self.copyMenuActionPerformer = copyMenuActionPerformer
        self.copyShortcutSender = copyShortcutSender
        self.delayProvider = delayProvider
        self.shortcutReadWrapper = shortcutReadWrapper
        self.alertVolumeGetter = alertVolumeGetter
        self.alertVolumeSetter = alertVolumeSetter
        self.alertVolumeRestoreDelayProvider = alertVolumeRestoreDelayProvider
    }

    public func readSelectedText(
        sourceProcessIdentifier: pid_t,
        forceSelectionMode: SelectionForceSelectionMode = .menuCopyThenShortcut
    ) async -> SelectedTextReadResult {
        let token = UUID()
        latestReadRequestToken = token
        guard let activeRead = await beginActiveRead(
            token: token,
            sourceProcessIdentifier: sourceProcessIdentifier,
            forceSelectionMode: forceSelectionMode
        ) else {
            if latestReadRequestToken == token {
                latestReadRequestToken = nil
            }
            return .emptySelection
        }

        let result = await withTaskCancellationHandler {
            await activeRead.task.value
        } onCancel: {
            activeRead.task.cancel()
        }

        if self.activeRead?.token == activeRead.token {
            self.activeRead = nil
        }
        if latestReadRequestToken == token {
            latestReadRequestToken = nil
        }
        return Task.isCancelled ? .emptySelection : result
    }

    private func beginActiveRead(
        token: UUID,
        sourceProcessIdentifier: pid_t,
        forceSelectionMode: SelectionForceSelectionMode
    ) async -> ActiveRead? {
        while let precedingRead = activeRead {
            guard latestReadRequestToken == token,
                  !Task.isCancelled
            else {
                return nil
            }
            precedingRead.task.cancel()
            _ = await precedingRead.task.value
            if activeRead?.token == precedingRead.token {
                activeRead = nil
            }
            guard latestReadRequestToken == token,
                  !Task.isCancelled
            else {
                return nil
            }
        }

        guard latestReadRequestToken == token,
              !Task.isCancelled
        else {
            return nil
        }
        let task = Task { @MainActor in
            await self.performRead(
                token: token,
                sourceProcessIdentifier: sourceProcessIdentifier,
                forceSelectionMode: forceSelectionMode
            )
        }
        let activeRead = ActiveRead(token: token, task: task)
        self.activeRead = activeRead
        return activeRead
    }

    private func performRead(
        token: UUID,
        sourceProcessIdentifier: pid_t,
        forceSelectionMode: SelectionForceSelectionMode
    ) async -> SelectedTextReadResult {
        guard !Task.isCancelled else {
            return .emptySelection
        }

        switch forceSelectionMode {
        case .disabled:
            return .unsupported
        case .menuCopyOnly:
            return await readSelectedTextByMenuAction(
                token: token,
                sourceProcessIdentifier: sourceProcessIdentifier,
                fallbackToShortcut: false
            )
        case .menuCopyThenShortcut:
            return await readSelectedTextByMenuAction(
                token: token,
                sourceProcessIdentifier: sourceProcessIdentifier,
                fallbackToShortcut: true
            )
        case .shortcutThenMenuCopy:
            let shortcutResult = await readSelectedTextByShortcut(
                token: token,
                sourceProcessIdentifier: sourceProcessIdentifier
            )
            if case .success = shortcutResult {
                return shortcutResult
            }
            guard !Task.isCancelled else {
                return .emptySelection
            }
            let menuResult = await readSelectedTextByMenuAction(
                token: token,
                sourceProcessIdentifier: sourceProcessIdentifier,
                fallbackToShortcut: false
            )
            return preferredFallbackResult(primary: shortcutResult, secondary: menuResult)
        }
    }

    public func cancelActiveRead() async {
        latestReadRequestToken = nil
        if let activeRead {
            activeRead.task.cancel()
            _ = await activeRead.task.value
            if self.activeRead?.token == activeRead.token {
                self.activeRead = nil
            }
        }
        await restorePendingAlertVolumeAndWait()
    }

    public func beginUserCopyHandoff() -> SelectionClipboardUserCopyHandoff {
        latestReadRequestToken = nil
        guard let activeRead else {
            return SelectionClipboardUserCopyHandoff(
                id: UUID(),
                boundaryChangeCount: pasteboard.changeCount,
                activeReadToken: nil,
                activeReadTask: nil,
                didRelinquishRestoration: false,
                didCaptureUnobservedSyntheticAction: false
            )
        }

        let transaction = pasteboardTransaction
        let didCaptureUnobservedSyntheticAction = transaction?.token == activeRead.token
            && transaction?.didDispatchCopyAction == true
            && transaction?.observedCopyChangeCount == nil
        let didRelinquishRestoration = transaction?.token == activeRead.token
            && (transaction?.observedCopyChangeCount != nil
                || transaction?.initialChangeCount != pasteboard.changeCount)
        relinquishedTransactionTokens.insert(activeRead.token)
        activeRead.task.cancel()

        return SelectionClipboardUserCopyHandoff(
            id: UUID(),
            boundaryChangeCount: pasteboard.changeCount,
            activeReadToken: activeRead.token,
            activeReadTask: activeRead.task,
            didRelinquishRestoration: didRelinquishRestoration,
            didCaptureUnobservedSyntheticAction: didCaptureUnobservedSyntheticAction
        )
    }

    public func finishUserCopyHandoff(
        _ handoff: SelectionClipboardUserCopyHandoff
    ) async -> SelectionClipboardUserCopyHandoffOutcome {
        guard let activeReadToken = handoff.activeReadToken,
              let activeReadTask = handoff.activeReadTask
        else {
            return .noActiveRead
        }

        _ = await activeReadTask.value
        if activeRead?.token == activeReadToken {
            activeRead = nil
        }
        relinquishedTransactionTokens.remove(activeReadToken)

        if handoff.didCaptureUnobservedSyntheticAction {
            return .unobservedSyntheticAction
        }
        return handoff.didRelinquishRestoration
            ? .restorationRelinquished
            : .completedWithoutPasteboardMutation
    }

    private func readSelectedTextByMenuAction(
        token: UUID,
        sourceProcessIdentifier: pid_t,
        fallbackToShortcut: Bool
    ) async -> SelectedTextReadResult {
        var menuActionResult = SelectionCopyMenuActionResult.noMenuItem
        let pasteboardResult = await readPasteboardText(
            token: token,
            sourceProcessIdentifier: sourceProcessIdentifier
        ) {
            menuActionResult = self.copyMenuActionPerformer(sourceProcessIdentifier)
            return menuActionResult == .performed
        }
        if case .invalidSource = pasteboardResult {
            return .emptySelection
        }

        switch menuActionResult {
        case .performed:
            if case .text(let text) = pasteboardResult {
                return .success(text)
            }
            return .emptySelection
        case .noMenuItem:
            return fallbackToShortcut
                ? await readSelectedTextByShortcut(
                    token: token,
                    sourceProcessIdentifier: sourceProcessIdentifier
                )
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
        let events = try makeCopyShortcutEvents(eventSource: eventSource)
        events.keyDown.post(tap: .cghidEventTap)
        events.keyUp.post(tap: .cghidEventTap)
    }

    static func makeCopyShortcutEvents(eventSource: CGEventSource?) throws -> CopyShortcutEvents {
        guard let eventSource,
              let keyDown = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: 0x08,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: 0x08,
                keyDown: false
              )
        else {
            throw SelectionClipboardReaderError.cannotCreateCopyEvent
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.setIntegerValueField(.eventSourceUserData, value: syntheticCopyEventUserData)
        keyUp.setIntegerValueField(.eventSourceUserData, value: syntheticCopyEventUserData)
        return CopyShortcutEvents(keyDown: keyDown, keyUp: keyUp)
    }

    private func readSelectedTextByShortcut(
        token: UUID,
        sourceProcessIdentifier: pid_t
    ) async -> SelectedTextReadResult {
        guard sourceProcessValidator(sourceProcessIdentifier) else {
            return .emptySelection
        }
        guard isTrusted() else {
            return .permissionDenied
        }

        var pasteboardResult = PasteboardReadResult.empty
        let readOperation: @MainActor () async -> String? = {
            pasteboardResult = await self.readPasteboardText(
                token: token,
                sourceProcessIdentifier: sourceProcessIdentifier
            ) {
                try self.copyShortcutSender(self.eventSource)
                return true
            }
            if case .text(let text) = pasteboardResult {
                return text
            }
            return nil
        }
        let wrappedText: String?
        if let shortcutReadWrapper {
            wrappedText = await shortcutReadWrapper(readOperation)
        } else {
            wrappedText = await withMutedAlertVolume(readOperation)
        }

        guard !Task.isCancelled else {
            return .emptySelection
        }
        guard case .text = pasteboardResult,
              let wrappedText,
              sourceProcessValidator(sourceProcessIdentifier)
        else {
            return .emptySelection
        }
        return .success(wrappedText)
    }

    private func preferredFallbackResult(
        primary: SelectedTextReadResult,
        secondary: SelectedTextReadResult
    ) -> SelectedTextReadResult {
        if case .success = secondary {
            return secondary
        }
        if case .success = primary {
            return primary
        }
        if secondary == .emptySelection {
            return secondary
        }
        if primary == .permissionDenied {
            return primary
        }
        return secondary
    }

    private func readPasteboardText(
        token: UUID,
        sourceProcessIdentifier: pid_t,
        after action: @MainActor () throws -> Bool
    ) async -> PasteboardReadResult {
        guard !Task.isCancelled else {
            return .empty
        }

        pasteboardTransaction = PasteboardTransaction(
            token: token,
            snapshot: clipboardService.save(),
            initialChangeCount: pasteboard.changeCount,
            didDispatchCopyAction: false,
            observedCopyChangeCount: nil
        )
        defer {
            finishPasteboardTransaction(token: token)
        }

        guard sourceProcessValidator(sourceProcessIdentifier) else {
            return .invalidSource
        }

        let shouldPoll: Bool
        do {
            shouldPoll = try action()
        } catch {
            recordObservedPasteboardChange(token: token)
            return .empty
        }
        if shouldPoll {
            recordDispatchedCopyAction(token: token)
        }
        recordObservedPasteboardChange(token: token)
        guard shouldPoll else {
            return .empty
        }

        var elapsedNanoseconds: UInt64 = 0
        while elapsedNanoseconds < pollTimeoutNanoseconds {
            if Task.isCancelled {
                return .empty
            }

            recordObservedPasteboardChange(token: token)
            if let observedCopyChangeCount = pasteboardTransaction?.observedCopyChangeCount {
                guard pasteboard.changeCount == observedCopyChangeCount else {
                    return .empty
                }

                if let text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    guard sourceProcessValidator(sourceProcessIdentifier) else {
                        return .invalidSource
                    }
                    guard pasteboard.changeCount == observedCopyChangeCount else {
                        return .empty
                    }
                    return .text(text)
                }
            }

            let nextDelay = min(pollIntervalNanoseconds, pollTimeoutNanoseconds - elapsedNanoseconds)
            await delayProvider(nextDelay)
            elapsedNanoseconds += nextDelay
        }

        return .empty
    }

    private func recordDispatchedCopyAction(token: UUID) {
        guard var transaction = pasteboardTransaction,
              transaction.token == token
        else {
            return
        }
        transaction.didDispatchCopyAction = true
        pasteboardTransaction = transaction
    }

    private func recordObservedPasteboardChange(token: UUID) {
        guard var transaction = pasteboardTransaction,
              transaction.token == token,
              transaction.observedCopyChangeCount == nil,
              pasteboard.changeCount != transaction.initialChangeCount
        else {
            return
        }
        transaction.observedCopyChangeCount = pasteboard.changeCount
        pasteboardTransaction = transaction
    }

    private func finishPasteboardTransaction(token: UUID) {
        guard let transaction = pasteboardTransaction,
              transaction.token == token
        else {
            return
        }
        defer {
            if pasteboardTransaction?.token == token {
                pasteboardTransaction = nil
            }
        }

        guard !relinquishedTransactionTokens.contains(token),
              activeRead?.token == token,
              let observedCopyChangeCount = transaction.observedCopyChangeCount,
              pasteboard.changeCount == observedCopyChangeCount
        else {
            return
        }
        _ = clipboardService.restore(transaction.snapshot)
    }

    @available(
        *,
        deprecated,
        message: "Use reader-owned selection reads so shutdown can await alert-volume restoration."
    )
    public static func systemWithMutedAlertVolume(
        _ operation: @escaping @MainActor () async -> String?
    ) async -> String? {
        let originalVolume = currentAlertVolume()
        if originalVolume != nil {
            setAlertVolume(0)
        }

        let result = await operation()

        if let originalVolume, originalVolume > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            setAlertVolume(originalVolume)
        }

        return result
    }

    private func withMutedAlertVolume(
        _ operation: @escaping @MainActor () async -> String?
    ) async -> String? {
        await restorePendingAlertVolumeAndWait()
        let originalVolume = alertVolumeGetter()
        if originalVolume != nil {
            alertVolumeSetter(0)
        }

        let result = await operation()

        if let originalVolume, originalVolume > 0 {
            scheduleAlertVolumeRestore(originalVolume)
        }

        return result
    }

    private func scheduleAlertVolumeRestore(_ originalVolume: Int) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.alertVolumeRestoreDelayProvider(1_000_000_000)
            guard !Task.isCancelled,
                  self.pendingAlertVolumeRestore?.token == token
            else {
                return
            }
            self.alertVolumeSetter(originalVolume)
            self.pendingAlertVolumeRestore = nil
        }
        pendingAlertVolumeRestore = PendingAlertVolumeRestore(
            token: token,
            originalVolume: originalVolume,
            task: task
        )
    }

    private func restorePendingAlertVolumeAndWait() async {
        guard let pendingAlertVolumeRestore else { return }
        self.pendingAlertVolumeRestore = nil
        pendingAlertVolumeRestore.task.cancel()
        alertVolumeSetter(pendingAlertVolumeRestore.originalVolume)
        await pendingAlertVolumeRestore.task.value
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
