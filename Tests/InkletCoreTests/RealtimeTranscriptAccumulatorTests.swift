import XCTest
@testable import InkletCore

final class RealtimeTranscriptAccumulatorTests: XCTestCase {
    func testDeltasAccumulateInArrivalOrderWithoutSequences() {
        var accumulator = RealtimeTranscriptAccumulator()

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "first "
        )), .provisional("first "))
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "second"
        )), .provisional("first second"))
    }

    func testWrongItemOrContentIsIgnored() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "one", sequence: 1, itemID: "item", contentIndex: 0, text: "accepted"
        ))

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "two", sequence: 2, itemID: "other", contentIndex: 0, text: "wrong item"
        )), .ignored)
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "three", sequence: 3, itemID: "item", contentIndex: 1, text: "wrong content"
        )), .ignored)
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "four", sequence: 4, itemID: "item", contentIndex: 0, text: "tail"
        )), .provisional("acceptedtail"))
    }

    func testDuplicateEventIDsAreIgnored() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "duplicate", sequence: nil, itemID: "item", contentIndex: 0, text: "once"
        ))

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "duplicate", sequence: nil, itemID: "item", contentIndex: 0, text: "twice"
        )), .ignored)
    }

    func testComparableOutOfOrderSequencesAreIgnored() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "one", sequence: 2, itemID: "item", contentIndex: 0, text: "two"
        ))

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "zero", sequence: 1, itemID: "item", contentIndex: 0, text: "one"
        )), .ignored)
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "same", sequence: 2, itemID: "item", contentIndex: 0, text: "same"
        )), .ignored)
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "three", sequence: 3, itemID: "item", contentIndex: 0, text: "three"
        )), .provisional("twothree"))
    }

    func testMissingSequencePreservesArrivalOrderAfterComparableSequence() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "one", sequence: 4, itemID: "item", contentIndex: 0, text: "four"
        ))

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "arrival"
        )), .provisional("fourarrival"))
    }

    func testCompletedTranscriptIsAuthoritative() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "one", sequence: 1, itemID: "item", contentIndex: 0, text: "provisional"
        ))

        XCTAssertEqual(accumulator.accept(.completed(
            eventID: "done", sequence: 2, itemID: "item", contentIndex: 0, transcript: "authoritative"
        )), .final("authoritative"))
    }

    func testAllEventsAfterCompletionAreIgnored() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.completed(
            eventID: "done", sequence: 1, itemID: "item", contentIndex: 0, transcript: "final"
        ))

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "later", sequence: 2, itemID: "item", contentIndex: 0, text: "later"
        )), .ignored)
        XCTAssertEqual(accumulator.accept(.completed(
            eventID: "later-done", sequence: 3, itemID: "other", contentIndex: 0, transcript: "other"
        )), .ignored)
    }

    func testWrongItemDoesNotPoisonEventIDOrSequenceState() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "first", sequence: 1, itemID: "item", contentIndex: 0, text: "start"
        ))
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "valid-later", sequence: 2, itemID: "other", contentIndex: 0, text: "wrong"
        )), .ignored)

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "valid-later", sequence: 2, itemID: "item", contentIndex: 0, text: "accepted"
        )), .provisional("startaccepted"))
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "next", sequence: 3, itemID: "item", contentIndex: 0, text: " next"
        )), .provisional("startaccepted next"))
    }

    func testCompletedTranscriptIsStoredInAccumulatorEquality() {
        var first = RealtimeTranscriptAccumulator()
        var second = RealtimeTranscriptAccumulator()

        _ = first.accept(.completed(
            eventID: "done", sequence: 1, itemID: "item", contentIndex: 0, transcript: "first final"
        ))
        _ = second.accept(.completed(
            eventID: "done", sequence: 1, itemID: "item", contentIndex: 0, transcript: "second final"
        ))

        XCTAssertNotEqual(first, second)
    }

    func testRejectedSequenceDoesNotConsumeEventID() {
        var accumulator = RealtimeTranscriptAccumulator()

        _ = accumulator.accept(.delta(
            eventID: "first", sequence: 2, itemID: "item", contentIndex: 0, text: "start"
        ))
        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "reusable", sequence: 1, itemID: "item", contentIndex: 0, text: "rejected"
        )), .ignored)

        XCTAssertEqual(accumulator.accept(.delta(
            eventID: "reusable", sequence: 3, itemID: "item", contentIndex: 0, text: "accepted"
        )), .provisional("startaccepted"))
    }
}
