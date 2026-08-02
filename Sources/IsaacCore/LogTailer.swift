import Foundation

/// Follows the game's log.txt.
///
/// This is the whole run-tracking channel. It is read-only and entirely outside the
/// game: no mod, no injection, no game files touched -- which is the point, since
/// enabling any mod in Afterbirth+ turns Steam achievements off.
///
/// The log is rewritten from scratch on every game launch, so the two things that
/// actually matter here are noticing truncation and surviving the file being
/// replaced underneath us.
public final class LogTailer: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let url: URL
    private let queue = DispatchQueue(label: "IsaacCompanion.logtail")
    private let handler: Handler
    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var partial = ""
    private var pollTimer: DispatchSourceTimer?

    public init(url: URL, handler: @escaping Handler) {
        self.url = url
        self.handler = handler
    }

    public func start() { queue.async { [self] in openAndReplay() } }

    public func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            pollTimer?.cancel()
            pollTimer = nil
            try? handle?.close()
            handle = nil
        }
    }

    /// Reads the file from the beginning, so attaching mid-run reconstructs the
    /// inventory rather than only seeing items picked up from now on.
    private func openAndReplay() {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            scheduleReopen()
            return
        }
        self.handle = handle
        offset = 0
        partial = ""
        drain()
        watch(handle)
    }

    private func watch(_ handle: FileHandle) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // The game replaced the file; reattach to the new one.
                src.cancel()
                self.source = nil
                try? self.handle?.close()
                self.handle = nil
                self.scheduleReopen()
                return
            }
            self.drain()
        }
        src.setCancelHandler { [weak handle] in try? handle?.close() }
        source = src
        src.resume()
    }

    private func scheduleReopen() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            timer.cancel()
            pollTimer = nil
            openAndReplay()
        }
        pollTimer = timer
        timer.resume()
    }

    private func drain() {
        guard let handle else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        // The reset and the lines that follow it go out in ONE callback. Delivered as
        // two, the consumer's actor hop could reorder them and wipe the new run.
        var pending: [String] = []
        // Shrinking means a new game session rewrote the log: start over so the
        // previous run's items are not carried forward.
        if size < offset {
            offset = 0
            partial = ""
            pending.append(LogTailer.resetMarker)
        }

        if (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(), !data.isEmpty {
            offset += UInt64(data.count)
            let text = partial + (String(data: data, encoding: .utf8) ?? "")
            var lines = text.components(separatedBy: "\n")
            // Keep the last fragment: the game may be mid-write on that line.
            partial = lines.removeLast()
            pending.append(contentsOf: lines)
        }

        if !pending.isEmpty { handler(pending) }
    }

    /// Sentinel pushed when the log is truncated, so the reducer can reset.
    public static let resetMarker = "\u{0}ISAAC_COMPANION_LOG_RESET"
}
