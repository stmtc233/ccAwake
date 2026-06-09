import Darwin
import Foundation

public enum FileLockError: LocalizedError {
    case couldNotOpen(URL, errno: Int32)
    case couldNotLock(URL, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url, let errno):
            return "Could not open lock file \(url.path): errno \(errno)."
        case .couldNotLock(let url, let errno):
            return "Could not lock file \(url.path): errno \(errno)."
        }
    }
}

public struct FileLock: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw FileLockError.couldNotOpen(url, errno: errno)
        }

        if flock(fd, LOCK_EX) != 0 {
            let lockErrno = errno
            close(fd)
            throw FileLockError.couldNotLock(url, errno: lockErrno)
        }

        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        return try body()
    }
}
