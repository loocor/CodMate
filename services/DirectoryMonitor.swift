import Foundation
import Darwin

final class DirectoryMonitor {
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "io.codmate.directorymonitor", qos: .utility)
    private let handler: () -> Void

    init?(url: URL, handler: @escaping () -> Void) {
        self.handler = handler
        guard let descriptor = DirectoryMonitor.openDescriptor(at: url) else { return nil }
        fileDescriptor = descriptor
        configureSource()
    }

    func updateURL(_ url: URL) {
        cancel()
        guard let descriptor = DirectoryMonitor.openDescriptor(at: url) else { return }
        fileDescriptor = descriptor
        configureSource()
    }

    func cancel() {
        source?.cancel()
        source = nil
        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    deinit {
        cancel()
    }

    private func configureSource() {
        guard fileDescriptor != -1 else { return }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            self?.handler()
        }
        newSource.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd != -1 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }
        source = newSource
        newSource.resume()
    }

    private static func openDescriptor(at url: URL) -> CInt? {
        let path = (url as NSURL).fileSystemRepresentation
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return nil }
        return fd
    }
}
