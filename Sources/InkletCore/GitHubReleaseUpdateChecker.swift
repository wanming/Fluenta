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

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(currentBuildNumber: String?) async throws -> AppUpdateCheckResult {
        guard let currentBuildNumber,
              let currentBuild = Self.parseCanonicalPositiveInteger(currentBuildNumber)
        else {
            throw AppUpdateCheckError.currentVersionUnavailable
        }

        try Task.checkCancellation()

        let request = Self.makeRequest()
        let data: Data
        let response: URLResponse
        let redirectDelegate = RedirectRejectingDelegate()

        do {
            (data, response) = try await session.data(
                for: request,
                delegate: redirectDelegate
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if redirectDelegate.didRejectRedirect {
                throw AppUpdateCheckError.serviceUnavailable
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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateCheckError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateCheckError.serviceUnavailable
        }

        if httpResponse.expectedContentLength != NSURLSessionTransferSizeUnknown,
           httpResponse.expectedContentLength > Int64(Self.maximumResponseSize) {
            throw AppUpdateCheckError.invalidResponse
        }
        guard data.count <= Self.maximumResponseSize else {
            throw AppUpdateCheckError.invalidResponse
        }

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

    private static func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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

final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejectedRedirect = false

    var didRejectRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
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
    public static func excerpt(_ body: String?, limit: Int = 800) -> String {
        guard limit > 0, let body else {
            return ""
        }

        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }

        guard normalized.count > limit else {
            return normalized
        }
        return String(normalized.prefix(limit - 1)) + "…"
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

enum InkletReleaseValidationError: Error, Equatable {
    case invalidTag
    case unavailableRelease
    case invalidAsset
    case invalidPageURL
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
