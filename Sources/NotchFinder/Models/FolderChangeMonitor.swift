import CoreServices
import Foundation

final class FolderChangeMonitor {
    private final class Receiver {
        let receive: @MainActor ([String], Bool) -> Void

        init(_ receive: @escaping @MainActor ([String], Bool) -> Void) {
            self.receive = receive
        }
    }

    private let stream: FSEventStreamRef

    @MainActor
    init?(directory: URL, receive: @escaping @MainActor ([String], Bool) -> Void) {
        let receiver = Receiver(receive)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(receiver).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Receiver>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                if let pointer { Unmanaged<Receiver>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info,
                  let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let rescans = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount
            )
            let rescan = UnsafeBufferPointer(start: flags, count: count).contains { $0 & rescans != 0 }
            let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { receiver.receive(paths, rescan) }
        }
        let path = directory.resolvingSymlinksInPath().path
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
