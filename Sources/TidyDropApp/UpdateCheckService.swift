import Foundation
import TidyDropCore

private enum UpdateCheckError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case unexpectedStatus(Int)
    case responseTooLarge
    case malformedMetadata

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The official update endpoint is invalid."
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case .unexpectedStatus(let status):
            return "GitHub returned HTTP status \(status). Try again later."
        case .responseTooLarge:
            return "The release response exceeded TidyDrop's safety limit."
        case .malformedMetadata:
            return "GitHub returned release metadata TidyDrop could not validate."
        }
    }
}

private final class BoundedReleaseRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumResponseBytes = 512 * 1_024

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var responseData = Data()
    private var session: URLSession?
    private var finished = false

    func load(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.waitsForConnectivity = false

            let delegateQueue = OperationQueue()
            delegateQueue.name = "io.github.bugroo.tidydrop.update-check"
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.qualityOfService = .utility

            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            lock.lock()
            self.continuation = continuation
            self.session = session
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest redirectedRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(UpdateCheckError.invalidResponse))
            return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(UpdateCheckError.unexpectedStatus(response.statusCode)))
            return
        }
        if response.expectedContentLength > Self.maximumResponseBytes {
            completionHandler(.cancel)
            finish(.failure(UpdateCheckError.responseTooLarge))
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
        let exceedsLimit = data.count > Self.maximumResponseBytes - responseData.count
        if !exceedsLimit {
            responseData.append(data)
        }
        lock.unlock()

        if exceedsLimit {
            dataTask.cancel()
            finish(.failure(UpdateCheckError.responseTooLarge))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let data = responseData
        lock.unlock()
        finish(.success(data))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

struct UpdateCheckService {
    private static let endpoint = "https://api.github.com/repos/bugroo/tidydrop/releases?per_page=20"

    func check(
        channel: UpdateChannel,
        currentVersion: ReleaseVersion,
        productVersion: String
    ) async throws -> AvailableRelease? {
        guard let endpoint = URL(string: Self.endpoint),
              endpoint.scheme == "https",
              endpoint.host == "api.github.com",
              endpoint.path == "/repos/bugroo/tidydrop/releases" else {
            throw UpdateCheckError.invalidEndpoint
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TidyDrop/\(productVersion)", forHTTPHeaderField: "User-Agent")

        let data = try await BoundedReleaseRequest().load(request)
        guard let releases = try? JSONDecoder().decode([ReleaseMetadata].self, from: data) else {
            throw UpdateCheckError.malformedMetadata
        }
        return ReleaseSelectionPolicy.latestNewerRelease(
            in: releases,
            channel: channel,
            currentVersion: currentVersion
        )
    }
}
