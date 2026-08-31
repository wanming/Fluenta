import Foundation

public enum AppUpdateCheckResult: Equatable, Sendable {
    case updateAvailable(InkletRelease)
    case upToDate(InkletRelease)
}

public enum AppUpdateCheckError: Error, Equatable, Sendable {
    case networkUnavailable
    case serviceUnavailable
    case invalidResponse
    case currentVersionUnavailable
}

public struct GitHubReleaseUpdateChecker: Sendable {
    private static let endpoint = URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")!
    private static let maximumResponseSize = 1_048_576
    private static let defaultTimeoutInterval: TimeInterval = 15

    private let session: URLSession
    private let timeoutInterval: TimeInterval

    public init() {
        session = URLSession(configuration: Self.makeSessionConfiguration())
        timeoutInterval = Self.defaultTimeoutInterval
    }

    init(session: URLSession, timeoutInterval: TimeInterval = Self.defaultTimeoutInterval) {
        precondition(timeoutInterval > 0 && timeoutInterval.isFinite)
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = defaultTimeoutInterval
        return configuration
    }

    public func check(currentBuildNumber: String?) async throws -> AppUpdateCheckResult {
        guard let currentBuildNumber,
              let currentBuild = Self.parseCanonicalPositiveInteger(currentBuildNumber)
        else {
            throw AppUpdateCheckError.currentVersionUnavailable
        }

        try Task.checkCancellation()

        let request = Self.makeRequest(timeoutInterval: timeoutInterval)
        let data: Data
        let responseLoader = BoundedHTTPResponseLoader(
            expectedURL: Self.endpoint,
            maximumResponseSize: Self.maximumResponseSize
        )

        do {
            data = try await responseLoader.load(
                request: request,
                configuration: session.configuration,
                timeoutInterval: timeoutInterval
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if error is UpdateCheckDeadlineExceeded {
                throw AppUpdateCheckError.networkUnavailable
            }
            if responseLoader.didRejectRedirect {
                throw AppUpdateCheckError.serviceUnavailable
            }
            if responseLoader.didRejectAuthentication {
                throw AppUpdateCheckError.serviceUnavailable
            }
            if let error = error as? AppUpdateCheckError {
                throw error
            }
            if error is CancellationError {
                throw CancellationError()
            }
            if let error = error as? URLError, error.code == .cancelled {
                throw CancellationError()
            }
            throw AppUpdateCheckError.networkUnavailable
        }

        try Task.checkCancellation()

        let release: InkletRelease
        do {
            release = try GitHubReleaseParser.parse(data)
        } catch {
            throw AppUpdateCheckError.invalidResponse
        }

        try Task.checkCancellation()

        if release.version.buildNumber > currentBuild {
            return .updateAvailable(release)
        }
        return .upToDate(release)
    }

    private static func makeRequest(timeoutInterval: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private static func parseCanonicalPositiveInteger(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              value.count == 1 || value.first != "0",
              let integer = Int(value),
              integer > 0
        else {
            return nil
        }
        return integer
    }
}

struct UpdateCheckDeadlineExceeded: Error {}

final class BoundedHTTPResponseLoader: RedirectRejectingDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private enum CompletionSource {
        case transport
        case deadlineTask
        case parentCancellation
    }

    private let expectedURL: URL
    private let maximumResponseSize: Int
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadlineTask: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var responseAccepted = false
    private var data = Data()
    private var finished = false

    init(
        expectedURL: URL,
        maximumResponseSize: Int,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.expectedURL = expectedURL
        self.maximumResponseSize = maximumResponseSize
        self.monotonicNow = monotonicNow
    }

    func load(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        timeoutInterval: TimeInterval
    ) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = monotonicNow().advanced(by: .seconds(timeoutInterval))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(
                    request: request,
                    configuration: configuration,
                    deadline: deadline,
                    clock: clock,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.finish(
                .failure(CancellationError()),
                cancellingTask: true,
                completionSource: .parentCancellation
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let rejection: AppUpdateCheckError?
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.url != expectedURL {
                rejection = .invalidResponse
            } else if !(200...299).contains(httpResponse.statusCode) {
                rejection = .serviceUnavailable
            } else if let contentEncoding = httpResponse.value(forHTTPHeaderField: "Content-Encoding"),
                      contentEncoding
                          .trimmingCharacters(in: .whitespacesAndNewlines)
                          .caseInsensitiveCompare("identity") != .orderedSame {
                rejection = .invalidResponse
            } else if httpResponse.expectedContentLength != NSURLSessionTransferSizeUnknown,
                      httpResponse.expectedContentLength > Int64(maximumResponseSize) {
                rejection = .invalidResponse
            } else {
                rejection = nil
            }
        } else {
            rejection = .invalidResponse
        }

        if let rejection {
            completionHandler(.cancel)
            finish(.failure(rejection), cancellingTask: true)
            return
        }

        lock.lock()
        let shouldAccept = !finished
        if shouldAccept {
            responseAccepted = true
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
        }
        lock.unlock()

        completionHandler(shouldAccept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
        lock.lock()
        let shouldReject: Bool
        if !finished, responseAccepted {
            // URLSession owns each uncompressed callback's allocation. Never copy a callback
            // that crosses the bound into our accumulator; identity encoding prevents amplification.
            if newData.count > maximumResponseSize - data.count {
                shouldReject = true
            } else {
                data.append(newData)
                shouldReject = false
            }
        } else {
            shouldReject = false
        }
        lock.unlock()

        if shouldReject {
            finish(.failure(AppUpdateCheckError.invalidResponse), cancellingTask: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if didRejectAuthentication {
            finish(.failure(AppUpdateCheckError.serviceUnavailable), cancellingTask: false)
            return
        }
        if let error {
            finish(.failure(error), cancellingTask: false)
            return
        }

        lock.lock()
        let responseAccepted = self.responseAccepted
        let completedData = data
        lock.unlock()

        if responseAccepted {
            finish(.success(completedData), cancellingTask: false)
        } else {
            finish(.failure(AppUpdateCheckError.invalidResponse), cancellingTask: false)
        }
    }

    private func start(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock,
        continuation: CheckedContinuation<Data, Error>
    ) {
        let requestConfiguration = configuration.copy() as! URLSessionConfiguration
        requestConfiguration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(
            configuration: requestConfiguration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        let deadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.finish(
                .failure(UpdateCheckDeadlineExceeded()),
                cancellingTask: true,
                completionSource: .deadlineTask
            )
        }

        lock.lock()
        if finished {
            let result = pendingResult ?? .failure(CancellationError())
            pendingResult = nil
            lock.unlock()

            deadlineTask.cancel()
            task.cancel()
            session.invalidateAndCancel()
            continuation.resume(with: result)
            return
        }

        self.continuation = continuation
        self.session = session
        self.task = task
        self.deadlineTask = deadlineTask
        self.deadline = deadline
        lock.unlock()

        task.resume()
    }

    private func finish(
        _ result: Result<Data, Error>,
        cancellingTask: Bool,
        completionSource: CompletionSource = .transport
    ) {
        let continuation: CheckedContinuation<Data, Error>?
        let session: URLSession?
        let task: URLSessionDataTask?
        let deadlineTask: Task<Void, Never>?
        let resolvedResult: Result<Data, Error>
        let shouldCancelTask: Bool

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if completionSource != .parentCancellation,
           let deadline,
           monotonicNow() >= deadline {
            resolvedResult = .failure(UpdateCheckDeadlineExceeded())
            shouldCancelTask = true
        } else {
            resolvedResult = result
            shouldCancelTask = cancellingTask
        }
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = resolvedResult
        }
        session = self.session
        self.session = nil
        task = self.task
        self.task = nil
        deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        self.deadline = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()

        deadlineTask?.cancel()
        if shouldCancelTask {
            task?.cancel()
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation?.resume(with: resolvedResult)
    }
}

class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejectedRedirect = false
    private var rejectedAuthentication = false

    var didRejectRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
    }

    var didRejectAuthentication: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedAuthentication
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        rejectedRedirect = true
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            lock.lock()
            rejectedAuthentication = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public struct InkletReleaseVersion: Equatable, Sendable {
    public let marketingVersion: String
    public let buildNumber: Int

    init(marketingVersion: String, buildNumber: Int) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    public init(tagName: String) throws {
        guard tagName.first == "v" else {
            throw InkletReleaseValidationError.invalidTag
        }

        let parts = tagName.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let buildNumber = Self.parseCanonicalPositiveInteger(parts[1])
        else {
            throw InkletReleaseValidationError.invalidTag
        }

        let versionComponents = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard versionComponents.count == 3,
              versionComponents.allSatisfy({ Self.parseCanonicalNonNegativeInteger($0) != nil })
        else {
            throw InkletReleaseValidationError.invalidTag
        }

        marketingVersion = versionComponents.map(String.init).joined(separator: ".")
        self.buildNumber = buildNumber
    }

    private static func parseCanonicalPositiveInteger(_ value: Substring) -> Int? {
        guard let integer = parseCanonicalNonNegativeInteger(value), integer > 0 else {
            return nil
        }
        return integer
    }

    private static func parseCanonicalNonNegativeInteger(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              value.count == 1 || value.first != "0"
        else {
            return nil
        }
        return Int(value)
    }
}

public enum InkletReleaseNotes {
    private static let maximumCharacterCount = 800
    private static let maximumUnicodeScalarCount = 3_200
    private static let maximumUTF8ByteCount = 12_800

    public static func excerpt(_ body: String?, limit: Int = 800) -> String {
        guard limit > 0, let body else {
            return ""
        }

        let normalized = UntrustedDisplayText.sanitize(body, preservingLineBreaks: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }

        return UntrustedDisplayText.bounded(
            normalized,
            maximumCharacters: min(limit, maximumCharacterCount),
            maximumUnicodeScalars: maximumUnicodeScalarCount,
            maximumUTF8Bytes: maximumUTF8ByteCount
        )
    }
}

public struct InkletRelease: Equatable, Sendable {
    public let version: InkletReleaseVersion
    public let tagName: String
    public let name: String?
    public let notes: String
    public let pageURL: URL

    init(
        version: InkletReleaseVersion,
        tagName: String,
        name: String?,
        notes: String,
        pageURL: URL
    ) {
        self.version = version
        self.tagName = tagName
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
    }
}

enum GitHubReleaseParser {
    fileprivate static let maximumNameCharacterCount = 120
    fileprivate static let maximumNameUnicodeScalarCount = 480
    fileprivate static let maximumNameUTF8ByteCount = 1_920

    static func parse(_ data: Data) throws -> InkletRelease {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.draft, !response.prerelease else {
            throw InkletReleaseValidationError.unavailableRelease
        }

        guard response.assets.contains(where: { $0.name == "Inklet.dmg" && $0.state == "uploaded" }) else {
            throw InkletReleaseValidationError.invalidAsset
        }

        let version = try InkletReleaseVersion(tagName: response.tagName)
        let pageURL = try validatedPageURL(response.htmlURL, tagName: response.tagName)
        let name = response.name?
            .boundedReleaseName
            .nonEmpty

        return InkletRelease(
            version: version,
            tagName: response.tagName,
            name: name,
            notes: InkletReleaseNotes.excerpt(response.body),
            pageURL: pageURL
        )
    }

    private static func validatedPageURL(_ value: String, tagName: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host?.caseInsensitiveCompare("github.com") == .orderedSame,
              components.percentEncodedHost?.caseInsensitiveCompare("github.com") == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil,
              components.fragment == nil
        else {
            throw InkletReleaseValidationError.invalidPageURL
        }

        let expectedPath = "/wanming/Inklet/releases/tag/\(tagName)"
        guard components.path == expectedPath,
              components.percentEncodedPath == expectedPath,
              let pageURL = URL(string: "https://github.com\(expectedPath)")
        else {
            throw InkletReleaseValidationError.invalidPageURL
        }
        return pageURL
    }

    private struct Response: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
    }
}

private enum UntrustedDisplayText {
    private static let ellipsis = "…"

    static func sanitize(_ value: String, preservingLineBreaks: Bool) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.unicodeScalars.reduce(into: "") { result, scalar in
            if !preservingLineBreaks, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append(" ")
                return
            }
            if preservingLineBreaks && (scalar == "\n" || scalar == "\t") {
                result.unicodeScalars.append(scalar)
                return
            }
            if scalar.value == 0x200C || scalar.value == 0x200D
                || (0xE0020...0xE007F).contains(scalar.value)
            {
                result.unicodeScalars.append(scalar)
                return
            }
            if !CharacterSet.controlCharacters.contains(scalar), !isBidirectionalControl(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    static func bounded(
        _ value: String,
        maximumCharacters: Int,
        maximumUnicodeScalars: Int,
        maximumUTF8Bytes: Int
    ) -> String {
        guard maximumCharacters > 0,
              maximumUnicodeScalars >= ellipsis.unicodeScalars.count,
              maximumUTF8Bytes >= ellipsis.utf8.count
        else {
            return ""
        }

        guard value.count > maximumCharacters
                || value.unicodeScalars.count > maximumUnicodeScalars
                || value.utf8.count > maximumUTF8Bytes
        else {
            return value
        }

        let characterBudget = maximumCharacters - ellipsis.count
        let scalarBudget = maximumUnicodeScalars - ellipsis.unicodeScalars.count
        let byteBudget = maximumUTF8Bytes - ellipsis.utf8.count
        var result = ""
        var characterCount = 0
        var scalarCount = 0
        var byteCount = 0

        for character in value {
            let characterScalarCount = character.unicodeScalars.count
            let characterByteCount = character.utf8.count
            guard characterCount < characterBudget,
                  scalarCount <= scalarBudget - characterScalarCount,
                  byteCount <= byteBudget - characterByteCount
            else {
                break
            }

            result.append(character)
            characterCount += 1
            scalarCount += characterScalarCount
            byteCount += characterByteCount
        }

        return result + ellipsis
    }

    private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        default:
            false
        }
    }
}

enum InkletReleaseValidationError: Error, Equatable {
    case invalidTag
    case unavailableRelease
    case invalidAsset
    case invalidPageURL
}

private extension String {
    var boundedReleaseName: String {
        let singleLine = UntrustedDisplayText
            .sanitize(self, preservingLineBreaks: false)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return UntrustedDisplayText.bounded(
            singleLine,
            maximumCharacters: GitHubReleaseParser.maximumNameCharacterCount,
            maximumUnicodeScalars: GitHubReleaseParser.maximumNameUnicodeScalarCount,
            maximumUTF8Bytes: GitHubReleaseParser.maximumNameUTF8ByteCount
        )
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
