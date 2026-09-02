import Foundation

@available(iOS, deprecated: 16.0, message: "Use Foundation's NSLock.withLock")
extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
