import CoreServices
import Foundation
import TidyDropCore

struct FileSystemEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags

    var requiresFullScan: Bool {
        let mask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        return flags & mask != 0
    }
}

private let tidyDropFSEventsCallback: FSEventStreamCallback = {
    _, contextInfo, eventCount, eventPathsPointer, eventFlags, _ in
    guard let contextInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
    let paths = unsafeBitCast(eventPathsPointer, to: CFArray.self) as NSArray
    var events: [FileSystemEvent] = []
    events.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        guard let path = paths.object(at: index) as? String else { continue }
        events.append(FileSystemEvent(path: path, flags: eventFlags[index]))
    }
    watcher.deliver(events)
}

final class FSEventsWatcher: @unchecked Sendable {
    private let handler: @Sendable ([FileSystemEvent]) -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], queue: DispatchQueue, handler: @escaping @Sendable ([FileSystemEvent]) -> Void) throws {
        self.handler = handler
#if DEBUG
        if let delayText = ProcessInfo.processInfo.environment[
            "TIDYDROP_TEST_FSEVENTS_SETUP_DELAY_MILLISECONDS"
        ], let delay = UInt32(delayText), delay > 0, delay <= 10_000 {
            usleep(delay * 1_000)
        }
#endif
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            tidyDropFSEventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            AgentSchedulingPolicy.eventStreamLatencySeconds,
            flags
        ) else {
            throw NSError(
                domain: "TidyDrop.FSEvents",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "FSEvents could not create the watcher stream"]
            )
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw NSError(
                domain: "TidyDrop.FSEvents",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "FSEvents could not start the watcher stream"]
            )
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(_ events: [FileSystemEvent]) {
        guard !events.isEmpty else { return }
        handler(events)
    }
}
