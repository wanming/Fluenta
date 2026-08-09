import Darwin
import Foundation
import XCTest
@testable import InkletCore

// macOS 26 marks Swift's imported fork unavailable; bridge the same libc symbol only for this test.
@_silgen_name("fork")
private func legacyMigrationTestFork() -> pid_t

final class LegacyMigrationLockTests: XCTestCase {
    func testLockCanBeAcquiredAgainAfterOperationReturns() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        let lock = LegacyMigrationLock(
            fileURL: directoryURL.appendingPathComponent("migration.lock"),
            timeout: .milliseconds(100),
            retryInterval: .milliseconds(1)
        )
        var acquisitionCount = 0

        try lock.withLock {
            acquisitionCount += 1
        }
        try lock.withLock {
            acquisitionCount += 1
        }

        XCTAssertEqual(acquisitionCount, 2)
    }

    func testLockCanBeAcquiredAgainAfterOperationThrows() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        let lock = LegacyMigrationLock(
            fileURL: directoryURL.appendingPathComponent("migration.lock"),
            timeout: .milliseconds(100),
            retryInterval: .milliseconds(1)
        )

        XCTAssertThrowsError(
            try lock.withLock {
                throw LockOperationTestError.expected
            }
        ) { error in
            XCTAssertEqual(error as? LockOperationTestError, .expected)
        }
        XCTAssertNoThrow(try lock.withLock {})
    }

    func testLockTimesOutWithinBoundWhileIndependentDescriptorHoldsFile() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = directoryURL.appendingPathComponent("migration.lock")
        let descriptor = try openLockFile(at: lockURL)
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let lock = LegacyMigrationLock(
            fileURL: lockURL,
            timeout: .milliseconds(5),
            retryInterval: .milliseconds(1)
        )
        let clock = ContinuousClock()
        let start = clock.now

        XCTAssertThrowsError(try lock.withLock {}) { error in
            XCTAssertEqual(error as? LegacyMigrationLockError, .timedOut)
        }

        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100))
    }

    func testPositiveSubnanosecondRetryRoundsUpToOneNanosecond() {
        let zero = LegacyMigrationLock.retrySleepTimespec(for: .zero)
        let subnanosecond = LegacyMigrationLock.retrySleepTimespec(
            for: Duration(secondsComponent: 0, attosecondsComponent: 1)
        )

        XCTAssertEqual(zero.tv_sec, 0)
        XCTAssertEqual(zero.tv_nsec, 0)
        XCTAssertEqual(subnanosecond.tv_sec, 0)
        XCTAssertEqual(subnanosecond.tv_nsec, 1)
    }

    func testLockTimesOutWhenRetrySleepReachesDeadlineBeforeNextAttempt() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = directoryURL.appendingPathComponent("migration.lock")
        let heldDescriptor = try openLockFile(at: lockURL)
        defer {
            _ = flock(heldDescriptor, LOCK_UN)
            _ = close(heldDescriptor)
        }
        XCTAssertEqual(flock(heldDescriptor, LOCK_EX | LOCK_NB), 0)
        let timing = DeterministicLegacyMigrationLockTiming(
            initialInstant: ContinuousClock.now,
            heldDescriptor: heldDescriptor
        )
        let lock = LegacyMigrationLock(
            fileURL: lockURL,
            timeout: .seconds(1),
            retryInterval: .seconds(1),
            now: { timing.now },
            sleep: { try timing.advanceAndReleaseHeldLock(by: $0) }
        )
        var operationRuns = 0

        XCTAssertThrowsError(
            try lock.withLock {
                operationRuns += 1
            }
        ) { error in
            XCTAssertEqual(error as? LegacyMigrationLockError, .timedOut)
        }
        XCTAssertEqual(timing.sleepCount, 1)
        XCTAssertEqual(operationRuns, 0)
    }

    func testParentReloadsPersistedMarkerAfterChildReleasesCrossProcessLock() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = directoryURL.appendingPathComponent("migration.lock")
        let markerURL = directoryURL.appendingPathComponent("marker")
        let bootstrapLock = LegacyMigrationLock(fileURL: lockURL)
        try bootstrapLock.withLock {}

        var readyPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&readyPipe) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let readyReadDescriptor = readyPipe[0]
        let readyWriteDescriptor = readyPipe[1]
        var readyReadIsOpen = true
        var readyWriteIsOpen = true
        defer {
            if readyReadIsOpen { _ = close(readyReadDescriptor) }
            if readyWriteIsOpen { _ = close(readyWriteDescriptor) }
        }

        guard let lockPath = strdup(lockURL.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer {
            free(lockPath)
        }
        guard let markerPath = strdup(markerURL.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer {
            free(markerPath)
        }

        var childHoldDuration = timespec(tv_sec: 0, tv_nsec: 75_000_000)
        let childPID = legacyMigrationTestFork()
        if childPID == 0 {
            _ = close(readyReadDescriptor)

            let descriptor: Int32 = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
            if descriptor < 0 {
                _ = close(readyWriteDescriptor)
                _exit(10)
            }
            if flock(descriptor, LOCK_EX) != 0 {
                _ = close(descriptor)
                _ = close(readyWriteDescriptor)
                _exit(11)
            }

            var byte: UInt8 = 1
            if Darwin.write(readyWriteDescriptor, &byte, 1) != 1 {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                _ = close(readyWriteDescriptor)
                _exit(12)
            }
            _ = close(readyWriteDescriptor)

            var remainingHoldDuration = timespec()
            while nanosleep(&childHoldDuration, &remainingHoldDuration) == -1 {
                if errno != EINTR {
                    _ = flock(descriptor, LOCK_UN)
                    _ = close(descriptor)
                    _exit(13)
                }
                childHoldDuration = remainingHoldDuration
            }

            let markerDescriptor: Int32 = Darwin.open(
                markerPath,
                O_CREAT | O_TRUNC | O_WRONLY,
                mode_t(0o600)
            )
            if markerDescriptor < 0 || Darwin.write(markerDescriptor, &byte, 1) != 1 {
                if markerDescriptor >= 0 { _ = close(markerDescriptor) }
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                _exit(14)
            }
            _ = close(markerDescriptor)
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            _exit(0)
        }
        guard childPID > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        _ = close(readyWriteDescriptor)
        readyWriteIsOpen = false
        var childNeedsReaping = true
        defer {
            if childNeedsReaping {
                if readyReadIsOpen {
                    _ = close(readyReadDescriptor)
                    readyReadIsOpen = false
                }
                if readyWriteIsOpen {
                    _ = close(readyWriteDescriptor)
                    readyWriteIsOpen = false
                }
                do {
                    try terminateAndReapChild(childPID)
                } catch {
                    XCTFail("Failed to reap forked lock-test child: \(error)")
                }
            }
        }

        try waitForReadableDescriptor(readyReadDescriptor, timeoutMilliseconds: 1_000)
        var byte: UInt8 = 0
        guard Darwin.read(readyReadDescriptor, &byte, 1) == 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        _ = close(readyReadDescriptor)
        readyReadIsOpen = false

        let parentLock = LegacyMigrationLock(
            fileURL: lockURL,
            timeout: .seconds(1),
            retryInterval: .milliseconds(2)
        )
        var protectedOperationRuns = 0
        var markerStore = PersistedMigrationMarkerStore(fileURL: markerURL)

        try parentLock.withLock {
            try markerStore.reload()
            if !markerStore.isComplete {
                protectedOperationRuns += 1
            }
        }

        XCTAssertEqual(markerStore.reloadCount, 1)
        XCTAssertTrue(markerStore.isComplete)
        XCTAssertEqual(protectedOperationRuns, 0)
        XCTAssertEqual(try waitForChild(childPID, timeoutMilliseconds: 1_000), 0)
        childNeedsReaping = false
    }

    private func makeTemporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigrationLockTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func openLockFile(at url: URL) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }

    private func waitForReadableDescriptor(
        _ descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws {
        var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = poll(&descriptorState, 1, timeoutMilliseconds)
            if result == 1, descriptorState.revents & Int16(POLLIN) != 0 {
                return
            }
            if result == -1, errno == EINTR { continue }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(result == 0 ? ETIMEDOUT : errno)
            )
        }
    }

    private func waitForChild(_ childPID: pid_t, timeoutMilliseconds: Int) throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        var status: Int32 = 0

        while ContinuousClock.now < deadline {
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID {
                return status
            }
            if result == -1 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            usleep(1_000)
        }

        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private func terminateAndReapChild(_ childPID: pid_t) throws {
        do {
            _ = try waitForChild(childPID, timeoutMilliseconds: 250)
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ECHILD) {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ETIMEDOUT) {
            // The child did not exit gracefully within its bounded hold interval.
        }

        if kill(childPID, SIGKILL) == -1, errno != ESRCH {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        _ = try waitForChild(childPID, timeoutMilliseconds: 1_000)
    }
}

private struct PersistedMigrationMarkerStore {
    let fileURL: URL
    private(set) var reloadCount = 0
    private(set) var isComplete = false

    mutating func reload() throws {
        reloadCount += 1
        isComplete = try Data(contentsOf: fileURL) == Data([1])
    }
}

private enum LockOperationTestError: Error, Equatable {
    case expected
}

private final class DeterministicLegacyMigrationLockTiming: @unchecked Sendable {
    private let stateLock = NSLock()
    private var currentInstant: ContinuousClock.Instant
    private let heldDescriptor: Int32
    private var recordedSleepCount = 0

    init(
        initialInstant: ContinuousClock.Instant,
        heldDescriptor: Int32
    ) {
        self.currentInstant = initialInstant
        self.heldDescriptor = heldDescriptor
    }

    var now: ContinuousClock.Instant {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentInstant
    }

    var sleepCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedSleepCount
    }

    func advanceAndReleaseHeldLock(by duration: Duration) throws {
        stateLock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        recordedSleepCount += 1
        stateLock.unlock()
        guard flock(heldDescriptor, LOCK_UN) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
