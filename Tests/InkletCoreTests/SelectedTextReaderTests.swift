import XCTest
@testable import InkletCore

final class SelectedTextReaderTests: XCTestCase {
    func testPermissionDeniedWhenNotTrusted() {
        let reader = SelectedTextReader(
            isTrusted: { false },
            focusedElementProvider: { nil },
            selectedTextProvider: { _ in .success("ignored") }
        )

        XCTAssertEqual(reader.readSelectedText(), .permissionDenied)
    }

    func testMissingFocusedElement() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            selectedTextProvider: { _ in .success("ignored") }
        )

        XCTAssertEqual(reader.readSelectedText(), .missingFocusedElement)
    }

    func testFallsBackToSourceApplicationFocusedElementWhenSystemFocusedElementIsMissing() {
        let requestedProcessIdentifier = TestBox<pid_t>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationAccessibilityEnabler: { _ in },
            applicationFocusedElementProvider: { processIdentifier in
                requestedProcessIdentifier.value = processIdentifier
                return SelectedTextElement(rawValue: "app-field")
            },
            elementAtPositionProvider: { _ in nil },
            elementProcessIdentifierProvider: { _ in 42 },
            selectedTextProvider: { element in
                element.rawValue == AnyHashable("app-field") ? .success("hello") : .success("")
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .success("hello"))
        XCTAssertEqual(requestedProcessIdentifier.value, 42)
    }

    func testEnablesSourceApplicationAccessibilityBeforeReadingApplicationFocusedElement() {
        let enabledProcessIdentifier = TestBox<pid_t>()
        let providerObservedEnabledApplication = TestBox<Bool>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationAccessibilityEnabler: { processIdentifier in
                enabledProcessIdentifier.value = processIdentifier
            },
            applicationFocusedElementProvider: { processIdentifier in
                providerObservedEnabledApplication.value = enabledProcessIdentifier.value == processIdentifier
                return SelectedTextElement(rawValue: "app-field")
            },
            elementAtPositionProvider: { _ in nil },
            elementProcessIdentifierProvider: { _ in 42 },
            selectedTextProvider: { element in
                element.rawValue == AnyHashable("app-field") ? .success("hello") : .success("")
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .success("hello"))
        XCTAssertEqual(enabledProcessIdentifier.value, 42)
        XCTAssertEqual(providerObservedEnabledApplication.value, true)
    }

    func testFallsBackToSourceApplicationFocusedWindowWhenFocusedElementIsMissing() {
        let requestedProcessIdentifier = TestBox<pid_t>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationAccessibilityEnabler: { _ in },
            applicationFocusedElementProvider: { _ in nil },
            applicationFocusedWindowProvider: { processIdentifier in
                requestedProcessIdentifier.value = processIdentifier
                return SelectedTextElement(rawValue: "app-window")
            },
            elementAtPositionProvider: { _ in nil },
            elementProcessIdentifierProvider: { _ in 42 },
            selectedTextProvider: { element in
                element.rawValue == AnyHashable("app-window") ? .success("window selection") : .success("")
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .success("window selection"))
        XCTAssertEqual(requestedProcessIdentifier.value, 42)
    }

    func testFallsBackToSourceApplicationElementChildrenWhenFocusedElementsAreMissing() {
        let requestedProcessIdentifier = TestBox<pid_t>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationAccessibilityEnabler: { _ in },
            applicationElementProvider: { processIdentifier in
                requestedProcessIdentifier.value = processIdentifier
                return SelectedTextElement(rawValue: "app")
            },
            applicationFocusedElementProvider: { _ in nil },
            applicationFocusedWindowProvider: { _ in nil },
            elementAtPositionProvider: { _ in nil },
            elementProcessIdentifierProvider: { _ in 42 },
            childElementsProvider: { element in
                element.rawValue == AnyHashable("app") ? [SelectedTextElement(rawValue: "app-window")] : []
            },
            selectedTextProvider: { element in
                element.rawValue == AnyHashable("app-window") ? .success("root child selection") : .failure(.unsupported)
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .success("root child selection"))
        XCTAssertEqual(requestedProcessIdentifier.value, 42)
    }

    func testFocusedSelectableElementAllowsMissingFocusedElement() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationAccessibilityEnabler: { _ in },
            applicationFocusedElementProvider: { _ in nil },
            elementProcessIdentifierProvider: { _ in 42 }
        )

        XCTAssertTrue(reader.isFocusedSelectableTextElement(sourceProcessIdentifier: 42))
    }

    func testIgnoresSystemFocusedElementOwnedByAnotherProcess() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "foreign-field") },
            applicationAccessibilityEnabler: { _ in },
            applicationElementProvider: { _ in nil },
            applicationFocusedElementProvider: { _ in SelectedTextElement(rawValue: "source-field") },
            applicationFocusedWindowProvider: { _ in nil },
            elementProcessIdentifierProvider: { element in
                switch element.rawValue {
                case AnyHashable("foreign-field"):
                    return 99
                case AnyHashable("source-field"):
                    return 42
                default:
                    return nil
                }
            },
            selectedTextProvider: { element in
                element.rawValue == AnyHashable("source-field") ? .success("expected") : .success("wrong")
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .success("expected"))
    }

    func testRejectsForeignDescendantOfSourceRoot() {
        let didReadForeignElement = TestBox<Bool>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationAccessibilityEnabler: { _ in },
            applicationElementProvider: { _ in SelectedTextElement(rawValue: "source-root") },
            applicationFocusedElementProvider: { _ in nil },
            applicationFocusedWindowProvider: { _ in nil },
            elementProcessIdentifierProvider: { element in
                element.rawValue == AnyHashable("source-root") ? 42 : 99
            },
            childElementsProvider: { element in
                element.rawValue == AnyHashable("source-root")
                    ? [SelectedTextElement(rawValue: "foreign-child")]
                    : []
            },
            selectedTextProvider: { element in
                if element.rawValue == AnyHashable("foreign-child") {
                    didReadForeignElement.value = true
                    return .success("wrong")
                }
                return .success("")
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .emptySelection)
        XCTAssertNil(didReadForeignElement.value)
    }

    func testRejectsCandidateWithUnknownOwnerForSourceProcess() {
        let didReadUnknownElement = TestBox<Bool>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "unknown-owner") },
            applicationAccessibilityEnabler: { _ in },
            applicationElementProvider: { _ in nil },
            applicationFocusedElementProvider: { _ in nil },
            applicationFocusedWindowProvider: { _ in nil },
            elementProcessIdentifierProvider: { _ in nil },
            selectedTextProvider: { _ in
                didReadUnknownElement.value = true
                return .success("wrong")
            }
        )

        XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .missingFocusedElement)
        XCTAssertNil(didReadUnknownElement.value)
    }

    func testDefaultOwnerProviderAcceptsAXElementOwnedBySourceProcess() throws {
        let sourceProcessIdentifier = getpid()
        let sourceElement = try XCTUnwrap(
            SelectedTextReader.systemApplicationElement(
                forProcessIdentifier: sourceProcessIdentifier
            )
        )
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { sourceElement },
            applicationAccessibilityEnabler: { _ in },
            applicationElementProvider: { _ in nil },
            applicationFocusedElementProvider: { _ in nil },
            applicationFocusedWindowProvider: { _ in nil },
            childElementsProvider: { _ in [] },
            selectedTextProvider: { _ in .success("expected") },
            selectedTextRangeProvider: { _ in .failure(.unsupported) },
            selectedTextMarkerRangeProvider: { _ in .failure(.unsupported) }
        )

        XCTAssertEqual(
            reader.readSelectedText(sourceProcessIdentifier: sourceProcessIdentifier),
            .success("expected")
        )
    }

    func testDefaultOwnerProviderRejectsNonAXElement() {
        let didReadInvalidElement = TestBox<Bool>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "not-an-ax-element") },
            applicationAccessibilityEnabler: { _ in },
            applicationElementProvider: { _ in nil },
            applicationFocusedElementProvider: { _ in nil },
            applicationFocusedWindowProvider: { _ in nil },
            selectedTextProvider: { _ in
                didReadInvalidElement.value = true
                return .success("wrong")
            }
        )

        XCTAssertEqual(
            reader.readSelectedText(sourceProcessIdentifier: getpid()),
            .missingFocusedElement
        )
        XCTAssertNil(didReadInvalidElement.value)
    }

    func testFocusedSelectableElementAllowsTextRoles() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            focusedElementRoleProvider: { _ in "AXTextArea" }
        )

        XCTAssertTrue(reader.isFocusedSelectableTextElement())
    }

    func testFocusedSelectableElementAllowsSelectedTextRange() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            focusedElementRoleProvider: { _ in "AXButton" },
            selectedTextRangeProvider: { _ in .success(SelectedTextRange(location: 2, length: 4)) }
        )

        XCTAssertTrue(reader.isFocusedSelectableTextElement())
    }

    func testFocusedSelectableElementAllowsNonEmptyValue() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            focusedElementRoleProvider: { _ in "AXButton" },
            focusedElementValueProvider: { _ in "visible text" },
            selectedTextRangeProvider: { _ in .failure(.unsupported) }
        )

        XCTAssertTrue(reader.isFocusedSelectableTextElement())
    }

    func testFocusedSelectableElementRejectsNonTextElementWithoutTextSignals() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "map") },
            focusedElementRoleProvider: { _ in "AXButton" },
            focusedElementValueProvider: { _ in "" },
            selectedTextRangeProvider: { _ in .failure(.unsupported) }
        )

        XCTAssertFalse(reader.isFocusedSelectableTextElement())
    }

    func testFallsBackToElementAtMouseLocationWhenFocusedElementsAreMissing() {
        let selectionPoint = SelectionPoint(x: 24, y: 48)
        let requestedPoint = TestBox<SelectionPoint>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { nil },
            applicationFocusedElementProvider: { _ in nil },
            elementAtPositionProvider: { point in
                requestedPoint.value = point
                return SelectedTextElement(rawValue: "hit-field")
            },
            selectedTextProvider: { element in
                element.rawValue == AnyHashable("hit-field") ? .success("hello") : .success("")
            }
        )

        XCTAssertEqual(reader.readSelectedText(mouseLocation: selectionPoint), .success("hello"))
        XCTAssertEqual(requestedPoint.value, selectionPoint)
    }

    func testSearchesChildElementsWhenCandidateElementHasNoSelectedText() {
        let requestedParents = TestBox<[SelectedTextElement]>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "parent") },
            childElementsProvider: { element in
                requestedParents.value = (requestedParents.value ?? []) + [element]
                return [SelectedTextElement(rawValue: "child")]
            },
            selectedTextProvider: { element in
                switch element.rawValue {
                case AnyHashable("parent"):
                    return .failure(.unsupported)
                case AnyHashable("child"):
                    return .success("child selection")
                default:
                    return .success("")
                }
            }
        )

        XCTAssertEqual(reader.readSelectedText(), .success("child selection"))
        XCTAssertTrue(requestedParents.value?.contains(SelectedTextElement(rawValue: "parent")) == true)
    }

    func testSearchesChildElementsWhenContainerReportsEmptySelection() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "container") },
            childElementsProvider: { element in
                element.rawValue == AnyHashable("container") ? [SelectedTextElement(rawValue: "child")] : []
            },
            selectedTextProvider: { element in
                switch element.rawValue {
                case AnyHashable("container"):
                    return .success("")
                case AnyHashable("child"):
                    return .success("nested selection")
                default:
                    return .failure(.unsupported)
                }
            }
        )

        XCTAssertEqual(reader.readSelectedText(), .success("nested selection"))
    }

    func testEmptySelection() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            selectedTextProvider: { _ in .success(" \n\t ") }
        )

        XCTAssertEqual(reader.readSelectedText(), .emptySelection)
    }

    func testSuccessfulSelectionTrimsOuterWhitespaceAndPreservesLineBreaks() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            selectedTextProvider: { _ in .success("  hello\nworld  ") }
        )

        XCTAssertEqual(reader.readSelectedText(), .success("hello\nworld"))
    }

    func testUnsupportedAttribute() {
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            selectedTextProvider: { _ in .failure(.unsupported) }
        )

        XCTAssertEqual(reader.readSelectedText(), .unsupported)
    }

    func testFallsBackToSelectedTextRangeWhenDirectSelectedTextIsUnsupported() {
        let requestedElement = TestBox<SelectedTextElement>()
        let requestedStringRange = TestBox<SelectedTextRange>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            selectedTextProvider: { _ in .failure(.unsupported) },
            selectedTextRangeProvider: { element in
                requestedElement.value = element
                return .success(SelectedTextRange(location: 7, length: 5))
            },
            stringForRangeProvider: { _, range in
                requestedStringRange.value = range
                return .success("hello")
            }
        )

        XCTAssertEqual(reader.readSelectedText(), .success("hello"))
        XCTAssertEqual(requestedElement.value, SelectedTextElement(rawValue: "field"))
        XCTAssertEqual(requestedStringRange.value, SelectedTextRange(location: 7, length: 5))
    }

    func testSelectedTextRangeWithZeroLengthRemainsEmptySelection() {
        let didRequestString = TestBox<Bool>()
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "field") },
            selectedTextProvider: { _ in .failure(.unsupported) },
            selectedTextRangeProvider: { _ in .success(SelectedTextRange(location: 7, length: 0)) },
            stringForRangeProvider: { _, _ in
                didRequestString.value = true
                return .success("ignored")
            }
        )

        XCTAssertEqual(reader.readSelectedText(), .emptySelection)
        XCTAssertNil(didRequestString.value)
    }

    func testFallsBackToSelectedTextMarkerRangeWhenCharacterRangeIsUnsupported() {
        let requestedElement = TestBox<SelectedTextElement>()
        let requestedMarkerRange = TestBox<SelectedTextMarkerRange>()
        let markerRange = SelectedTextMarkerRange(rawValue: "marker-range")
        let reader = SelectedTextReader(
            isTrusted: { true },
            focusedElementProvider: { SelectedTextElement(rawValue: "web-area") },
            selectedTextProvider: { _ in .failure(.unsupported) },
            selectedTextRangeProvider: { _ in .failure(.unsupported) },
            stringForRangeProvider: { _, _ in .failure(.unsupported) },
            selectedTextMarkerRangeProvider: { element in
                requestedElement.value = element
                return .success(markerRange)
            },
            stringForMarkerRangeProvider: { _, range in
                requestedMarkerRange.value = range
                return .success("chrome selection")
            }
        )

        XCTAssertEqual(reader.readSelectedText(), .success("chrome selection"))
        XCTAssertEqual(requestedElement.value, SelectedTextElement(rawValue: "web-area"))
        XCTAssertEqual(requestedMarkerRange.value, markerRange)
    }
}

private final class TestBox<Value>: @unchecked Sendable {
    var value: Value?
}
