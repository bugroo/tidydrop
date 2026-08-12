import Foundation
import TidyDropCore
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private struct XCTSkip: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private enum TestRuntime {
    static var failures: [String] = []

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

private final class RenameThenThrowFileManager: FileManager, @unchecked Sendable {
    private var throwsRemaining: Int

    init(throws: Int = 1) {
        self.throwsRemaining = `throws`
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
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
            fileManager: RenameThenThrowFileManager()
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
            fileManager: RenameThenThrowFileManager()
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
    ("testActiveFolderRejectsRootSymlinkAndTraversal", suite.testActiveFolderRejectsRootSymlinkAndTraversal),
    ("testUnavailableSourceFailsSafely", suite.testUnavailableSourceFailsSafely),
]

var passed = 0
var skipped = 0
var failed = 0

print("TidyDrop self-tests — sin XCTest")
for (name, body) in tests {
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

print("Resultado: \(passed) PASS, \(skipped) SKIP, \(failed) FAIL; total=\(tests.count)")
exit(failed == 0 ? 0 : 1)
