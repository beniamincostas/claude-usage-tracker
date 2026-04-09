import Foundation

final class FileWatcher {
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var fallbackTimer: DispatchSourceTimer?
    private var lastMtime: Date?
    private let filePath: String
    var onChange: (() -> Void)?

    init(filePath: String) {
        self.filePath = filePath
    }

    func start() {
        startDispatchSource()
        startFallbackTimer()
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func startDispatchSource() {
        // Clean up previous source — cancel handler owns the fd close
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1  // old fd will be closed by cancel handler

        fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            self.handleFileChange()
            // File was deleted or renamed (atomic write) — re-establish watcher
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startDispatchSource()
                }
            }
        }
        // Capture the fd value — not self.fileDescriptor — so we close the right one
        // even if startDispatchSource() was called again before this handler fires
        let fdToClose = fileDescriptor
        source.setCancelHandler { [weak self] in
            close(fdToClose)
            if self?.fileDescriptor == fdToClose {
                self?.fileDescriptor = -1
            }
        }
        source.resume()
        dispatchSource = source
    }

    /// Fallback: GCD timer that fires even when RunLoop-based timers are throttled
    private func startFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5.0, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.handleFileChange()
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func handleFileChange() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if lastMtime != mtime {
            lastMtime = mtime
            onChange?()
        }
    }
}
