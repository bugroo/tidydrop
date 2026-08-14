import Foundation
import TidyDropUpdateSecurity

public enum UpdateTransportFailure: Error, Equatable, Sendable {
    case invalidRequest
    case redirectRejected
    case tooManyRedirects
    case authenticationRejected
    case invalidResponse
    case unexpectedStatus(Int)
    case contentLengthMismatch(declared: Int64, authenticated: UInt64)
    case networkFailure
    case cancelled
    case stagingFailure(UpdateStagingFailure)
}

public final class UpdateDownloadOperation: @unchecked Sendable {
    private let cancellation: @Sendable () -> Void

    fileprivate init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        cancellation()
    }
}

/// A non-shipping transport boundary for a future authenticated updater.
///
/// The request URL is derived only from authenticated manifest fields and the
/// fixed official repository. Bytes stream directly into private staging. This
/// type does not mount, extract, install, launch, or replace an application.
public enum FixedOriginUpdateTransport {
    private static let repositoryHost = "github.com"
    private static let assetHost = "release-assets.githubusercontent.com"
    private static let maximumRedirects = 3
    private static let requestTimeout: TimeInterval = 20
    private static let resourceTimeout: TimeInterval = 5 * 60

    public static func artifactURL(
        for authenticatedManifest: AuthenticatedReleaseManifest
    ) throws -> URL {
        let manifest = authenticatedManifest.manifest
        let path = "/bugroo/tidydrop/releases/download/\(manifest.version.tag)/\(manifest.artifactName)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = repositoryHost
        components.percentEncodedPath = path
        guard let url = components.url,
              isAllowedURL(url, initialURL: url) else {
            throw UpdateTransportFailure.invalidRequest
        }
        return url
    }

    @discardableResult
    public static func start(
        authenticatedManifest: AuthenticatedReleaseManifest,
        stagingParent: URL,
        maximumBytes: UInt64,
        completion: @escaping @Sendable (Result<StagedUpdateArtifact, UpdateTransportFailure>) -> Void
    ) throws -> UpdateDownloadOperation {
        try start(
            authenticatedManifest: authenticatedManifest,
            stagingParent: stagingParent,
            maximumBytes: maximumBytes,
            protocolClasses: nil,
            completion: completion
        )
    }

    @_spi(Testing)
    public static func startForTesting(
        authenticatedManifest: AuthenticatedReleaseManifest,
        stagingParent: URL,
        maximumBytes: UInt64,
        protocolClasses: [AnyClass],
        completion: @escaping @Sendable (Result<StagedUpdateArtifact, UpdateTransportFailure>) -> Void
    ) throws -> UpdateDownloadOperation {
        guard !protocolClasses.isEmpty else {
            throw UpdateTransportFailure.invalidRequest
        }
        return try start(
            authenticatedManifest: authenticatedManifest,
            stagingParent: stagingParent,
            maximumBytes: maximumBytes,
            protocolClasses: protocolClasses,
            completion: completion
        )
    }

    private static func start(
        authenticatedManifest: AuthenticatedReleaseManifest,
        stagingParent: URL,
        maximumBytes: UInt64,
        protocolClasses: [AnyClass]?,
        completion: @escaping @Sendable (Result<StagedUpdateArtifact, UpdateTransportFailure>) -> Void
    ) throws -> UpdateDownloadOperation {
        let initialURL = try artifactURL(for: authenticatedManifest)
        guard authenticatedManifest.manifest.artifactLength <= UInt64(Int64.max) else {
            throw UpdateTransportFailure.invalidRequest
        }
        let writer: PrivateUpdateStagingWriter
        do {
            writer = try PrivateUpdateStagingWriter.create(
                in: stagingParent,
                authenticatedManifest: authenticatedManifest,
                maximumBytes: maximumBytes
            )
        } catch let failure as UpdateStagingFailure {
            throw UpdateTransportFailure.stagingFailure(failure)
        } catch {
            throw UpdateTransportFailure.invalidRequest
        }

        let delegate = UpdateTransportDelegate(
            initialURL: initialURL,
            expectedBytes: Int64(authenticatedManifest.manifest.artifactLength),
            writer: writer,
            completion: completion
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }

        let delegateQueue = OperationQueue()
        delegateQueue.name = "io.github.bugroo.tidydrop.authenticated-update-transport"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        var request = URLRequest(url: initialURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("TidyDrop-UpdateTransport/1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        delegate.attach(session: session, task: task)
        task.resume()

        return UpdateDownloadOperation { delegate.cancel() }
    }

    public static func sanitizedRedirect(
        _ proposed: URLRequest,
        initialURL: URL,
        redirectCount: Int
    ) -> Result<URLRequest, UpdateTransportFailure> {
        guard redirectCount <= maximumRedirects else {
            return .failure(.tooManyRedirects)
        }
        guard let url = proposed.url,
              isAllowedURL(url, initialURL: initialURL),
              proposed.httpMethod == nil || proposed.httpMethod == "GET" else {
            return .failure(.redirectRejected)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("TidyDrop-UpdateTransport/1", forHTTPHeaderField: "User-Agent")
        return .success(request)
    }

    public static func validateResponse(
        statusCode: Int,
        declaredContentLength: Int64,
        authenticatedLength: UInt64
    ) throws {
        guard statusCode == 200 else {
            throw UpdateTransportFailure.unexpectedStatus(statusCode)
        }
        guard authenticatedLength <= UInt64(Int64.max) else {
            throw UpdateTransportFailure.invalidRequest
        }
        if declaredContentLength > 0,
           declaredContentLength != Int64(authenticatedLength) {
            throw UpdateTransportFailure.contentLengthMismatch(
                declared: declaredContentLength,
                authenticated: authenticatedLength
            )
        }
    }

    private static func isAllowedURL(_ url: URL, initialURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        if host == repositoryHost {
            return url == initialURL
        }
        return host == assetHost
    }
}

private final class UpdateTransportDelegate: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let initialURL: URL
    private let expectedBytes: Int64
    private let writer: PrivateUpdateStagingWriter
    private var completion: (@Sendable (Result<StagedUpdateArtifact, UpdateTransportFailure>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var redirectCount = 0
    private var requestedCancellation = false
    private var terminalFailure: UpdateTransportFailure?
    private var completed = false

    init(
        initialURL: URL,
        expectedBytes: Int64,
        writer: PrivateUpdateStagingWriter,
        completion: @escaping @Sendable (Result<StagedUpdateArtifact, UpdateTransportFailure>) -> Void
    ) {
        self.initialURL = initialURL
        self.expectedBytes = expectedBytes
        self.writer = writer
        self.completion = completion
    }

    func attach(session: URLSession, task: URLSessionTask) {
        lock.lock()
        self.session = session
        self.task = task
        let shouldCancel = requestedCancellation
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requestedCancellation = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        switch FixedOriginUpdateTransport.sanitizedRedirect(
            request,
            initialURL: initialURL,
            redirectCount: count
        ) {
        case .success(let safeRequest):
            completionHandler(safeRequest)
        case .failure(let failure):
            record(failure)
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            record(.authenticationRejected)
            completionHandler(.cancelAuthenticationChallenge, nil)
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            record(.invalidResponse)
            completionHandler(.cancel)
            return
        }
        do {
            try FixedOriginUpdateTransport.validateResponse(
                statusCode: response.statusCode,
                declaredContentLength: response.expectedContentLength,
                authenticatedLength: UInt64(expectedBytes)
            )
        } catch let failure as UpdateTransportFailure {
            record(failure)
            completionHandler(.cancel)
            return
        } catch {
            record(.invalidResponse)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let cancelled = requestedCancellation
        lock.unlock()
        if cancelled {
            dataTask.cancel()
            return
        }
        do {
            try writer.append(data)
        } catch let failure as UpdateStagingFailure {
            record(.stagingFailure(failure))
            dataTask.cancel()
        } catch {
            record(.networkFailure)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let cancelled = requestedCancellation
        let failure = terminalFailure
        lock.unlock()

        if cancelled {
            writer.cancel()
            finish(.failure(.cancelled))
            return
        }
        if let failure {
            writer.cancel()
            finish(.failure(failure))
            return
        }
        if error != nil {
            writer.cancel()
            finish(.failure(.networkFailure))
            return
        }
        do {
            finish(.success(try writer.finish()))
        } catch let failure as UpdateStagingFailure {
            finish(.failure(.stagingFailure(failure)))
        } catch {
            finish(.failure(.networkFailure))
        }
    }

    private func record(_ failure: UpdateTransportFailure) {
        lock.lock()
        if terminalFailure == nil { terminalFailure = failure }
        lock.unlock()
    }

    private func finish(_ result: Result<StagedUpdateArtifact, UpdateTransportFailure>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let completion = self.completion
        self.completion = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        completion?(result)
    }
}
