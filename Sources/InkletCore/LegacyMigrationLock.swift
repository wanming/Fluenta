import Darwin
import Foundation

public enum LegacyMigrationLockError: Error, Equatable {
    case timedOut
}

public final class LegacyMigrationLock: @unchecked Sendable {
    private let fileURL: URL
    private let timeout: Duration
    private let retryInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) throws -> Void

    public convenience init(
        fileURL: URL,
        timeout: Duration = .seconds(5),
        retryInterval: Duration = .milliseconds(50)
    ) {
        self.init(
            fileURL: fileURL,
            timeout: timeout,
            retryInterval: retryInterval,
            now: { ContinuousClock.now },
            sleep: { try Self.sleepWithoutBusySpinning(for: $0) }
        )
    }

    init(
        fileURL: URL,
        timeout: Duration,
        retryInterval: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @Sendable (Duration) throws -> Void
    ) {
        self.fileURL = fileURL
        self.timeout = max(timeout, .zero)
        self.retryInterval = retryInterval > .zero ? retryInterval : .milliseconds(1)
        self.now = now
        self.sleep = sleep
    }

    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        let parentDirectoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let descriptor = try openLockFile()
        defer { _ = close(descriptor) }

        try acquire(descriptor)
        defer { _ = flock(descriptor, LOCK_UN) }

        return try operation()
    }

    private func openLockFile() throws -> Int32 {
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw Self.posixError()
        }
        return descriptor
    }

    private func acquire(_ descriptor: Int32) throws {
        let deadline = now().advanced(by: timeout)
        var isInitialAttempt = true

        while true {
            if !isInitialAttempt, now() >= deadline {
                throw LegacyMigrationLockError.timedOut
            }
            let currentAttemptIsInitial = isInitialAttempt
            isInitialAttempt = false
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                if !currentAttemptIsInitial, now() >= deadline {
                    _ = flock(descriptor, LOCK_UN)
                    throw LegacyMigrationLockError.timedOut
                }
                return
            }

            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw Self.posixError(code: lockError)
            }

            let currentInstant = now()
            guard currentInstant < deadline else {
                throw LegacyMigrationLockError.timedOut
            }

            try sleep(
                min(retryInterval, currentInstant.duration(to: deadline))
            )
        }
    }

    private static func sleepWithoutBusySpinning(for duration: Duration) throws {
        var requested = Self.retrySleepTimespec(for: duration)
        guard requested.tv_sec > 0 || requested.tv_nsec > 0 else { return }
        var remaining = timespec()
        while nanosleep(&requested, &remaining) == -1 {
            let sleepError = errno
            guard sleepError == EINTR else {
                throw posixError(code: sleepError)
            }
            requested = remaining
        }
    }

    static func retrySleepTimespec(for duration: Duration) -> timespec {
        guard duration > .zero else { return timespec() }

        let attosecondsPerNanosecond: Int64 = 1_000_000_000
        let nanosecondsPerSecond: Int64 = 1_000_000_000
        let components = duration.components
        var seconds = components.seconds
        var nanoseconds = components.attoseconds / attosecondsPerNanosecond
        if components.attoseconds % attosecondsPerNanosecond != 0 {
            nanoseconds += 1
        }
        if nanoseconds >= nanosecondsPerSecond {
            if seconds < Int64.max {
                seconds += 1
                nanoseconds -= nanosecondsPerSecond
            } else {
                nanoseconds = nanosecondsPerSecond - 1
            }
        }
        return timespec(
            tv_sec: Int(clamping: seconds),
            tv_nsec: Int(nanoseconds)
        )
    }

    private static func posixError(code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
