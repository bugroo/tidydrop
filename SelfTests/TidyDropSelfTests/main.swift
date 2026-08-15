import CryptoKit
import Foundation
import SQLite3
import TidyDropCore
@_spi(Testing) import TidyDropUpdateInspection
@_spi(Testing) import TidyDropUpdateRecovery
import TidyDropUpdateSecurity
@_spi(Testing) import TidyDropUpdateTransport
#if os(macOS)
import Darwin

@objc private protocol SignedXPCProbeProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
}

private final class SignedXPCProbeService: NSObject, SignedXPCProbeProtocol {
    func ping(withReply reply: @escaping (String) -> Void) {
        reply("tidydrop-xpc-ok")
    }
}

private final class SignedXPCProbeListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let clientRequirement: String
    private let service = SignedXPCProbeService()

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.setCodeSigningRequirement(clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: SignedXPCProbeProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
#else
import Glibc
#endif

private struct XCTSkip: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private enum TestRuntime {
    // The custom harness executes tests serially on the process main thread.
    nonisolated(unsafe) static var failures: [String] = []

    static func reset() {
        failures.removeAll(keepingCapacity: true)
    }

    static func fail(_ message: String, file: StaticString, line: UInt) {
        failures.append("\(file):\(line): \(message)")
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try !expression() {
            let detail = message()
            TestRuntime.fail(detail.isEmpty ? "Se esperaba true" : detail, file: file, line: line)
        }
    } catch {
        TestRuntime.fail("La expresión lanzó un error: \(error)", file: file, line: line)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try expression() {
            let detail = message()
            TestRuntime.fail(detail.isEmpty ? "Se esperaba false" : detail, file: file, line: line)
        }
    } catch {
        TestRuntime.fail("La expresión lanzó un error: \(error)", file: file, line: line)
    }
}

private func XCTAssertEqual<T: Equatable>(
    _ lhs: @autoclosure () throws -> T,
    _ rhs: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let left = try lhs()
        let right = try rhs()
        if left != right {
            let detail = message()
            TestRuntime.fail(
                detail.isEmpty ? "No son iguales: \(String(describing: left)) != \(String(describing: right))" : detail,
                file: file,
                line: line
            )
        }
    } catch {
        TestRuntime.fail("La comparación lanzó un error: \(error)", file: file, line: line)
    }
}

private func XCTAssertEqual<T: BinaryFloatingPoint>(
    _ lhs: @autoclosure () throws -> T,
    _ rhs: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let left = try lhs()
        let right = try rhs()
        if abs(left - right) > accuracy {
            let detail = message()
            TestRuntime.fail(
                detail.isEmpty ? "Diferencia fuera de tolerancia: \(left) vs \(right), accuracy=\(accuracy)" : detail,
                file: file,
                line: line
            )
        }
    } catch {
        TestRuntime.fail("La comparación lanzó un error: \(error)", file: file, line: line)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ lhs: @autoclosure () throws -> T,
    _ rhs: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let left = try lhs()
        let right = try rhs()
        if left == right {
            let detail = message()
            TestRuntime.fail(
                detail.isEmpty ? "Se esperaban valores distintos: \(String(describing: left))" : detail,
                file: file,
                line: line
            )
        }
    } catch {
        TestRuntime.fail("La comparación lanzó un error: \(error)", file: file, line: line)
    }
}

private func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try expression() == nil {
            let detail = message()
            TestRuntime.fail(detail.isEmpty ? "Se esperaba un valor no nil" : detail, file: file, line: line)
        }
    } catch {
        TestRuntime.fail("La expresión lanzó un error: \(error)", file: file, line: line)
    }
}

private func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        let detail = message()
        TestRuntime.fail(detail.isEmpty ? "Se esperaba un error" : detail, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private func XCTFail(
    _ message: String = "Fallo explícito",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    TestRuntime.fail(message, file: file, line: line)
}


private struct StubMIMETypeDetector: MIMETypeDetecting {
    let value: String?
    func mimeType(for url: URL) -> String? { value }
}

private final class RenameThenThrowMover {
    private var throwsRemaining: Int

    init(throws: Int = 1) {
        self.throwsRemaining = `throws`
    }

    func move(from source: URL, to destination: URL, snapshot: FileSnapshot) throws {
        try FileSystemSecurity.moveRegularFileExclusively(
            from: source,
            to: destination,
            expectedSnapshot: snapshot
        )
        if throwsRemaining > 0 {
            throwsRemaining -= 1
            throw NSError(
                domain: "TidyDropTests.RenameThenThrow",
                code: 91,
                userInfo: [NSLocalizedDescriptionKey: "injected error after rename"]
            )
        }
    }
}

private final class MutateBeforeMoveFileManager: FileManager, @unchecked Sendable {
    let sourceFile: URL
    private var mutated = false

    init(sourceFile: URL) {
        self.sourceFile = sourceFile
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if url.lastPathComponent == "Documentos", !mutated {
            mutated = true
            try Data("changed-before-move".utf8).write(to: sourceFile)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

private final class TemporaryWorkspace {
    let root: URL
    let source: URL
    let state: URL
    let logs: URL

    init() throws {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("TidyDropIntegration.selftest.\(UUID().uuidString)", isDirectory: true)
        self.root = base
        self.source = base.appendingPathComponent("Downloads", isDirectory: true)
        self.state = base.appendingPathComponent("state", isDirectory: true)
        self.logs = base.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeConfig(
        observations: Int = 1,
        minimumAge: Double = 0,
        probeDelayMilliseconds: Int = 0,
        useMIME: Bool = false
    ) throws -> ResolvedConfiguration {
        var config = DefaultConfiguration.make()
        config.paths = PathsConfig(
            sourceDirectory: source.path,
            destinationRoot: source.path,
            stateDirectory: state.path,
            logDirectory: logs.path
        )
        config.automation.applyEnabled = false
        config.stability.minimumStableObservations = observations
        config.stability.minimumAgeSeconds = minimumAge
        config.stability.probeDelayMilliseconds = probeDelayMilliseconds
        config.classification.useMIMEFallback = useMIME
        config.safety.maxFilesPerRun = 1_000
        return try ConfigurationIO.resolve(config)
    }

    @discardableResult
    func createFile(_ relativePath: String, contents: String = "data") throws -> URL {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }
}

private struct SignedReleaseManifestFixture {
    let workspace: TemporaryWorkspace
    let artifactURL: URL
    let artifactData: Data
    let manifest: ReleaseManifest
    let manifestData: Data
    let signature: Data
    let publicKey: Data
    let currentVersion: ReleaseVersion
    let now: Date

    init(
        publishedAt: Date = Date(timeIntervalSince1970: 1_786_640_000),
        artifactName: String = "TidyDrop-1.3.0-community-preview-macos-universal.dmg",
        artifactData suppliedArtifactData: Data? = nil,
        currentTag: String = "v1.3.0-community.1",
        nextTag: String = "v1.3.0-community.2"
    ) throws {
        guard let currentVersion = ReleaseVersion.parse(
            tag: currentTag,
            channel: .community
        ), let nextVersion = ReleaseVersion.parse(
            tag: nextTag,
            channel: .community
        ) else {
            throw NSError(domain: "TidyDropTests.ReleaseManifest", code: 1)
        }
        let workspace = try TemporaryWorkspace()
        let artifactData = suppliedArtifactData ?? Data("signed update artifact\n".utf8)
        let artifactURL = workspace.root.appendingPathComponent(artifactName)
        try artifactData.write(to: artifactURL, options: .atomic)
        let manifest = ReleaseManifest(
            version: nextVersion,
            channel: .community,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            artifactName: artifactName,
            artifactLength: UInt64(artifactData.count),
            artifactSHA256: ReleaseManifestVerifier.sha256Hex(of: artifactData),
            minimumMacOS: OperatingSystemVersion(
                majorVersion: 13,
                minorVersion: 0,
                patchVersion: 0
            ),
            publishedAt: publishedAt
        )
        let manifestData = try ReleaseManifestCodec.encode(manifest)
        let ephemeralSigner = Curve25519.Signing.PrivateKey()
        self.workspace = workspace
        self.artifactURL = artifactURL
        self.artifactData = artifactData
        self.manifest = manifest
        self.manifestData = manifestData
        self.signature = try ephemeralSigner.signature(for: manifestData)
        self.publicKey = ephemeralSigner.publicKey.rawRepresentation
        self.currentVersion = currentVersion
        self.now = publishedAt.addingTimeInterval(60)
    }

    func policy(
        currentVersion: ReleaseVersion? = nil,
        channel: UpdateChannel = .community,
        bundleIdentifier: String = "io.github.bugroo.tidydrop",
        artifactName: String? = nil,
        maximumArtifactBytes: UInt64 = 100 * 1_024 * 1_024,
        currentSystem: OperatingSystemVersion = OperatingSystemVersion(
            majorVersion: 14,
            minorVersion: 0,
            patchVersion: 0
        ),
        now: Date? = nil,
        newestAcceptedPublication: Date? = nil,
        maximumManifestAge: TimeInterval = 90 * 24 * 60 * 60,
        futureTolerance: TimeInterval = 5 * 60
    ) -> ReleaseManifestPolicy {
        ReleaseManifestPolicy(
            currentVersion: currentVersion ?? self.currentVersion,
            channel: channel,
            bundleIdentifier: bundleIdentifier,
            artifactName: artifactName ?? manifest.artifactName,
            maximumArtifactBytes: maximumArtifactBytes,
            currentSystem: currentSystem,
            now: now ?? self.now,
            newestAcceptedPublication: newestAcceptedPublication,
            maximumManifestAge: maximumManifestAge,
            futureTolerance: futureTolerance
        )
    }

    func authenticated() throws -> AuthenticatedReleaseManifest {
        try ReleaseManifestVerifier.authenticateManifest(
            manifestData: manifestData,
            signature: signature,
            publicKey: publicKey,
            policy: policy()
        )
    }
}

#if os(macOS)
private final class LockedResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        let value = self.value
        lock.unlock()
        return value
    }
}

private final class UpdateTransportURLProtocol: URLProtocol, @unchecked Sendable {
    enum Plan: Sendable {
        case response(data: Data, status: Int, declaredLength: Int64?)
        case delayed(data: Data, nanoseconds: UInt64)
    }

    private static let planLock = NSLock()
    nonisolated(unsafe) private static var configuredPlan: Plan?
    nonisolated(unsafe) private static var observedRequest: URLRequest?
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(_ plan: Plan) {
        planLock.lock()
        configuredPlan = plan
        observedRequest = nil
        planLock.unlock()
    }

    static func request() -> URLRequest? {
        planLock.lock()
        let request = observedRequest
        planLock.unlock()
        return request
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host?.lowercased()
        return host == "github.com" || host == "release-assets.githubusercontent.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.planLock.lock()
        Self.observedRequest = request
        let plan = Self.configuredPlan
        Self.planLock.unlock()
        guard let plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch plan {
        case let .response(data, status, declaredLength):
            emit(data: data, status: status, declaredLength: declaredLength)
        case let .delayed(data, nanoseconds):
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds))
            ) { [weak self] in
                self?.emit(data: data, status: 200, declaredLength: Int64(data.count))
            }
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func emit(data: Data, status: Int, declaredLength: Int64?) {
        stateLock.lock()
        let stopped = self.stopped
        stateLock.unlock()
        guard !stopped, let url = request.url else { return }
        var headers: [String: String] = [:]
        if let declaredLength { headers["Content-Length"] = String(declaredLength) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let split = data.count / 2
        if split > 0 { client?.urlProtocol(self, didLoad: data.prefix(split)) }
        client?.urlProtocol(self, didLoad: data.suffix(from: split))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif

private final class TidyDropCoreTests {
    func testExtensionClassificationUsesLongestCompoundExtension() throws {
        var classification = DefaultConfiguration.make().classification
        classification.useMIMEFallback = false
        let classifier = try FileClassifier(config: classification, detector: NullMIMETypeDetector())

        let decision = classifier.classify(URL(fileURLWithPath: "/tmp/ARCHIVE.TAR.GZ"))
        XCTAssertEqual(decision.category, "Archivos comprimidos")
        XCTAssertEqual(decision.matchedExtension, "tar.gz")
        XCTAssertEqual(decision.reason, "extension:.tar.gz")
    }

    func testKnownExtensionPrecedesNamePattern() throws {
        var classification = DefaultConfiguration.make().classification
        classification.useMIMEFallback = false
        let classifier = try FileClassifier(config: classification, detector: NullMIMETypeDetector())

        let decision = classifier.classify(URL(fileURLWithPath: "/tmp/README.zip"))
        XCTAssertEqual(decision.category, "Archivos comprimidos")
    }

    func testExtensionlessDockerfileUsesNamePattern() throws {
        var classification = DefaultConfiguration.make().classification
        classification.useMIMEFallback = false
        let classifier = try FileClassifier(config: classification, detector: NullMIMETypeDetector())

        let decision = classifier.classify(URL(fileURLWithPath: "/tmp/Dockerfile"))
        XCTAssertEqual(decision.category, "Código")
        XCTAssertTrue(decision.reason.hasPrefix("name_pattern:"))
    }



    func testFallbackCategoryUsesCanonicalConfiguredCategoryName() throws {
        var classification = DefaultConfiguration.make().classification
        classification.useMIMEFallback = false
        classification.fallbackCategory = "otros"
        let classifier = try FileClassifier(config: classification, detector: NullMIMETypeDetector())

        let decision = classifier.classify(URL(fileURLWithPath: "/tmp/no-extension-and-no-pattern"))
        XCTAssertEqual(decision.category, "Otros")
    }

    func testSystemMIMEDetectorUsesNativeFileUtilityWhenAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/file") else {
            throw XCTSkip("/usr/bin/file no está disponible")
        }
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("mime-probe", contents: "plain text\n")
        let detected = SystemMIMETypeDetector().mimeType(for: file)
        XCTAssertEqual(detected, "text/plain")
    }

    func testMIMEFallbackClassifiesUnknownExtension() throws {
        var classification = DefaultConfiguration.make().classification
        classification.useMIMEFallback = true
        let classifier = try FileClassifier(
            config: classification,
            detector: StubMIMETypeDetector(value: "image/png")
        )

        let decision = classifier.classify(URL(fileURLWithPath: "/tmp/blob.unknown"))
        XCTAssertEqual(decision.category, "Imágenes")
        XCTAssertEqual(decision.mimeType, "image/png")
    }

    func testExclusionsCoverHiddenTemporarySymlinkAndDirectory() throws {
        let evaluator = try ExclusionEvaluator(config: DefaultConfiguration.make().exclusions)
        let regular = FileSnapshot(size: 1, modificationTime: 0, fileIdentifier: "1")

        XCTAssertEqual(
            evaluator.exclusionReason(
                url: URL(fileURLWithPath: "/tmp/.secret.pdf"),
                facts: ItemFacts(isRegularFile: true, isDirectory: false, isSymbolicLink: false, isHidden: true, snapshot: regular)
            ),
            "hidden"
        )
        XCTAssertEqual(
            evaluator.exclusionReason(
                url: URL(fileURLWithPath: "/tmp/file.crdownload"),
                facts: ItemFacts(isRegularFile: true, isDirectory: false, isSymbolicLink: false, isHidden: false, snapshot: regular)
            ),
            "temporary_or_incomplete_extension"
        )
        XCTAssertEqual(
            evaluator.exclusionReason(
                url: URL(fileURLWithPath: "/tmp/link.pdf"),
                facts: ItemFacts(isRegularFile: false, isDirectory: false, isSymbolicLink: true, isHidden: false, snapshot: nil)
            ),
            "symlink"
        )
        XCTAssertEqual(
            evaluator.exclusionReason(
                url: URL(fileURLWithPath: "/tmp/App.app"),
                facts: ItemFacts(isRegularFile: false, isDirectory: true, isSymbolicLink: false, isHidden: false, snapshot: nil)
            ),
            "directory"
        )
    }

    func testDryRunDoesNotMoveUnicodeFilename() throws {
        let workspace = try TemporaryWorkspace()
        let sourceFile = try workspace.createFile("Informe final ü 2026.pdf")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())

        let summary = try engine.run(mode: .dryRun)

        XCTAssertEqual(summary.planned, 1)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.source.appendingPathComponent("Documentos/Informe final ü 2026.pdf").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.paths.humanLogFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.paths.auditLogFile.path))
    }

    func testStabilityRequiresMultipleObservations() throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.createFile("photo.png")
        let resolved = try workspace.makeConfig(observations: 2)
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())

        let first = try engine.run(mode: .dryRun)
        let second = try engine.run(mode: .dryRun)

        XCTAssertEqual(first.deferred, 1)
        XCTAssertEqual(first.planned, 0)
        XCTAssertEqual(second.planned, 1)
    }

    func testChangeDuringProbeDefersMove() throws {
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("changing.txt", contents: "v1")
        let resolved = try workspace.makeConfig(probeDelayMilliseconds: 1)
        let engine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            sleepProvider: { _ in
                try? Data("v2-longer".utf8).write(to: file)
            }
        )

        let summary = try engine.run(mode: .apply)

        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.deferred, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testApplyAvoidsCollisionAndPreservesCompoundExtension() throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.createFile("archive.tar.gz", contents: "new")
        let category = workspace.source.appendingPathComponent("Archivos comprimidos", isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let existing = category.appendingPathComponent("archive.tar.gz")
        try Data("existing".utf8).write(to: existing)

        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        let summary = try engine.run(mode: .apply)

        XCTAssertEqual(summary.moved, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: existing), as: UTF8.self), "existing")
        let moved = category.appendingPathComponent("archive (1).tar.gz")
        XCTAssertEqual(String(decoding: try Data(contentsOf: moved), as: UTF8.self), "new")
    }

    func testSecondApplyIsIdempotent() throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.createFile("manual.pdf")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())

        let first = try engine.run(mode: .apply)
        let second = try engine.run(mode: .apply)

        XCTAssertEqual(first.moved, 1)
        XCTAssertEqual(second.moved, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.source.appendingPathComponent("Documentos/manual.pdf").path
            )
        )
    }

    func testDirectoriesApplicationsAndSymlinksAreNeverMoved() throws {
        let workspace = try TemporaryWorkspace()
        let appDirectory = workspace.source.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let target = try workspace.createFile("target.pdf")
        let symlink = workspace.source.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        let summary = try engine.run(mode: .apply)

        XCTAssertEqual(summary.moved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDirectory.path))
        let symlinkFacts = try symlink.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(symlinkFacts.isSymbolicLink, true)
    }


    func testCategorySymlinkOutsideDestinationIsRejected() throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.createFile("escape.pdf", contents: "safe")
        let outside = workspace.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let categoryLink = workspace.source.appendingPathComponent("Documentos")
        try FileManager.default.createSymbolicLink(at: categoryLink, withDestinationURL: outside)

        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        let summary = try engine.run(mode: .apply)

        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.errors, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.source.appendingPathComponent("escape.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.pdf").path))
    }

    func testUndoPreviewAndApplyRestoreLastTransaction() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("restore me.pdf", contents: "important")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())

        let apply = try engine.run(mode: .apply)
        XCTAssertEqual(apply.moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        let preview = try engine.undoLatest(mode: .preview)
        XCTAssertEqual(preview.planned, 1)
        XCTAssertEqual(preview.restored, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        let undo = try engine.undoLatest(mode: .apply)
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), "important")
    }


    func testUndoRefusesDestinationReplacedByDifferentFileIdentity() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("identity.pdf", contents: "original")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        _ = try engine.run(mode: .apply)

        let destination = workspace.source.appendingPathComponent("Documentos/identity.pdf")
        let journaledSnapshot = try FileSystemSecurity.snapshot(of: destination)

        // Keep the unlinked inode alive so the test cannot accidentally pass
        // because the filesystem immediately reused the same inode number.
        let heldHandle = try FileHandle(forReadingFrom: destination)
        defer { try? heldHandle.close() }
        try FileManager.default.removeItem(at: destination)
        try Data("replaced".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: journaledSnapshot.modificationTime)],
            ofItemAtPath: destination.path
        )

        let replacementSnapshot = try FileSystemSecurity.snapshot(of: destination)
        XCTAssertEqual(journaledSnapshot.size, replacementSnapshot.size)
        XCTAssertEqual(
            journaledSnapshot.modificationTime,
            replacementSnapshot.modificationTime,
            accuracy: 0.000_001
        )
        XCTAssertNotEqual(journaledSnapshot.inode, replacementSnapshot.inode)

        let undo = try engine.undoLatest(mode: .apply)

        XCTAssertEqual(undo.restored, 0)
        XCTAssertEqual(undo.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: destination), as: UTF8.self), "replaced")
    }

    func testJournalSnapshotRejectsDifferentIdentityWithSameMetadata() {
        let journaled = FileSnapshot(
            size: 8,
            modificationTime: 1234,
            fileIdentifier: nil,
            deviceID: 9,
            inode: 100
        )
        let replacement = FileSnapshot(
            size: 8,
            modificationTime: 1234,
            fileIdentifier: nil,
            deviceID: 9,
            inode: 101
        )

        XCTAssertFalse(journaled.matchesJournaledSnapshot(replacement))
    }

    func testUndoRefusesDestinationModifiedInPlace() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("modified.pdf", contents: "original")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        _ = try engine.run(mode: .apply)

        let destination = workspace.source.appendingPathComponent("Documentos/modified.pdf")
        let before = try FileSystemSecurity.snapshot(of: destination)
        try Data("modified".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: before.modificationTime + 10)],
            ofItemAtPath: destination.path
        )
        let after = try FileSystemSecurity.snapshot(of: destination)
        XCTAssertEqual(before.inode, after.inode)
        XCTAssertNotEqual(before.modificationTime, after.modificationTime)

        let undo = try engine.undoLatest(mode: .apply)

        XCTAssertEqual(undo.restored, 0)
        XCTAssertEqual(undo.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: destination), as: UTF8.self), "modified")
    }

    func testUndoRefusesToOverwriteNewSourceCollision() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("collision.pdf", contents: "moved")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        _ = try engine.run(mode: .apply)
        try Data("new source".utf8).write(to: original)

        let undo = try engine.undoLatest(mode: .apply)

        XCTAssertEqual(undo.restored, 0)
        XCTAssertEqual(undo.skipped, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), "new source")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.source.appendingPathComponent("Documentos/collision.pdf").path
            )
        )
    }

    func testConfigurationRejectsDestinationOutsideSource() throws {
        let workspace = try TemporaryWorkspace()
        var config = DefaultConfiguration.make()
        config.paths = PathsConfig(
            sourceDirectory: workspace.source.path,
            destinationRoot: workspace.root.appendingPathComponent("outside").path,
            stateDirectory: workspace.state.path,
            logDirectory: workspace.logs.path
        )
        XCTAssertThrowsError(try ConfigurationIO.resolve(config))
    }

    func testConfigurationRejectsPathTraversalCategory() throws {
        var config = DefaultConfiguration.make()
        config.classification.categories[0].name = "../Escape"
        XCTAssertThrowsError(try ConfigurationIO.validate(config))
    }

    func testConfigurationRoundTripPreservesApplyFlag() throws {
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        var config = DefaultConfiguration.make()
        config.paths = PathsConfig(
            sourceDirectory: workspace.source.path,
            destinationRoot: workspace.source.path,
            stateDirectory: workspace.state.path,
            logDirectory: workspace.logs.path
        )
        config.automation.applyEnabled = true
        try ConfigurationIO.save(config, to: configURL)

        let loaded = try ConfigurationIO.load(from: configURL)
        XCTAssertTrue(loaded.config.automation.applyEnabled)
    }
    func testProcessLockRejectsConcurrentExecution() throws {
        let workspace = try TemporaryWorkspace()
        let lockURL = workspace.state.appendingPathComponent("run.lock")
        let first = try ProcessFileLock(url: lockURL)

        XCTAssertThrowsError(try ProcessFileLock(url: lockURL)) { error in
            guard case StewardError.lockBusy = error else {
                return XCTFail("Se esperaba lockBusy, recibido: \(error)")
            }
        }

        withExtendedLifetime(first) {}
    }

    func testMoveErrorReportedAfterRenameRemainsRecoverableAndUndoable() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("rename-then-error.pdf", contents: "recover me")
        let resolved = try workspace.makeConfig()
        let faultingEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            moveOperation: RenameThenThrowMover().move
        )

        let firstRun = try faultingEngine.run(mode: .apply)
        let destination = workspace.source.appendingPathComponent("Documentos/rename-then-error.pdf")

        XCTAssertEqual(firstRun.moved, 0)
        XCTAssertEqual(firstRun.errors, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let pending = try store.load(runID: firstRun.runID)
        XCTAssertEqual(pending.status, .inProgress)
        XCTAssertEqual(pending.moves.first?.executionStatus, .planned)

        let events = try store.reconcileInterruptedTransactions()
        XCTAssertEqual(events.map(\.outcome), [.recoveredCompleted])
        let recovered = try store.load(runID: firstRun.runID)
        XCTAssertEqual(recovered.moves.first?.executionStatus, .completed)

        let normalEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector()
        )
        let undo = try normalEngine.undoLatest(mode: .apply)
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), "recover me")
    }

    func testUndoErrorReportedAfterRenameIsReconciledWithoutRepeatingMove() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("undo-rename-then-error.pdf", contents: "restore once")
        let resolved = try workspace.makeConfig()
        let normalEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector()
        )
        let apply = try normalEngine.run(mode: .apply)
        XCTAssertEqual(apply.moved, 1)

        let faultingEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            moveOperation: RenameThenThrowMover().move
        )
        let firstUndo = try faultingEngine.undoLatest(mode: .apply)
        let destination = workspace.source.appendingPathComponent("Documentos/undo-rename-then-error.pdf")

        XCTAssertEqual(firstUndo.restored, 0)
        XCTAssertEqual(firstUndo.errors, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let beforeRecovery = try store.load(runID: apply.runID)
        XCTAssertNotEqual(beforeRecovery.moves.first?.undoStatus, .undone)

        let events = try store.reconcileInterruptedTransactions()
        XCTAssertEqual(events.map(\.outcome), [.recoveredUndoCompleted])
        let recovered = try store.load(runID: apply.runID)
        XCTAssertEqual(recovered.moves.first?.undoStatus, .undone)
        XCTAssertEqual(recovered.status, .fullyUndone)
        XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), "restore once")
    }

    func testInterruptedCompletedMoveIsReconciledAndUndoable() throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.createFile("interrupted.pdf", contents: "journaled")
        let resolved = try workspace.makeConfig()
        let category = workspace.source.appendingPathComponent("Documentos", isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let destination = category.appendingPathComponent(source.lastPathComponent)
        let snapshot = try FileSystemSecurity.snapshot(of: source)
        try FileManager.default.moveItem(at: source, to: destination)

        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let manifest = TransactionManifest(
            runID: "20260812T000000.000Z-interrupted",
            mode: .apply,
            moves: [
                MoveRecord(
                    source: source.path,
                    destination: destination.path,
                    category: "Documentos",
                    reason: "extension:.pdf",
                    sourceSnapshot: snapshot
                )
            ]
        )
        try store.save(manifest)

        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        let undo = try engine.undoLatest(mode: .apply)

        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: source), as: UTF8.self), "journaled")
        let recovered = try store.load(runID: manifest.runID)
        XCTAssertEqual(recovered.moves[0].executionStatus, .completed)
        XCTAssertEqual(recovered.moves[0].undoStatus, .undone)
        XCTAssertEqual(recovered.moves[0].recoveryNote, "source_absent_destination_matches_journal")
    }

    func testInterruptedMoveThatNeverHappenedIsMarkedFailedWithoutMoving() throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.createFile("not-moved.pdf", contents: "still here")
        let resolved = try workspace.makeConfig()
        let destination = workspace.source
            .appendingPathComponent("Documentos", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        let snapshot = try FileSystemSecurity.snapshot(of: source)
        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let manifest = TransactionManifest(
            runID: "20260812T000001.000Z-notmoved",
            mode: .apply,
            moves: [
                MoveRecord(
                    source: source.path,
                    destination: destination.path,
                    category: "Documentos",
                    reason: "extension:.pdf",
                    sourceSnapshot: snapshot
                )
            ]
        )
        try store.save(manifest)

        let events = try store.reconcileInterruptedTransactions()

        XCTAssertEqual(events.map(\.outcome), [.recoveredNotMoved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let recovered = try store.load(runID: manifest.runID)
        XCTAssertEqual(recovered.moves[0].executionStatus, .failed)
        XCTAssertThrowsError(try store.latestUndoable()) { error in
            guard case StewardError.noUndoableTransaction = error else {
                return XCTFail("Se esperaba noUndoableTransaction, recibido: \(error)")
            }
        }
    }

    func testConfigurationRejectsDisablingDestinationContainment() throws {
        var config = DefaultConfiguration.make()
        config.safety.requireDestinationInsideSource = false
        XCTAssertThrowsError(try ConfigurationIO.validate(config))
    }

    func testConfigurationRejectsCategoryWhitespaceAtEdges() throws {
        var config = DefaultConfiguration.make()
        config.classification.categories[0].name = " Documentos"
        XCTAssertThrowsError(try ConfigurationIO.validate(config))
    }

    func testAmbiguousInterruptedMoveBlocksNewApply() throws {
        let workspace = try TemporaryWorkspace()
        let interruptedSource = try workspace.createFile("ambiguous.pdf", contents: "original")
        let sourceSnapshot = try FileSystemSecurity.snapshot(of: interruptedSource)
        try FileManager.default.removeItem(at: interruptedSource)
        let category = workspace.source.appendingPathComponent("Documentos", isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let ambiguousDestination = category.appendingPathComponent("ambiguous.pdf")
        try Data("different object".utf8).write(to: ambiguousDestination)
        let newCandidate = try workspace.createFile("new.pdf", contents: "must remain")

        let resolved = try workspace.makeConfig()
        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let manifest = TransactionManifest(
            runID: "20260812T000002.000Z-ambiguous",
            mode: .apply,
            moves: [
                MoveRecord(
                    source: interruptedSource.path,
                    destination: ambiguousDestination.path,
                    category: "Documentos",
                    reason: "extension:.pdf",
                    sourceSnapshot: sourceSnapshot
                )
            ]
        )
        try store.save(manifest)

        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        XCTAssertThrowsError(try engine.run(mode: .apply))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newCandidate.path))
        let recovered = try store.load(runID: manifest.runID)
        XCTAssertEqual(recovered.moves[0].executionStatus, .planned)
        XCTAssertEqual(recovered.moves[0].recoveryNote, "source_absent_destination_snapshot_mismatch")
    }



    func testInterruptedAfterMoveCompletionFinalizesManifestStatus() throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.createFile("status-finalization.pdf", contents: "complete")
        let resolved = try workspace.makeConfig()
        let category = workspace.source.appendingPathComponent("Documentos", isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let destination = category.appendingPathComponent(source.lastPathComponent)
        let snapshot = try FileSystemSecurity.snapshot(of: source)
        try FileManager.default.moveItem(at: source, to: destination)

        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let manifest = TransactionManifest(
            runID: "20260812T000003.000Z-finalize",
            mode: .apply,
            status: .inProgress,
            moves: [
                MoveRecord(
                    source: source.path,
                    destination: destination.path,
                    category: "Documentos",
                    reason: "extension:.pdf",
                    sourceSnapshot: snapshot,
                    movedAt: Date(),
                    executionStatus: .completed
                )
            ]
        )
        try store.save(manifest)

        let events = try store.reconcileInterruptedTransactions()
        XCTAssertTrue(events.isEmpty)
        let recovered = try store.load(runID: manifest.runID)
        XCTAssertEqual(recovered.status, .completed)
        XCTAssertNotNil(recovered.finishedAt)
    }

    func testInterruptedUndoMoveIsReconciledAsUndoneWithoutMovingAgain() throws {
        let workspace = try TemporaryWorkspace()
        let original = try workspace.createFile("undo-interrupted.pdf", contents: "restored")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        _ = try engine.run(mode: .apply)

        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let pending = try store.latestUndoable()
        guard let move = pending.moves.first(where: { $0.executionStatus == .completed }) else {
            return XCTFail("Se esperaba un movimiento completado")
        }
        let destination = URL(fileURLWithPath: move.destination)

        // Simula SIGKILL después de moveItem durante undo y antes de guardar el manifiesto.
        try FileManager.default.moveItem(at: destination, to: original)

        let events = try store.reconcileInterruptedTransactions()
        XCTAssertTrue(events.contains { $0.outcome == .recoveredUndoCompleted })
        XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), "restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let recovered = try store.load(runID: pending.runID)
        XCTAssertEqual(recovered.moves[0].undoStatus, .undone)
        XCTAssertEqual(recovered.moves[0].undoRecoveryNote, "source_restored_destination_absent_matches_journal")
        XCTAssertEqual(recovered.status, .fullyUndone)
        XCTAssertThrowsError(try store.latestUndoable()) { error in
            guard case StewardError.noUndoableTransaction = error else {
                return XCTFail("Se esperaba noUndoableTransaction, recibido: \(error)")
            }
        }
    }


    func testCorruptTransactionManifestBlocksApplyWithoutMovingCandidate() throws {
        let workspace = try TemporaryWorkspace()
        let candidate = try workspace.createFile("must-stay.pdf", contents: "safe")
        let resolved = try workspace.makeConfig()
        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        try Data("{not-json".utf8).write(
            to: store.directory.appendingPathComponent("corrupt.json")
        )

        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        XCTAssertThrowsError(try engine.run(mode: .apply))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.source.appendingPathComponent("Documentos/must-stay.pdf").path
            )
        )
    }

    func testManifestFilenameMustMatchRunID() throws {
        let workspace = try TemporaryWorkspace()
        let resolved = try workspace.makeConfig()
        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let manifest = TransactionManifest(runID: "valid-run-id", mode: .apply)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: store.directory.appendingPathComponent("different-name.json")
        )

        XCTAssertThrowsError(try store.reconcileInterruptedTransactions())
    }

    func testTransactionRunIDCannotEscapeStateDirectory() throws {
        let workspace = try TemporaryWorkspace()
        let resolved = try workspace.makeConfig()
        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let manifest = TransactionManifest(runID: "../../escape", mode: .apply)

        XCTAssertThrowsError(try store.save(manifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.state.appendingPathComponent("escape.json").path))
    }


    func testVersion100LoggingConfigDecodesWithSafeDefaults() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(DefaultConfiguration.make())
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var logging = object["logging"] as? [String: Any] else {
            return XCTFail("No se pudo preparar la configuración heredada")
        }
        logging.removeValue(forKey: "max_file_bytes")
        logging.removeValue(forKey: "rotated_file_count")
        logging.removeValue(forKey: "suppress_scheduled_noop_audit")
        logging.removeValue(forKey: "transaction_manifest_limit")
        object["logging"] = logging
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StewardConfig.self, from: legacyData)
        XCTAssertEqual(decoded.logging.maxFileBytes, 5_242_880)
        XCTAssertEqual(decoded.logging.rotatedFileCount, 3)
        XCTAssertTrue(decoded.logging.suppressScheduledNoopAudit)
        XCTAssertEqual(decoded.logging.transactionManifestLimit, 100)
    }

    func testBoundedLogsRotateAndRemainLimited() throws {
        let workspace = try TemporaryWorkspace()
        let human = workspace.logs.appendingPathComponent("steward.log")
        let audit = workspace.logs.appendingPathComponent("audit.jsonl")
        let logger = try AuditLogger(
            humanLogURL: human,
            auditLogURL: audit,
            maxFileBytes: 1_024,
            rotatedFileCount: 2
        )

        for index in 0..<30 {
            try logger.record(AuditEvent(
                runID: "rotation-\(index)",
                level: "info",
                mode: "dry-run",
                action: "rotation_probe",
                detail: String(repeating: "x", count: 160)
            ))
        }

        for base in [human, audit] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("1").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("2").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathExtension("3").path))
            XCTAssertTrue(try FileSystemSecurity.regularFileSize(base) <= 1_024)
            XCTAssertTrue(try FileSystemSecurity.regularFileSize(base.appendingPathExtension("1")) <= 1_024)
            XCTAssertTrue(try FileSystemSecurity.regularFileSize(base.appendingPathExtension("2")) <= 1_024)
        }
    }

    func testScheduledNoopCanAvoidAuditAndStabilityWrites() throws {
        let workspace = try TemporaryWorkspace()
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())

        let summary = try engine.run(mode: .dryRun, recordEmptyRun: false)

        XCTAssertEqual(summary.scanned, 0)
        XCTAssertEqual(try FileSystemSecurity.regularFileSize(resolved.paths.humanLogFile), 0)
        XCTAssertEqual(try FileSystemSecurity.regularFileSize(resolved.paths.auditLogFile), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.paths.stabilityStateFile.path))
    }

    func testScheduledEventfulRunWritesBalancedAuditBoundaries() throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.createFile("eventful.pdf", contents: "stable")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())

        let summary = try engine.run(mode: .dryRun, recordEmptyRun: false)

        XCTAssertEqual(summary.planned, 1)
        let auditData = try FileSystemSecurity.readRegularFile(resolved.paths.auditLogFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try auditData.split(separator: 0x0A).map {
            try decoder.decode(AuditEvent.self, from: Data($0))
        }
        XCTAssertEqual(events.map(\.action), ["run_started", "would_move", "run_finished"])
        XCTAssertEqual(Set(events.map(\.runID)).count, 1)
    }

    func testTransactionRetentionPreservesInProgressAndNewestTerminalFiles() throws {
        let workspace = try TemporaryWorkspace()
        let transactions = workspace.state.appendingPathComponent("transactions", isDirectory: true)
        let store = try TransactionStore(directory: transactions)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<5 {
            var manifest = TransactionManifest(
                runID: "terminal-\(index)",
                mode: .apply,
                startedAt: base.addingTimeInterval(Double(index))
            )
            manifest.status = .completed
            manifest.finishedAt = base.addingTimeInterval(Double(index) + 1)
            try store.save(manifest)
        }
        let inProgress = TransactionManifest(
            runID: "still-in-progress",
            mode: .apply,
            startedAt: base.addingTimeInterval(100)
        )
        try store.save(inProgress)

        let removed = try store.pruneTerminalManifests(retaining: 2)

        XCTAssertEqual(removed, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: "still-in-progress").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: "terminal-4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: "terminal-3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: "terminal-0").path))
    }

    func testLogWriterRejectsSymbolicLinkPath() throws {
        let workspace = try TemporaryWorkspace()
        let target = workspace.root.appendingPathComponent("target.log")
        let link = workspace.logs.appendingPathComponent("steward.log")
        try FileSystemSecurity.ensurePrivateDirectory(workspace.logs)
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try FileSystemSecurity.ensureRegularFileExists(link))
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "target")
    }

    func testFreshSnapshotChangesWhenReusingSameURL() throws {
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("same-url.txt", contents: "before")
        let before = try FileSystemSecurity.freshSnapshot(of: file)
        try Data("after!".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: before.modificationTime + 5)],
            ofItemAtPath: file.path
        )
        let after = try FileSystemSecurity.freshSnapshot(of: file)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.inode, after.inode)
    }

    func testPOSIXSnapshotPreservesDeviceAndInode() throws {
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("identity.bin")
        let metadata = try FileSystemSecurity.freshPOSIXMetadata(of: file)
        let snapshot = try FileSystemSecurity.freshSnapshot(of: file)
        XCTAssertEqual(snapshot.deviceID, metadata.deviceID)
        XCTAssertEqual(snapshot.inode, metadata.inode)
        XCTAssertNotNil(snapshot.modificationSeconds)
        XCTAssertNotNil(snapshot.modificationNanoseconds)
    }

    func testFreshSnapshotRejectsSymlinkUsingLstat() throws {
        let workspace = try TemporaryWorkspace()
        let target = try workspace.createFile("target.txt")
        let link = workspace.source.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FileSystemSecurity.freshSnapshot(of: link))
    }

    func testSameSizeMtimeChangeDuringProbeDefersMove() throws {
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("mtime.txt", contents: "aaaa")
        let initial = try FileSystemSecurity.freshSnapshot(of: file)
        let resolved = try workspace.makeConfig(probeDelayMilliseconds: 1)
        let engine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            sleepProvider: { _ in
                try? Data("bbbb".utf8).write(to: file)
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: initial.modificationTime + 2)],
                    ofItemAtPath: file.path
                )
            }
        )
        let summary = try engine.run(mode: .apply)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.deferred, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testChangeImmediatelyBeforeMoveDefersMove() throws {
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("last-check.pdf", contents: "original")
        let resolved = try workspace.makeConfig()
        let manager = MutateBeforeMoveFileManager(sourceFile: file)
        let engine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            fileManager: manager
        )
        let summary = try engine.run(mode: .apply)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.deferred, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testActiveFolderAcceptsSpacesAndUnicode() throws {
        let workspace = try TemporaryWorkspace()
        let folder = workspace.root.appendingPathComponent("Carpeta ü con espacios", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let validation = try ActiveFolderManager.validate(path: folder.path)
        XCTAssertTrue(validation.exists)
        XCTAssertEqual(validation.canonicalPath, folder.resolvingSymlinksInPath().path)
        XCTAssertNotNil(validation.deviceID)
    }

    func testFolderSetAlwaysReturnsToDryRunAndPreservesTransactions() throws {
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        var config = try workspace.makeConfig().config
        config.automation.applyEnabled = true
        try ConfigurationIO.save(config, to: configURL)
        let marker = workspace.state.appendingPathComponent("transactions/keep.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: marker)
        let other = workspace.root.appendingPathComponent("Otra carpeta", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        _ = try ActiveFolderManager.set(path: other.path, configurationURL: configURL)
        let changed = try ConfigurationIO.load(from: configURL)
        XCTAssertFalse(changed.config.automation.applyEnabled)
        XCTAssertEqual(changed.paths.sourceDirectory.path, other.resolvingSymlinksInPath().path)
        XCTAssertEqual(changed.paths.destinationRoot.path, other.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancelledFolderSelectionDoesNotChangeConfiguration() throws {
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        try ConfigurationIO.save(try workspace.makeConfig().config, to: configURL)
        let before = try Data(contentsOf: configURL)
        let result = try ActiveFolderManager.applySelection(nil, configurationURL: configURL)
        let after = try Data(contentsOf: configURL)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(before, after)
    }

    func testFolderResetDownloadsUsesIsolatedHomeAndReturnsToDryRun() throws {
        let workspace = try TemporaryWorkspace()
        let isolatedHome = workspace.root.appendingPathComponent("home", isDirectory: true)
        let downloads = isolatedHome.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let configURL = workspace.root.appendingPathComponent("config.json")
        var config = try workspace.makeConfig().config
        config.automation.applyEnabled = true
        try ConfigurationIO.save(config, to: configURL)

        _ = try ActiveFolderManager.resetToDownloads(
            configurationURL: configURL,
            homeDirectory: isolatedHome
        )
        let changed = try ConfigurationIO.load(from: configURL, homeDirectory: isolatedHome)
        XCTAssertFalse(changed.config.automation.applyEnabled)
        XCTAssertEqual(changed.paths.sourceDirectory.path, downloads.resolvingSymlinksInPath().path)
        XCTAssertEqual(changed.paths.destinationRoot.path, downloads.resolvingSymlinksInPath().path)
    }

    func testDangerousActiveFolderRootsAreRejected() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: "/"))
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: home.path))
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: home.appendingPathComponent("Library").path))
        XCTAssertThrowsError(try ActiveFolderManager.validate(
            path: home.appendingPathComponent("Library/Application Support/TidyDrop").path
        ))
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        try ConfigurationIO.save(try workspace.makeConfig().config, to: configURL)
        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ActiveFolderManager.set(
            path: workspace.state.path,
            configurationURL: configURL
        ))
    }

    func testSystemApplicationsScopeContainingInstalledBundleIsRejected() throws {
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: "/Applications"))
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: "/Applications/TidyDrop.app"))
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: "/Applications/TidyDrop.app/Contents"))
    }

    func testLaunchAgentStatusRecognizesBundledAgentExecution() throws {
        XCTAssertEqual(
            LaunchAgentStatusResolver.accessStatus(agentInstalled: false, scheduledRecord: nil),
            "not_installed"
        )
        XCTAssertEqual(
            LaunchAgentStatusResolver.accessStatus(agentInstalled: true, scheduledRecord: nil),
            "installed_not_verified"
        )
        let successfulRun = ScheduledRunRecord(
            outcome: .success,
            runID: "runtime-regression",
            mode: ExecutionMode.apply.rawValue
        )
        XCTAssertEqual(
            LaunchAgentStatusResolver.accessStatus(
                agentInstalled: true,
                scheduledRecord: successfulRun
            ),
            "success"
        )
        XCTAssertEqual(
            LaunchAgentStatusResolver.accessStatus(
                agentInstalled: true,
                scheduledRecord: ScheduledRunRecord(
                    outcome: .success,
                    runID: "watcher-starting",
                    mode: ExecutionMode.dryRun.rawValue,
                    moved: 0,
                    errors: 0,
                    agentReady: false
                )
            ),
            "watcher_starting"
        )
        XCTAssertEqual(
            LaunchAgentStatusResolver.accessStatus(
                agentInstalled: true,
                scheduledRecord: ScheduledRunRecord(
                    outcome: .error,
                    runID: "watcher-error",
                    errors: 1,
                    agentReady: false
                )
            ),
            "error"
        )
    }

    func testActiveFolderRejectsRootSymlinkAndTraversal() throws {
        let workspace = try TemporaryWorkspace()
        let target = workspace.root.appendingPathComponent("real", isDirectory: true)
        let link = workspace.root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: link.path))
        XCTAssertThrowsError(try ActiveFolderManager.validate(path: target.path + "/../real"))
    }

    func testUnavailableSourceFailsSafely() throws {
        let workspace = try TemporaryWorkspace()
        var config = DefaultConfiguration.make()
        let missing = workspace.root.appendingPathComponent("unmounted", isDirectory: true)
        config.paths = PathsConfig(
            sourceDirectory: missing.path,
            destinationRoot: missing.path,
            stateDirectory: workspace.state.path,
            logDirectory: workspace.logs.path
        )
        let resolved = try ConfigurationIO.resolve(config)
        let engine = try StewardEngine(configuration: resolved, mimeDetector: NullMIMETypeDetector())
        XCTAssertThrowsError(try engine.run(mode: .dryRun)) { error in
            XCTAssertTrue(String(describing: error).contains("source_unavailable"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testExclusiveMoveNeverOverwritesLateCollision() throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.createFile("exclusive-source.txt", contents: "source")
        let destination = workspace.source.appendingPathComponent("exclusive-destination.txt")
        try Data("destination".utf8).write(to: destination)
        let snapshot = try FileSystemSecurity.freshSnapshot(of: source)

        XCTAssertThrowsError(try FileSystemSecurity.moveRegularFileExclusively(
            from: source,
            to: destination,
            expectedSnapshot: snapshot
        ))
        XCTAssertEqual(String(decoding: try Data(contentsOf: source), as: UTF8.self), "source")
        XCTAssertEqual(String(decoding: try Data(contentsOf: destination), as: UTF8.self), "destination")
    }

    func testEngineNeverOverwritesCollisionCreatedAtRename() throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.createFile("late-collision.pdf", contents: "source")
        let destination = workspace.source.appendingPathComponent("Documentos/late-collision.pdf")
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            moveOperation: { from, to, snapshot in
                try Data("late destination".utf8).write(to: to)
                try FileSystemSecurity.moveRegularFileExclusively(
                    from: from,
                    to: to,
                    expectedSnapshot: snapshot
                )
            }
        )

        let summary = try engine.run(mode: .apply)

        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.errors, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: source), as: UTF8.self), "source")
        XCTAssertEqual(String(decoding: try Data(contentsOf: destination), as: UTF8.self), "late destination")
    }

    func testExclusiveMoveRejectsCategoryReplacedBySymlink() throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.createFile("category-race.pdf", contents: "source")
        let category = workspace.source.appendingPathComponent("Documentos", isDirectory: true)
        let outside = workspace.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let resolved = try workspace.makeConfig()
        let engine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            moveOperation: { from, to, snapshot in
                try FileManager.default.removeItem(at: category)
                try FileManager.default.createSymbolicLink(at: category, withDestinationURL: outside)
                try FileSystemSecurity.moveRegularFileExclusively(
                    from: from,
                    to: to,
                    expectedSnapshot: snapshot
                )
            }
        )

        let summary = try engine.run(mode: .apply)

        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.errors, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("category-race.pdf").path
        ))
    }

    func testLockRejectsSymbolicLink() throws {
        let workspace = try TemporaryWorkspace()
        let target = workspace.root.appendingPathComponent("lock-target")
        try Data("do not touch".utf8).write(to: target)
        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        let lock = workspace.state.appendingPathComponent("run.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)

        XCTAssertThrowsError(try ProcessFileLock(url: lock))
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "do not touch")
    }

    func testJSONReaderRejectsSymbolicLinkAndOversizedInput() throws {
        let workspace = try TemporaryWorkspace()
        let target = workspace.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = workspace.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try JSONFile.load(
            StabilityDatabase.self,
            from: link,
            default: StabilityDatabase()
        ))

        let oversized = workspace.root.appendingPathComponent("oversized.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 1_025)
        try handle.close()
        XCTAssertThrowsError(try JSONFile.load(
            StabilityDatabase.self,
            from: oversized,
            default: StabilityDatabase(),
            maximumBytes: 1_024
        ))

        let boundedSave = workspace.root.appendingPathComponent("bounded-save.json")
        XCTAssertThrowsError(try JSONFile.save(
            String(repeating: "x", count: 1_024),
            to: boundedSave,
            maximumBytes: 128
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundedSave.path))
    }

    func testScheduledDryRunReusesUnchangedPlanWithoutProbeOrLogGrowth() throws {
        let workspace = try TemporaryWorkspace()
        let file = try workspace.createFile("cached-plan.pdf", contents: "stable")
        let resolved = try workspace.makeConfig(probeDelayMilliseconds: 1)
        var probeCount = 0
        let firstEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            sleepProvider: { _ in probeCount += 1 }
        )
        let first = try firstEngine.run(
            mode: .dryRun,
            recordEmptyRun: false,
            suppressUnchangedDryRunPlans: true
        )
        XCTAssertEqual(first.planned, 1)
        XCTAssertEqual(probeCount, 1)
        let firstHumanSize = try FileSystemSecurity.regularFileSize(resolved.paths.humanLogFile)
        let firstAuditSize = try FileSystemSecurity.regularFileSize(resolved.paths.auditLogFile)
        let firstStability = try FileSystemSecurity.readRegularFile(resolved.paths.stabilityStateFile)
        let firstCache = try FileSystemSecurity.readRegularFile(resolved.paths.scheduledDryRunCacheFile)

        let secondEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            sleepProvider: { _ in probeCount += 1 }
        )
        let second = try secondEngine.run(
            mode: .dryRun,
            recordEmptyRun: false,
            suppressUnchangedDryRunPlans: true
        )
        XCTAssertEqual(second.planned, 1)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(try FileSystemSecurity.regularFileSize(resolved.paths.humanLogFile), firstHumanSize)
        XCTAssertEqual(try FileSystemSecurity.regularFileSize(resolved.paths.auditLogFile), firstAuditSize)
        XCTAssertEqual(try FileSystemSecurity.readRegularFile(resolved.paths.stabilityStateFile), firstStability)
        XCTAssertEqual(try FileSystemSecurity.readRegularFile(resolved.paths.scheduledDryRunCacheFile), firstCache)

        try Data("changed".utf8).write(to: file)
        let thirdEngine = try StewardEngine(
            configuration: resolved,
            mimeDetector: NullMIMETypeDetector(),
            sleepProvider: { _ in probeCount += 1 }
        )
        let third = try thirdEngine.run(
            mode: .dryRun,
            recordEmptyRun: false,
            suppressUnchangedDryRunPlans: true
        )
        XCTAssertEqual(third.planned, 1)
        XCTAssertEqual(probeCount, 2)
        XCTAssertTrue(try FileSystemSecurity.regularFileSize(resolved.paths.auditLogFile) > firstAuditSize)
    }

    func testMIMEDetectorTimesOutBoundedHelper() throws {
        let workspace = try TemporaryWorkspace()
        let helper = workspace.root.appendingPathComponent("slow-file-helper")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: helper.path
        )
        let candidate = try workspace.createFile("unknown-content")
        let detector = SystemMIMETypeDetector(
            executableURL: helper,
            timeoutSeconds: 0.05
        )
        let started = Date()
        let result = detector.mimeType(for: candidate)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result, nil)
        XCTAssertTrue(elapsed < 1.0, "el helper MIME tardó \(elapsed) segundos")
    }

    func testConfigurationBoundsRuleCountsAndLengths() throws {
        var config = DefaultConfiguration.make()
        config.classification.categories = (0..<129).map { CategoryRule(name: "Category\($0)") }
        XCTAssertThrowsError(try ConfigurationIO.validate(config))

        config = DefaultConfiguration.make()
        config.classification.categories[0].namePatterns = [String(repeating: "a", count: 1_025)]
        XCTAssertThrowsError(try ConfigurationIO.validate(config))

        config = DefaultConfiguration.make()
        config.exclusions.extensions = [String(repeating: "x", count: 65)]
        XCTAssertThrowsError(try ConfigurationIO.validate(config))
    }

    func testAtomicJSONSaveRejectsSymlinkAndUsesPrivatePermissions() throws {
        let workspace = try TemporaryWorkspace()
        let target = workspace.root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: target)
        let link = workspace.state.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try JSONFile.save(StabilityDatabase(), to: link))
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "outside")

        try FileManager.default.removeItem(at: link)
        try JSONFile.save(StabilityDatabase(), to: link)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testScheduledExecutionWritesDryRunSuccessRecord() throws {
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        let resolved = try workspace.makeConfig()
        try ConfigurationIO.save(resolved.config, to: configURL)

        let exitCode = ScheduledExecution.run(configurationURL: configURL)
        let record = try JSONFile.load(
            ScheduledRunRecord.self,
            from: resolved.paths.scheduledStatusFile,
            default: ScheduledRunRecord(outcome: .error, runID: "missing")
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(record.outcome, .success)
        XCTAssertEqual(record.mode, ExecutionMode.dryRun.rawValue)
        XCTAssertEqual(record.moved, 0)
        XCTAssertEqual(record.errors, 0)
        XCTAssertEqual(record.sourceDirectory, resolved.paths.sourceDirectory.path)
        let indexedRuns = try AgentActivityDatabase.recentRuns(
            at: resolved.paths.activityDatabaseFile,
            limit: 10
        )
        XCTAssertEqual(indexedRuns.map(\.runID), [record.runID])
        XCTAssertEqual(indexedRuns.first?.outcome, .success)
        XCTAssertEqual(indexedRuns.first?.mode, ExecutionMode.dryRun.rawValue)
    }

    func testAgentActivityDatabaseMigratesAndReadsNewestFirst() throws {
        let workspace = try TemporaryWorkspace()
        let databaseURL = workspace.state.appendingPathComponent("activity.sqlite3")
        let older = ScheduledRunRecord(
            timestamp: Date(timeIntervalSince1970: 1),
            outcome: .success,
            runID: "older",
            mode: "dry-run",
            moved: 0,
            errors: 0,
            sourceDirectory: ConfigurationIO.canonicalURL(workspace.source).path
        )
        let newer = ScheduledRunRecord(
            timestamp: Date(timeIntervalSince1970: 2),
            outcome: .sourceUnavailable,
            runID: "newer",
            mode: "dry-run",
            moved: 0,
            errors: 1,
            sourceDirectory: ConfigurationIO.canonicalURL(workspace.source).path
        )
        try AgentActivityDatabase.record(older, at: databaseURL)
        try AgentActivityDatabase.record(newer, at: databaseURL)

        var rows = try AgentActivityDatabase.recentRuns(at: databaseURL, limit: 10)
        XCTAssertEqual(rows.map(\.runID), ["newer", "older"])
        XCTAssertEqual(rows.first?.outcome, .sourceUnavailable)

        let updatedOlder = ScheduledRunRecord(
            timestamp: Date(timeIntervalSince1970: 3),
            outcome: .error,
            runID: "older",
            mode: "dry-run",
            moved: 0,
            errors: 1,
            detail: "updated"
        )
        try AgentActivityDatabase.record(updatedOlder, at: databaseURL)
        rows = try AgentActivityDatabase.recentRuns(at: databaseURL, limit: 10)
        XCTAssertEqual(rows.map(\.runID), ["older", "newer"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.detail, "updated")
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAgentActivityDatabaseReaderDoesNotCreateMissingDatabase() throws {
        let workspace = try TemporaryWorkspace()
        let databaseURL = workspace.state.appendingPathComponent("missing.sqlite3")
        XCTAssertEqual(try AgentActivityDatabase.recentRuns(at: databaseURL, limit: 10), [])
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(databaseURL))
    }

    func testAgentActivityDatabaseRejectsSymlink() throws {
        let workspace = try TemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        let target = workspace.root.appendingPathComponent("outside.sqlite3")
        try Data("not-a-database".utf8).write(to: target)
        let databaseURL = workspace.state.appendingPathComponent("activity.sqlite3")
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: target)
        XCTAssertThrowsError(try AgentActivityDatabase.record(
            ScheduledRunRecord(outcome: .success, runID: "must-fail"),
            at: databaseURL
        ))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "not-a-database")
    }

    func testAgentActivityDatabaseRejectsSymlinkSidecar() throws {
        let workspace = try TemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        let databaseURL = workspace.state.appendingPathComponent("activity.sqlite3")
        let target = workspace.root.appendingPathComponent("outside-wal")
        try Data("protected".utf8).write(to: target)
        let sidecar = URL(fileURLWithPath: databaseURL.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)

        XCTAssertThrowsError(try AgentActivityDatabase.record(
            ScheduledRunRecord(outcome: .success, runID: "must-fail"),
            at: databaseURL
        ))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "protected")
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(databaseURL))
    }

    func testBackgroundVerificationRequiresFreshMatchingSource() throws {
        let workspace = try TemporaryWorkspace()
        let now = Date()
        let matching = ScheduledRunRecord(
            timestamp: now.addingTimeInterval(-30),
            outcome: .success,
            runID: "matching-source",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            errors: 0,
            sourceDirectory: workspace.source.path,
            agentReady: true
        )
        XCTAssertTrue(BackgroundVerificationPolicy.accepts(
            matching,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            now: now
        ))

        let otherSource = workspace.root.appendingPathComponent("other", isDirectory: true)
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            matching,
            sourceDirectory: otherSource,
            applyEnabled: false,
            now: now
        ))

        let watcherStarting = ScheduledRunRecord(
            timestamp: now,
            outcome: .success,
            runID: "watcher-starting",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            errors: 0,
            sourceDirectory: workspace.source.path,
            agentReady: false
        )
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            watcherStarting,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            now: now
        ))
        let legacyReadyUnknown = ScheduledRunRecord(
            timestamp: now,
            outcome: .success,
            runID: "legacy-readiness-unknown",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            errors: 0,
            sourceDirectory: workspace.source.path
        )
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            legacyReadyUnknown,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            now: now
        ))

        let legacyRecordWithoutSource = ScheduledRunRecord(
            timestamp: now,
            outcome: .success,
            runID: "legacy",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            errors: 0
        )
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            legacyRecordWithoutSource,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            now: now
        ))
    }

    func testBackgroundVerificationHonorsModeFreshnessAndMoveSafety() throws {
        let workspace = try TemporaryWorkspace()
        let now = Date()
        let dryRun = ScheduledRunRecord(
            timestamp: now,
            outcome: .success,
            runID: "dry-run",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            errors: 0,
            sourceDirectory: workspace.source.path,
            agentReady: true
        )
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            dryRun,
            sourceDirectory: workspace.source,
            applyEnabled: true,
            now: now
        ))

        let unsafeDryRun = ScheduledRunRecord(
            timestamp: now,
            outcome: .success,
            runID: "unexpected-move",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 1,
            errors: 0,
            sourceDirectory: workspace.source.path,
            agentReady: true
        )
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            unsafeDryRun,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            now: now
        ))

        let stale = ScheduledRunRecord(
            timestamp: now.addingTimeInterval(-601),
            outcome: .success,
            runID: "stale",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            errors: 0,
            sourceDirectory: workspace.source.path,
            agentReady: true
        )
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            stale,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            now: now
        ))
        XCTAssertFalse(BackgroundVerificationPolicy.accepts(
            dryRun,
            sourceDirectory: workspace.source,
            applyEnabled: false,
            notOlderThan: now.addingTimeInterval(1),
            now: now
        ))
    }

    func testScheduledExecutionUnavailableSourceFailsClosed() throws {
        let workspace = try TemporaryWorkspace()
        let unavailable = workspace.root.appendingPathComponent("unmounted-source", isDirectory: true)
        let configURL = workspace.root.appendingPathComponent("config.json")
        var config = try workspace.makeConfig().config
        config.paths.sourceDirectory = unavailable.path
        config.paths.destinationRoot = unavailable.path
        try ConfigurationIO.save(config, to: configURL)
        let resolved = try ConfigurationIO.load(from: configURL)

        let exitCode = ScheduledExecution.run(configurationURL: configURL)
        let record = try JSONFile.load(
            ScheduledRunRecord.self,
            from: resolved.paths.scheduledStatusFile,
            default: ScheduledRunRecord(outcome: .error, runID: "missing")
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(record.outcome, .sourceUnavailable)
        XCTAssertEqual(record.mode, ExecutionMode.dryRun.rawValue)
        XCTAssertEqual(record.moved, 0)
        XCTAssertEqual(record.errors, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
    }

    func testWorkbenchAuditHistoryIsBoundedAndNewestFirst() throws {
        let workspace = try TemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.logs, withIntermediateDirectories: true)
        let auditURL = workspace.logs.appendingPathComponent("audit.jsonl")
        let logger = try AuditLogger(
            humanLogURL: workspace.logs.appendingPathComponent("steward.log"),
            auditLogURL: auditURL,
            maxFileBytes: 1_048_576,
            rotatedFileCount: 1
        )
        for index in 1...4 {
            try logger.record(AuditEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                runID: "run-\(index)",
                level: "info",
                mode: "dry-run",
                action: "would_move"
            ))
        }

        let events = try WorkbenchData.auditEvents(
            at: auditURL,
            rotatedFileCount: 1,
            maximumFileBytes: 1_048_576,
            limit: 2
        )
        XCTAssertEqual(events.map(\.runID), ["run-4", "run-3"])
    }

    func testWorkbenchAuditHistoryRejectsCorruptRecord() throws {
        let workspace = try TemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.logs, withIntermediateDirectories: true)
        let auditURL = workspace.logs.appendingPathComponent("audit.jsonl")
        try Data("{not-json}\n".utf8).write(to: auditURL)

        XCTAssertThrowsError(try WorkbenchData.auditEvents(
            at: auditURL,
            rotatedFileCount: 0,
            maximumFileBytes: 1_048_576,
            limit: 10
        ))
    }

    func testWorkbenchTransactionHistorySortsAndDerivesUndoableState() throws {
        let workspace = try TemporaryWorkspace()
        let resolved = try workspace.makeConfig()
        let store = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let old = TransactionManifest(
            runID: "old",
            mode: .apply,
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1),
            moves: [MoveRecord(
                source: workspace.source.appendingPathComponent("a.pdf").path,
                destination: workspace.source.appendingPathComponent("Documentos/a.pdf").path,
                category: "Documentos",
                reason: "extension:.pdf",
                executionStatus: .completed
            )]
        )
        let current = TransactionManifest(
            runID: "current",
            mode: .apply,
            status: .fullyUndone,
            startedAt: Date(timeIntervalSince1970: 2),
            moves: []
        )
        try store.save(old)
        try store.save(current)

        let history = try store.manifests(limit: 10)
        XCTAssertEqual(history.map(\.runID), ["current", "old"])
        XCTAssertFalse(history[0].containsUndoableMove)
        XCTAssertTrue(history[1].containsUndoableMove)
    }

    func testWorkbenchRuleEditReturnsToDryRunAndPreservesTransactions() throws {
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        var configuration = try workspace.makeConfig().config
        configuration.automation.applyEnabled = true
        try ConfigurationIO.save(configuration, to: configURL)
        let resolved = try ConfigurationIO.load(from: configURL)
        try FileManager.default.createDirectory(
            at: resolved.paths.transactionsDirectory,
            withIntermediateDirectories: true
        )
        let marker = resolved.paths.transactionsDirectory.appendingPathComponent("preserve.marker")
        try Data("keep".utf8).write(to: marker)

        var edited = configuration.classification.categories[0]
        edited.extensions.append("workbench-test")
        let updated = try WorkbenchData.replaceCategory(
            at: 0,
            with: edited,
            configurationURL: configURL,
            homeDirectory: workspace.root
        )

        XCTAssertFalse(updated.config.automation.applyEnabled)
        XCTAssertTrue(updated.config.classification.categories[0].extensions.contains("workbench-test"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWorkbenchRuleEditRejectsInvalidIndex() throws {
        let workspace = try TemporaryWorkspace()
        let configURL = workspace.root.appendingPathComponent("config.json")
        let configuration = try workspace.makeConfig().config
        try ConfigurationIO.save(configuration, to: configURL)

        XCTAssertThrowsError(try WorkbenchData.replaceCategory(
            at: configuration.classification.categories.count,
            with: configuration.classification.categories[0],
            configurationURL: configURL,
            homeDirectory: workspace.root
        ))
    }

    func testAgentSchedulingFiltersNestedEventsAndAcceptsRecovery() throws {
        let workspace = try TemporaryWorkspace()
        XCTAssertTrue(AgentSchedulingPolicy.sourceEventRequiresRun(
            eventPath: workspace.source.appendingPathComponent("file.pdf").path,
            sourceDirectory: workspace.source,
            requiresFullScan: false
        ))
        XCTAssertTrue(AgentSchedulingPolicy.sourceEventRequiresRun(
            eventPath: workspace.source.appendingPathComponent("alias.pdf").path
                .replacingOccurrences(of: "/private/tmp/", with: "/tmp/"),
            sourceDirectory: workspace.source,
            requiresFullScan: false
        ))
        XCTAssertTrue(AgentSchedulingPolicy.sourceEventRequiresRun(
            eventPath: workspace.source.path,
            sourceDirectory: workspace.source,
            requiresFullScan: false
        ))
        XCTAssertFalse(AgentSchedulingPolicy.sourceEventRequiresRun(
            eventPath: workspace.source.appendingPathComponent("Documentos/file.pdf").path,
            sourceDirectory: workspace.source,
            requiresFullScan: false
        ))
        XCTAssertTrue(AgentSchedulingPolicy.sourceEventRequiresRun(
            eventPath: workspace.source.appendingPathComponent("Documentos/file.pdf").path,
            sourceDirectory: workspace.source,
            requiresFullScan: true
        ))
    }

    func testAgentSchedulingUsesOneBoundedFollowUpOnlyWhenNeeded() throws {
        var stability = DefaultConfiguration.make().stability
        stability.minimumAgeSeconds = 45
        let deferred = ScheduledRunRecord(
            outcome: .success,
            runID: "deferred",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            deferred: 1,
            errors: 0
        )
        XCTAssertEqual(
            AgentSchedulingPolicy.followUpDelay(after: deferred, stability: stability),
            46
        )
        let idle = ScheduledRunRecord(
            outcome: .success,
            runID: "idle",
            mode: ExecutionMode.dryRun.rawValue,
            moved: 0,
            deferred: 0,
            errors: 0
        )
        XCTAssertEqual(
            AgentSchedulingPolicy.followUpDelay(after: idle, stability: stability),
            nil
        )
        let unavailable = ScheduledRunRecord(outcome: .sourceUnavailable, runID: "missing")
        XCTAssertEqual(
            AgentSchedulingPolicy.followUpDelay(after: unavailable, stability: stability),
            nil
        )
    }

    func testAgentSchedulingUsesBackgroundEventCoalescing() throws {
        XCTAssertEqual(AgentSchedulingPolicy.eventStreamLatencySeconds, 2)
        XCTAssertTrue(
            AgentSchedulingPolicy.eventStreamLatencySeconds
                >= AgentSchedulingPolicy.eventDebounceSeconds
        )
    }

    func testAgentRunRequestIsPrivateAndSourceBound() throws {
        let workspace = try TemporaryWorkspace()
        let requestURL = workspace.state.appendingPathComponent("agent-run-request.json")
        try AgentRunRequestSignal.request(
            at: requestURL,
            sourceDirectory: workspace.source,
            timestamp: Date(timeIntervalSince1970: 123)
        )
        let request = try JSONFile.load(
            AgentRunRequest.self,
            from: requestURL,
            default: AgentRunRequest(sourceDirectory: "missing")
        )
        XCTAssertEqual(
            request.sourceDirectory,
            ConfigurationIO.canonicalURL(workspace.source).path
        )
        XCTAssertEqual(request.timestamp, Date(timeIntervalSince1970: 123))
        let attributes = try FileManager.default.attributesOfItem(atPath: requestURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testAgentRunRequestRejectsSymlinkDestination() throws {
        let workspace = try TemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        let target = workspace.root.appendingPathComponent("outside-request.json")
        try Data("unchanged".utf8).write(to: target)
        let requestURL = workspace.state.appendingPathComponent("agent-run-request.json")
        try FileManager.default.createSymbolicLink(at: requestURL, withDestinationURL: target)

        XCTAssertThrowsError(try AgentRunRequestSignal.request(
            at: requestURL,
            sourceDirectory: workspace.source
        ))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testAgentRunRequestValidationRejectsStaleOrDifferentSource() throws {
        let workspace = try TemporaryWorkspace()
        let requestURL = workspace.state.appendingPathComponent("agent-run-request.json")
        let now = Date(timeIntervalSince1970: 1_000)
        try AgentRunRequestSignal.request(
            at: requestURL,
            sourceDirectory: workspace.source,
            timestamp: now
        )
        XCTAssertEqual(AgentRunRequestSignal.validation(
            at: requestURL,
            sourceDirectory: workspace.source,
            now: now
        ), .valid)
        XCTAssertFalse(AgentRunRequestSignal.isValid(
            at: requestURL,
            sourceDirectory: workspace.root,
            now: now
        ))
        XCTAssertFalse(AgentRunRequestSignal.isValid(
            at: requestURL,
            sourceDirectory: workspace.source,
            now: now.addingTimeInterval(AgentRunRequestSignal.maximumAge + 1)
        ))
        XCTAssertTrue(AgentRunRequestSignal.consumeIfValid(
            at: requestURL,
            sourceDirectory: workspace.source,
            now: now
        ))
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(requestURL))

        try FileManager.default.createDirectory(at: workspace.state, withIntermediateDirectories: true)
        let manualRequest = """
        {
          "request_id": "00000000-0000-4000-8000-000000000001",
          "source_directory": "\(workspace.source.path)",
          "timestamp": "1970-01-01T00:16:40Z",
          "version": 1
        }
        """
        try Data(manualRequest.utf8).write(to: requestURL)
        XCTAssertEqual(AgentRunRequestSignal.validation(
            at: requestURL,
            sourceDirectory: workspace.source,
            now: now
        ), .sourceMismatch)
        let canonicalManualRequest = manualRequest.replacingOccurrences(
            of: workspace.source.path,
            with: ConfigurationIO.canonicalURL(workspace.source).path
        )
        try Data(canonicalManualRequest.utf8).write(to: requestURL)
        XCTAssertEqual(AgentRunRequestSignal.validation(
            at: requestURL,
            sourceDirectory: workspace.source,
            now: now
        ), .valid)
    }

    func testCodeSigningRequirementMatchesOnlyCurrentSignedCode() throws {
#if os(macOS)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let requirement = try CodeSigningRequirement.designatedRequirement(for: executableURL)
        XCTAssertTrue(requirement.contains("identifier") || requirement.contains("cdhash"))
        XCTAssertTrue(try CodeSigningRequirement.currentProcessSatisfies(requirement))
        XCTAssertFalse(try CodeSigningRequirement.currentProcessSatisfies(
            "identifier \"io.github.bugroo.tidydrop.invalid-peer\""
        ))
#else
        throw XCTSkip("code-signing requirements are macOS-only")
#endif
    }

    func testSecurityScopedBookmarkRoundTripBalancesAccess() throws {
#if os(macOS)
        let workspace = try TemporaryWorkspace()
        let data = try SecurityScopedBookmark.create(for: workspace.source)
        XCTAssertTrue(data.count <= SecurityScopedBookmark.maximumBytes)
        let resolved = try SecurityScopedBookmark.resolve(data)
        XCTAssertEqual(resolved.url, ConfigurationIO.canonicalURL(workspace.source))
        XCTAssertFalse(resolved.isStale)
        let accessedPath = try SecurityScopedBookmark.withAccess(to: data) { accessible in
            let metadata = try FileSystemSecurity.freshPOSIXMetadata(of: accessible.url)
            XCTAssertEqual(metadata.kind, .directory)
            return accessible.url.path
        }
        XCTAssertEqual(accessedPath, ConfigurationIO.canonicalURL(workspace.source).path)
#else
        throw XCTSkip("security-scoped bookmarks are macOS-only")
#endif
    }

    func testXPCMutualCodeSigningRequirementAcceptsAndRejects() throws {
#if os(macOS)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let currentRequirement = try CodeSigningRequirement.designatedRequirement(for: executableURL)

        func invoke(serverRequirement: String, clientRequirement: String) -> String? {
            let listener = NSXPCListener.anonymous()
            let delegate = SignedXPCProbeListenerDelegate(clientRequirement: clientRequirement)
            listener.delegate = delegate
            listener.resume()

            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: SignedXPCProbeProtocol.self)
            connection.setCodeSigningRequirement(serverRequirement)
            let semaphore = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var result: String?
            connection.invalidationHandler = { semaphore.signal() }
            connection.interruptionHandler = { semaphore.signal() }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                semaphore.signal()
            } as? SignedXPCProbeProtocol
            proxy?.ping { value in
                resultLock.lock()
                result = value
                resultLock.unlock()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
            connection.invalidate()
            listener.invalidate()
            resultLock.lock()
            defer { resultLock.unlock() }
            return result
        }

        XCTAssertEqual(
            invoke(serverRequirement: currentRequirement, clientRequirement: currentRequirement),
            "tidydrop-xpc-ok"
        )
        XCTAssertEqual(
            invoke(
                serverRequirement: "identifier \"io.github.bugroo.tidydrop.invalid-server\"",
                clientRequirement: currentRequirement
            ),
            nil
        )
        XCTAssertEqual(
            invoke(
                serverRequirement: currentRequirement,
                clientRequirement: "identifier \"io.github.bugroo.tidydrop.invalid-client\""
            ),
            nil
        )
#else
        throw XCTSkip("XPC signing requirements are macOS-only")
#endif
    }

    func testReleaseVersionParsingIsStrictAndOverflowSafe() {
        let community = ReleaseVersion.parse(tag: "v1.2.0-community.2", channel: .community)
        XCTAssertEqual(community?.major, 1)
        XCTAssertEqual(community?.minor, 2)
        XCTAssertEqual(community?.patch, 0)
        XCTAssertEqual(community?.communitySequence, 2)
        XCTAssertEqual(community?.tag, "v1.2.0-community.2")

        let stable = ReleaseVersion.parse(tag: "v2.0.1", channel: .stable)
        XCTAssertEqual(stable?.tag, "v2.0.1")
        XCTAssertEqual(stable?.channel, .stable)

        let invalid: [(String, UpdateChannel)] = [
            ("1.2.0-community.2", .community),
            ("v1.2-community.2", .community),
            ("v1.2.0-community.0", .community),
            ("v1.2.0-community.02", .community),
            ("v01.2.0-community.2", .community),
            ("v1.2.0-community.-1", .community),
            ("v1.2.0-community.2-extra", .community),
            ("v1.2.0", .community),
            ("v1.2.0-community.2", .stable),
            ("v1.2.0-beta", .stable),
            ("v1.2.999999999999999999999999999999", .stable),
            ("v1.2.0-communitý.2", .community)
        ]
        for (tag, channel) in invalid {
            XCTAssertEqual(ReleaseVersion.parse(tag: tag, channel: channel), nil, tag)
        }
    }

    func testCommunityReleaseSelectionRejectsDraftStableMalformedAndDowngrade() {
        guard let current = ReleaseVersion.parse(tag: "v1.2.0-community.2", channel: .community) else {
            XCTAssertTrue(false, "Current Community version must parse")
            return
        }
        let releases = [
            ReleaseMetadata(tagName: "v9.0.0-community.1", draft: true, prerelease: true),
            ReleaseMetadata(tagName: "v8.0.0-community.1", draft: false, prerelease: false),
            ReleaseMetadata(tagName: "v7.0.0", draft: false, prerelease: false),
            ReleaseMetadata(tagName: "v1.2.0-community.2", draft: false, prerelease: true),
            ReleaseMetadata(tagName: "v1.1.9-community.99", draft: false, prerelease: true),
            ReleaseMetadata(tagName: "v1.2.0-community.latest", draft: false, prerelease: true),
            ReleaseMetadata(
                tagName: "v1.2.0-community.4",
                name: "TidyDrop 1.2 Community Preview 4",
                draft: false,
                prerelease: true,
                publishedAt: "2026-08-14T12:00:00Z"
            ),
            ReleaseMetadata(tagName: "v1.2.0-community.3", draft: false, prerelease: true)
        ]
        let selected = ReleaseSelectionPolicy.latestNewerRelease(
            in: releases,
            channel: .community,
            currentVersion: current
        )
        XCTAssertEqual(selected?.version.tag, "v1.2.0-community.4")
        XCTAssertEqual(selected?.displayName, "TidyDrop 1.2 Community Preview 4")
        XCTAssertEqual(
            selected?.officialPageURL.absoluteString,
            "https://github.com/bugroo/tidydrop/releases/tag/v1.2.0-community.4"
        )
    }

    func testStableReleaseSelectionRejectsPrereleaseAndDowngrade() {
        guard let current = ReleaseVersion.parse(tag: "v1.2.0", channel: .stable) else {
            XCTAssertTrue(false, "Current stable version must parse")
            return
        }
        let releases = [
            ReleaseMetadata(tagName: "v2.0.0-community.1", draft: false, prerelease: true),
            ReleaseMetadata(tagName: "v9.0.0", draft: false, prerelease: true),
            ReleaseMetadata(tagName: "v1.2.0", draft: false, prerelease: false),
            ReleaseMetadata(tagName: "v1.1.9", draft: false, prerelease: false),
            ReleaseMetadata(tagName: "v1.3.0", draft: false, prerelease: false)
        ]
        let selected = ReleaseSelectionPolicy.latestNewerRelease(
            in: releases,
            channel: .stable,
            currentVersion: current
        )
        XCTAssertEqual(selected?.version.tag, "v1.3.0")
    }

    func testReleaseSelectionIsBoundedAndChannelLocked() {
        guard let current = ReleaseVersion.parse(tag: "v1.2.0-community.2", channel: .community),
              let stableCurrent = ReleaseVersion.parse(tag: "v1.2.0", channel: .stable) else {
            XCTAssertTrue(false, "Current versions must parse")
            return
        }
        var releases = Array(repeating:
            ReleaseMetadata(tagName: "invalid", draft: false, prerelease: true),
            count: ReleaseSelectionPolicy.maximumReleaseCount
        )
        releases.append(
            ReleaseMetadata(tagName: "v99.0.0-community.1", draft: false, prerelease: true)
        )
        XCTAssertEqual(
            ReleaseSelectionPolicy.latestNewerRelease(
                in: releases,
                channel: .community,
                currentVersion: current
            ),
            nil
        )
        XCTAssertEqual(
            ReleaseSelectionPolicy.latestNewerRelease(
                in: [],
                channel: .community,
                currentVersion: stableCurrent
            ),
            nil
        )
    }

    func testReleaseDisplayFieldsAreBounded() {
        guard let current = ReleaseVersion.parse(tag: "v1.2.0-community.2", channel: .community) else {
            XCTAssertTrue(false, "Current Community version must parse")
            return
        }
        let oversizedName = String(repeating: "x", count: 161)
        let oversizedDate = String(repeating: "2", count: 65)
        let selected = ReleaseSelectionPolicy.latestNewerRelease(
            in: [ReleaseMetadata(
                tagName: "v1.2.0-community.3",
                name: oversizedName,
                draft: false,
                prerelease: true,
                publishedAt: oversizedDate
            )],
            channel: .community,
            currentVersion: current
        )
        XCTAssertEqual(selected?.displayName, "v1.2.0-community.3")
        XCTAssertEqual(selected?.publishedAt, nil)
    }

    func testReleaseMetadataDecodesOnlyRequiredFields() throws {
        let data = Data(#"[{"tag_name":"v1.2.0-community.3","name":null,"draft":false,"prerelease":true,"published_at":"2026-08-14T12:00:00Z","html_url":"https://attacker.invalid/","body":"ignored"}]"#.utf8)
        let decoded = try JSONDecoder().decode([ReleaseMetadata].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.tagName, "v1.2.0-community.3")
        XCTAssertEqual(decoded.first?.publishedAt, "2026-08-14T12:00:00Z")
    }

    func testSignedReleaseManifestVerifiesCanonicalArtifact() throws {
        let fixture = try SignedReleaseManifestFixture()
        XCTAssertEqual(
            try ReleaseManifestCodec.decodeCanonical(fixture.manifestData),
            fixture.manifest
        )
        XCTAssertEqual(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy()
            ),
            fixture.manifest
        )
    }

    func testReleaseManifestRejectsNonCanonicalAndOversizedEncoding() throws {
        let fixture = try SignedReleaseManifestFixture()
        var lines = String(decoding: fixture.manifestData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines.swapAt(1, 2)
        XCTAssertThrowsError(
            try ReleaseManifestCodec.decodeCanonical(Data(lines.joined(separator: "\n").utf8))
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .nonCanonicalManifest)
        }

        let carriageReturns = Data(
            String(decoding: fixture.manifestData, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\r\n").utf8
        )
        XCTAssertThrowsError(try ReleaseManifestCodec.decodeCanonical(carriageReturns)) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .invalidEncoding)
        }
        XCTAssertThrowsError(
            try ReleaseManifestCodec.decodeCanonical(
                Data(repeating: 65, count: ReleaseManifest.maximumEncodedBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .oversizedManifest)
        }
    }

    func testReleaseManifestRejectsWrongKeyAndMalformedSignature() throws {
        let fixture = try SignedReleaseManifestFixture()
        let unrelatedSigner = Curve25519.Signing.PrivateKey()
        let cases: [(Data, Data, ReleaseManifestFailure)] = [
            (unrelatedSigner.publicKey.rawRepresentation, fixture.signature, .invalidSignature),
            (fixture.publicKey, Data(fixture.signature.dropLast()), .invalidSignature),
            (Data(repeating: 0, count: 31), fixture.signature, .invalidPublicKey)
        ]
        for (publicKey, signature, expected) in cases {
            XCTAssertThrowsError(
                try ReleaseManifestVerifier.verify(
                    manifestData: fixture.manifestData,
                    signature: signature,
                    publicKey: publicKey,
                    artifactURL: fixture.artifactURL,
                    policy: fixture.policy()
                )
            ) { error in
                XCTAssertEqual(error as? ReleaseManifestFailure, expected)
            }
        }

        let replacementPrefix = fixture.manifest.artifactSHA256.first == "0" ? "1" : "0"
        let alteredDigest = replacementPrefix + fixture.manifest.artifactSHA256.dropFirst()
        let alteredManifest = Data(
            String(decoding: fixture.manifestData, as: UTF8.self)
                .replacingOccurrences(
                    of: fixture.manifest.artifactSHA256,
                    with: String(alteredDigest)
                ).utf8
        )
        XCTAssertThrowsError(
            try ReleaseManifestVerifier.verify(
                manifestData: alteredManifest,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy()
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .invalidSignature)
        }
    }

    func testReleaseManifestRejectsChannelDowngradeAndIdentityMismatch() throws {
        let fixture = try SignedReleaseManifestFixture()
        guard let stableCurrent = ReleaseVersion.parse(tag: "v1.3.0", channel: .stable),
              let sameVersion = ReleaseVersion.parse(
                  tag: "v1.3.0-community.2",
                  channel: .community
              ) else {
            XCTFail("Policy versions must parse")
            return
        }
        let cases: [(ReleaseManifestPolicy, ReleaseManifestFailure)] = [
            (fixture.policy(currentVersion: stableCurrent, channel: .stable), .wrongChannel),
            (fixture.policy(currentVersion: sameVersion), .downgrade),
            (fixture.policy(bundleIdentifier: "io.github.attacker.tidydrop"), .wrongBundleIdentifier),
            (fixture.policy(artifactName: "TidyDrop-unexpected.dmg"), .wrongArtifactName)
        ]
        for (policy, expected) in cases {
            XCTAssertThrowsError(
                try ReleaseManifestVerifier.verify(
                    manifestData: fixture.manifestData,
                    signature: fixture.signature,
                    publicKey: fixture.publicKey,
                    artifactURL: fixture.artifactURL,
                    policy: policy
                )
            ) { error in
                XCTAssertEqual(error as? ReleaseManifestFailure, expected)
            }
        }
    }

    func testReleaseManifestRejectsReplayStaleAndFuturePublication() throws {
        let fixture = try SignedReleaseManifestFixture()
        let cases: [(ReleaseManifestPolicy, ReleaseManifestFailure)] = [
            (fixture.policy(newestAcceptedPublication: fixture.manifest.publishedAt), .replay),
            (
                fixture.policy(
                    now: fixture.manifest.publishedAt.addingTimeInterval(121),
                    maximumManifestAge: 120
                ),
                .staleManifest
            ),
            (
                fixture.policy(
                    now: fixture.manifest.publishedAt.addingTimeInterval(-61),
                    futureTolerance: 60
                ),
                .futurePublication
            )
        ]
        for (policy, expected) in cases {
            XCTAssertThrowsError(
                try ReleaseManifestVerifier.verify(
                    manifestData: fixture.manifestData,
                    signature: fixture.signature,
                    publicKey: fixture.publicKey,
                    artifactURL: fixture.artifactURL,
                    policy: policy
                )
            ) { error in
                XCTAssertEqual(error as? ReleaseManifestFailure, expected)
            }
        }
    }

    func testReleaseManifestHashesArtifactAndEnforcesBounds() throws {
        let fixture = try SignedReleaseManifestFixture()
        XCTAssertThrowsError(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy(maximumArtifactBytes: UInt64(fixture.artifactData.count - 1))
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .oversizedArtifact)
        }

        try Data(repeating: 120, count: fixture.artifactData.count).write(
            to: fixture.artifactURL,
            options: .atomic
        )
        XCTAssertThrowsError(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy()
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .artifactDigestMismatch)
        }

        try fixture.artifactData.write(to: fixture.artifactURL, options: .atomic)
        var longerArtifact = fixture.artifactData
        longerArtifact.append(0)
        try longerArtifact.write(to: fixture.artifactURL, options: .atomic)
        XCTAssertThrowsError(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy()
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .artifactLengthMismatch)
        }

        try fixture.artifactData.write(to: fixture.artifactURL, options: .atomic)
        XCTAssertThrowsError(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy(
                    currentSystem: OperatingSystemVersion(
                        majorVersion: 12,
                        minorVersion: 6,
                        patchVersion: 0
                    )
                )
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .unsupportedSystem)
        }
    }

    func testReleaseManifestRejectsSymlinkAndUnsafeArtifactNames() throws {
        let fixture = try SignedReleaseManifestFixture()
        let unsafeManifest = ReleaseManifest(
            version: fixture.manifest.version,
            channel: fixture.manifest.channel,
            bundleIdentifier: fixture.manifest.bundleIdentifier,
            artifactName: "../TidyDrop.dmg",
            artifactLength: fixture.manifest.artifactLength,
            artifactSHA256: fixture.manifest.artifactSHA256,
            minimumMacOS: fixture.manifest.minimumMacOS,
            publishedAt: fixture.manifest.publishedAt
        )
        XCTAssertThrowsError(try ReleaseManifestCodec.encode(unsafeManifest)) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .invalidField("artifact-name"))
        }

        let target = fixture.workspace.root.appendingPathComponent("artifact-target.dmg")
        try fixture.artifactData.write(to: target)
        try FileManager.default.removeItem(at: fixture.artifactURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.artifactURL,
            withDestinationURL: target
        )
        XCTAssertThrowsError(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: fixture.artifactURL,
                policy: fixture.policy()
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestFailure, .invalidArtifact)
        }
    }

    func testPrivateUpdateStagingFinalizesDescriptorBoundArtifact() throws {
        let fixture = try SignedReleaseManifestFixture()
        let parent = fixture.workspace.root.appendingPathComponent("private-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )

        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: 1_024 * 1_024
        )
        let split = fixture.artifactData.count / 2
        try writer.append(fixture.artifactData.prefix(split))
        try writer.append(fixture.artifactData.suffix(from: split))
        let staged = try writer.finish()

        XCTAssertEqual(staged.byteCount, UInt64(fixture.artifactData.count))
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), fixture.artifactData)
        var fileMetadata = stat()
        XCTAssertEqual(lstat(staged.fileURL.path, &fileMetadata), 0)
        XCTAssertEqual(fileMetadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(fileMetadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(fileMetadata.st_nlink, 1)
        XCTAssertEqual(UInt64(fileMetadata.st_dev), staged.deviceID)
        XCTAssertEqual(UInt64(fileMetadata.st_ino), staged.inode)

        var workspaceMetadata = stat()
        XCTAssertEqual(lstat(staged.workspaceURL.path, &workspaceMetadata), 0)
        XCTAssertEqual(workspaceMetadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(workspaceMetadata.st_mode & 0o777, 0o700)
        XCTAssertEqual(
            try ReleaseManifestVerifier.verify(
                manifestData: fixture.manifestData,
                signature: fixture.signature,
                publicKey: fixture.publicKey,
                artifactURL: staged.fileURL,
                policy: fixture.policy()
            ),
            fixture.manifest
        )
    }

    func testPrivateUpdateStagingRejectsSymlinkAndBroadParent() throws {
        let fixture = try SignedReleaseManifestFixture()
        let privateParent = fixture.workspace.root.appendingPathComponent("private-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: privateParent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: privateParent.path
        )
        let parentLink = fixture.workspace.root.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: privateParent)
        XCTAssertThrowsError(
            try PrivateUpdateStagingWriter.create(
                in: parentLink,
                authenticatedManifest: try fixture.authenticated(),
                maximumBytes: 1_024 * 1_024
            )
        ) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .unsafeParent)
        }

        let broadParent = fixture.workspace.root.appendingPathComponent("broad-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: broadParent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o777))],
            ofItemAtPath: broadParent.path
        )
        XCTAssertThrowsError(
            try PrivateUpdateStagingWriter.create(
                in: broadParent,
                authenticatedManifest: try fixture.authenticated(),
                maximumBytes: 1_024 * 1_024
            )
        ) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .unsafeParent)
        }
    }

    func testPrivateUpdateStagingBoundsAndCleansPartialWorkspace() throws {
        let fixture = try SignedReleaseManifestFixture()
        let parent = fixture.workspace.root.appendingPathComponent("bounded-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: UInt64(fixture.artifactData.count)
        )
        var oversized = fixture.artifactData
        oversized.append(0)
        XCTAssertThrowsError(try writer.append(oversized)) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .sizeLimitExceeded)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])

        let incomplete = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: UInt64(fixture.artifactData.count)
        )
        try incomplete.append(fixture.artifactData.prefix(1))
        XCTAssertThrowsError(try incomplete.finish()) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .incompleteArtifact)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testPrivateUpdateStagingCancellationCleansPartialWorkspace() throws {
        let fixture = try SignedReleaseManifestFixture()
        let parent = fixture.workspace.root.appendingPathComponent("cancel-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: 1_024 * 1_024
        )
        try writer.append(fixture.artifactData.prefix(2))
        writer.cancel()
        XCTAssertThrowsError(try writer.append(fixture.artifactData)) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testPrivateUpdateStagingDiskFullFaultCleansPartialWorkspace() throws {
        let fixture = try SignedReleaseManifestFixture()
        let parent = fixture.workspace.root.appendingPathComponent("disk-full-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: 1_024 * 1_024,
            faultInjection: .diskFull(afterBytes: 2)
        )
        XCTAssertThrowsError(try writer.append(fixture.artifactData)) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .insufficientSpace)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testPrivateUpdateStagingNeverOverwritesFinalCollision() throws {
        let fixture = try SignedReleaseManifestFixture()
        let parent = fixture.workspace.root.appendingPathComponent("collision-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: 1_024 * 1_024
        )
        try writer.append(fixture.artifactData)
        let entries = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertEqual(entries.count, 1)
        let collision = parent
            .appendingPathComponent(entries[0], isDirectory: true)
            .appendingPathComponent(fixture.manifest.artifactName)
        let sentinel = Data("do-not-overwrite".utf8)
        try sentinel.write(to: collision)
        XCTAssertThrowsError(try writer.finish()) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .finalizeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: collision), sentinel)
    }

    func testPrivateUpdateStagingRejectsDigestMismatchBeforeFinalization() throws {
        let fixture = try SignedReleaseManifestFixture()
        let parent = fixture.workspace.root.appendingPathComponent("digest-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: try fixture.authenticated(),
            maximumBytes: 1_024 * 1_024
        )
        try writer.append(Data(repeating: 0x78, count: fixture.artifactData.count))
        XCTAssertThrowsError(try writer.finish()) { error in
            XCTAssertEqual(error as? UpdateStagingFailure, .artifactDigestMismatch)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testFixedOriginUpdateTransportBuildsAndSanitizesOfficialURLs() throws {
        let fixture = try SignedReleaseManifestFixture()
        let authenticated = try fixture.authenticated()
        let initial = try FixedOriginUpdateTransport.artifactURL(for: authenticated)
        XCTAssertEqual(initial.scheme, "https")
        XCTAssertEqual(initial.host, "github.com")
        XCTAssertEqual(
            initial.path,
            "/bugroo/tidydrop/releases/download/v1.3.0-community.2/\(fixture.manifest.artifactName)"
        )

        var approved = URLRequest(
            url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/example?token=opaque")!
        )
        approved.setValue("secret", forHTTPHeaderField: "Authorization")
        approved.setValue("tracking=1", forHTTPHeaderField: "Cookie")
        let sanitized = try FixedOriginUpdateTransport.sanitizedRedirect(
            approved,
            initialURL: initial,
            redirectCount: 1
        ).get()
        XCTAssertTrue(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
        XCTAssertTrue(sanitized.value(forHTTPHeaderField: "Cookie") == nil)
        XCTAssertEqual(sanitized.value(forHTTPHeaderField: "Accept-Encoding"), "identity")

        let external = URLRequest(url: URL(string: "https://example.com/update.dmg")!)
        XCTAssertEqual(
            FixedOriginUpdateTransport.sanitizedRedirect(
                external,
                initialURL: initial,
                redirectCount: 1
            ),
            .failure(.redirectRejected)
        )
        XCTAssertEqual(
            FixedOriginUpdateTransport.sanitizedRedirect(
                approved,
                initialURL: initial,
                redirectCount: 4
            ),
            .failure(.tooManyRedirects)
        )
        XCTAssertThrowsError(
            try FixedOriginUpdateTransport.validateResponse(
                statusCode: 200,
                declaredContentLength: Int64(fixture.artifactData.count + 1),
                authenticatedLength: UInt64(fixture.artifactData.count)
            )
        ) { error in
            XCTAssertEqual(
                error as? UpdateTransportFailure,
                .contentLengthMismatch(
                    declared: Int64(fixture.artifactData.count + 1),
                    authenticated: UInt64(fixture.artifactData.count)
                )
            )
        }
    }

    func testFixedOriginUpdateTransportStreamsAuthenticatedArtifact() throws {
#if os(macOS)
        let fixture = try SignedReleaseManifestFixture()
        let parent = try privateTransportParent(fixture: fixture, name: "transport-success")
        UpdateTransportURLProtocol.configure(
            .response(
                data: fixture.artifactData,
                status: 200,
                declaredLength: Int64(fixture.artifactData.count)
            )
        )
        let result = try awaitTransportResult(
            authenticated: fixture.authenticated(),
            parent: parent
        )
        guard case .success(let staged) = result else {
            XCTFail("Authenticated transport should succeed: \(result)")
            return
        }
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), fixture.artifactData)
        let request = UpdateTransportURLProtocol.request()
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Authorization") == nil)
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Cookie") == nil)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
#else
        throw XCTSkip("URLProtocol transport regression requires macOS")
#endif
    }

    func testFixedOriginUpdateTransportRejectsStatusAndCleansStaging() throws {
#if os(macOS)
        let fixture = try SignedReleaseManifestFixture()
        let parent = try privateTransportParent(fixture: fixture, name: "transport-length")
        UpdateTransportURLProtocol.configure(
            .response(
                data: fixture.artifactData,
                status: 503,
                declaredLength: nil
            )
        )
        let result = try awaitTransportResult(
            authenticated: fixture.authenticated(),
            parent: parent
        )
        XCTAssertEqual(result, .failure(.unexpectedStatus(503)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
#else
        throw XCTSkip("URLProtocol transport regression requires macOS")
#endif
    }

    func testFixedOriginUpdateTransportCancellationCleansStaging() throws {
#if os(macOS)
        let fixture = try SignedReleaseManifestFixture()
        let parent = try privateTransportParent(fixture: fixture, name: "transport-cancel")
        UpdateTransportURLProtocol.configure(
            .delayed(data: fixture.artifactData, nanoseconds: 500_000_000)
        )
        let result = try awaitTransportResult(
            authenticated: fixture.authenticated(),
            parent: parent,
            cancelImmediately: true
        )
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
#else
        throw XCTSkip("URLProtocol transport regression requires macOS")
#endif
    }

    func testSafeUpdateBundleInspectorRejectsForgedStagedEvidenceBeforeMount() throws {
#if os(macOS)
        let fixture = try SignedReleaseManifestFixture()
        let parent = try privateUpdateInspectionParent(fixture: fixture, name: "inspection-forged")
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: fixture.authenticated(),
            maximumBytes: 1_024 * 1_024
        )
        try writer.append(fixture.artifactData)
        let staged = try writer.finish()
        let forged = StagedUpdateArtifact(
            fileURL: staged.fileURL,
            workspaceURL: staged.workspaceURL,
            byteCount: staged.byteCount,
            deviceID: staged.deviceID,
            inode: staged.inode + 1
        )
        let policy = UpdateBundleInspectionPolicy(
            authenticatedManifest: try fixture.authenticated(),
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\"",
            maximumEntries: 64,
            maximumUncompressedBytes: 16 * 1_024 * 1_024
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspect(
            stagedArtifact: forged,
            authenticatedManifest: fixture.authenticated(),
            policy: policy
        )) { error in
            XCTAssertEqual(
                error as? UpdateBundleInspectionFailure,
                .unauthenticatedArtifact
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staged.workspaceURL.path),
            [fixture.manifest.artifactName]
        )
#else
        throw XCTSkip("DMG inspection requires macOS")
#endif
    }

    func testSafeUpdateBundleInspectorMountsReadOnlyAndValidatesSignedUniversalApp() throws {
#if os(macOS)
        let buildWorkspace: TemporaryWorkspace?
        let imageURL: URL
        if let suppliedPath = ProcessInfo.processInfo.environment["TIDYDROP_INSPECTION_DMG"],
           !suppliedPath.isEmpty {
            buildWorkspace = nil
            imageURL = URL(fileURLWithPath: suppliedPath).standardizedFileURL
            var suppliedMetadata = stat()
            let status = imageURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.lstat(path, &suppliedMetadata)
            }
            guard status == 0,
                  (suppliedMetadata.st_mode & S_IFMT) == S_IFREG,
                  suppliedMetadata.st_nlink == 1,
                  suppliedMetadata.st_size > 0,
                  suppliedMetadata.st_size <= 128 * 1_024 * 1_024 else {
                throw NSError(domain: "TidyDropTests.SuppliedInspectionDMG", code: 1)
            }
        } else {
            let workspace = try TemporaryWorkspace()
            buildWorkspace = workspace
            imageURL = try makeInspectionDiskImage(
                workspace: workspace,
                bundleIdentifier: "io.github.bugroo.tidydrop",
                universal: true
            )
        }
        let imageData = try withExtendedLifetime(buildWorkspace) {
            try Data(contentsOf: imageURL)
        }
        let fixture = try SignedReleaseManifestFixture(artifactData: imageData)
        let authenticated = try fixture.authenticated()
        let parent = try privateUpdateInspectionParent(fixture: fixture, name: "inspection-success")
        let writer = try PrivateUpdateStagingWriter.create(
            in: parent,
            authenticatedManifest: authenticated,
            maximumBytes: 32 * 1_024 * 1_024
        )
        try writer.append(imageData)
        let staged = try writer.finish()
        let policy = UpdateBundleInspectionPolicy(
            authenticatedManifest: authenticated,
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\"",
            maximumEntries: 1_024,
            maximumUncompressedBytes: 256 * 1_024 * 1_024
        )
        let inspected = try SafeUpdateBundleInspector.inspect(
            stagedArtifact: staged,
            authenticatedManifest: authenticated,
            policy: policy
        )
        XCTAssertEqual(inspected.bundleIdentifier, "io.github.bugroo.tidydrop")
        XCTAssertEqual(inspected.marketingVersion, "1.3.0")
        XCTAssertEqual(inspected.executableName, "TidyDropApp")
        XCTAssertEqual(Set(inspected.architectures), Set(["arm64", "x86_64"]))
        XCTAssertTrue(inspected.entryCount >= 4)
        XCTAssertTrue(inspected.uncompressedRegularBytes > 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staged.workspaceURL.path),
            [fixture.manifest.artifactName]
        )
#else
        throw XCTSkip("DMG inspection requires macOS")
#endif
    }

    func testMountedUpdateBundleInspectionRejectsUnexpectedRootAndBundleSymlink() throws {
#if os(macOS)
        let fixture = try SignedReleaseManifestFixture()
        let policy = UpdateBundleInspectionPolicy(
            authenticatedManifest: try fixture.authenticated(),
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\"",
            maximumEntries: 64,
            maximumUncompressedBytes: 16 * 1_024 * 1_024
        )

        let unexpectedWorkspace = try TemporaryWorkspace()
        let unexpectedRoot = try makeInspectionImageRoot(
            workspace: unexpectedWorkspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true
        )
        try Data("unexpected".utf8).write(
            to: unexpectedRoot.appendingPathComponent("README.txt")
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectMountedRootForTesting(
            unexpectedRoot,
            policy: policy
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .unsafeImageLayout)
        }

        let symlinkWorkspace = try TemporaryWorkspace()
        let symlinkRoot = try makeInspectionImageRoot(
            workspace: symlinkWorkspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true
        )
        let link = symlinkRoot
            .appendingPathComponent("TidyDrop.app/Contents/Resources", isDirectory: true)
            .appendingPathComponent("unsafe-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/private/tmp"
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectMountedRootForTesting(
            symlinkRoot,
            policy: policy
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .unsafeBundleEntry)
        }
#else
        throw XCTSkip("bundle inspection requires macOS")
#endif
    }

    func testMountedUpdateBundleInspectionRejectsWrongIdentityThinBinaryAndTampering() throws {
#if os(macOS)
        let fixture = try SignedReleaseManifestFixture()
        let policy = UpdateBundleInspectionPolicy(
            authenticatedManifest: try fixture.authenticated(),
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\"",
            maximumEntries: 64,
            maximumUncompressedBytes: 16 * 1_024 * 1_024
        )

        let wrongIdentityWorkspace = try TemporaryWorkspace()
        let wrongIdentityRoot = try makeInspectionImageRoot(
            workspace: wrongIdentityWorkspace,
            bundleIdentifier: "com.example.not-tidydrop",
            universal: true
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectMountedRootForTesting(
            wrongIdentityRoot,
            policy: policy
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .wrongBundleIdentifier)
        }

        let thinWorkspace = try TemporaryWorkspace()
        let thinRoot = try makeInspectionImageRoot(
            workspace: thinWorkspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: false
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectMountedRootForTesting(
            thinRoot,
            policy: policy
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .architectureMismatch)
        }

        let nestedThinWorkspace = try TemporaryWorkspace()
        let nestedThinRoot = try makeInspectionImageRoot(
            workspace: nestedThinWorkspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true
        )
        let thinBytes = try Data(contentsOf: nestedThinWorkspace.root.appendingPathComponent(
            "inspection-arm64"
        ))
        let nestedAgent = nestedThinRoot.appendingPathComponent(
            "TidyDrop.app/Contents/Resources/tidydrop-agent"
        )
        try thinBytes.write(to: nestedAgent)
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectMountedRootForTesting(
            nestedThinRoot,
            policy: policy
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .architectureMismatch)
        }

        let tamperedWorkspace = try TemporaryWorkspace()
        let tamperedRoot = try makeInspectionImageRoot(
            workspace: tamperedWorkspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true
        )
        try Data("tampered-after-signing".utf8).write(
            to: tamperedRoot.appendingPathComponent(
                "TidyDrop.app/Contents/Resources/signed-resource.txt"
            )
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectMountedRootForTesting(
            tamperedRoot,
            policy: policy
        )) { error in
            guard case .invalidCodeSignature = error as? UpdateBundleInspectionFailure else {
                XCTFail("Expected invalid code signature, got \(error)")
                return
            }
        }
#else
        throw XCTSkip("bundle inspection requires macOS")
#endif
    }

#if os(macOS)
    private func privateUpdateInspectionParent(
        fixture: SignedReleaseManifestFixture,
        name: String
    ) throws -> URL {
        let parent = fixture.workspace.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        return parent
    }

    private func makeInspectionDiskImage(
        workspace: TemporaryWorkspace,
        bundleIdentifier: String,
        universal: Bool
    ) throws -> URL {
        let root = try makeInspectionImageRoot(
            workspace: workspace,
            bundleIdentifier: bundleIdentifier,
            universal: universal
        )
        let image = workspace.root.appendingPathComponent("inspection.dmg")
        try runInspectionTool(
            "/usr/bin/hdiutil",
            arguments: [
                "create", "-volname", "TidyDrop", "-srcfolder", root.path,
                "-format", "UDZO", "-imagekey", "zlib-level=1", image.path
            ],
            timeout: 60
        )
        return image
    }

    private func makeInspectionImageRoot(
        workspace: TemporaryWorkspace,
        bundleIdentifier: String,
        universal: Bool,
        marketingVersion: String = "1.3.0"
    ) throws -> URL {
        let root = workspace.root.appendingPathComponent(
            "inspection-root-\(UUID().uuidString)",
            isDirectory: true
        )
        let app = root.appendingPathComponent("TidyDrop.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let source = workspace.root.appendingPathComponent("inspection-main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let arm = workspace.root.appendingPathComponent("inspection-arm64")
        try runInspectionTool(
            "/usr/bin/xcrun",
            arguments: [
                "--sdk", "macosx", "clang", "-arch", "arm64",
                "-mmacosx-version-min=13.0", source.path, "-o", arm.path
            ],
            timeout: 30
        )
        let executable = macOS.appendingPathComponent("TidyDropApp")
        if universal {
            let intel = workspace.root.appendingPathComponent("inspection-x86_64")
            try runInspectionTool(
                "/usr/bin/xcrun",
                arguments: [
                    "--sdk", "macosx", "clang", "-arch", "x86_64",
                    "-mmacosx-version-min=13.0", source.path, "-o", intel.path
                ],
                timeout: 30
            )
            try runInspectionTool(
                "/usr/bin/lipo",
                arguments: ["-create", arm.path, intel.path, "-output", executable.path],
                timeout: 30
            )
        } else {
            try FileManager.default.copyItem(at: arm, to: executable)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        let cli = resources.appendingPathComponent("tidydrop")
        let agent = resources.appendingPathComponent("tidydrop-agent")
        try FileManager.default.copyItem(at: executable, to: cli)
        try FileManager.default.copyItem(at: executable, to: agent)
        for nested in [cli, agent] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: nested.path
            )
            try runInspectionTool(
                "/usr/bin/codesign",
                arguments: [
                    "--force", "--sign", "-", "--options", "runtime",
                    "--timestamp=none", nested.path
                ],
                timeout: 30
            )
        }

        let info: [String: Any] = [
            "CFBundleExecutable": "TidyDropApp",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": marketingVersion,
            "CFBundleVersion": "10"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("signed-resource".utf8).write(
            to: resources.appendingPathComponent("signed-resource.txt")
        )
        try runInspectionTool(
            "/usr/bin/codesign",
            arguments: [
                "--force", "--sign", "-", "--identifier", bundleIdentifier,
                "--options", "runtime", "--timestamp=none", app.path
            ],
            timeout: 30
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Applications").path,
            withDestinationPath: "/Applications"
        )
        return root
    }

    private func runInspectionTool(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = completed.wait(timeout: .now() + 5)
            throw NSError(domain: "TidyDropTests.UpdateInspectionTimeout", code: 1)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(
                domain: "TidyDropTests.UpdateInspectionTool",
                code: Int(process.terminationStatus)
            )
        }
    }

    func testPrivateRecoverySnapshotPreservesStateAndForcesDryRunBackup() throws {
        let fixture = try SignedReleaseManifestFixture()
        let configURL = fixture.workspace.root.appendingPathComponent("config.json")
        var configuration = try fixture.workspace.makeConfig().config
        configuration.automation.applyEnabled = true
        try ConfigurationIO.save(configuration, to: configURL)

        let resolved = try ConfigurationIO.load(from: configURL)
        try AgentActivityDatabase.record(
            ScheduledRunRecord(
                timestamp: Date(timeIntervalSince1970: 1_786_640_001),
                outcome: .success,
                runID: "recovery-state-run",
                mode: "apply",
                scanned: 1,
                planned: 1,
                moved: 1,
                deferred: 0,
                skipped: 0,
                errors: 0,
                detail: nil,
                sourceDirectory: fixture.workspace.source.path
            ),
            at: resolved.paths.activityDatabaseFile
        )
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(
                at: resolved.paths.activityDatabaseFile,
                limit: 10
            ).map(\.runID),
            ["recovery-state-run"]
        )

        let recoveryParent = try privateRecoveryParent(fixture: fixture, name: "recovery")
        let snapshot = try PrivateUpdateRecoverySnapshotBuilder.prepare(
            configurationURL: configURL,
            recoveryParent: recoveryParent,
            currentVersion: "1.3.0-community.1",
            authenticatedTarget: try fixture.authenticated()
        )

        XCTAssertTrue(try ConfigurationIO.load(from: configURL).config.automation.applyEnabled)
        XCTAssertFalse(
            try ConfigurationIO.load(from: snapshot.configurationBackupURL)
                .config.automation.applyEnabled
        )
        XCTAssertFalse(snapshot.manifest.applyEnabled)
        XCTAssertEqual(snapshot.manifest.configurationSchemaVersion, 1)
        XCTAssertEqual(snapshot.manifest.activitySchemaVersion, AgentActivityDatabase.schemaVersion)
        XCTAssertEqual(snapshot.manifest.configurationSHA256.count, 64)
        XCTAssertEqual(snapshot.manifest.activitySHA256?.count, 64)
        XCTAssertTrue(try FileSystemSecurity.pathEntryExists(snapshot.manifestURL))
        guard let activityBackupURL = snapshot.activityBackupURL else {
            throw NSError(domain: "TidyDropTests.RecoverySnapshot", code: 1)
        }
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(at: activityBackupURL, limit: 10).map(\.runID),
            ["recovery-state-run"]
        )
        for file in [snapshot.configurationBackupURL, snapshot.manifestURL] +
            (snapshot.activityBackupURL.map { [$0] } ?? []) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testPrivateRecoverySnapshotFaultsLeaveNoPublishedWorkspace() throws {
        for fault in [
            UpdateRecoverySnapshotFault.afterConfigurationBackup,
            .afterActivityBackup,
            .beforeManifest
        ] {
            let fixture = try SignedReleaseManifestFixture()
            let configURL = fixture.workspace.root.appendingPathComponent("config.json")
            try ConfigurationIO.save(try fixture.workspace.makeConfig().config, to: configURL)
            if fault != .afterConfigurationBackup {
                let resolved = try ConfigurationIO.load(from: configURL)
                try AgentActivityDatabase.record(
                    ScheduledRunRecord(
                        outcome: .success,
                        runID: "fault-backup-run",
                        mode: "dry-run"
                    ),
                    at: resolved.paths.activityDatabaseFile
                )
            }
            let recoveryParent = try privateRecoveryParent(
                fixture: fixture,
                name: "recovery-\(UUID().uuidString)"
            )
            XCTAssertThrowsError(
                try PrivateUpdateRecoverySnapshotBuilder.prepare(
                    configurationURL: configURL,
                    recoveryParent: recoveryParent,
                    currentVersion: "1.3.0-community.1",
                    authenticatedTarget: try fixture.authenticated(),
                    fault: fault
                )
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    at: recoveryParent,
                    includingPropertiesForKeys: nil
                ).count,
                0
            )
        }
    }

    func testPrivateRecoverySnapshotRejectsSymlinkParentAndDatabase() throws {
        let fixture = try SignedReleaseManifestFixture()
        let configURL = fixture.workspace.root.appendingPathComponent("config.json")
        try ConfigurationIO.save(try fixture.workspace.makeConfig().config, to: configURL)
        let authenticated = try fixture.authenticated()

        let realParent = try privateRecoveryParent(fixture: fixture, name: "real-recovery")
        let linkedParent = fixture.workspace.root.appendingPathComponent("linked-recovery")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        XCTAssertThrowsError(
            try PrivateUpdateRecoverySnapshotBuilder.prepare(
                configurationURL: configURL,
                recoveryParent: linkedParent,
                currentVersion: "1.3.0-community.1",
                authenticatedTarget: authenticated
            )
        )

        let broadParent = fixture.workspace.root.appendingPathComponent(
            "broad-recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: broadParent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: broadParent.path
        )
        XCTAssertThrowsError(
            try PrivateUpdateRecoverySnapshotBuilder.prepare(
                configurationURL: configURL,
                recoveryParent: broadParent,
                currentVersion: "1.3.0-community.1",
                authenticatedTarget: authenticated
            )
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: broadParent.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o755
        )

        let missingParent = fixture.workspace.root.appendingPathComponent(
            "missing-recovery",
            isDirectory: true
        )
        XCTAssertThrowsError(
            try PrivateUpdateRecoverySnapshotBuilder.prepare(
                configurationURL: configURL,
                recoveryParent: missingParent,
                currentVersion: "1.3.0-community.1",
                authenticatedTarget: authenticated
            )
        )
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(missingParent))

        let resolved = try ConfigurationIO.load(from: configURL)
        try FileManager.default.createDirectory(
            at: resolved.paths.stateDirectory,
            withIntermediateDirectories: true
        )
        let outsideDatabase = fixture.workspace.root.appendingPathComponent("outside.sqlite3")
        try Data("not-a-database".utf8).write(to: outsideDatabase)
        try FileManager.default.createSymbolicLink(
            at: resolved.paths.activityDatabaseFile,
            withDestinationURL: outsideDatabase
        )
        let safeParent = try privateRecoveryParent(fixture: fixture, name: "safe-recovery")
        XCTAssertThrowsError(
            try PrivateUpdateRecoverySnapshotBuilder.prepare(
                configurationURL: configURL,
                recoveryParent: safeParent,
                currentVersion: "1.3.0-community.1",
                authenticatedTarget: authenticated
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: safeParent,
                includingPropertiesForKeys: nil
            ).count,
            0
        )
    }

    func testAgentActivityDatabaseBackupHandlesPhysicalTmpPath() throws {
        let fixture = try SignedReleaseManifestFixture()
        guard fixture.workspace.root.path.hasPrefix("/private/tmp/") else {
            throw XCTSkip("physical /private/tmp path is unavailable")
        }
        let physicalDatabase = fixture.workspace.root.appendingPathComponent(
            "physical-state/activity.sqlite3"
        )
        try AgentActivityDatabase.record(
            ScheduledRunRecord(outcome: .success, runID: "physical-path-run"),
            at: physicalDatabase
        )
        let relativeRoot = String(
            fixture.workspace.root.path.dropFirst("/private/tmp/".count)
        )
        let logicalDatabase = URL(
            fileURLWithPath: "/tmp/\(relativeRoot)/physical-state/activity.sqlite3"
        )
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(at: logicalDatabase, limit: 10).map(\.runID),
            ["physical-path-run"]
        )

        let backupDirectory = fixture.workspace.root.appendingPathComponent(
            "physical-backup",
            isDirectory: true
        )
        try FileSystemSecurity.ensurePrivateDirectory(backupDirectory)
        let logicalBackup = URL(
            fileURLWithPath: "/tmp/\(relativeRoot)/physical-backup/activity.sqlite3"
        )
        XCTAssertEqual(
            try AgentActivityDatabase.createVerifiedBackup(
                from: logicalDatabase,
                to: logicalBackup
            ),
            AgentActivityDatabase.schemaVersion
        )
        let backupHeader = try Data(contentsOf: logicalBackup).prefix(20)
        XCTAssertEqual(backupHeader.count, 20)
        XCTAssertEqual(backupHeader[backupHeader.index(backupHeader.startIndex, offsetBy: 18)], 1)
        XCTAssertEqual(backupHeader[backupHeader.index(backupHeader.startIndex, offsetBy: 19)], 1)
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(
            URL(fileURLWithPath: logicalBackup.path + "-wal")
        ))
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(
            URL(fileURLWithPath: logicalBackup.path + "-shm")
        ))
        XCTAssertFalse(try FileSystemSecurity.pathEntryExists(
            URL(fileURLWithPath: logicalBackup.path + "-journal")
        ))
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(at: logicalBackup, limit: 10).map(\.runID),
            ["physical-path-run"]
        )
    }

    func testDryRunStateRestorationRestoresStateWithoutUndoReplay() throws {
        let setup = try makeDryRunStateRestorationSetup(
            name: "state-restore-success",
            includeActivityBackup: true
        )
        let transactionBefore = try Data(contentsOf: setup.transactionSentinel)
        let personalBefore = try Data(contentsOf: setup.personalFile)
        let recoveryJournal = try CurrentBundleRetentionBuilder.loadRecovering(
            locator: setup.transaction.locator
        )
        let snapshotManifest = try JSONDecoder().decode(
            UpdateRecoverySnapshotManifest.self,
            from: Data(
                contentsOf: setup.transaction.workspaceURL.appendingPathComponent(
                    "recovery-manifest.json"
                )
            )
        )
        XCTAssertEqual(snapshotManifest.transactionID, recoveryJournal.transactionID)
        XCTAssertEqual(snapshotManifest.currentVersion, recoveryJournal.currentVersion)
        XCTAssertEqual(snapshotManifest.targetVersion, recoveryJournal.targetVersion)
        XCTAssertEqual(snapshotManifest.bundleIdentifier, recoveryJournal.bundleIdentifier)
        XCTAssertTrue(setup.transaction.workspaceURL.isFileURL)
        XCTAssertFalse(recoveryJournal.applyEnabled)
        XCTAssertEqual(recoveryJournal.stateSnapshotManifestName, "recovery-manifest.json")

        let outcome = try DryRunStateRestorationProtocol.restore(
            locator: setup.transaction.locator,
            configurationURL: setup.configurationURL,
            homeDirectory: setup.fixture.workspace.root
        )
        XCTAssertEqual(outcome.state, .stateRestored)
        XCTAssertTrue(outcome.configurationRestored)
        XCTAssertTrue(outcome.activityDatabaseRestored)
        XCTAssertFalse(outcome.applyEnabled)
        XCTAssertFalse(
            try ConfigurationIO.load(
                from: setup.configurationURL,
                homeDirectory: setup.fixture.workspace.root
            ).config.automation.applyEnabled
        )
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(
                at: setup.activityDatabaseURL,
                limit: 10
            ).map(\.runID),
            ["before-update-run"]
        )
        XCTAssertEqual(try Data(contentsOf: setup.transactionSentinel), transactionBefore)
        XCTAssertEqual(try Data(contentsOf: setup.personalFile), personalBefore)
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: setup.transaction.locator
            ).state,
            .stateRestored
        )

        let oldConfiguration = setup.configurationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".tidydrop-config-restore-\(setup.transaction.journal.transactionID).next"
            )
        XCTAssertTrue(
            try ConfigurationIO.load(
                from: oldConfiguration,
                homeDirectory: setup.fixture.workspace.root
            ).config.automation.applyEnabled
        )
        let oldActivity = setup.activityDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".tidydrop-activity-restore-\(setup.transaction.journal.transactionID).next"
            )
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(at: oldActivity, limit: 10).map(\.runID),
            ["after-update-run", "before-update-run"]
        )

        XCTAssertEqual(
            try DryRunStateRestorationProtocol.restore(
                locator: setup.transaction.locator,
                configurationURL: setup.configurationURL,
                homeDirectory: setup.fixture.workspace.root
            ),
            outcome
        )
    }

    func testDryRunStateRestorationRecoversEveryInjectedBoundary() throws {
        for fault in [
            DryRunStateRestorationFault.afterStaging,
            .afterRestorationStarted,
            .afterConfigurationSwap,
            .afterConfigurationJournal,
            .afterActivitySwap
        ] {
            let setup = try makeDryRunStateRestorationSetup(
                name: "state-restore-fault-\(String(describing: fault))",
                includeActivityBackup: true
            )
            XCTAssertThrowsError(try DryRunStateRestorationProtocol.restore(
                locator: setup.transaction.locator,
                configurationURL: setup.configurationURL,
                homeDirectory: setup.fixture.workspace.root,
                supportedConfigurationSchemaVersion: 1,
                supportedActivitySchemaVersion: AgentActivityDatabase.schemaVersion,
                fault: fault
            )) { error in
                XCTAssertEqual(
                    error as? DryRunStateRestorationFailure,
                    .injectedFailure
                )
            }
            let recovered = try DryRunStateRestorationProtocol.restore(
                locator: setup.transaction.locator,
                configurationURL: setup.configurationURL,
                homeDirectory: setup.fixture.workspace.root
            )
            XCTAssertEqual(recovered.state, .stateRestored)
            XCTAssertFalse(
                try ConfigurationIO.load(
                    from: setup.configurationURL,
                    homeDirectory: setup.fixture.workspace.root
                ).config.automation.applyEnabled
            )
            XCTAssertEqual(
                try AgentActivityDatabase.recentRuns(
                    at: setup.activityDatabaseURL,
                    limit: 10
                ).map(\.runID),
                ["before-update-run"]
            )
        }
    }

    func testDryRunStateRestorationRejectsIncompatibleSchemaBeforeMutation() throws {
        let configurationSetup = try makeDryRunStateRestorationSetup(
            name: "state-restore-config-schema",
            includeActivityBackup: true
        )
        let configurationBefore = try Data(contentsOf: configurationSetup.configurationURL)
        XCTAssertThrowsError(try DryRunStateRestorationProtocol.restore(
            locator: configurationSetup.transaction.locator,
            configurationURL: configurationSetup.configurationURL,
            homeDirectory: configurationSetup.fixture.workspace.root,
            supportedConfigurationSchemaVersion: 0,
            supportedActivitySchemaVersion: AgentActivityDatabase.schemaVersion,
            fault: .none
        )) { error in
            XCTAssertEqual(
                error as? DryRunStateRestorationFailure,
                .incompatibleConfigurationSchema
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: configurationSetup.configurationURL),
            configurationBefore
        )
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: configurationSetup.transaction.locator
            ).state,
            .rolledBack
        )

        let activitySetup = try makeDryRunStateRestorationSetup(
            name: "state-restore-activity-schema",
            includeActivityBackup: true
        )
        let activityBefore = try Data(contentsOf: activitySetup.activityDatabaseURL)
        XCTAssertThrowsError(try DryRunStateRestorationProtocol.restore(
            locator: activitySetup.transaction.locator,
            configurationURL: activitySetup.configurationURL,
            homeDirectory: activitySetup.fixture.workspace.root,
            supportedConfigurationSchemaVersion: 1,
            supportedActivitySchemaVersion: 0,
            fault: .none
        )) { error in
            XCTAssertEqual(
                error as? DryRunStateRestorationFailure,
                .incompatibleActivitySchema
            )
        }
        XCTAssertEqual(try Data(contentsOf: activitySetup.activityDatabaseURL), activityBefore)
        XCTAssertTrue(
            try ConfigurationIO.load(
                from: activitySetup.configurationURL,
                homeDirectory: activitySetup.fixture.workspace.root
            ).config.automation.applyEnabled
        )
    }

    func testDryRunStateRestorationRejectsUnsafeDestinationAndBusyDatabase() throws {
        let linkedSetup = try makeDryRunStateRestorationSetup(
            name: "state-restore-linked-parent",
            includeActivityBackup: true
        )
        let linkedParent = linkedSetup.fixture.workspace.root.appendingPathComponent(
            "linked-config-parent",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: linkedSetup.configurationURL.deletingLastPathComponent()
        )
        XCTAssertThrowsError(try DryRunStateRestorationProtocol.restore(
            locator: linkedSetup.transaction.locator,
            configurationURL: linkedParent.appendingPathComponent("config.json"),
            homeDirectory: linkedSetup.fixture.workspace.root
        )) { error in
            XCTAssertEqual(error as? DryRunStateRestorationFailure, .unsafeDestination)
        }

        let busySetup = try makeDryRunStateRestorationSetup(
            name: "state-restore-busy-database",
            includeActivityBackup: true
        )
        var busyDatabase: OpaquePointer?
        XCTAssertEqual(
            busySetup.activityDatabaseURL.path.withCString {
                sqlite3_open_v2(
                    $0,
                    &busyDatabase,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
                    nil
                )
            },
            SQLITE_OK
        )
        guard let busyDatabase else {
            throw StewardError.commandFailed("busy SQLite test could not open database")
        }
        defer {
            _ = sqlite3_exec(busyDatabase, "ROLLBACK;", nil, nil, nil)
            sqlite3_close_v2(busyDatabase)
        }
        XCTAssertEqual(
            sqlite3_exec(
                busyDatabase,
                "BEGIN IMMEDIATE; UPDATE agent_runs SET detail='busy' WHERE run_id='after-update-run';",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertThrowsError(try DryRunStateRestorationProtocol.restore(
            locator: busySetup.transaction.locator,
            configurationURL: busySetup.configurationURL,
            homeDirectory: busySetup.fixture.workspace.root
        )) { error in
            XCTAssertEqual(error as? DryRunStateRestorationFailure, .liveStateBusy)
        }
        XCTAssertTrue(
            try ConfigurationIO.load(
                from: busySetup.configurationURL,
                homeDirectory: busySetup.fixture.workspace.root
            ).config.automation.applyEnabled
        )
    }

    func testDryRunStateRestorationWithoutActivityBackupPreservesDerivedState() throws {
        let setup = try makeDryRunStateRestorationSetup(
            name: "state-restore-no-activity-backup",
            includeActivityBackup: false
        )
        let activityBefore = try Data(contentsOf: setup.activityDatabaseURL)
        let outcome = try DryRunStateRestorationProtocol.restore(
            locator: setup.transaction.locator,
            configurationURL: setup.configurationURL,
            homeDirectory: setup.fixture.workspace.root
        )
        XCTAssertFalse(outcome.activityDatabaseRestored)
        XCTAssertFalse(
            try ConfigurationIO.load(
                from: setup.configurationURL,
                homeDirectory: setup.fixture.workspace.root
            ).config.automation.applyEnabled
        )
        XCTAssertEqual(try Data(contentsOf: setup.activityDatabaseURL), activityBefore)
        XCTAssertEqual(
            try AgentActivityDatabase.recentRuns(
                at: setup.activityDatabaseURL,
                limit: 10
            ).map(\.runID),
            ["after-update-run"]
        )
    }

    func testCurrentBundleRetentionPreservesVerifiedUniversalAppAndPublishesDryRunJournal() throws {
        let setup = try makeCurrentBundleRetentionSetup(name: "retention-success")
        let transaction = try CurrentBundleRetentionBuilder.prepare(
            snapshot: setup.snapshot,
            currentBundleURL: setup.currentBundleURL,
            currentBundlePolicy: setup.policy,
            authenticatedTarget: setup.authenticated
        )
        XCTAssertEqual(transaction.journal.state, .prepared)
        XCTAssertEqual(transaction.journal.sequence, 0)
        XCTAssertFalse(transaction.journal.applyEnabled)
        XCTAssertEqual(transaction.journal.currentVersion, "1.3.0")
        XCTAssertTrue(transaction.journal.retainedBundleEntryCount > 0)
        XCTAssertTrue(transaction.journal.retainedBundleBytes > 0)
        XCTAssertEqual(transaction.journal.retainedBundleTreeSHA256.utf8.count, 64)
        XCTAssertEqual(transaction.journal.stateSnapshotManifestSHA256.utf8.count, 64)
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(transaction: transaction),
            transaction.journal
        )
        let retained = try SafeUpdateBundleInspector.inspectExistingBundle(
            at: transaction.retainedBundleURL,
            policy: setup.policy
        )
        XCTAssertEqual(Set(retained.architectures), Set(["arm64", "x86_64"]))
        XCTAssertEqual(retained.entryCount, transaction.journal.retainedBundleEntryCount)
        XCTAssertEqual(retained.uncompressedRegularBytes, transaction.journal.retainedBundleBytes)
        let workspaceAttributes = try FileManager.default.attributesOfItem(
            atPath: transaction.workspaceURL.path
        )
        let journalAttributes = try FileManager.default.attributesOfItem(
            atPath: transaction.journalURL.path
        )
        XCTAssertEqual(
            (workspaceAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (journalAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertThrowsError(try CurrentBundleRetentionBuilder.prepare(
            snapshot: setup.snapshot,
            currentBundleURL: setup.currentBundleURL,
            currentBundlePolicy: setup.policy,
            authenticatedTarget: setup.authenticated
        )) { error in
            XCTAssertEqual(error as? CurrentBundleRetentionFailure, .invalidRequest)
        }
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(transaction: transaction),
            transaction.journal
        )
    }

    func testCurrentBundleRetentionFaultsCleanOnlyRetainedArtifacts() throws {
        for fault in [
            CurrentBundleRetentionFault.afterDestinationCreation,
            .duringBundleCopy,
            .beforeJournalPublication
        ] {
            let setup = try makeCurrentBundleRetentionSetup(
                name: "retention-fault-\(UUID().uuidString)"
            )
            XCTAssertThrowsError(try CurrentBundleRetentionBuilder.prepare(
                snapshot: setup.snapshot,
                currentBundleURL: setup.currentBundleURL,
                currentBundlePolicy: setup.policy,
                authenticatedTarget: setup.authenticated,
                fault: fault
            )) { error in
                XCTAssertEqual(error as? CurrentBundleRetentionFailure, .injectedFailure)
            }
            let names = Set(try FileManager.default.contentsOfDirectory(
                atPath: setup.snapshot.workspaceURL.path
            ))
            XCTAssertTrue(names.contains("config.dry-run.json"))
            XCTAssertTrue(names.contains("recovery-manifest.json"))
            XCTAssertFalse(names.contains("TidyDrop.app"))
            XCTAssertFalse(names.contains("external-recovery-journal.json"))
            XCTAssertFalse(names.contains("external-recovery-journal.next"))
        }
    }

    func testCurrentBundleRetentionRejectsSymlinkAndTamperedRetainedTree() throws {
        let symlinkSetup = try makeCurrentBundleRetentionSetup(name: "retention-symlink")
        let linkedParent = symlinkSetup.snapshot.workspaceURL.deletingLastPathComponent()
            .appendingPathComponent("linked-current", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedParent, withIntermediateDirectories: false)
        let linkedBundle = linkedParent.appendingPathComponent("TidyDrop.app")
        try FileManager.default.createSymbolicLink(
            atPath: linkedBundle.path,
            withDestinationPath: symlinkSetup.currentBundleURL.path
        )
        XCTAssertThrowsError(try CurrentBundleRetentionBuilder.prepare(
            snapshot: symlinkSetup.snapshot,
            currentBundleURL: linkedBundle,
            currentBundlePolicy: symlinkSetup.policy,
            authenticatedTarget: symlinkSetup.authenticated
        )) { error in
            XCTAssertEqual(error as? CurrentBundleRetentionFailure, .sourceBundleRejected)
        }

        let tamperSetup = try makeCurrentBundleRetentionSetup(name: "retention-tamper")
        let transaction = try CurrentBundleRetentionBuilder.prepare(
            snapshot: tamperSetup.snapshot,
            currentBundleURL: tamperSetup.currentBundleURL,
            currentBundlePolicy: tamperSetup.policy,
            authenticatedTarget: tamperSetup.authenticated
        )
        try Data("tampered-retained-copy".utf8).write(
            to: transaction.retainedBundleURL.appendingPathComponent(
                "Contents/Resources/signed-resource.txt"
            )
        )
        XCTAssertThrowsError(
            try CurrentBundleRetentionBuilder.loadRecovering(transaction: transaction)
        ) { error in
            XCTAssertEqual(error as? CurrentBundleRetentionFailure, .journalInvalid)
        }
    }

    func testExternalRecoveryJournalRecoversSynchronizedNextStateAndRejectsReplay() throws {
        let setup = try makeCurrentBundleRetentionSetup(name: "recovery-journal")
        let transaction = try CurrentBundleRetentionBuilder.prepare(
            snapshot: setup.snapshot,
            currentBundleURL: setup.currentBundleURL,
            currentBundlePolicy: setup.policy,
            authenticatedTarget: setup.authenticated
        )
        let replacement = try CurrentBundleRetentionBuilder.advance(
            transaction: transaction,
            to: .replacementStarted
        )
        XCTAssertEqual(replacement.sequence, 1)
        XCTAssertEqual(replacement.state, .replacementStarted)

        XCTAssertThrowsError(try CurrentBundleRetentionBuilder.advance(
            transaction: transaction,
            to: .newBundleInstalled,
            fault: .afterNextJournalSynchronization
        )) { error in
            XCTAssertEqual(error as? CurrentBundleRetentionFailure, .injectedFailure)
        }
        let recovered = try CurrentBundleRetentionBuilder.loadRecovering(transaction: transaction)
        XCTAssertEqual(recovered.sequence, 2)
        XCTAssertEqual(recovered.state, .newBundleInstalled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: transaction.workspaceURL.appendingPathComponent(
                "external-recovery-journal.next"
            ).path
        ))

        let rollbackStarted = try CurrentBundleRetentionBuilder.advance(
            transaction: transaction,
            to: .rollbackStarted
        )
        XCTAssertEqual(rollbackStarted.state, .rollbackStarted)
        let rolledBack = try CurrentBundleRetentionBuilder.advance(
            transaction: transaction,
            to: .rolledBack
        )
        XCTAssertEqual(rolledBack.state, .rolledBack)
        let committed = try CurrentBundleRetentionBuilder.advance(
            transaction: transaction,
            to: .committed
        )
        XCTAssertEqual(committed.state, .committed)
        XCTAssertFalse(committed.applyEnabled)
        XCTAssertThrowsError(try CurrentBundleRetentionBuilder.advance(
            transaction: transaction,
            to: .replacementStarted
        )) { error in
            XCTAssertEqual(
                error as? CurrentBundleRetentionFailure,
                .journalTransitionRejected
            )
        }
    }

    func testExistingBundleInspectorRejectsWrongVersionAndBundleSymlink() throws {
        let setup = try makeCurrentBundleRetentionSetup(name: "existing-inspection")
        let wrongVersion = ExistingBundleInspectionPolicy(
            bundleIdentifier: setup.policy.bundleIdentifier,
            marketingVersion: "9.9.9",
            codeSigningRequirement: setup.policy.codeSigningRequirement,
            maximumEntries: setup.policy.maximumEntries,
            maximumUncompressedBytes: setup.policy.maximumUncompressedBytes
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectExistingBundle(
            at: setup.currentBundleURL,
            policy: wrongVersion
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .wrongBundleVersion)
        }

        let linkedBundle = setup.currentBundleURL.deletingLastPathComponent()
            .appendingPathComponent("linked", isDirectory: true)
            .appendingPathComponent("TidyDrop.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedBundle.deletingLastPathComponent(),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkedBundle.path,
            withDestinationPath: setup.currentBundleURL.path
        )
        XCTAssertThrowsError(try SafeUpdateBundleInspector.inspectExistingBundle(
            at: linkedBundle,
            policy: setup.policy
        )) { error in
            XCTAssertEqual(error as? UpdateBundleInspectionFailure, .unsafeBundleEntry)
        }
    }

    func testDestinationVolumeReplacementAtomicallyInstallsAndRollsBack() throws {
        let setup = try makeDestinationVolumeReplacementSetup(name: "replacement-success")
        XCTAssertEqual(
            try DestinationVolumeReplacementProtocol.install(
                locator: setup.transaction.locator,
                destinationParentURL: setup.destinationParent
            ),
            .newBundleInstalled
        )
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: setup.transaction.locator
            ).state,
            .newBundleInstalled
        )
        _ = try SafeUpdateBundleInspector.inspectExistingBundle(
            at: setup.installedBundle,
            policy: setup.targetPolicy
        )
        _ = try SafeUpdateBundleInspector.inspectExistingBundle(
            at: setup.candidateBundle,
            policy: setup.currentPolicy
        )

        XCTAssertEqual(
            try DestinationVolumeReplacementProtocol.rollback(
                locator: setup.transaction.locator,
                destinationParentURL: setup.destinationParent
            ),
            .rolledBack
        )
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: setup.transaction.locator
            ).state,
            .rolledBack
        )
        _ = try SafeUpdateBundleInspector.inspectExistingBundle(
            at: setup.installedBundle,
            policy: setup.currentPolicy
        )
        _ = try SafeUpdateBundleInspector.inspectExistingBundle(
            at: setup.candidateBundle,
            policy: setup.targetPolicy
        )
    }

    func testDestinationVolumeReplacementRecoversBothInterruptedSwaps() throws {
        let installSetup = try makeDestinationVolumeReplacementSetup(
            name: "replacement-interrupted-install"
        )
        XCTAssertThrowsError(try DestinationVolumeReplacementProtocol.install(
            locator: installSetup.transaction.locator,
            destinationParentURL: installSetup.destinationParent,
            fault: .afterInstallSwap
        )) { error in
            XCTAssertEqual(
                error as? DestinationVolumeReplacementFailure,
                .injectedFailure
            )
        }
        XCTAssertEqual(
            try DestinationVolumeReplacementProtocol.recover(
                locator: installSetup.transaction.locator,
                destinationParentURL: installSetup.destinationParent
            ),
            .newBundleInstalled
        )
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: installSetup.transaction.locator
            ).state,
            .newBundleInstalled
        )

        XCTAssertThrowsError(try DestinationVolumeReplacementProtocol.rollback(
            locator: installSetup.transaction.locator,
            destinationParentURL: installSetup.destinationParent,
            fault: .afterRollbackSwap
        )) { error in
            XCTAssertEqual(
                error as? DestinationVolumeReplacementFailure,
                .injectedFailure
            )
        }
        XCTAssertEqual(
            try DestinationVolumeReplacementProtocol.recover(
                locator: installSetup.transaction.locator,
                destinationParentURL: installSetup.destinationParent
            ),
            .rolledBack
        )
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: installSetup.transaction.locator
            ).state,
            .rolledBack
        )
    }

    func testDestinationVolumeReplacementResumesBeforeEitherSwap() throws {
        let installSetup = try makeDestinationVolumeReplacementSetup(
            name: "replacement-before-install"
        )
        XCTAssertThrowsError(try DestinationVolumeReplacementProtocol.install(
            locator: installSetup.transaction.locator,
            destinationParentURL: installSetup.destinationParent,
            fault: .afterReplacementStarted
        )) { error in
            XCTAssertEqual(error as? DestinationVolumeReplacementFailure, .injectedFailure)
        }
        XCTAssertEqual(
            try DestinationVolumeReplacementProtocol.recover(
                locator: installSetup.transaction.locator,
                destinationParentURL: installSetup.destinationParent
            ),
            .newBundleInstalled
        )

        XCTAssertThrowsError(try DestinationVolumeReplacementProtocol.rollback(
            locator: installSetup.transaction.locator,
            destinationParentURL: installSetup.destinationParent,
            fault: .afterRollbackStarted
        )) { error in
            XCTAssertEqual(error as? DestinationVolumeReplacementFailure, .injectedFailure)
        }
        XCTAssertEqual(
            try DestinationVolumeReplacementProtocol.recover(
                locator: installSetup.transaction.locator,
                destinationParentURL: installSetup.destinationParent
            ),
            .rolledBack
        )
    }

    func testDestinationVolumeReplacementRejectsInstalledScopeAndSymlinkCandidate() throws {
        let scopeSetup = try makeDestinationVolumeReplacementSetup(
            name: "replacement-scope"
        )
        XCTAssertThrowsError(try DestinationVolumeReplacementProtocol.install(
            locator: scopeSetup.transaction.locator,
            destinationParentURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )) { error in
            XCTAssertEqual(
                error as? DestinationVolumeReplacementFailure,
                .nonShippingScopeRequired
            )
        }
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: scopeSetup.transaction.locator
            ).state,
            .prepared
        )

        let symlinkSetup = try makeDestinationVolumeReplacementSetup(
            name: "replacement-symlink"
        )
        try FileManager.default.removeItem(at: symlinkSetup.candidateBundle)
        try FileManager.default.createSymbolicLink(
            at: symlinkSetup.candidateBundle,
            withDestinationURL: symlinkSetup.installedBundle
        )
        XCTAssertThrowsError(try DestinationVolumeReplacementProtocol.install(
            locator: symlinkSetup.transaction.locator,
            destinationParentURL: symlinkSetup.destinationParent
        ))
        XCTAssertEqual(
            try CurrentBundleRetentionBuilder.loadRecovering(
                locator: symlinkSetup.transaction.locator
            ).state,
            .prepared
        )
    }

    func testRecoveryHelperSurvivesProcessKillAtEveryDurableBoundary() throws {
        let helperURL = try recoveryHelperExecutableURL()
        let cases: [(DestinationVolumeReplacementCheckpoint, String, ExternalRecoveryState)] = [
            (.replacementStarted, "install", .newBundleInstalled),
            (.installSwapSynchronized, "install", .newBundleInstalled),
            (.rollbackStarted, "rollback", .rolledBack),
            (.rollbackSwapSynchronized, "rollback", .rolledBack)
        ]

        for (checkpoint, command, expectedState) in cases {
            let setup = try makeDestinationVolumeReplacementSetup(
                name: "process-kill-\(checkpoint.rawValue)"
            )
            if command == "rollback" {
                let installed = try runRecoveryHelper(
                    helperURL: helperURL,
                    command: "install",
                    locator: setup.transaction.locator,
                    destinationParent: setup.destinationParent
                )
                guard installed.status == 0,
                      installed.output.contains("outcome=newBundleInstalled") else {
                    throw processHarnessError("helper could not prepare rollback: \(installed.error)")
                }
            }

            try killRecoveryHelper(
                helperURL: helperURL,
                command: command,
                checkpoint: checkpoint,
                locator: setup.transaction.locator,
                destinationParent: setup.destinationParent
            )
            let recovered = try runRecoveryHelper(
                helperURL: helperURL,
                command: "recover",
                locator: setup.transaction.locator,
                destinationParent: setup.destinationParent
            )
            guard recovered.status == 0 else {
                throw processHarnessError("helper recovery failed: \(recovered.error)")
            }
            XCTAssertEqual(
                try CurrentBundleRetentionBuilder.loadRecovering(
                    locator: setup.transaction.locator
                ).state,
                expectedState
            )

            switch expectedState {
            case .newBundleInstalled:
                XCTAssertTrue(recovered.output.contains("outcome=newBundleInstalled"))
                _ = try SafeUpdateBundleInspector.inspectExistingBundle(
                    at: setup.installedBundle,
                    policy: setup.targetPolicy
                )
                _ = try SafeUpdateBundleInspector.inspectExistingBundle(
                    at: setup.candidateBundle,
                    policy: setup.currentPolicy
                )
            case .rolledBack:
                XCTAssertTrue(recovered.output.contains("outcome=rolledBack"))
                _ = try SafeUpdateBundleInspector.inspectExistingBundle(
                    at: setup.installedBundle,
                    policy: setup.currentPolicy
                )
                _ = try SafeUpdateBundleInspector.inspectExistingBundle(
                    at: setup.candidateBundle,
                    policy: setup.targetPolicy
                )
            default:
                throw processHarnessError("unexpected terminal recovery state")
            }
        }
    }

    private struct RecoveryHelperResult {
        let status: Int32
        let output: String
        let error: String
    }

    private func recoveryHelperExecutableURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TIDYDROP_RECOVERY_HELPER_BIN"],
              path.hasPrefix("/"),
              URL(fileURLWithPath: path).lastPathComponent == "tidydrop-recovery-helper" else {
            throw processHarnessError("recovery helper path is missing or invalid")
        }
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o111 != 0 else {
            throw processHarnessError("recovery helper is not an owned executable regular file")
        }
        return URL(fileURLWithPath: path)
    }

    private func recoveryHelperArguments(
        command: String,
        locator: ExternalRecoveryTransactionLocator,
        destinationParent: URL
    ) -> [String] {
        [
            command,
            locator.workspaceURL.path,
            locator.transactionID,
            destinationParent.path
        ]
    }

    private func runRecoveryHelper(
        helperURL: URL,
        command: String,
        locator: ExternalRecoveryTransactionLocator,
        destinationParent: URL
    ) throws -> RecoveryHelperResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = recoveryHelperArguments(
            command: command,
            locator: locator,
            destinationParent: destinationParent
        )
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TIDYDROP_RECOVERY_TEST_STOP_AFTER")
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let error = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return RecoveryHelperResult(
            status: process.terminationStatus,
            output: output,
            error: error
        )
    }

    private func killRecoveryHelper(
        helperURL: URL,
        command: String,
        checkpoint: DestinationVolumeReplacementCheckpoint,
        locator: ExternalRecoveryTransactionLocator,
        destinationParent: URL
    ) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = recoveryHelperArguments(
            command: command,
            locator: locator,
            destinationParent: destinationParent
        )
        var environment = ProcessInfo.processInfo.environment
        environment["TIDYDROP_RECOVERY_TEST_STOP_AFTER"] = checkpoint.rawValue
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let markerURL = locator.workspaceURL.appendingPathComponent(checkpoint.markerFileName)
        let deadline = Date().addingTimeInterval(15)
        var markerMetadata = stat()
        var markerReady = false
        while Date() < deadline {
            if markerURL.path.withCString({ Darwin.lstat($0, &markerMetadata) }) == 0 {
                markerReady = true
                break
            }
            if !process.isRunning { break }
            usleep(10_000)
        }
        guard markerReady,
              (markerMetadata.st_mode & S_IFMT) == S_IFREG,
              markerMetadata.st_uid == Darwin.geteuid(),
              markerMetadata.st_mode & 0o777 == 0o600,
              try String(contentsOf: markerURL, encoding: .utf8)
                == "\(checkpoint.rawValue)\n" else {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            let helperError = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw processHarnessError("checkpoint marker was not durable: \(helperError)")
        }

        guard process.isRunning,
              Darwin.kill(process.processIdentifier, SIGKILL) == 0 else {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw processHarnessError("helper was not alive at the kill boundary")
        }
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal,
              process.terminationStatus == SIGKILL else {
            throw processHarnessError("helper did not terminate from SIGKILL")
        }
        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
    }

    private func processHarnessError(_ message: String) -> NSError {
        NSError(
            domain: "TidyDropTests.RecoveryHelperProcess",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func makeDestinationVolumeReplacementSetup(
        name: String
    ) throws -> (
        fixture: SignedReleaseManifestFixture,
        transaction: PreparedExternalRecoveryTransaction,
        destinationParent: URL,
        installedBundle: URL,
        candidateBundle: URL,
        currentPolicy: ExistingBundleInspectionPolicy,
        targetPolicy: ExistingBundleInspectionPolicy
    ) {
        let fixture = try SignedReleaseManifestFixture(
            artifactName: "TidyDrop-1.4.0-community-preview-macos-universal.dmg",
            currentTag: "v1.3.0-community.2",
            nextTag: "v1.4.0-community.1"
        )
        let authenticated = try fixture.authenticated()
        let configurationURL = fixture.workspace.root.appendingPathComponent("\(name)-config.json")
        var configuration = try fixture.workspace.makeConfig().config
        configuration.automation.applyEnabled = true
        try ConfigurationIO.save(configuration, to: configurationURL)
        let recoveryParent = try privateRecoveryParent(
            fixture: fixture,
            name: "\(name)-recovery"
        )
        let snapshot = try PrivateUpdateRecoverySnapshotBuilder.prepare(
            configurationURL: configurationURL,
            recoveryParent: recoveryParent,
            currentVersion: "1.3.0",
            authenticatedTarget: authenticated
        )
        let currentRoot = try makeInspectionImageRoot(
            workspace: fixture.workspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true,
            marketingVersion: "1.3.0"
        )
        let current = currentRoot.appendingPathComponent("TidyDrop.app", isDirectory: true)
        let currentPolicy = ExistingBundleInspectionPolicy(
            bundleIdentifier: "io.github.bugroo.tidydrop",
            marketingVersion: "1.3.0",
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\""
        )
        let transaction = try CurrentBundleRetentionBuilder.prepare(
            snapshot: snapshot,
            currentBundleURL: current,
            currentBundlePolicy: currentPolicy,
            authenticatedTarget: authenticated
        )

        let destination = fixture.workspace.root.appendingPathComponent(
            "\(name)-destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: destination.path
        )
        let installed = destination.appendingPathComponent("TidyDrop.app", isDirectory: true)
        try FileManager.default.copyItem(at: current, to: installed)

        let targetRoot = try makeInspectionImageRoot(
            workspace: fixture.workspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true,
            marketingVersion: "1.4.0"
        )
        let target = targetRoot.appendingPathComponent("TidyDrop.app", isDirectory: true)
        let candidateContainerName = try DestinationVolumeReplacementProtocol.candidateContainerName(
            transactionID: transaction.journal.transactionID
        )
        let candidateContainer = destination.appendingPathComponent(
            candidateContainerName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: candidateContainer,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: candidateContainer.path
        )
        let candidate = candidateContainer.appendingPathComponent(
            "TidyDrop.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: target, to: candidate)
        let targetPolicy = ExistingBundleInspectionPolicy(
            bundleIdentifier: "io.github.bugroo.tidydrop",
            marketingVersion: "1.4.0",
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\""
        )
        return (
            fixture,
            transaction,
            destination,
            installed,
            candidate,
            currentPolicy,
            targetPolicy
        )
    }

    private struct DryRunRestorationSetup {
        let fixture: SignedReleaseManifestFixture
        let transaction: PreparedExternalRecoveryTransaction
        let configurationURL: URL
        let activityDatabaseURL: URL
        let transactionSentinel: URL
        let personalFile: URL
    }

    private func makeDryRunStateRestorationSetup(
        name: String,
        includeActivityBackup: Bool
    ) throws -> DryRunRestorationSetup {
        let fixture = try SignedReleaseManifestFixture()
        let authenticated = try fixture.authenticated()
        let configurationURL = fixture.workspace.root.appendingPathComponent("config.json")
        var configuration = try fixture.workspace.makeConfig().config
        configuration.automation.applyEnabled = true
        try ConfigurationIO.save(configuration, to: configurationURL)
        let resolved = try ConfigurationIO.load(
            from: configurationURL,
            homeDirectory: fixture.workspace.root
        )
        try FileSystemSecurity.ensurePrivateDirectory(resolved.paths.transactionsDirectory)
        let transactionSentinel = resolved.paths.transactionsDirectory.appendingPathComponent(
            "pre-update-transaction.json"
        )
        try Data("transaction-journal-must-not-be-replayed".utf8).write(
            to: transactionSentinel
        )
        let personalFile = try fixture.workspace.createFile(
            "personal-restore-sentinel.txt",
            contents: "personal-content-must-not-move"
        )

        if includeActivityBackup {
            try AgentActivityDatabase.record(
                ScheduledRunRecord(
                    timestamp: Date(timeIntervalSince1970: 1_786_640_001),
                    outcome: .success,
                    runID: "before-update-run",
                    mode: "apply",
                    moved: 1,
                    sourceDirectory: fixture.workspace.source.path
                ),
                at: resolved.paths.activityDatabaseFile
            )
        }
        let recoveryParent = try privateRecoveryParent(
            fixture: fixture,
            name: "\(name)-recovery"
        )
        let snapshot = try PrivateUpdateRecoverySnapshotBuilder.prepare(
            configurationURL: configurationURL,
            recoveryParent: recoveryParent,
            currentVersion: "1.3.0",
            authenticatedTarget: authenticated
        )
        let imageRoot = try makeInspectionImageRoot(
            workspace: fixture.workspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true,
            marketingVersion: "1.3.0"
        )
        let currentBundle = imageRoot.appendingPathComponent("TidyDrop.app", isDirectory: true)
        let currentPolicy = ExistingBundleInspectionPolicy(
            bundleIdentifier: "io.github.bugroo.tidydrop",
            marketingVersion: "1.3.0",
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\""
        )
        let transaction = try CurrentBundleRetentionBuilder.prepare(
            snapshot: snapshot,
            currentBundleURL: currentBundle,
            currentBundlePolicy: currentPolicy,
            authenticatedTarget: authenticated
        )
        _ = try CurrentBundleRetentionBuilder.advance(
            locator: transaction.locator,
            to: .replacementStarted
        )
        _ = try CurrentBundleRetentionBuilder.advance(
            locator: transaction.locator,
            to: .rollbackStarted
        )
        _ = try CurrentBundleRetentionBuilder.advance(
            locator: transaction.locator,
            to: .rolledBack
        )

        configuration.automation.applyEnabled = true
        try ConfigurationIO.save(configuration, to: configurationURL)
        try AgentActivityDatabase.record(
            ScheduledRunRecord(
                timestamp: Date(timeIntervalSince1970: 1_786_640_002),
                outcome: .success,
                runID: "after-update-run",
                mode: "apply",
                moved: 1,
                sourceDirectory: fixture.workspace.source.path
            ),
            at: resolved.paths.activityDatabaseFile
        )
        return DryRunRestorationSetup(
            fixture: fixture,
            transaction: transaction,
            configurationURL: configurationURL,
            activityDatabaseURL: resolved.paths.activityDatabaseFile,
            transactionSentinel: transactionSentinel,
            personalFile: personalFile
        )
    }

    private func makeCurrentBundleRetentionSetup(
        name: String
    ) throws -> (
        fixture: SignedReleaseManifestFixture,
        snapshot: PreparedUpdateRecoverySnapshot,
        currentBundleURL: URL,
        policy: ExistingBundleInspectionPolicy,
        authenticated: AuthenticatedReleaseManifest
    ) {
        let fixture = try SignedReleaseManifestFixture()
        let authenticated = try fixture.authenticated()
        let configurationURL = fixture.workspace.root.appendingPathComponent(
            "\(name)-config.json"
        )
        var configuration = try fixture.workspace.makeConfig().config
        configuration.automation.applyEnabled = true
        try ConfigurationIO.save(configuration, to: configurationURL)
        let recoveryParent = try privateRecoveryParent(
            fixture: fixture,
            name: "\(name)-recovery"
        )
        let snapshot = try PrivateUpdateRecoverySnapshotBuilder.prepare(
            configurationURL: configurationURL,
            recoveryParent: recoveryParent,
            currentVersion: "1.3.0",
            authenticatedTarget: authenticated
        )
        let imageRoot = try makeInspectionImageRoot(
            workspace: fixture.workspace,
            bundleIdentifier: "io.github.bugroo.tidydrop",
            universal: true
        )
        let bundle = imageRoot.appendingPathComponent("TidyDrop.app", isDirectory: true)
        let policy = ExistingBundleInspectionPolicy(
            bundleIdentifier: "io.github.bugroo.tidydrop",
            marketingVersion: "1.3.0",
            codeSigningRequirement: "identifier \"io.github.bugroo.tidydrop\"",
            maximumEntries: 1_024,
            maximumUncompressedBytes: 256 * 1_024 * 1_024
        )
        return (fixture, snapshot, bundle, policy, authenticated)
    }

    private func privateRecoveryParent(
        fixture: SignedReleaseManifestFixture,
        name: String
    ) throws -> URL {
        let parent = fixture.workspace.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        return parent
    }

    private func privateTransportParent(
        fixture: SignedReleaseManifestFixture,
        name: String
    ) throws -> URL {
        let parent = fixture.workspace.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        return parent
    }

    private func awaitTransportResult(
        authenticated: AuthenticatedReleaseManifest,
        parent: URL,
        cancelImmediately: Bool = false
    ) throws -> Result<StagedUpdateArtifact, UpdateTransportFailure> {
        let box = LockedResultBox<Result<StagedUpdateArtifact, UpdateTransportFailure>>()
        let semaphore = DispatchSemaphore(value: 0)
        let operation = try FixedOriginUpdateTransport.startForTesting(
            authenticatedManifest: authenticated,
            stagingParent: parent,
            maximumBytes: 1_024 * 1_024,
            protocolClasses: [UpdateTransportURLProtocol.self]
        ) { result in
            box.store(result)
            semaphore.signal()
        }
        if cancelImmediately { operation.cancel() }
        guard semaphore.wait(timeout: .now() + 5) == .success,
              let result = box.load() else {
            operation.cancel()
            throw NSError(domain: "TidyDropTests.UpdateTransport", code: 1)
        }
        return result
    }
#endif

}


private let suite = TidyDropCoreTests()
private let tests: [(String, () throws -> Void)] = [
    ("testExtensionClassificationUsesLongestCompoundExtension", suite.testExtensionClassificationUsesLongestCompoundExtension),
    ("testKnownExtensionPrecedesNamePattern", suite.testKnownExtensionPrecedesNamePattern),
    ("testExtensionlessDockerfileUsesNamePattern", suite.testExtensionlessDockerfileUsesNamePattern),
    ("testFallbackCategoryUsesCanonicalConfiguredCategoryName", suite.testFallbackCategoryUsesCanonicalConfiguredCategoryName),
    ("testSystemMIMEDetectorUsesNativeFileUtilityWhenAvailable", suite.testSystemMIMEDetectorUsesNativeFileUtilityWhenAvailable),
    ("testMIMEFallbackClassifiesUnknownExtension", suite.testMIMEFallbackClassifiesUnknownExtension),
    ("testExclusionsCoverHiddenTemporarySymlinkAndDirectory", suite.testExclusionsCoverHiddenTemporarySymlinkAndDirectory),
    ("testDryRunDoesNotMoveUnicodeFilename", suite.testDryRunDoesNotMoveUnicodeFilename),
    ("testStabilityRequiresMultipleObservations", suite.testStabilityRequiresMultipleObservations),
    ("testChangeDuringProbeDefersMove", suite.testChangeDuringProbeDefersMove),
    ("testApplyAvoidsCollisionAndPreservesCompoundExtension", suite.testApplyAvoidsCollisionAndPreservesCompoundExtension),
    ("testSecondApplyIsIdempotent", suite.testSecondApplyIsIdempotent),
    ("testDirectoriesApplicationsAndSymlinksAreNeverMoved", suite.testDirectoriesApplicationsAndSymlinksAreNeverMoved),
    ("testCategorySymlinkOutsideDestinationIsRejected", suite.testCategorySymlinkOutsideDestinationIsRejected),
    ("testUndoPreviewAndApplyRestoreLastTransaction", suite.testUndoPreviewAndApplyRestoreLastTransaction),
    ("testUndoRefusesDestinationReplacedByDifferentFileIdentity", suite.testUndoRefusesDestinationReplacedByDifferentFileIdentity),
    ("testJournalSnapshotRejectsDifferentIdentityWithSameMetadata", suite.testJournalSnapshotRejectsDifferentIdentityWithSameMetadata),
    ("testUndoRefusesDestinationModifiedInPlace", suite.testUndoRefusesDestinationModifiedInPlace),
    ("testUndoRefusesToOverwriteNewSourceCollision", suite.testUndoRefusesToOverwriteNewSourceCollision),
    ("testConfigurationRejectsDestinationOutsideSource", suite.testConfigurationRejectsDestinationOutsideSource),
    ("testConfigurationRejectsPathTraversalCategory", suite.testConfigurationRejectsPathTraversalCategory),
    ("testConfigurationRoundTripPreservesApplyFlag", suite.testConfigurationRoundTripPreservesApplyFlag),
    ("testProcessLockRejectsConcurrentExecution", suite.testProcessLockRejectsConcurrentExecution),
    ("testMoveErrorReportedAfterRenameRemainsRecoverableAndUndoable", suite.testMoveErrorReportedAfterRenameRemainsRecoverableAndUndoable),
    ("testUndoErrorReportedAfterRenameIsReconciledWithoutRepeatingMove", suite.testUndoErrorReportedAfterRenameIsReconciledWithoutRepeatingMove),
    ("testInterruptedCompletedMoveIsReconciledAndUndoable", suite.testInterruptedCompletedMoveIsReconciledAndUndoable),
    ("testInterruptedMoveThatNeverHappenedIsMarkedFailedWithoutMoving", suite.testInterruptedMoveThatNeverHappenedIsMarkedFailedWithoutMoving),
    ("testConfigurationRejectsDisablingDestinationContainment", suite.testConfigurationRejectsDisablingDestinationContainment),
    ("testConfigurationRejectsCategoryWhitespaceAtEdges", suite.testConfigurationRejectsCategoryWhitespaceAtEdges),
    ("testAmbiguousInterruptedMoveBlocksNewApply", suite.testAmbiguousInterruptedMoveBlocksNewApply),
    ("testInterruptedAfterMoveCompletionFinalizesManifestStatus", suite.testInterruptedAfterMoveCompletionFinalizesManifestStatus),
    ("testInterruptedUndoMoveIsReconciledAsUndoneWithoutMovingAgain", suite.testInterruptedUndoMoveIsReconciledAsUndoneWithoutMovingAgain),
    ("testCorruptTransactionManifestBlocksApplyWithoutMovingCandidate", suite.testCorruptTransactionManifestBlocksApplyWithoutMovingCandidate),
    ("testManifestFilenameMustMatchRunID", suite.testManifestFilenameMustMatchRunID),
    ("testTransactionRunIDCannotEscapeStateDirectory", suite.testTransactionRunIDCannotEscapeStateDirectory),
    ("testVersion100LoggingConfigDecodesWithSafeDefaults", suite.testVersion100LoggingConfigDecodesWithSafeDefaults),
    ("testBoundedLogsRotateAndRemainLimited", suite.testBoundedLogsRotateAndRemainLimited),
    ("testScheduledNoopCanAvoidAuditAndStabilityWrites", suite.testScheduledNoopCanAvoidAuditAndStabilityWrites),
    ("testScheduledEventfulRunWritesBalancedAuditBoundaries", suite.testScheduledEventfulRunWritesBalancedAuditBoundaries),
    ("testTransactionRetentionPreservesInProgressAndNewestTerminalFiles", suite.testTransactionRetentionPreservesInProgressAndNewestTerminalFiles),
    ("testLogWriterRejectsSymbolicLinkPath", suite.testLogWriterRejectsSymbolicLinkPath),
    ("testFreshSnapshotChangesWhenReusingSameURL", suite.testFreshSnapshotChangesWhenReusingSameURL),
    ("testPOSIXSnapshotPreservesDeviceAndInode", suite.testPOSIXSnapshotPreservesDeviceAndInode),
    ("testFreshSnapshotRejectsSymlinkUsingLstat", suite.testFreshSnapshotRejectsSymlinkUsingLstat),
    ("testSameSizeMtimeChangeDuringProbeDefersMove", suite.testSameSizeMtimeChangeDuringProbeDefersMove),
    ("testChangeImmediatelyBeforeMoveDefersMove", suite.testChangeImmediatelyBeforeMoveDefersMove),
    ("testActiveFolderAcceptsSpacesAndUnicode", suite.testActiveFolderAcceptsSpacesAndUnicode),
    ("testFolderSetAlwaysReturnsToDryRunAndPreservesTransactions", suite.testFolderSetAlwaysReturnsToDryRunAndPreservesTransactions),
    ("testCancelledFolderSelectionDoesNotChangeConfiguration", suite.testCancelledFolderSelectionDoesNotChangeConfiguration),
    ("testFolderResetDownloadsUsesIsolatedHomeAndReturnsToDryRun", suite.testFolderResetDownloadsUsesIsolatedHomeAndReturnsToDryRun),
    ("testDangerousActiveFolderRootsAreRejected", suite.testDangerousActiveFolderRootsAreRejected),
    ("testSystemApplicationsScopeContainingInstalledBundleIsRejected", suite.testSystemApplicationsScopeContainingInstalledBundleIsRejected),
    ("testLaunchAgentStatusRecognizesBundledAgentExecution", suite.testLaunchAgentStatusRecognizesBundledAgentExecution),
    ("testActiveFolderRejectsRootSymlinkAndTraversal", suite.testActiveFolderRejectsRootSymlinkAndTraversal),
    ("testUnavailableSourceFailsSafely", suite.testUnavailableSourceFailsSafely),
    ("testExclusiveMoveNeverOverwritesLateCollision", suite.testExclusiveMoveNeverOverwritesLateCollision),
    ("testEngineNeverOverwritesCollisionCreatedAtRename", suite.testEngineNeverOverwritesCollisionCreatedAtRename),
    ("testExclusiveMoveRejectsCategoryReplacedBySymlink", suite.testExclusiveMoveRejectsCategoryReplacedBySymlink),
    ("testLockRejectsSymbolicLink", suite.testLockRejectsSymbolicLink),
    ("testJSONReaderRejectsSymbolicLinkAndOversizedInput", suite.testJSONReaderRejectsSymbolicLinkAndOversizedInput),
    ("testScheduledDryRunReusesUnchangedPlanWithoutProbeOrLogGrowth", suite.testScheduledDryRunReusesUnchangedPlanWithoutProbeOrLogGrowth),
    ("testMIMEDetectorTimesOutBoundedHelper", suite.testMIMEDetectorTimesOutBoundedHelper),
    ("testConfigurationBoundsRuleCountsAndLengths", suite.testConfigurationBoundsRuleCountsAndLengths),
    ("testAtomicJSONSaveRejectsSymlinkAndUsesPrivatePermissions", suite.testAtomicJSONSaveRejectsSymlinkAndUsesPrivatePermissions),
    ("testScheduledExecutionWritesDryRunSuccessRecord", suite.testScheduledExecutionWritesDryRunSuccessRecord),
    ("testAgentActivityDatabaseMigratesAndReadsNewestFirst", suite.testAgentActivityDatabaseMigratesAndReadsNewestFirst),
    ("testAgentActivityDatabaseReaderDoesNotCreateMissingDatabase", suite.testAgentActivityDatabaseReaderDoesNotCreateMissingDatabase),
    ("testAgentActivityDatabaseRejectsSymlink", suite.testAgentActivityDatabaseRejectsSymlink),
    ("testAgentActivityDatabaseRejectsSymlinkSidecar", suite.testAgentActivityDatabaseRejectsSymlinkSidecar),
    ("testBackgroundVerificationRequiresFreshMatchingSource", suite.testBackgroundVerificationRequiresFreshMatchingSource),
    ("testBackgroundVerificationHonorsModeFreshnessAndMoveSafety", suite.testBackgroundVerificationHonorsModeFreshnessAndMoveSafety),
    ("testScheduledExecutionUnavailableSourceFailsClosed", suite.testScheduledExecutionUnavailableSourceFailsClosed),
    ("testWorkbenchAuditHistoryIsBoundedAndNewestFirst", suite.testWorkbenchAuditHistoryIsBoundedAndNewestFirst),
    ("testWorkbenchAuditHistoryRejectsCorruptRecord", suite.testWorkbenchAuditHistoryRejectsCorruptRecord),
    ("testWorkbenchTransactionHistorySortsAndDerivesUndoableState", suite.testWorkbenchTransactionHistorySortsAndDerivesUndoableState),
    ("testWorkbenchRuleEditReturnsToDryRunAndPreservesTransactions", suite.testWorkbenchRuleEditReturnsToDryRunAndPreservesTransactions),
    ("testWorkbenchRuleEditRejectsInvalidIndex", suite.testWorkbenchRuleEditRejectsInvalidIndex),
    ("testAgentSchedulingFiltersNestedEventsAndAcceptsRecovery", suite.testAgentSchedulingFiltersNestedEventsAndAcceptsRecovery),
    ("testAgentSchedulingUsesOneBoundedFollowUpOnlyWhenNeeded", suite.testAgentSchedulingUsesOneBoundedFollowUpOnlyWhenNeeded),
    ("testAgentSchedulingUsesBackgroundEventCoalescing", suite.testAgentSchedulingUsesBackgroundEventCoalescing),
    ("testAgentRunRequestIsPrivateAndSourceBound", suite.testAgentRunRequestIsPrivateAndSourceBound),
    ("testAgentRunRequestRejectsSymlinkDestination", suite.testAgentRunRequestRejectsSymlinkDestination),
    ("testAgentRunRequestValidationRejectsStaleOrDifferentSource", suite.testAgentRunRequestValidationRejectsStaleOrDifferentSource),
    ("testCodeSigningRequirementMatchesOnlyCurrentSignedCode", suite.testCodeSigningRequirementMatchesOnlyCurrentSignedCode),
    ("testSecurityScopedBookmarkRoundTripBalancesAccess", suite.testSecurityScopedBookmarkRoundTripBalancesAccess),
    ("testXPCMutualCodeSigningRequirementAcceptsAndRejects", suite.testXPCMutualCodeSigningRequirementAcceptsAndRejects),
    ("testReleaseVersionParsingIsStrictAndOverflowSafe", suite.testReleaseVersionParsingIsStrictAndOverflowSafe),
    ("testCommunityReleaseSelectionRejectsDraftStableMalformedAndDowngrade", suite.testCommunityReleaseSelectionRejectsDraftStableMalformedAndDowngrade),
    ("testStableReleaseSelectionRejectsPrereleaseAndDowngrade", suite.testStableReleaseSelectionRejectsPrereleaseAndDowngrade),
    ("testReleaseSelectionIsBoundedAndChannelLocked", suite.testReleaseSelectionIsBoundedAndChannelLocked),
    ("testReleaseDisplayFieldsAreBounded", suite.testReleaseDisplayFieldsAreBounded),
    ("testReleaseMetadataDecodesOnlyRequiredFields", suite.testReleaseMetadataDecodesOnlyRequiredFields),
    ("testSignedReleaseManifestVerifiesCanonicalArtifact", suite.testSignedReleaseManifestVerifiesCanonicalArtifact),
    ("testReleaseManifestRejectsNonCanonicalAndOversizedEncoding", suite.testReleaseManifestRejectsNonCanonicalAndOversizedEncoding),
    ("testReleaseManifestRejectsWrongKeyAndMalformedSignature", suite.testReleaseManifestRejectsWrongKeyAndMalformedSignature),
    ("testReleaseManifestRejectsChannelDowngradeAndIdentityMismatch", suite.testReleaseManifestRejectsChannelDowngradeAndIdentityMismatch),
    ("testReleaseManifestRejectsReplayStaleAndFuturePublication", suite.testReleaseManifestRejectsReplayStaleAndFuturePublication),
    ("testReleaseManifestHashesArtifactAndEnforcesBounds", suite.testReleaseManifestHashesArtifactAndEnforcesBounds),
    ("testReleaseManifestRejectsSymlinkAndUnsafeArtifactNames", suite.testReleaseManifestRejectsSymlinkAndUnsafeArtifactNames),
    ("testPrivateUpdateStagingFinalizesDescriptorBoundArtifact", suite.testPrivateUpdateStagingFinalizesDescriptorBoundArtifact),
    ("testPrivateUpdateStagingRejectsSymlinkAndBroadParent", suite.testPrivateUpdateStagingRejectsSymlinkAndBroadParent),
    ("testPrivateUpdateStagingBoundsAndCleansPartialWorkspace", suite.testPrivateUpdateStagingBoundsAndCleansPartialWorkspace),
    ("testPrivateUpdateStagingCancellationCleansPartialWorkspace", suite.testPrivateUpdateStagingCancellationCleansPartialWorkspace),
    ("testPrivateUpdateStagingDiskFullFaultCleansPartialWorkspace", suite.testPrivateUpdateStagingDiskFullFaultCleansPartialWorkspace),
    ("testPrivateUpdateStagingNeverOverwritesFinalCollision", suite.testPrivateUpdateStagingNeverOverwritesFinalCollision),
    ("testPrivateUpdateStagingRejectsDigestMismatchBeforeFinalization", suite.testPrivateUpdateStagingRejectsDigestMismatchBeforeFinalization),
    ("testFixedOriginUpdateTransportBuildsAndSanitizesOfficialURLs", suite.testFixedOriginUpdateTransportBuildsAndSanitizesOfficialURLs),
    ("testFixedOriginUpdateTransportStreamsAuthenticatedArtifact", suite.testFixedOriginUpdateTransportStreamsAuthenticatedArtifact),
    ("testFixedOriginUpdateTransportRejectsStatusAndCleansStaging", suite.testFixedOriginUpdateTransportRejectsStatusAndCleansStaging),
    ("testFixedOriginUpdateTransportCancellationCleansStaging", suite.testFixedOriginUpdateTransportCancellationCleansStaging),
    ("testSafeUpdateBundleInspectorRejectsForgedStagedEvidenceBeforeMount", suite.testSafeUpdateBundleInspectorRejectsForgedStagedEvidenceBeforeMount),
    ("testSafeUpdateBundleInspectorMountsReadOnlyAndValidatesSignedUniversalApp", suite.testSafeUpdateBundleInspectorMountsReadOnlyAndValidatesSignedUniversalApp),
    ("testMountedUpdateBundleInspectionRejectsUnexpectedRootAndBundleSymlink", suite.testMountedUpdateBundleInspectionRejectsUnexpectedRootAndBundleSymlink),
    ("testMountedUpdateBundleInspectionRejectsWrongIdentityThinBinaryAndTampering", suite.testMountedUpdateBundleInspectionRejectsWrongIdentityThinBinaryAndTampering),
    ("testPrivateRecoverySnapshotPreservesStateAndForcesDryRunBackup", suite.testPrivateRecoverySnapshotPreservesStateAndForcesDryRunBackup),
    ("testPrivateRecoverySnapshotFaultsLeaveNoPublishedWorkspace", suite.testPrivateRecoverySnapshotFaultsLeaveNoPublishedWorkspace),
    ("testPrivateRecoverySnapshotRejectsSymlinkParentAndDatabase", suite.testPrivateRecoverySnapshotRejectsSymlinkParentAndDatabase),
    ("testAgentActivityDatabaseBackupHandlesPhysicalTmpPath", suite.testAgentActivityDatabaseBackupHandlesPhysicalTmpPath),
    ("testDryRunStateRestorationRestoresStateWithoutUndoReplay", suite.testDryRunStateRestorationRestoresStateWithoutUndoReplay),
    ("testDryRunStateRestorationRecoversEveryInjectedBoundary", suite.testDryRunStateRestorationRecoversEveryInjectedBoundary),
    ("testDryRunStateRestorationRejectsIncompatibleSchemaBeforeMutation", suite.testDryRunStateRestorationRejectsIncompatibleSchemaBeforeMutation),
    ("testDryRunStateRestorationRejectsUnsafeDestinationAndBusyDatabase", suite.testDryRunStateRestorationRejectsUnsafeDestinationAndBusyDatabase),
    ("testDryRunStateRestorationWithoutActivityBackupPreservesDerivedState", suite.testDryRunStateRestorationWithoutActivityBackupPreservesDerivedState),
    ("testCurrentBundleRetentionPreservesVerifiedUniversalAppAndPublishesDryRunJournal", suite.testCurrentBundleRetentionPreservesVerifiedUniversalAppAndPublishesDryRunJournal),
    ("testCurrentBundleRetentionFaultsCleanOnlyRetainedArtifacts", suite.testCurrentBundleRetentionFaultsCleanOnlyRetainedArtifacts),
    ("testCurrentBundleRetentionRejectsSymlinkAndTamperedRetainedTree", suite.testCurrentBundleRetentionRejectsSymlinkAndTamperedRetainedTree),
    ("testExternalRecoveryJournalRecoversSynchronizedNextStateAndRejectsReplay", suite.testExternalRecoveryJournalRecoversSynchronizedNextStateAndRejectsReplay),
    ("testExistingBundleInspectorRejectsWrongVersionAndBundleSymlink", suite.testExistingBundleInspectorRejectsWrongVersionAndBundleSymlink),
    ("testDestinationVolumeReplacementAtomicallyInstallsAndRollsBack", suite.testDestinationVolumeReplacementAtomicallyInstallsAndRollsBack),
    ("testDestinationVolumeReplacementRecoversBothInterruptedSwaps", suite.testDestinationVolumeReplacementRecoversBothInterruptedSwaps),
    ("testDestinationVolumeReplacementResumesBeforeEitherSwap", suite.testDestinationVolumeReplacementResumesBeforeEitherSwap),
    ("testDestinationVolumeReplacementRejectsInstalledScopeAndSymlinkCandidate", suite.testDestinationVolumeReplacementRejectsInstalledScopeAndSymlinkCandidate),
]

private let recoveryHelperProcessTests: [(String, () throws -> Void)] = {
    guard ProcessInfo.processInfo.environment["TIDYDROP_RECOVERY_HELPER_BIN"] != nil else {
        return []
    }
    return [
        (
            "testRecoveryHelperSurvivesProcessKillAtEveryDurableBoundary",
            suite.testRecoveryHelperSurvivesProcessKillAtEveryDurableBoundary
        )
    ]
}()

private let availableTests = tests + recoveryHelperProcessTests

private let selectedTests: [(String, () throws -> Void)]
if let filter = ProcessInfo.processInfo.environment["TIDYDROP_SELF_TEST_FILTER"] {
    let requested = filter.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !filter.isEmpty,
          filter.utf8.count <= 4_096,
          requested.count <= 32,
          requested.allSatisfy({ name in
              !name.isEmpty && name.utf8.count <= 160 && name.utf8.allSatisfy {
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                      || ($0 >= 97 && $0 <= 122) || $0 == 95
              }
          }) else {
        print("FALLO: filtro de self-tests inválido")
        exit(2)
    }
    let requestedNames = Set(requested)
    let matches = availableTests.filter { requestedNames.contains($0.0) }
    guard requestedNames.count == requested.count,
          matches.count == requested.count else {
        print("FALLO: filtro de self-tests duplicado o desconocido")
        exit(2)
    }
    selectedTests = matches
} else {
    selectedTests = tests
}

var passed = 0
var skipped = 0
var failed = 0

print("TidyDrop self-tests — sin XCTest")
for (name, body) in selectedTests {
    TestRuntime.reset()
    do {
        try body()
    } catch let skip as XCTSkip {
        skipped += 1
        print("SKIP  \(name): \(skip.description)")
        continue
    } catch {
        TestRuntime.fail("Error no controlado: \(error)", file: #filePath, line: #line)
    }

    if TestRuntime.failures.isEmpty {
        passed += 1
        print("PASS  \(name)")
    } else {
        failed += 1
        print("FAIL  \(name)")
        for failure in TestRuntime.failures {
            print("      \(failure)")
        }
    }
}

print("Resultado: \(passed) PASS, \(skipped) SKIP, \(failed) FAIL; total=\(selectedTests.count)")
exit(failed == 0 ? 0 : 1)
