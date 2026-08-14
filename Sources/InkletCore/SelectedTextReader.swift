import ApplicationServices
import Foundation

public struct SelectedTextElement: Equatable, Hashable, @unchecked Sendable {
    public let rawValue: AnyHashable

    public init(rawValue: AnyHashable) {
        self.rawValue = rawValue
    }
}

public struct SelectedTextRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct SelectedTextMarkerRange: Equatable, @unchecked Sendable {
    public let rawValue: AnyHashable

    public init(rawValue: AnyHashable) {
        self.rawValue = rawValue
    }
}

public enum SelectedTextReadError: Error, Equatable, Sendable {
    case unsupported
    case accessibilityFailure(String)
}

public enum SelectedTextReadResult: Equatable, Sendable {
    case success(String)
    case permissionDenied
    case emptySelection
    case unsupported
    case missingFocusedElement
    case failed(String)
}

public struct SelectedTextReader: Sendable {
    public typealias TrustChecker = @Sendable () -> Bool
    public typealias FocusedElementProvider = @Sendable () -> SelectedTextElement?
    public typealias ApplicationAccessibilityEnabler = @Sendable (pid_t) -> Void
    public typealias ApplicationElementProvider = @Sendable (pid_t) -> SelectedTextElement?
    public typealias ApplicationFocusedElementProvider = @Sendable (pid_t) -> SelectedTextElement?
    public typealias ApplicationFocusedWindowProvider = @Sendable (pid_t) -> SelectedTextElement?
    public typealias ElementAtPositionProvider = @Sendable (SelectionPoint) -> SelectedTextElement?
    public typealias ChildElementsProvider = @Sendable (SelectedTextElement) -> [SelectedTextElement]
    public typealias FocusedElementRoleProvider = @Sendable (SelectedTextElement) -> String?
    public typealias FocusedElementValueProvider = @Sendable (SelectedTextElement) -> String?
    public typealias SelectedTextProvider = @Sendable (SelectedTextElement) -> Result<String, SelectedTextReadError>
    public typealias SelectedTextRangeProvider = @Sendable (SelectedTextElement) -> Result<SelectedTextRange, SelectedTextReadError>
    public typealias StringForRangeProvider = @Sendable (SelectedTextElement, SelectedTextRange) -> Result<String, SelectedTextReadError>
    public typealias SelectedTextMarkerRangeProvider = @Sendable (SelectedTextElement) -> Result<SelectedTextMarkerRange, SelectedTextReadError>
    public typealias StringForMarkerRangeProvider = @Sendable (SelectedTextElement, SelectedTextMarkerRange) -> Result<String, SelectedTextReadError>

    private let isTrusted: TrustChecker
    private let focusedElementProvider: FocusedElementProvider
    private let applicationAccessibilityEnabler: ApplicationAccessibilityEnabler
    private let applicationElementProvider: ApplicationElementProvider
    private let applicationFocusedElementProvider: ApplicationFocusedElementProvider
    private let applicationFocusedWindowProvider: ApplicationFocusedWindowProvider
    private let elementAtPositionProvider: ElementAtPositionProvider
    private let childElementsProvider: ChildElementsProvider
    private let focusedElementRoleProvider: FocusedElementRoleProvider
    private let focusedElementValueProvider: FocusedElementValueProvider
    private let selectedTextProvider: SelectedTextProvider
    private let selectedTextRangeProvider: SelectedTextRangeProvider
    private let stringForRangeProvider: StringForRangeProvider
    private let selectedTextMarkerRangeProvider: SelectedTextMarkerRangeProvider
    private let stringForMarkerRangeProvider: StringForMarkerRangeProvider

    public init(
        isTrusted: @escaping TrustChecker = { AXIsProcessTrusted() },
        focusedElementProvider: @escaping FocusedElementProvider = { Self.systemFocusedElement() },
        applicationAccessibilityEnabler: @escaping ApplicationAccessibilityEnabler = { Self.systemEnableApplicationAccessibility(forProcessIdentifier: $0) },
        applicationElementProvider: @escaping ApplicationElementProvider = { Self.systemApplicationElement(forProcessIdentifier: $0) },
        applicationFocusedElementProvider: @escaping ApplicationFocusedElementProvider = {
            Self.systemFocusedElement(forProcessIdentifier: $0)
        },
        applicationFocusedWindowProvider: @escaping ApplicationFocusedWindowProvider = {
            Self.systemFocusedWindow(forProcessIdentifier: $0)
        },
        elementAtPositionProvider: @escaping ElementAtPositionProvider = { Self.systemElement(at: $0) },
        childElementsProvider: @escaping ChildElementsProvider = { Self.systemChildElements(from: $0) },
        focusedElementRoleProvider: @escaping FocusedElementRoleProvider = { Self.systemRoleValue(from: $0) },
        focusedElementValueProvider: @escaping FocusedElementValueProvider = { Self.systemValue(from: $0) },
        selectedTextProvider: @escaping SelectedTextProvider = { Self.systemSelectedText(from: $0) },
        selectedTextRangeProvider: @escaping SelectedTextRangeProvider = { Self.systemSelectedTextRange(from: $0) },
        stringForRangeProvider: @escaping StringForRangeProvider = { Self.systemStringForRange(from: $0, range: $1) },
        selectedTextMarkerRangeProvider: @escaping SelectedTextMarkerRangeProvider = {
            Self.systemSelectedTextMarkerRange(from: $0)
        },
        stringForMarkerRangeProvider: @escaping StringForMarkerRangeProvider = {
            Self.systemStringForMarkerRange(from: $0, markerRange: $1)
        }
    ) {
        self.isTrusted = isTrusted
        self.focusedElementProvider = focusedElementProvider
        self.applicationAccessibilityEnabler = applicationAccessibilityEnabler
        self.applicationElementProvider = applicationElementProvider
        self.applicationFocusedElementProvider = applicationFocusedElementProvider
        self.applicationFocusedWindowProvider = applicationFocusedWindowProvider
        self.elementAtPositionProvider = elementAtPositionProvider
        self.childElementsProvider = childElementsProvider
        self.focusedElementRoleProvider = focusedElementRoleProvider
        self.focusedElementValueProvider = focusedElementValueProvider
        self.selectedTextProvider = selectedTextProvider
        self.selectedTextRangeProvider = selectedTextRangeProvider
        self.stringForRangeProvider = stringForRangeProvider
        self.selectedTextMarkerRangeProvider = selectedTextMarkerRangeProvider
        self.stringForMarkerRangeProvider = stringForMarkerRangeProvider
    }

    public func readSelectedText(
        sourceProcessIdentifier: pid_t? = nil,
        mouseLocation: SelectionPoint? = nil
    ) -> SelectedTextReadResult {
        guard isTrusted() else {
            return .permissionDenied
        }

        let elements = candidateElements(
            sourceProcessIdentifier: sourceProcessIdentifier,
            mouseLocation: mouseLocation
        )
        guard !elements.isEmpty else {
            return .missingFocusedElement
        }

        var fallbackResult: SelectedTextReadResult = .emptySelection
        for element in elements {
            switch readSelectedText(from: element) {
            case .success(let text):
                return .success(text)
            case .emptySelection:
                fallbackResult = .emptySelection
            case .unsupported:
                if fallbackResult == .emptySelection {
                    fallbackResult = .unsupported
                }
            case .failed(let message):
                fallbackResult = .failed(message)
            case .permissionDenied, .missingFocusedElement:
                break
            }
        }

        return fallbackResult
    }

    public func isFocusedSelectableTextElement(sourceProcessIdentifier: pid_t? = nil) -> Bool {
        guard isTrusted() else {
            return false
        }

        if let sourceProcessIdentifier {
            applicationAccessibilityEnabler(sourceProcessIdentifier)
        }

        let focusedElement = sourceProcessIdentifier.flatMap(applicationFocusedElementProvider)
            ?? focusedElementProvider()

        guard let focusedElement else {
            return false
        }

        if let roleValue = focusedElementRoleProvider(focusedElement),
           Self.selectableTextRoles.contains(roleValue) {
            return true
        }

        if case .success = selectedTextRangeProvider(focusedElement) {
            return true
        }

        if case .success = selectedTextMarkerRangeProvider(focusedElement) {
            return true
        }

        return false
    }

    public static func systemFocusedElement() -> SelectedTextElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedStatus == .success,
              let focusedElement = focusedObject as! AXUIElement?
        else {
            return nil
        }

        return SelectedTextElement(rawValue: AXElementBox(focusedElement))
    }

    public static func systemFocusedElement(forProcessIdentifier processIdentifier: pid_t) -> SelectedTextElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedObject: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedStatus == .success,
              let focusedElement = focusedObject as! AXUIElement?
        else {
            return nil
        }

        return SelectedTextElement(rawValue: AXElementBox(focusedElement))
    }

    public static func systemApplicationElement(forProcessIdentifier processIdentifier: pid_t) -> SelectedTextElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        return SelectedTextElement(rawValue: AXElementBox(applicationElement))
    }

    public static func systemFocusedWindow(forProcessIdentifier processIdentifier: pid_t) -> SelectedTextElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowObject
        )

        guard status == .success,
              let focusedWindow = focusedWindowObject as! AXUIElement?
        else {
            return nil
        }

        return SelectedTextElement(rawValue: AXElementBox(focusedWindow))
    }

    public static func systemEnableApplicationAccessibility(forProcessIdentifier processIdentifier: pid_t) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetAttributeValue(
            applicationElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    public static func systemElement(at point: SelectionPoint) -> SelectedTextElement? {
        let systemWide = AXUIElementCreateSystemWide()
        let accessibilityPoint = accessibilityPoint(fromMouseLocation: point)
        var elementObject: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &elementObject
        )

        guard status == .success,
              let element = elementObject
        else {
            return nil
        }

        return SelectedTextElement(rawValue: AXElementBox(element))
    }

    public static func systemSelectedText(from element: SelectedTextElement) -> Result<String, SelectedTextReadError> {
        let results = [
            systemDirectSelectedText(from: element),
            systemSelectedTextViaRange(from: element),
            systemSelectedTextViaMarkerRange(from: element)
        ]
        return preferredSystemTextResult(from: results)
    }

    public static func systemDirectSelectedText(from element: SelectedTextElement) -> Result<String, SelectedTextReadError> {
        guard let box = element.rawValue.base as? AXElementBox else {
            return .failure(.accessibilityFailure("Invalid focused element."))
        }

        var selectedTextObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            box.element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextObject
        )

        guard status == .success else {
            if status == .attributeUnsupported {
                return .failure(.unsupported)
            }
            return .failure(.accessibilityFailure("Accessibility read failed with status \(status.rawValue)."))
        }

        guard let selectedText = selectedTextObject as? String else {
            return .success("")
        }
        return .success(selectedText)
    }

    public static func systemRoleValue(from element: SelectedTextElement) -> String? {
        guard let box = element.rawValue.base as? AXElementBox else {
            return nil
        }

        var roleObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            box.element,
            kAXRoleAttribute as CFString,
            &roleObject
        )
        guard status == .success else {
            return nil
        }

        return roleObject as? String
    }

    public static func systemValue(from element: SelectedTextElement) -> String? {
        guard let box = element.rawValue.base as? AXElementBox else {
            return nil
        }

        var valueObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            box.element,
            kAXValueAttribute as CFString,
            &valueObject
        )
        guard status == .success else {
            return nil
        }

        return valueObject as? String
    }

    public static func systemChildElements(from element: SelectedTextElement) -> [SelectedTextElement] {
        guard let box = element.rawValue.base as? AXElementBox else {
            return []
        }

        var childrenObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            box.element,
            kAXChildrenAttribute as CFString,
            &childrenObject
        )

        guard status == .success,
              let children = childrenObject as? [AXUIElement]
        else {
            return []
        }

        return children.prefix(8).map { SelectedTextElement(rawValue: AXElementBox($0)) }
    }

    public static func systemSelectedTextViaRange(from element: SelectedTextElement) -> Result<String, SelectedTextReadError> {
        switch systemSelectedTextRange(from: element) {
        case .success(let range):
            guard range.length > 0 else {
                return .success("")
            }
            return systemStringForRange(from: element, range: range)
        case .failure(let error):
            return .failure(error)
        }
    }

    public static func systemSelectedTextViaMarkerRange(from element: SelectedTextElement) -> Result<String, SelectedTextReadError> {
        switch systemSelectedTextMarkerRange(from: element) {
        case .success(let markerRange):
            return systemStringForMarkerRange(from: element, markerRange: markerRange)
        case .failure(let error):
            return .failure(error)
        }
    }

    public static func systemSelectedTextRange(from element: SelectedTextElement) -> Result<SelectedTextRange, SelectedTextReadError> {
        guard let box = element.rawValue.base as? AXElementBox else {
            return .failure(.accessibilityFailure("Invalid focused element."))
        }

        var rangeObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            box.element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeObject
        )

        guard status == .success else {
            if status == .attributeUnsupported {
                return .failure(.unsupported)
            }
            return .failure(.accessibilityFailure("Accessibility selected range read failed with status \(status.rawValue)."))
        }

        guard let rangeObject,
              CFGetTypeID(rangeObject) == AXValueGetTypeID()
        else {
            return .failure(.accessibilityFailure("Accessibility selected range was not a CFRange."))
        }

        let rangeValue = rangeObject as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else {
            return .failure(.accessibilityFailure("Accessibility selected range was not a CFRange."))
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            return .failure(.accessibilityFailure("Accessibility selected range could not be decoded."))
        }

        return .success(SelectedTextRange(location: range.location, length: range.length))
    }

    public static func systemStringForRange(
        from element: SelectedTextElement,
        range selectedRange: SelectedTextRange
    ) -> Result<String, SelectedTextReadError> {
        guard let box = element.rawValue.base as? AXElementBox else {
            return .failure(.accessibilityFailure("Invalid focused element."))
        }

        var cfRange = CFRange(location: selectedRange.location, length: selectedRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            return .failure(.accessibilityFailure("Accessibility selected range could not be encoded."))
        }

        var stringObject: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            box.element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringObject
        )

        guard status == .success else {
            if status == .attributeUnsupported {
                return .failure(.unsupported)
            }
            return .failure(.accessibilityFailure("Accessibility string-for-range read failed with status \(status.rawValue)."))
        }

        guard let selectedText = stringObject as? String else {
            return .success("")
        }
        return .success(selectedText)
    }

    public static func systemSelectedTextMarkerRange(from element: SelectedTextElement) -> Result<SelectedTextMarkerRange, SelectedTextReadError> {
        guard let box = element.rawValue.base as? AXElementBox else {
            return .failure(.accessibilityFailure("Invalid focused element."))
        }

        var markerRangeObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            box.element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeObject
        )

        guard status == .success else {
            if status == .attributeUnsupported {
                return .failure(.unsupported)
            }
            return .failure(.accessibilityFailure("Accessibility selected marker range read failed with status \(status.rawValue)."))
        }

        guard let markerRangeObject else {
            return .failure(.accessibilityFailure("Accessibility selected marker range was empty."))
        }

        return .success(SelectedTextMarkerRange(rawValue: AnyHashable(AXTextMarkerRangeBox(markerRangeObject))))
    }

    public static func systemStringForMarkerRange(
        from element: SelectedTextElement,
        markerRange: SelectedTextMarkerRange
    ) -> Result<String, SelectedTextReadError> {
        guard let box = element.rawValue.base as? AXElementBox else {
            return .failure(.accessibilityFailure("Invalid focused element."))
        }
        guard let markerRangeBox = markerRange.rawValue.base as? AXTextMarkerRangeBox else {
            return .failure(.accessibilityFailure("Invalid selected marker range."))
        }

        var stringObject: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            box.element,
            "AXStringForTextMarkerRange" as CFString,
            markerRangeBox.value,
            &stringObject
        )

        guard status == .success else {
            if status == .attributeUnsupported {
                return .failure(.unsupported)
            }
            return .failure(.accessibilityFailure("Accessibility string-for-marker-range read failed with status \(status.rawValue)."))
        }

        guard let selectedText = stringObject as? String else {
            return .success("")
        }
        return .success(selectedText)
    }

    private func candidateElements(
        sourceProcessIdentifier: pid_t?,
        mouseLocation: SelectionPoint?
    ) -> [SelectedTextElement] {
        if let sourceProcessIdentifier {
            applicationAccessibilityEnabler(sourceProcessIdentifier)
        }

        return [
            focusedElementProvider(),
            sourceProcessIdentifier.flatMap(applicationFocusedElementProvider),
            sourceProcessIdentifier.flatMap(applicationFocusedWindowProvider),
            sourceProcessIdentifier.flatMap(applicationElementProvider),
            mouseLocation.flatMap(elementAtPositionProvider)
        ].compactMap { $0 }
    }

    private func readSelectedText(from element: SelectedTextElement) -> SelectedTextReadResult {
        var fallbackResult: SelectedTextReadResult = .unsupported
        for candidate in expandedCandidateElements(from: element) {
            let result = readSelectedTextFromSingleElement(candidate)
            if case .success = result {
                return result
            }
            switch result {
            case .emptySelection:
                fallbackResult = .emptySelection
            case .failed:
                if fallbackResult != .emptySelection {
                    fallbackResult = result
                }
            case .unsupported:
                break
            case .permissionDenied, .missingFocusedElement, .success:
                break
            }
        }

        return fallbackResult
    }

    private func readSelectedTextFromSingleElement(_ element: SelectedTextElement) -> SelectedTextReadResult {
        let results = [
            selectedTextProvider(element),
            selectedTextViaRange(from: element),
            selectedTextViaMarkerRange(from: element)
        ].map(normalizedReadResult)

        for result in results {
            if case .success(let text) = result {
                return .success(text)
            }
        }

        return fallbackReadResult(from: results)
    }

    private func expandedCandidateElements(from element: SelectedTextElement) -> [SelectedTextElement] {
        var result: [SelectedTextElement] = [element]
        var queue: [(SelectedTextElement, Int)] = [(element, 0)]
        var visited = Set<SelectedTextElement>()
        visited.insert(element)

        while !queue.isEmpty, result.count < 64 {
            let (current, depth) = queue.removeFirst()
            guard depth < 4 else {
                continue
            }

            for child in childElementsProvider(current).prefix(8) where !visited.contains(child) {
                visited.insert(child)
                result.append(child)
                queue.append((child, depth + 1))
                if result.count >= 64 {
                    break
                }
            }
        }

        return result
    }

    private func selectedTextViaRange(from element: SelectedTextElement) -> Result<String, SelectedTextReadError> {
        switch selectedTextRangeProvider(element) {
        case .success(let range):
            guard range.length > 0 else {
                return .success("")
            }
            return stringForRangeProvider(element, range)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func selectedTextViaMarkerRange(from element: SelectedTextElement) -> Result<String, SelectedTextReadError> {
        switch selectedTextMarkerRangeProvider(element) {
        case .success(let markerRange):
            return stringForMarkerRangeProvider(element, markerRange)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func normalizedReadResult(from result: Result<String, SelectedTextReadError>) -> SelectedTextReadResult {
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .emptySelection : .success(trimmed)
        case .failure(.unsupported):
            return .unsupported
        case .failure(.accessibilityFailure(let message)):
            return .failed(message)
        }
    }

    private func fallbackReadResult(from results: [SelectedTextReadResult]) -> SelectedTextReadResult {
        if results.contains(.emptySelection) {
            return .emptySelection
        }

        if results.contains(.unsupported) {
            return .unsupported
        }

        for result in results {
            if case .failed = result {
                return result
            }
        }

        return .emptySelection
    }

    private static func preferredSystemTextResult(
        from results: [Result<String, SelectedTextReadError>]
    ) -> Result<String, SelectedTextReadError> {
        for result in results {
            if case .success(let text) = result,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result
            }
        }

        for result in results {
            if case .success = result {
                return result
            }
        }

        for result in results {
            if case .failure(.accessibilityFailure) = result {
                return result
            }
        }

        return .failure(.unsupported)
    }

    private static let selectableTextRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        kAXSearchFieldSubrole,
        kAXPopUpButtonRole,
        kAXMenuRole,
        kAXStaticTextRole,
        kAXGroupRole,
        "AXWebArea"
    ]

    private static func accessibilityPoint(fromMouseLocation point: SelectionPoint) -> SelectionPoint {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
            return SelectionPoint(x: point.x, y: Double(mainDisplayBounds.height) - point.y)
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
            return SelectionPoint(x: point.x, y: Double(mainDisplayBounds.height) - point.y)
        }

        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        return SelectionPoint(x: point.x, y: Double(mainDisplayBounds.height) - point.y)
    }
}

private final class AXElementBox: Hashable, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXElementBox, rhs: AXElementBox) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

private final class AXTextMarkerRangeBox: Hashable, @unchecked Sendable {
    let value: CFTypeRef

    init(_ value: CFTypeRef) {
        self.value = value
    }

    static func == (lhs: AXTextMarkerRangeBox, rhs: AXTextMarkerRangeBox) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
